import XCTest
@testable import ssshCore

/// End-to-end over the two modes. The sessions here are transcripts of what a
/// real shell sends, including the parts that make naive segmentation look
/// silly: history recall, a progress bar, a full-screen editor, an empty
/// Return and a multi-line paste.
final class CommandBlockSegmenterTests: XCTestCase {
    private struct Session {
        var segmenter = CommandBlockSegmenter()
        var store = CommandBlockStore()

        init(limits: CommandBlockSegmenter.Limits = .init(), capacity: Int = 500) {
            segmenter = CommandBlockSegmenter(limits: limits)
            store = CommandBlockStore(capacity: capacity)
        }

        mutating func output(_ text: String) { output(Array(text.utf8)) }

        mutating func output(_ bytes: [UInt8]) {
            store.apply(segmenter.consumeOutput(bytes[...]))
        }

        /// Feeds the same bytes in randomly sized pieces, which is how they
        /// actually arrive.
        mutating func outputInPieces(_ text: String, seed: UInt64) {
            var generator = SplitMix64(seed: seed)
            let bytes = Array(text.utf8)
            var index = 0
            while index < bytes.count {
                let size = Int(generator.next() % 5) + 1
                let end = min(index + size, bytes.count)
                output(Array(bytes[index..<end]))
                index = end
            }
        }

        mutating func input(_ text: String) {
            store.apply(segmenter.consumeInput(Array(text.utf8)[...]))
        }

        mutating func finish() { store.apply(segmenter.finish()) }

        var blocks: [CommandBlock] { store.blocks }
    }

    /// A tiny deterministic generator, so a failure is reproducible.
    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func osc133(_ kind: String, _ argument: String? = nil) -> String {
        "\u{1B}]133;\(kind)\(argument.map { ";\($0)" } ?? "")\u{07}"
    }

    // MARK: - Shell integration

    func testShellIntegrationGivesExactBoundariesAndStatus() {
        var session = Session()
        let stream =
            osc133("A") + "user@host:~$ " + osc133("B") + "ls -l" + osc133("C") +
            "\r\ntotal 0\r\n-rw-r--r-- 1 u u 0 file\r\n" + osc133("D", "0") +
            osc133("A") + "user@host:~$ " + osc133("B") + "false" + osc133("C") +
            "\r\n" + osc133("D", "1") +
            osc133("A") + "user@host:~$ " + osc133("B")
        session.outputInPieces(stream, seed: 7)

        XCTAssertEqual(session.segmenter.mode, .shellIntegration)
        XCTAssertEqual(session.blocks.count, 3)

        XCTAssertEqual(session.blocks[0].command, "ls -l")
        XCTAssertEqual(session.blocks[0].exitStatus, 0)
        XCTAssertEqual(session.blocks[0].outputText, "total 0\n-rw-r--r-- 1 u u 0 file\n")
        XCTAssertFalse(session.blocks[0].isHeuristic)

        XCTAssertEqual(session.blocks[1].command, "false")
        XCTAssertEqual(session.blocks[1].exitStatus, 1)
        XCTAssertEqual(session.blocks[1].outputText, "")

        // The prompt on screen is a block that has not run anything yet.
        XCTAssertEqual(session.blocks[2].state, .prompting)
        XCTAssertEqual(session.blocks[2].command, "")
    }

    func testVSCodeCommandLineBeatsTheEcho() {
        var session = Session()
        session.output("\u{1B}]633;A\u{07}$ \u{1B}]633;B\u{07}")
        session.output("\u{1B}]633;E;echo \\x22hi\\x22\u{07}")
        session.output("\u{1B}]633;C\u{07}hi\r\n\u{1B}]633;D;0\u{07}")

        XCTAssertEqual(session.blocks.count, 1)
        XCTAssertEqual(session.blocks[0].command, #"echo "hi""#)
        XCTAssertEqual(session.blocks[0].outputText, "hi\n")
        XCTAssertEqual(session.blocks[0].exitStatus, 0)
    }

    func testMarkersStopReturnFromCuttingBlocksAsWell() {
        // Once the shell marks its own boundaries, a Return must not cut a
        // second block on top of the marked one.
        var session = Session()
        session.output("$ ")
        session.input("ls\r")
        session.output(osc133("A") + "$ " + osc133("B") + "ls" + osc133("C") + "\r\nfile\r\n" + osc133("D", "0"))
        XCTAssertEqual(session.segmenter.mode, .shellIntegration)
        XCTAssertEqual(session.blocks.filter { !$0.command.isEmpty }.map(\.command), ["ls"])
    }

    // MARK: - Fallback

    func testFallbackSeparatesPromptFromCommand() {
        var session = Session()
        session.output("Welcome to Ubuntu\r\nuser@host:~$ ")
        session.input("l"); session.output("l")
        session.input("s"); session.output("s")
        session.input("\r")
        session.output("\r\nfile-a\r\nfile-b\r\nuser@host:~$ ")
        session.input("echo hi\r")
        session.output("echo hi\r\nhi\r\nuser@host:~$ ")
        session.finish()

        XCTAssertEqual(session.segmenter.mode, .fallback)
        XCTAssertEqual(session.blocks.count, 2)
        XCTAssertEqual(session.blocks[0].prompt, "user@host:~$ ")
        XCTAssertEqual(session.blocks[0].command, "ls")
        XCTAssertEqual(session.blocks[0].outputText, "file-a\nfile-b\n")
        XCTAssertTrue(session.blocks[0].isHeuristic)
        XCTAssertNil(session.blocks[0].exitStatus)
        XCTAssertEqual(session.blocks[1].command, "echo hi")
        XCTAssertEqual(session.blocks[1].outputText, "hi\n")
        // The prompt left on screen at the end belongs to no block.
        XCTAssertFalse(session.blocks[1].outputText.contains("user@host"))
    }

    /// The reason the command comes from the echo and not from the keystrokes:
    /// pressing Up types nothing at all.
    func testHistoryRecallRecoversTheRealCommand() {
        var session = Session()
        session.output("$ ")
        session.input("\u{1B}[A")
        session.output("echo previous")
        session.input("\r")
        session.output("\r\nprevious\r\n$ ")
        session.finish()

        XCTAssertEqual(session.blocks.count, 1)
        XCTAssertEqual(session.blocks[0].command, "echo previous")
        XCTAssertEqual(session.blocks[0].outputText, "previous\n")
    }

    func testEmptyReturnOpensNoBlock() {
        var session = Session()
        session.output("$ ")
        session.input("\r")
        session.output("\r\n$ ")
        session.input("id\r")
        session.output("id\r\nuid=0\r\n$ ")
        session.finish()

        XCTAssertEqual(session.blocks.map(\.command), ["id"])
        XCTAssertEqual(session.blocks[0].outputText, "uid=0\n")
    }

    /// A paste arrives as many Returns at once, long before their echoes. Only
    /// one is armed, so the run becomes one block rather than several blocks
    /// whose "commands" are really output lines.
    func testMultiLinePasteBecomesOneBlock() {
        var session = Session()
        session.output("$ ")
        session.input("one\rtwo\rthree\r")
        session.output("one\r\n1\r\n$ two\r\n2\r\n$ three\r\n3\r\n$ ")
        session.finish()

        XCTAssertEqual(session.blocks.count, 1)
        XCTAssertEqual(session.blocks[0].command, "one")
        XCTAssertEqual(session.blocks[0].outputText, "1\n$ two\n2\n$ three\n3\n")
    }

    func testProgressBarCollapsesInTheCapturedText() {
        var session = Session()
        session.output("$ ")
        session.input("download\r")
        session.output("download\r\n")
        session.output("10%\r50%\r100%\r\ndone\r\n$ ")
        session.finish()

        XCTAssertEqual(session.blocks[0].command, "download")
        XCTAssertEqual(session.blocks[0].outputText, "100%\ndone\n")
    }

    // MARK: - Things that are not commands

    func testAlternateScreenIsNotCaptured() {
        var session = Session()
        session.output("$ ")
        session.input("vim\r")
        session.output("vim\r\n")
        session.output("\u{1B}[?1049h" + String(repeating: "~", count: 50) + "\u{1B}[?1049l")
        session.output("$ ")
        session.finish()

        XCTAssertEqual(session.blocks.count, 1)
        XCTAssertEqual(session.blocks[0].command, "vim")
        XCTAssertEqual(session.blocks[0].outputText, "")
        // Honest about it: output was dropped, and the UI can say so.
        XCTAssertTrue(session.blocks[0].outputTruncated)
    }

    func testOutputIsCappedPerBlock() {
        var session = Session(limits: .init(outputBytesPerBlock: 10))
        session.output("$ ")
        session.input("yes\r")
        session.output("yes\r\n" + String(repeating: "z", count: 50) + "\r\n$ ")
        session.finish()

        XCTAssertEqual(session.blocks[0].output.count, 10)
        XCTAssertTrue(session.blocks[0].outputTruncated)
    }

    func testFinishClosesTheRunningBlock() {
        var session = Session()
        session.output("$ ")
        session.input("sleep 1\r")
        session.output("sleep 1\r\n")
        XCTAssertTrue(session.blocks[0].isRunning)
        session.finish()
        XCTAssertFalse(session.blocks[0].isRunning)
        // Nothing reported a status, so there is none. Not zero.
        XCTAssertNil(session.blocks[0].exitStatus)
    }

    func testStoreEvictsOldestBeyondCapacity() {
        var session = Session(capacity: 2)
        for index in 1...4 {
            session.output("$ ")
            session.input("c\(index)\r")
            session.output("c\(index)\r\nout\(index)\r\n")
        }
        session.finish()
        XCTAssertEqual(session.blocks.map(\.command), ["c3", "c4"])
        XCTAssertEqual(session.store.evicted.count, 2)
    }
}
