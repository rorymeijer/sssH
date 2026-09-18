import Foundation
import ssshCore

/// The result of one check.
enum CheckOutcome {
    case passed(detail: String?)
    case skipped(reason: String)
    case failed(reason: String)
    /// Known not to work, and known why. Reported but not fatal, because a
    /// green run must not depend on someone remembering which failures are
    /// expected.
    case expectedGap(reason: String)
}

struct CheckResult {
    let name: String
    let outcome: CheckOutcome
    let duration: Duration
}

/// The Phase 0 conformance suite: everything §3 of the brief lists as a
/// prerequisite for building the app on this backend.
///
/// The checks drive a real shell over a real PTY, which means they have to
/// cope with a real terminal stream: output arrives in arbitrary chunks, the
/// PTY echoes what we type, and a prompt is whatever the remote user's shell
/// decided it should be. Two conventions handle all of that:
///
/// - **Split sentinels.** A check sends `echo "MAR""K3"`, so the remote shell
///   prints `MARK3` while the PTY's echo of the command line shows
///   `MAR""K3`. Waiting for `MARK3` therefore cannot match our own input.
/// - **Reset between checks**, so a stale match from an earlier command
///   cannot satisfy a later expectation.
struct SpikeChecks {
    let transport: any SSHTransport
    let session: any SSHShellSession
    let collector: OutputCollector
    let configuration: SpikeConfiguration

    private static let markerCounter = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    // MARK: - Shell driving primitives

    /// Sends a command and waits until its output has been produced.
    ///
    /// - Returns: everything the terminal emitted for this command, echo
    ///   included. Callers assert on substrings rather than on exact output,
    ///   because a prompt, a `stty` quirk or a locale can all add noise.
    @discardableResult
    private func run(_ command: String, timeout: Duration = .seconds(20)) async throws -> String {
        let id = Self.markerCounter.next()
        let marker = "SSSHMARK\(id)"
        // Split so the echoed command line does not contain the marker.
        let echoed = "SSSHMAR\"\"K\(id)"

        collector.reset()
        try await write("\(command); echo \(echoed)\n")
        try await collector.expect(marker, timeout: timeout)
        return collector.collectedText
    }

    private func write(_ string: String) async throws {
        try await session.write(Array(string.utf8)[...])
    }

    private func writeBytes(_ bytes: [UInt8]) async throws {
        try await session.write(bytes[...])
    }

    /// Whether a program exists on the remote host, so a missing `htop` is a
    /// skip rather than a failure.
    private func remoteHasCommand(_ name: String) async throws -> Bool {
        let output = try await run("command -v \(name) >/dev/null 2>&1 && echo HAS\"\"IT || echo NOP\"\"E")
        return output.contains("HASIT")
    }

    // MARK: - Suite

    func runAll() async -> [CheckResult] {
        var results: [CheckResult] = []

        // Ordered deliberately: each check assumes the shell is at a prompt,
        // and the destructive ones (Ctrl-C, full-screen apps, teardown) come
        // after the cheap observations.
        results.append(await measure("shell reaches a prompt") { try await self.checkPromptReady() })
        results.append(await measure("PTY is allocated") { try await self.checkPTYAllocated() })
        results.append(await measure("TERM is xterm-256color") { try await self.checkTerminalType() })
        results.append(await measure("initial PTY size matches pty-req") { try await self.checkInitialSize() })
        results.append(await measure("window-change resizes the PTY") { try await self.checkResize() })
        results.append(await measure("Ctrl-C interrupts the foreground process") { try await self.checkInterrupt() })
        results.append(await measure("large output arrives intact") { try await self.checkThroughputIntegrity() })
        results.append(await measure("full-screen app (vim) drives the terminal") { try await self.checkVim() })
        results.append(await measure("full-screen app (htop) redraws") { try await self.checkHtop() })
        results.append(await measure("tmux attaches inside the PTY") { try await self.checkTmux() })
        results.append(await measure("a second shell multiplexes on one connection") { try await self.checkSecondShell() })
        results.append(await measure("SSH signal request") { try await self.checkSignalRequest() })
        results.append(await measure("keep-alive probe round-trips") { try await self.checkKeepAlive() })
        results.append(await measure("clean teardown reports exit status") { try await self.checkTeardown() })

        return results
    }

    private func measure(_ name: String, _ body: () async throws -> CheckOutcome) async -> CheckResult {
        let start = ContinuousClock.now
        do {
            let outcome = try await body()
            return CheckResult(name: name, outcome: outcome, duration: ContinuousClock.now - start)
        } catch {
            return CheckResult(
                name: name,
                outcome: .failed(reason: String(describing: error)),
                duration: ContinuousClock.now - start
            )
        }
    }

    // MARK: - Individual checks

    /// Nothing else can be trusted until the shell is actually reading input.
    private func checkPromptReady() async throws -> CheckOutcome {
        let output = try await run("echo READ\"\"Y", timeout: .seconds(30))
        guard output.contains("READY") else {
            return .failed(reason: "no response from the shell; saw \(collector.tail().debugDescription)")
        }
        return .passed(detail: nil)
    }

    /// `tty` naming a pseudo-terminal device is the direct evidence that
    /// `pty-req` was honoured — as opposed to an `exec` channel, where it
    /// prints "not a tty".
    private func checkPTYAllocated() async throws -> CheckOutcome {
        let output = try await run("tty")
        let isPTY = output.contains("/dev/pts/") || output.contains("/dev/ttys") || output.contains("/dev/tty")
        guard isPTY, !output.contains("not a tty") else {
            return .failed(reason: "tty did not report a pseudo-terminal: \(collector.tail(200).debugDescription)")
        }
        return .passed(detail: nil)
    }

    private func checkTerminalType() async throws -> CheckOutcome {
        let output = try await run("printf 'TERM=[%s]\\n' \"$TERM\"")
        guard output.contains("TERM=[xterm-256color]") else {
            return .failed(reason: "unexpected TERM: \(collector.tail(200).debugDescription)")
        }
        return .passed(detail: nil)
    }

    /// `stty size` reads the kernel's window size for the PTY, so it reflects
    /// what the server set from `pty-req` rather than anything the shell
    /// guessed.
    private func checkInitialSize() async throws -> CheckOutcome {
        let expected = "\(configuration.rows) \(configuration.columns)"
        let output = try await run("stty size")
        guard output.contains(expected) else {
            return .failed(reason: "expected \(expected.debugDescription), saw \(collector.tail(200).debugDescription)")
        }
        return .passed(detail: expected)
    }

    /// The one in §3 that is easiest to get wrong: a resize has to reach the
    /// remote PTY, not just the local emulator.
    private func checkResize() async throws -> CheckOutcome {
        let resized = TerminalSize(columns: configuration.columns + 37, rows: configuration.rows + 11)
        try await session.resize(to: resized)

        let expected = "\(resized.rows) \(resized.columns)"
        let output = try await run("stty size")
        guard output.contains(expected) else {
            return .failed(reason: "after window-change expected \(expected.debugDescription), saw \(collector.tail(200).debugDescription)")
        }

        // Put it back so later checks see the configured geometry.
        try await session.resize(to: configuration.terminalSize)
        return .passed(detail: "\(configuration.columns)x\(configuration.rows) -> \(resized.columns)x\(resized.rows)")
    }

    /// Ctrl-C is not an SSH signal: it is byte 0x03 on the PTY, turned into
    /// SIGINT by the remote line discipline. If the PTY were missing or its
    /// modes wrong, this would hang instead.
    private func checkInterrupt() async throws -> CheckOutcome {
        collector.reset()
        try await write("sleep 45\n")
        // Give the shell time to actually start `sleep`; sending 0x03 before it
        // has forked would interrupt the shell's own read instead and prove
        // nothing.
        try await Task.sleep(for: .milliseconds(750))
        try await writeBytes([0x03])

        do {
            let output = try await run("echo INTERRUPT\"\"ED", timeout: .seconds(10))
            guard output.contains("INTERRUPTED") else {
                return .failed(reason: "no prompt after Ctrl-C: \(collector.tail(200).debugDescription)")
            }
            return .passed(detail: nil)
        } catch {
            return .failed(reason: "Ctrl-C did not interrupt `sleep`: \(error)")
        }
    }

    /// Streams roughly 1.2 MB and counts it, which exercises the backpressure
    /// path in `SSHShellEventSink` and would expose bytes dropped by a lossy
    /// buffering policy.
    private func checkThroughputIntegrity() async throws -> CheckOutcome {
        let lineCount = 60_000
        let payload = "ssshpayload"

        let before = collector.bytesReceived
        let output = try await run(
            "yes \(payload) | head -n \(lineCount)",
            timeout: .seconds(90)
        )
        let transferred = collector.bytesReceived - before

        let occurrences = output.components(separatedBy: payload).count - 1
        // The echoed command line contains the payload word once.
        let received = occurrences - 1

        guard received == lineCount else {
            return .failed(reason: "expected \(lineCount) lines, counted \(received) (\(transferred) bytes transferred)")
        }
        return .passed(detail: "\(lineCount) lines, \(transferred) bytes, no loss")
    }

    private func checkVim() async throws -> CheckOutcome {
        guard try await remoteHasCommand("vim") else {
            return .skipped(reason: "vim is not installed on the remote host")
        }

        collector.reset()
        // `-u NONE` keeps a user's vimrc from changing what gets drawn.
        try await write("vim -u NONE\n")

        do {
            // Either the alternate-screen switch or vim's splash screen proves
            // it is driving a real terminal. Different builds and termcaps pick
            // different sequences, so accept any of them.
            try await expectAny(
                ["\u{1B}[?1049h", "\u{1B}[?1047h", "VIM - Vi IMproved"],
                timeout: .seconds(20)
            )
        } catch {
            // Leave vim if it did start but drew something unexpected.
            try? await writeBytes([0x1B])
            try? await write(":q!\r")
            return .failed(reason: "vim did not take over the terminal: \(collector.tail(300).debugDescription)")
        }

        try await writeBytes([0x1B])
        try await write(":q!\r")

        let output = try await run("echo VIMD\"\"ONE", timeout: .seconds(20))
        guard output.contains("VIMDONE") else {
            return .failed(reason: "shell did not come back after quitting vim")
        }
        return .passed(detail: nil)
    }

    private func checkHtop() async throws -> CheckOutcome {
        guard try await remoteHasCommand("htop") else {
            return .skipped(reason: "htop is not installed on the remote host")
        }

        collector.reset()
        try await write("htop -d 5\n")

        do {
            try await expectAny(["Load average", "Tasks", "Mem["], timeout: .seconds(20))
        } catch {
            try? await write("q")
            return .failed(reason: "htop did not redraw: \(collector.tail(300).debugDescription)")
        }

        try await write("q")
        let output = try await run("echo HTOPD\"\"ONE", timeout: .seconds(20))
        guard output.contains("HTOPDONE") else {
            return .failed(reason: "shell did not come back after quitting htop")
        }
        return .passed(detail: nil)
    }

    private func checkTmux() async throws -> CheckOutcome {
        guard try await remoteHasCommand("tmux") else {
            return .skipped(reason: "tmux is not installed on the remote host")
        }

        // `-f /dev/null` ignores the user's tmux.conf, which could change the
        // status line this check looks for.
        try await run("tmux -f /dev/null kill-session -t ssshspike 2>/dev/null; true")
        try await run("tmux -f /dev/null new-session -d -s ssshspike 'sleep 120'")

        collector.reset()
        try await write("tmux -f /dev/null attach -t ssshspike\n")

        do {
            // The alternate screen, not the session name. "ssshspike" appears
            // in the echo of the command line we just sent, so waiting for it
            // matches before tmux has done anything at all — and the detach
            // keys then go to the shell, which types them onto the next
            // command line. Entering the alternate screen is tmux actually
            // taking the terminal over.
            try await expectAny(Self.alternateScreenEnter, timeout: .seconds(20))
        } catch {
            try? await detachTmux()
            return .failed(reason: "tmux did not attach: \(collector.tail(300).debugDescription)")
        }

        do {
            try await detachTmux()
        } catch {
            return .failed(reason: "tmux did not hand the terminal back after Ctrl-B d")
        }

        let output = try await run("tmux -f /dev/null kill-session -t ssshspike; echo TMUXD\"\"ONE", timeout: .seconds(20))
        guard output.contains("TMUXDONE") else {
            return .failed(reason: "shell did not come back after detaching tmux")
        }
        return .passed(detail: "plain tmux attach/detach; control mode (-CC) is a separate Phase 2 question")
    }

    /// Ctrl-B d, and then waits until tmux has actually let go of the terminal.
    ///
    /// The wait is the point. Writing the next command straight after the key
    /// sequence is a race the harness loses: the bytes arrive while tmux still
    /// owns the PTY, so they are typed into the attached pane — which in this
    /// check is running `sleep`, so they go nowhere and the marker never
    /// appears. tmux announces the handover by printing `[detached …]` and
    /// leaving the alternate screen.
    private func detachTmux() async throws {
        try await writeBytes([0x02, UInt8(ascii: "d")])
        try await expectAny(["[detached"] + Self.alternateScreenLeave, timeout: .seconds(10))
    }

    /// The sequences a full-screen program uses to borrow the terminal and to
    /// give it back. 1049 is what xterm-256color's terminfo gives tmux; the
    /// older two are there so a stripped-down remote terminfo does not turn
    /// this check into a mystery.
    private static let alternateScreenEnter = ["\u{1B}[?1049h", "\u{1B}[?1047h", "\u{1B}[?47h"]
    private static let alternateScreenLeave = ["\u{1B}[?1049l", "\u{1B}[?1047l", "\u{1B}[?47l"]

    /// Tabs and split panes all share one TCP connection, so opening a second
    /// session channel has to work.
    private func checkSecondShell() async throws -> CheckOutcome {
        let second = try await transport.openShell(
            SSHShellConfiguration(initialSize: TerminalSize(columns: 100, rows: 30))
        )
        let secondCollector = OutputCollector()
        let drain = Task { await secondCollector.consume(second) }
        defer {
            drain.cancel()
        }

        do {
            try await second.write(Array("stty size; echo SECON\"\"D\n".utf8)[...])
            try await secondCollector.expect("SECOND", timeout: .seconds(20))
            guard secondCollector.collectedText.contains("30 100") else {
                await second.close()
                return .failed(reason: "second shell has the wrong PTY size: \(secondCollector.tail(200).debugDescription)")
            }
        } catch {
            await second.close()
            return .failed(reason: "second shell failed: \(error)")
        }

        await second.close()
        return .passed(detail: nil)
    }

    /// OpenSSH's sshd has never implemented the `signal` channel request, so a
    /// refusal here is the expected answer against the usual server. The check
    /// exists to record which server does what, not to gate the phase — the UI
    /// must use PTY control bytes for Ctrl-C regardless.
    private func checkSignalRequest() async throws -> CheckOutcome {
        collector.reset()
        try await write("sleep 45\n")
        try await Task.sleep(for: .milliseconds(750))

        do {
            try await session.send(signal: .int)
        } catch {
            return .expectedGap(reason: "server refused the signal request: \(error)")
        }

        // If SIGINT was delivered, `sleep` is gone and the shell answers
        // immediately. If it was not, the marker cannot appear until the sleep
        // finishes, so a short timeout is the whole test.
        let delivered: Bool
        do {
            let output = try await run("echo SIGNALD\"\"ONE", timeout: .seconds(5))
            delivered = output.contains("SIGNALDONE")
        } catch {
            delivered = false
        }

        // Either way, leave the shell at a prompt for the checks that follow.
        try? await writeBytes([0x03])
        _ = try? await run("true", timeout: .seconds(60))

        guard delivered else {
            return .expectedGap(reason: "the server accepted the request but did not deliver SIGINT (normal for OpenSSH sshd)")
        }
        return .passed(detail: "server honours SSH signal requests")
    }

    private func checkKeepAlive() async throws -> CheckOutcome {
        do {
            try await transport.sendKeepAliveProbe(timeout: .seconds(10))
            return .passed(detail: "global-request round trip answered")
        } catch {
            return .failed(reason: "keep-alive probe failed: \(error)")
        }
    }

    /// Runs last: it ends the session.
    private func checkTeardown() async throws -> CheckOutcome {
        try await write("exit\n")

        // Wait for the stream to end rather than polling: the exit event is
        // pushed before the stream finishes, so once `consume` returns the
        // status is there.
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let exit = collector.exitStatus {
                guard exit.status == 0 else {
                    return .failed(reason: "shell exited with status \(exit.status.map(String.init) ?? "?") signal \(exit.signal ?? "-")")
                }
                return .passed(detail: "exit-status 0")
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        return .failed(reason: "no exit status within 15s of sending `exit`")
    }

    // MARK: - Helpers

    /// Waits for whichever of several alternatives appears first.
    private func expectAny(_ needles: [String], timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for needle in needles {
                group.addTask { try await self.collector.expect(needle, timeout: timeout) }
            }
            defer { group.cancelAll() }
            // The first success wins; if every alternative fails, rethrow the
            // last error so the message names a concrete expectation.
            var lastError: Error?
            for _ in needles {
                do {
                    try await group.next()
                    return
                } catch {
                    lastError = error
                }
            }
            if let lastError { throw lastError }
        }
    }
}
