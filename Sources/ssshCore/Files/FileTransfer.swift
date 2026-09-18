import Foundation

/// One file moving in one direction.
///
/// A value type with no IO in it, so the queue's rules — what may retry, what
/// counts as finished, how "42 MB of 300 MB, 8 minutes left" is worked out —
/// can be tested without a server.
public struct FileTransfer: Identifiable, Sendable {
    public enum Direction: String, Sendable, Hashable {
        case upload
        case download
    }

    public enum State: Sendable {
        case waiting
        case running
        case paused
        case finished
        case cancelled
        case failed(String)

        public var isTerminal: Bool {
            switch self {
            case .finished, .cancelled, .failed: return true
            case .waiting, .running, .paused: return false
            }
        }

        public var isActive: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// What to do when the destination already has a file of that name.
    public enum CollisionPolicy: String, Sendable, Hashable, CaseIterable {
        /// Refuse and report. The default, because the other two lose data and
        /// a file browser must not do that on its own.
        case ask
        case replace
        /// Keep both, renaming the incoming one.
        case keepBoth
        /// Continue where a previous attempt stopped. Only offered when the
        /// partial file is shorter than the source: a longer one is not a
        /// partial download, it is a different file.
        case resume
    }

    public let id: UUID
    public let direction: Direction
    /// Absolute path on the remote side.
    public var remotePath: String
    /// Absolute path on this device.
    public var localPath: String
    public var totalBytes: UInt64?
    public var transferredBytes: UInt64
    public var state: State
    public var collisionPolicy: CollisionPolicy
    public var startedAt: Date?
    public var finishedAt: Date?
    /// How many times this has been retried automatically, so a transfer that
    /// keeps dropping stops rather than spinning.
    public var retryCount: Int

    public init(
        id: UUID = UUID(),
        direction: Direction,
        remotePath: String,
        localPath: String,
        totalBytes: UInt64? = nil,
        transferredBytes: UInt64 = 0,
        state: State = .waiting,
        collisionPolicy: CollisionPolicy = .ask,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        retryCount: Int = 0
    ) {
        self.id = id
        self.direction = direction
        self.remotePath = remotePath
        self.localPath = localPath
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.state = state
        self.collisionPolicy = collisionPolicy
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.retryCount = retryCount
    }

    public var name: String {
        RemotePath.lastComponent(of: remotePath)
    }

    /// `nil` when the size is not known — which is normal for an upload of
    /// something still being written, and for a download the server would not
    /// stat. A progress bar must show indeterminate rather than guess.
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    public var isResumable: Bool {
        guard case .failed = state else { return false }
        return true
    }
}

/// Turns byte counts over time into a rate and an estimate.
///
/// A sliding window rather than "bytes ÷ elapsed", because the average over a
/// whole transfer keeps reporting the speed of a link that has since changed,
/// and a remaining-time estimate built on it is wrong in exactly the moments
/// someone is watching it.
public struct TransferRateEstimator: Sendable {
    public struct Sample: Sendable {
        var at: Date
        var bytes: UInt64
    }

    private var samples: [Sample] = []
    private let window: TimeInterval

    public init(window: TimeInterval = 5) {
        self.window = window
    }

    public mutating func record(_ transferredBytes: UInt64, at date: Date = Date()) {
        samples.append(Sample(at: date, bytes: transferredBytes))
        let cutoff = date.addingTimeInterval(-window)
        // Keep one sample from before the cutoff so a rate can still be
        // computed at the start, when there is nothing else to compare with.
        while samples.count > 2, samples[1].at < cutoff {
            samples.removeFirst()
        }
    }

    /// Bytes per second, or `nil` until there is enough to say.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let elapsed = last.at.timeIntervalSince(first.at)
        guard elapsed > 0.2, last.bytes >= first.bytes else { return nil }
        return Double(last.bytes - first.bytes) / elapsed
    }

    public func estimatedTimeRemaining(totalBytes: UInt64?) -> TimeInterval? {
        guard let totalBytes, let rate = bytesPerSecond, rate > 0,
              let last = samples.last, totalBytes > last.bytes
        else {
            return nil
        }
        return Double(totalBytes - last.bytes) / rate
    }

    public mutating func reset() {
        samples.removeAll()
    }
}
