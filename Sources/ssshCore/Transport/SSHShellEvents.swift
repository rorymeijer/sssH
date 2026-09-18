import Foundation

/// Something the remote end of an interactive channel produced.
public enum SSHShellEvent: Sendable {
    /// Bytes from the channel's normal data stream. With a PTY allocated this
    /// carries both stdout and stderr, because the PTY merges them — which is
    /// why the terminal only ever needs to feed this one stream.
    case output([UInt8])
    /// Bytes from SSH's extended data stream. Only appears when no PTY was
    /// requested (i.e. `exec` mode), and is kept separate so command blocks can
    /// tell the two apart.
    case errorOutput([UInt8])
    /// The remote process ended. Always the last event.
    case exit(SSHShellExit)
}

public struct SSHShellExit: Hashable, Sendable {
    /// The process's exit status, if the server sent `exit-status`.
    public var status: Int32?
    /// The signal that killed it, if the server sent `exit-signal` instead.
    public var signal: String?

    public init(status: Int32? = nil, signal: String? = nil) {
        self.status = status
        self.signal = signal
    }

    public var isSuccess: Bool { status == 0 && signal == nil }
}

/// A single-consumer stream of shell events with real backpressure.
///
/// Why not `AsyncThrowingStream`: its buffering policies are unbounded (a
/// `cat` of a large file balloons memory until the terminal catches up) or
/// lossy (`bufferingNewest`, which corrupts a terminal stream — dropped bytes
/// are dropped escape sequences). This type instead lets the *producer* ask
/// whether to keep reading, so the backend can stop calling `read()` on the
/// SSH channel and let the window fill up, which is what the SSH flow-control
/// window is for.
///
/// Exactly one task may iterate a stream. Iterating twice is a programmer
/// error and traps.
public struct SSHShellEventStream: AsyncSequence, Sendable {
    public typealias Element = SSHShellEvent

    private let sink: SSHShellEventSink

    internal init(sink: SSHShellEventSink) {
        self.sink = sink
    }

    public func makeAsyncIterator() -> AsyncIterator {
        sink.claimConsumer()
        return AsyncIterator(sink: sink)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let sink: SSHShellEventSink

        internal init(sink: SSHShellEventSink) {
            self.sink = sink
        }

        public mutating func next() async throws -> SSHShellEvent? {
            try await sink.next()
        }
    }
}

/// The producer half of an ``SSHShellEventStream``.
///
/// Lives in `ssshCore` rather than in the backend so that the buffering rules
/// are testable without a network, and identical for every backend.
public final class SSHShellEventSink: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Stop reading from the channel once this many bytes are queued.
        public var highWaterMark: Int
        /// Resume reading once the queue drops back to this.
        public var lowWaterMark: Int

        public init(highWaterMark: Int = 1 << 20, lowWaterMark: Int = 1 << 18) {
            precondition(lowWaterMark <= highWaterMark, "low water mark must not exceed high water mark")
            self.highWaterMark = highWaterMark
            self.lowWaterMark = lowWaterMark
        }

        public static let `default` = Configuration()
    }

    private enum Termination {
        case running
        case finished(Error?)
    }

    private let lock = NSLock()
    private let configuration: Configuration

    // All of the following are guarded by `lock`.
    private var queue: [SSHShellEvent] = []
    private var queueHead = 0
    private var bufferedBytes = 0
    private var termination: Termination = .running
    private var waiter: CheckedContinuation<SSHShellEvent?, Error>?
    private var readsSuspended = false
    private var consumerClaimed = false
    private var requestMore: (@Sendable () -> Void)?

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// The stream handed to the consumer. Create it once.
    public func makeStream() -> SSHShellEventStream {
        SSHShellEventStream(sink: self)
    }

    /// Wires the "please read more from the channel" callback. The backend sets
    /// this to something that hops onto its event loop and issues a read.
    public func onDemandForMoreData(_ body: @escaping @Sendable () -> Void) {
        lock.lock()
        requestMore = body
        lock.unlock()
    }

    // MARK: - Producer side

    /// Enqueue one event. Safe to call from the transport's event loop.
    public func push(_ event: SSHShellEvent) {
        lock.lock()

        guard case .running = termination else {
            // Late data after the channel was closed. Dropping it is correct:
            // the consumer has already been told the session ended.
            lock.unlock()
            return
        }

        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: event)
            return
        }

        queue.append(event)
        bufferedBytes += Self.byteCount(of: event)
        lock.unlock()
    }

    /// Whether the producer should keep pulling data out of the channel.
    ///
    /// Call this after each batch of reads. When it returns `false` the
    /// producer must stop reading; the sink will invoke the
    /// ``onDemandForMoreData(_:)`` callback once the consumer has drained
    /// enough to make room.
    public func shouldContinueReading() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if case .finished = termination { return false }

        if bufferedBytes >= configuration.highWaterMark {
            readsSuspended = true
            return false
        }
        return true
    }

    /// Terminate the stream. `error` is delivered to the consumer after any
    /// already-queued events, so output produced just before a failure is not
    /// lost.
    public func finish(throwing error: Error? = nil) {
        lock.lock()

        guard case .running = termination else {
            lock.unlock()
            return
        }
        termination = .finished(error)

        if let waiter, queueHead == queue.count {
            self.waiter = nil
            lock.unlock()
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: nil)
            }
            return
        }

        lock.unlock()
    }

    // MARK: - Consumer side

    internal func claimConsumer() {
        lock.lock()
        let alreadyClaimed = consumerClaimed
        consumerClaimed = true
        lock.unlock()
        precondition(!alreadyClaimed, "SSHShellEventStream supports a single consumer")
    }

    internal func next() async throws -> SSHShellEvent? {
        // Poll first: the common case under load is that data is already
        // queued, and that path must not suspend.
        switch poll() {
        case .event(let event): return event
        case .finished: return nil
        case .failed(let error): throw error
        case .pending: break
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SSHShellEvent?, Error>) in
                // Re-poll under the lock before parking, so that a `push` or a
                // `finish` that landed between the poll above and here is not
                // missed. `cancelWaiter` may already have run (if the task was
                // cancelled before we got here), which shows up as a
                // `.finished(CancellationError)` termination.
                lock.lock()

                if let event = takeQueuedEventLocked() {
                    let resume = shouldResumeReadingLocked()
                    lock.unlock()
                    resume?()
                    continuation.resume(returning: event)
                    return
                }

                if case .finished(let error) = termination {
                    lock.unlock()
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: nil)
                    }
                    return
                }

                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            cancelWaiter()
        }
    }

    private enum Poll {
        case event(SSHShellEvent)
        case finished
        case failed(Error)
        case pending
    }

    private func poll() -> Poll {
        lock.lock()

        if let event = takeQueuedEventLocked() {
            let resume = shouldResumeReadingLocked()
            lock.unlock()
            resume?()
            return .event(event)
        }

        if case .finished(let error) = termination {
            lock.unlock()
            return error.map(Poll.failed) ?? .finished
        }

        lock.unlock()
        return .pending
    }

    /// Must be called with `lock` held.
    private func takeQueuedEventLocked() -> SSHShellEvent? {
        guard queueHead < queue.count else { return nil }
        let event = queue[queueHead]
        // Drop our reference to the payload straight away rather than waiting
        // for the next compaction, so a paused consumer does not pin buffers.
        queue[queueHead] = .output([])
        queueHead += 1
        bufferedBytes -= Self.byteCount(of: event)
        compactIfNeededLocked()
        return event
    }

    private func cancelWaiter() {
        lock.lock()
        guard let waiter else {
            lock.unlock()
            return
        }
        self.waiter = nil
        termination = .finished(CancellationError())
        lock.unlock()
        waiter.resume(throwing: CancellationError())
    }

    /// Must be called with `lock` held. Returns the callback to invoke *after*
    /// unlocking, if reads should resume.
    private func shouldResumeReadingLocked() -> (@Sendable () -> Void)? {
        guard readsSuspended, bufferedBytes <= configuration.lowWaterMark else { return nil }
        readsSuspended = false
        return requestMore
    }

    /// Must be called with `lock` held.
    private func compactIfNeededLocked() {
        guard queueHead > 0, queueHead == queue.count || queueHead >= 64 else { return }
        queue.removeFirst(queueHead)
        queueHead = 0
    }

    private static func byteCount(of event: SSHShellEvent) -> Int {
        switch event {
        case .output(let bytes), .errorOutput(let bytes): return bytes.count
        case .exit: return 0
        }
    }
}
