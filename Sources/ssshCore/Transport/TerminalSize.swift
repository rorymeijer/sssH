import Foundation

/// The size of a pseudo-terminal, in both units SSH's `pty-req` carries.
///
/// Character dimensions win when non-zero, which is how OpenSSH behaves; the
/// pixel dimensions are still sent because some full-screen applications use
/// them for sixel/image sizing.
public struct TerminalSize: Hashable, Sendable {
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        // A zero-sized PTY makes curses applications divide by zero. Clamp
        // rather than trap: a SwiftUI view can legitimately report 0x0 for one
        // layout pass before it has a frame.
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
    }

    public static let `default` = TerminalSize(columns: 80, rows: 24)
}

/// The `TERM` value requested for the remote PTY.
public struct TerminalType: Hashable, Sendable, ExpressibleByStringLiteral {
    public var name: String

    public init(_ name: String) { self.name = name }
    public init(stringLiteral value: StringLiteralType) { self.name = value }

    /// What SwiftTerm actually emulates, and what the spike asserts against.
    public static let xterm256Color = TerminalType("xterm-256color")
}

/// Options for one interactive shell channel.
public struct SSHShellConfiguration: Sendable {
    public var terminalType: TerminalType
    public var initialSize: TerminalSize
    /// Sent as `env` requests before the shell starts. Most servers ignore
    /// everything outside `AcceptEnv`.
    public var environment: [String: String]
    /// Written to the shell's stdin once it is running — the per-host
    /// "startup command" from §5.5.
    public var startupCommand: String?

    public init(
        terminalType: TerminalType = .xterm256Color,
        initialSize: TerminalSize = .default,
        environment: [String: String] = [:],
        startupCommand: String? = nil
    ) {
        self.terminalType = terminalType
        self.initialSize = initialSize
        self.environment = environment
        self.startupCommand = startupCommand
    }
}

/// Signals worth sending from a terminal UI.
///
/// Note that Ctrl-C in an interactive session is *not* this: it is the byte
/// 0x03 written to the PTY, which the remote line discipline turns into
/// SIGINT for the foreground process group. This enum is for the cases where
/// there is no PTY, or where the UI offers an explicit "send signal" action.
public enum SSHSignal: String, Sendable, CaseIterable {
    case hup = "HUP"
    case int = "INT"
    case quit = "QUIT"
    case term = "TERM"
    case kill = "KILL"
    case usr1 = "USR1"
    case usr2 = "USR2"
}
