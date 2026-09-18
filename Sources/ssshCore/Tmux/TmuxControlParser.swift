import Foundation

/// Something tmux said in control mode.
///
/// Control mode (`tmux -CC`) turns tmux's output into a line protocol: either a
/// notification beginning with `%`, or the output of a command wrapped in
/// `%begin`/`%end`. Everything the app needs — which windows exist, which panes
/// are in them, what each pane printed — arrives this way.
public enum TmuxControlEvent: Hashable, Sendable {
    /// `%output %<pane> <escaped data>` — already unescaped.
    case output(pane: TmuxPaneID, bytes: [UInt8])
    /// A command's reply, correlated by the number tmux echoes back.
    case commandReply(number: Int, lines: [String], isError: Bool)
    case windowAdded(TmuxWindowID)
    case windowClosed(TmuxWindowID)
    case windowRenamed(TmuxWindowID, name: String)
    case layoutChanged(TmuxWindowID, layout: String)
    case sessionChanged(TmuxSessionID, name: String)
    case sessionsChanged
    case paneModeChanged(TmuxPaneID)
    case clientDetached
    /// `%exit` — tmux is leaving control mode, and the terminal goes back to
    /// being an ordinary shell.
    case exited(reason: String?)
    /// A notification this version of sssh does not act on. Kept rather than
    /// dropped so a log shows what a newer tmux is saying.
    case unhandled(name: String, arguments: String)
}

public struct TmuxWindowID: Hashable, Sendable, CustomStringConvertible {
    /// tmux writes these as `@3`. The `@` is not part of the number.
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "@\(rawValue)" }
}

public struct TmuxPaneID: Hashable, Sendable, CustomStringConvertible {
    /// tmux writes these as `%5`.
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "%\(rawValue)" }
}

public struct TmuxSessionID: Hashable, Sendable, CustomStringConvertible {
    /// tmux writes these as `$1`.
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "$\(rawValue)" }
}

/// Turns tmux control-mode bytes into ``TmuxControlEvent``s.
///
/// Incremental: `consume` may be handed any split of the stream, including one
/// that lands mid-line or mid-escape, because that is what arrives over SSH.
///
/// ## The two things that are easy to get wrong
///
/// **`%output` is not text.** tmux escapes only control characters and the
/// backslash, as three-digit octal; every other byte passes through raw,
/// including the high bytes of UTF-8 and of any other encoding the remote
/// program happens to emit. So an output line is a *byte* string that is not
/// necessarily valid UTF-8, and decoding it before unescaping replaces those
/// bytes with U+FFFD — which is corruption that cannot be undone. The output
/// path here therefore never builds a `String`.
///
/// **Command output is bracketed, not tagged.** Between `%begin` and `%end`
/// every line belongs to that command, including lines that start with `%`.
/// A parser that looks for notifications everywhere will mistake a command's
/// output for one.
public struct TmuxControlParser {
    private var buffer: [UInt8] = []
    private var pendingCommand: PendingCommand?

    private struct PendingCommand {
        var number: Int
        var lines: [String]
    }

    public init() {}

    /// Feeds bytes in and returns whatever became complete.
    public mutating func consume(_ bytes: [UInt8]) -> [TmuxControlEvent] {
        buffer.append(contentsOf: bytes)

        var events: [TmuxControlEvent] = []

        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var line = Array(buffer[..<newline])
            buffer.removeFirst(newline + 1)

            // tmux sends CRLF over a PTY.
            if line.last == UInt8(ascii: "\r") {
                line.removeLast()
            }

            if let event = handle(line: line) {
                events.append(event)
            }
        }

        return events
    }

    /// Anything buffered but not yet terminated by a newline. Used when the
    /// stream ends, so a trailing partial line is not silently lost.
    public var unterminatedBytes: [UInt8] { buffer }

    private mutating func handle(line: [UInt8]) -> TmuxControlEvent? {
        // `%output` is handled on bytes, before anything is decoded: its
        // payload is not necessarily valid UTF-8.
        if pendingCommand == nil, let event = outputEvent(line: line) {
            return event
        }

        let text = String(decoding: line, as: UTF8.self)

        // Inside a command's output, everything is output — including lines
        // that happen to begin with `%`.
        if var pending = pendingCommand {
            if text.hasPrefix("%end ") || text.hasPrefix("%error ") {
                let isError = text.hasPrefix("%error ")
                pendingCommand = nil
                return .commandReply(number: pending.number, lines: pending.lines, isError: isError)
            }
            pending.lines.append(text)
            pendingCommand = pending
            return nil
        }

        guard text.hasPrefix("%") else {
            // tmux does not emit bare lines outside a command block. If one
            // appears, it is more useful surfaced than swallowed.
            return text.isEmpty ? nil : .unhandled(name: "", arguments: text)
        }

        let withoutPercent = String(text.dropFirst())
        let name = withoutPercent.prefix(while: { !$0.isWhitespace })
        let arguments = String(withoutPercent.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)

        switch name {
        case "begin":
            // `%begin <timestamp> <number> <flags>`
            let fields = arguments.split(separator: " ")
            let number = fields.count > 1 ? Int(fields[1]) ?? -1 : -1
            pendingCommand = PendingCommand(number: number, lines: [])
            return nil

        case "window-add":
            return Self.windowID(arguments).map { .windowAdded($0) }

        case "window-close", "unlinked-window-close":
            return Self.windowID(arguments).map { .windowClosed($0) }

        case "window-renamed":
            let fields = arguments.split(separator: " ", maxSplits: 1)
            guard let window = Self.windowID(String(fields.first ?? "")) else { return nil }
            return .windowRenamed(window, name: fields.count > 1 ? String(fields[1]) : "")

        case "layout-change":
            let fields = arguments.split(separator: " ")
            guard let window = Self.windowID(String(fields.first ?? "")), fields.count > 1 else { return nil }
            return .layoutChanged(window, layout: String(fields[1]))

        case "session-changed":
            let fields = arguments.split(separator: " ", maxSplits: 1)
            guard let session = Self.sessionID(String(fields.first ?? "")) else { return nil }
            return .sessionChanged(session, name: fields.count > 1 ? String(fields[1]) : "")

        case "sessions-changed":
            return .sessionsChanged

        case "pane-mode-changed":
            return Self.paneID(arguments).map { .paneModeChanged($0) }

        case "client-detached":
            return .clientDetached

        case "exit":
            return .exited(reason: arguments.isEmpty ? nil : arguments)

        default:
            return .unhandled(name: String(name), arguments: arguments)
        }
    }

    private static let outputPrefix = Array("%output ".utf8)

    /// Recognises and decodes `%output %<pane> <bytes>` without decoding the
    /// payload as text.
    private func outputEvent(line: [UInt8]) -> TmuxControlEvent? {
        guard line.starts(with: Self.outputPrefix) else { return nil }

        var rest = line.dropFirst(Self.outputPrefix.count)
        guard let space = rest.firstIndex(of: UInt8(ascii: " ")) else { return nil }

        let identifier = String(decoding: rest[..<space], as: UTF8.self)
        guard let pane = Self.paneID(identifier) else { return nil }

        rest = rest[rest.index(after: space)...]
        return .output(pane: pane, bytes: Self.unescape(Array(rest)))
    }

    // MARK: - Escaping

    /// Undoes tmux's octal escaping.
    ///
    /// tmux escapes a byte as a backslash and three octal digits when it is a
    /// control character or a backslash, and passes everything else through
    /// untouched — including high bytes. So this is bytes in, bytes out, and
    /// never text.
    public static func unescape(_ escaped: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(escaped.count)

        var index = escaped.startIndex
        while index < escaped.endIndex {
            let byte = escaped[index]

            guard byte == UInt8(ascii: "\\") else {
                output.append(byte)
                index += 1
                continue
            }

            if index + 3 < escaped.endIndex,
               let value = octalValue(escaped[index + 1], escaped[index + 2], escaped[index + 3]) {
                output.append(value)
                index += 4
                continue
            }

            // Some versions escape a literal backslash by doubling it.
            if index + 1 < escaped.endIndex, escaped[index + 1] == UInt8(ascii: "\\") {
                output.append(UInt8(ascii: "\\"))
                index += 2
                continue
            }

            // Not an escape after all. Pass the backslash through rather than
            // dropping a byte.
            output.append(byte)
            index += 1
        }

        return output
    }

    /// Convenience for tests and for callers that already have text.
    public static func unescape(_ escaped: String) -> [UInt8] {
        unescape(Array(escaped.utf8))
    }

    private static func octalValue(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8? {
        func digit(_ byte: UInt8) -> UInt8? {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7") else { return nil }
            return byte - UInt8(ascii: "0")
        }
        guard let first = digit(a), let second = digit(b), let third = digit(c) else { return nil }
        let value = Int(first) * 64 + Int(second) * 8 + Int(third)
        guard value <= 0xFF else { return nil }
        return UInt8(value)
    }

    // MARK: - Identifier parsing

    static func paneID(_ text: String) -> TmuxPaneID? {
        guard text.hasPrefix("%"), let value = Int(text.dropFirst()) else { return nil }
        return TmuxPaneID(rawValue: value)
    }

    static func windowID(_ text: String) -> TmuxWindowID? {
        guard text.hasPrefix("@"), let value = Int(text.dropFirst()) else { return nil }
        return TmuxWindowID(rawValue: value)
    }

    static func sessionID(_ text: String) -> TmuxSessionID? {
        guard text.hasPrefix("$"), let value = Int(text.dropFirst()) else { return nil }
        return TmuxSessionID(rawValue: value)
    }
}
