import Foundation
import ssshCore

/// Accumulates a shell session's output and lets a check wait for a pattern.
///
/// A terminal stream is not line-oriented and arrives in arbitrary chunks, so
/// every check is "wait until the bytes seen so far contain X, or give up after
/// N seconds". Matching against the accumulated buffer rather than each chunk
/// is what lets a prompt split across two packets still match.
///
/// Lock-based rather than an actor: waiters are resumed from whichever thread
/// delivered the data, and an explicit lock keeps that obvious.
final class OutputCollector: @unchecked Sendable {
    struct PatternNotFound: Error, CustomStringConvertible {
        let needle: String
        let timeout: Duration
        let seenTail: String

        var description: String {
            """
            timed out after \(timeout) waiting for \(needle.debugDescription)
            last bytes seen: \(seenTail.debugDescription)
            """
        }
    }

    struct SessionEndedEarly: Error, CustomStringConvertible {
        let exit: SSHShellExit?
        var description: String {
            "session ended before the expected output appeared (exit: \(exit.map(String.init(describing:)) ?? "none"))"
        }
    }

    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var text = ""
    private var totalBytes = 0
    private var exit: SSHShellExit?
    private var failure: Error?
    private var isFinished = false
    private var waiters: [UUID: (needle: String, continuation: CheckedContinuation<Void, Error>)] = [:]

    // MARK: - Consuming

    /// Drains the session for its whole lifetime.
    func consume(_ session: any SSHShellSession) async {
        do {
            for try await event in session.events {
                switch event {
                case .output(let bytes), .errorOutput(let bytes):
                    append(bytes)
                case .exit(let status):
                    lock.lock()
                    exit = status
                    lock.unlock()
                }
            }
            finish(error: nil)
        } catch {
            finish(error: error)
        }
    }

    private func append(_ bytes: [UInt8]) {
        lock.lock()
        buffer.append(contentsOf: bytes)
        totalBytes += bytes.count
        // Decoding the whole buffer each time, rather than per chunk, because a
        // UTF-8 sequence can straddle a packet boundary. `reset()` keeps this
        // from growing without bound across checks.
        text = String(decoding: buffer, as: UTF8.self)

        var matched: [(needle: String, continuation: CheckedContinuation<Void, Error>)] = []
        for (id, waiter) in waiters where text.contains(waiter.needle) {
            matched.append(waiter)
            waiters[id] = nil
        }
        lock.unlock()

        for waiter in matched { waiter.continuation.resume() }
    }

    private func finish(error: Error?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        failure = error
        let pending = Array(waiters.values)
        let exit = self.exit
        waiters.removeAll()
        lock.unlock()

        for waiter in pending {
            waiter.continuation.resume(throwing: error ?? SessionEndedEarly(exit: exit))
        }
    }

    // MARK: - Inspecting

    var collectedText: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    /// Bytes received since the session started, across resets — the
    /// throughput check needs this.
    var bytesReceived: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    var exitStatus: SSHShellExit? {
        lock.lock()
        defer { lock.unlock() }
        return exit
    }

    func tail(_ count: Int = 300) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(text.suffix(count))
    }

    /// Forgets what has been seen, so the next `expect` cannot match the echo
    /// of an earlier command.
    func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        text = ""
        lock.unlock()
    }

    // MARK: - Waiting

    func expect(_ needle: String, timeout: Duration = .seconds(15)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitForMatch(needle) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PatternNotFound(needle: needle, timeout: timeout, seenTail: self.tail())
            }

            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func waitForMatch(_ needle: String) async throws {
        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()

                if text.contains(needle) {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if isFinished {
                    let error = failure ?? SessionEndedEarly(exit: exit)
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }

                waiters[id] = (needle: needle, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}
