import Foundation
import ssshCore

/// Attaches the local terminal to a remote shell.
///
/// This is the manual half of the Phase 0 proof: the automated checks assert
/// that `vim`, `htop` and a resize behave, but somebody still has to look at
/// `htop` redrawing and drag a window edge. The wiring here is deliberately
/// the same shape as the app's: bytes in from the input device, bytes out to
/// the display, and a size change turned into `window-change`. In the app,
/// SwiftTerm's `TerminalViewDelegate` takes the place of stdin and stdout.
struct InteractiveBridge {
    let session: any SSHShellSession

    func run(initialSize: TerminalSize) async {
        let savedState = LocalTerminal.saveState()
        LocalTerminal.enterRawMode()
        defer { LocalTerminal.restore(savedState) }

        let output = Task { await pumpRemoteOutput() }
        let input = startStdinPump()
        let resize = Task { await pollForResize(startingFrom: initialSize) }

        // The remote shell ending is what ends the session.
        await output.value

        resize.cancel()
        input.cancel()
        await session.close()
    }

    private func pumpRemoteOutput() async {
        do {
            for try await event in session.events {
                switch event {
                case .output(let bytes), .errorOutput(let bytes):
                    FileHandle.standardOutput.write(Data(bytes))
                case .exit(let exit):
                    LocalTerminal.restore(nil)
                    let status = exit.status.map(String.init) ?? exit.signal.map { "signal \($0)" } ?? "unknown"
                    FileHandle.standardError.write(Data("\r\n[sssh-ptyspike] remote shell exited: \(status)\r\n".utf8))
                }
            }
        } catch {
            LocalTerminal.restore(nil)
            FileHandle.standardError.write(Data("\r\n[sssh-ptyspike] session error: \(error)\r\n".utf8))
        }
    }

    /// Reads stdin on a thread of its own.
    ///
    /// `FileHandle.availableData` blocks, and blocking a cooperative-pool
    /// thread would stall the whole concurrency runtime — the one place in this
    /// harness where a plain `Thread` is the right tool.
    private func startStdinPump() -> Task<Void, Never> {
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()

        let thread = Thread {
            while true {
                let data = FileHandle.standardInput.availableData
                if data.isEmpty { break }  // EOF
                continuation.yield(Array(data))
            }
            continuation.finish()
        }
        thread.name = "sssh.spike.stdin"
        thread.start()

        return Task {
            for await chunk in stream {
                if Task.isCancelled { return }
                try? await session.write(chunk[...])
            }
        }
    }

    /// Polls the local window size and forwards changes.
    ///
    /// A `SIGWINCH` handler would be tidier, but a C signal handler cannot
    /// capture context, so it would need process-global mutable state for no
    /// benefit in a harness. `resize(to:)` already ignores a size that has not
    /// changed, so a poll that finds nothing costs one `stty` and no SSH
    /// traffic.
    private func pollForResize(startingFrom initial: TerminalSize) async {
        var lastKnown = LocalTerminal.Size(columns: initial.columns, rows: initial.rows)

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }

            guard let size = LocalTerminal.currentSize(), size != lastKnown else { continue }
            lastKnown = size
            try? await session.resize(to: TerminalSize(columns: size.columns, rows: size.rows))
        }
    }
}
