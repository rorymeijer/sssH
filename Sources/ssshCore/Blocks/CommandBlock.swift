import Foundation

/// One command and the output it produced.
///
/// A block is a view of the terminal stream, not a replacement for it. The
/// emulator still receives every byte and still renders the session as a
/// continuous screen; the block store keeps a parallel, bounded record so the
/// session can be navigated, searched and copied from in units a person thinks
/// in — "that failed build", not "somewhere around line 4000".
public struct CommandBlock: Identifiable, Sendable {
    public enum State: Hashable, Sendable {
        /// The prompt is on screen and the user is typing.
        case prompting
        /// The command is running.
        case running
        /// The command finished. `exitStatus` is `nil` when the shell did not
        /// report one, which is the normal case without shell integration —
        /// and is shown as "unknown", never as success.
        case finished(exitStatus: Int32?)
    }

    public let id: UUID
    /// The command as text, once it is known.
    ///
    /// With `OSC 633 ; E` this is exact. With `OSC 133` alone it is recovered
    /// from the echoed bytes between `B` and `C`. Without shell integration it
    /// is what the user typed, reconstructed from the input stream.
    public var command: String
    /// The prompt the command was typed at, when it is known.
    ///
    /// Only the fallback mode fills this in, and only because it has to: the
    /// line it reads is prompt and command together, and separating them is
    /// both possible and necessary. Shell integration marks the command
    /// directly and never needs it.
    public var prompt: String
    /// Captured output bytes, truncated at ``CommandBlockStore`` limits.
    public var output: [UInt8]
    /// True when output was dropped because the block outgrew its cap.
    public var outputTruncated: Bool
    public var state: State
    public var startedAt: Date
    public var finishedAt: Date?
    /// True when the block was produced by the input-driven fallback rather
    /// than by shell integration, so the UI can be honest about it: the end of
    /// a fallback block is "where the next command started", not "where the
    /// output stopped".
    public var isHeuristic: Bool

    public init(
        id: UUID = UUID(),
        command: String = "",
        prompt: String = "",
        output: [UInt8] = [],
        outputTruncated: Bool = false,
        state: State = .prompting,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        isHeuristic: Bool = false
    ) {
        self.id = id
        self.command = command
        self.prompt = prompt
        self.output = output
        self.outputTruncated = outputTruncated
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.isHeuristic = isHeuristic
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// `nil` when the command is still running, or when nothing reported a
    /// status. Callers must not read the absence of a failure as success.
    public var exitStatus: Int32? {
        if case .finished(let status) = state { return status }
        return nil
    }

    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    /// The output as text, with escape sequences removed.
    ///
    /// The first line is dropped when it is empty, because it usually is: the
    /// shell echoes the newline of the user's Return before the command writes
    /// anything, and a blank first line in every block reads like a bug.
    public var outputText: String {
        let text = PlainText.extract(from: output[...])
        return text.hasPrefix("\n") ? String(text.dropFirst()) : text
    }

    /// The output as lines, matching ``outputText``. Line numbers in search
    /// results are indices into this.
    public var outputLines: [String] {
        var lines = PlainText.lines(from: output[...])
        if lines.first?.isEmpty == true { lines.removeFirst() }
        return lines
    }
}
