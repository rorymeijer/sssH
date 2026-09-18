import Foundation

/// Local-terminal control for the harness's interactive mode.
///
/// Implemented by shelling out to `stty` rather than by importing `termios`
/// and calling `ioctl`. `ioctl` is a C variadic function and so is not
/// reliably importable into Swift, and `TIOCGWINSZ` is a macro that expands
/// differently on Darwin and Linux. `stty` is portable, already installed
/// wherever this harness runs, and this is a developer tool where spawning a
/// process for a window-size poll costs nothing that matters.
///
/// The app itself never needs any of this: SwiftTerm reports its own size.
struct LocalTerminal {
    struct Size: Equatable {
        var columns: Int
        var rows: Int
    }

    /// The opaque `stty -g` string, to be handed back to ``restore(_:)``.
    static func saveState() -> String? {
        run(["-g"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hands every keystroke straight through, so Ctrl-C and arrow keys reach
    /// the remote shell instead of being interpreted locally.
    static func enterRawMode() {
        _ = run(["raw", "-echo", "-isig", "-ixon"])
    }

    static func restore(_ state: String?) {
        if let state, !state.isEmpty {
            _ = run([state])
        } else {
            _ = run(["sane"])
        }
    }

    static func currentSize() -> Size? {
        guard let output = run(["size"]) else { return nil }
        let parts = output.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count >= 2, let rows = Int(parts[0]), let columns = Int(parts[1]) else { return nil }
        return Size(columns: columns, rows: rows)
    }

    private static func run(_ arguments: [String]) -> String? {
        guard let tty = FileHandle(forReadingAtPath: "/dev/tty") else { return nil }
        defer { try? tty.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `stty` must read the controlling terminal, not our (possibly
        // redirected) stdin, hence the explicit redirect.
        process.arguments = ["-c", "stty \(arguments.joined(separator: " ")) < /dev/tty"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = tty

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
