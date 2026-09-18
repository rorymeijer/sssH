import Foundation
import XCTest
@testable import ssshCore

/// tmux control mode.
///
/// The fixtures are built with tmux's own escaping rule from `control.c` —
/// escape a byte as three-digit octal when it is below 0x20 or a backslash,
/// pass everything else through — so these are round trips against the real
/// format rather than against this parser's idea of it.
final class TmuxControlParserTests: XCTestCase {
    /// tmux's escaping, as the server performs it.
    private func escape(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for byte in data {
            if byte < 0x20 || byte == UInt8(ascii: "\\") {
                out.append(contentsOf: Array(String(format: "\\%03o", Int(byte)).utf8))
            } else {
                out.append(byte)
            }
        }
        return out
    }

    private func outputLine(pane: Int, _ payload: [UInt8]) -> [UInt8] {
        Array("%output %\(pane) ".utf8) + escape(payload) + [UInt8(ascii: "\n")]
    }

    // MARK: - Output

    func testUTF8OutputSurvives() {
        var parser = TmuxControlParser()
        let payload = Array("echo hé — ✓\r\n".utf8)

        let events = parser.consume(outputLine(pane: 3, payload))

        XCTAssertEqual(events, [.output(pane: TmuxPaneID(rawValue: 3), bytes: payload)])
    }

    func testOutputReassemblesAcrossChunkBoundaries() {
        // SSH delivers whatever it delivers, including a split in the middle of
        // an escape sequence.
        var parser = TmuxControlParser()
        let payload = Array("some \u{1B}[31mcoloured\u{1B}[0m text".utf8)
        let line = outputLine(pane: 3, payload)

        var events: [TmuxControlEvent] = []
        for chunk in stride(from: 0, to: line.count, by: 5) {
            let slice = Array(line[chunk..<min(chunk + 5, line.count)])
            events.append(contentsOf: parser.consume(slice))
        }

        XCTAssertEqual(events, [.output(pane: TmuxPaneID(rawValue: 3), bytes: payload)])
    }

    func testControlCharactersAndBackslashRoundTrip() {
        var parser = TmuxControlParser()
        let payload = Array("\u{1B}[31mred\u{1B}[0m C:\\path\u{07}".utf8)

        XCTAssertEqual(
            parser.consume(outputLine(pane: 1, payload)),
            [.output(pane: TmuxPaneID(rawValue: 1), bytes: payload)]
        )
    }

    func testBytesThatAreNotValidUTF8SurviveIntact() {
        // The reason the output path never builds a `String`: decoding these
        // would replace them with U+FFFD, and that cannot be undone.
        var parser = TmuxControlParser()
        let payload: [UInt8] = [0xC3, 0x28, 0xFF, 0xFE]

        XCTAssertEqual(
            parser.consume(outputLine(pane: 2, payload)),
            [.output(pane: TmuxPaneID(rawValue: 2), bytes: payload)]
        )
    }

    func testSpacesInOutputAreNotADelimiter() {
        var parser = TmuxControlParser()
        let payload = Array("total 12 drwxr-xr-x  3 rory".utf8)

        XCTAssertEqual(
            parser.consume(outputLine(pane: 4, payload)),
            [.output(pane: TmuxPaneID(rawValue: 4), bytes: payload)]
        )
    }

    func testEmptyPayload() {
        var parser = TmuxControlParser()
        XCTAssertEqual(
            parser.consume(Array("%output %1 \n".utf8)),
            [.output(pane: TmuxPaneID(rawValue: 1), bytes: [])]
        )
    }

    // MARK: - Command blocks

    func testLinesInsideACommandBlockAreNotNotifications() {
        // The trap: between %begin and %end, a line starting with % is output,
        // not an event. A parser that scans for notifications everywhere will
        // act on a command's own text.
        var parser = TmuxControlParser()
        let stream = """
        %begin 1700000000 42 1
        %output %9 this is not an output notification
        real output
        %end 1700000000 42 1

        """

        XCTAssertEqual(
            parser.consume(Array(stream.utf8)),
            [.commandReply(
                number: 42,
                lines: ["%output %9 this is not an output notification", "real output"],
                isError: false
            )]
        )
    }

    func testErrorsAreReportedAsErrors() {
        var parser = TmuxControlParser()
        let stream = "%begin 1 7 1\ncan't find window: @99\n%error 1 7 1\n"

        XCTAssertEqual(
            parser.consume(Array(stream.utf8)),
            [.commandReply(number: 7, lines: ["can't find window: @99"], isError: true)]
        )
    }

    // MARK: - Notifications

    func testWindowNotifications() {
        var parser = TmuxControlParser()
        let stream = """
        %window-add @3
        %window-renamed @3 build logs
        %layout-change @3 bb62,178x45,0,0,1
        %window-close @3

        """

        XCTAssertEqual(parser.consume(Array(stream.utf8)), [
            .windowAdded(TmuxWindowID(rawValue: 3)),
            .windowRenamed(TmuxWindowID(rawValue: 3), name: "build logs"),
            .layoutChanged(TmuxWindowID(rawValue: 3), layout: "bb62,178x45,0,0,1"),
            .windowClosed(TmuxWindowID(rawValue: 3)),
        ])
    }

    func testSessionAndExitNotifications() {
        var parser = TmuxControlParser()
        let stream = "%session-changed $1 work\n%sessions-changed\n%client-detached\n%exit killed\n"

        XCTAssertEqual(parser.consume(Array(stream.utf8)), [
            .sessionChanged(TmuxSessionID(rawValue: 1), name: "work"),
            .sessionsChanged,
            .clientDetached,
            .exited(reason: "killed"),
        ])
    }

    func testExitWithoutAReason() {
        var parser = TmuxControlParser()
        XCTAssertEqual(parser.consume(Array("%exit\n".utf8)), [.exited(reason: nil)])
    }

    func testCRLFLineEndings() {
        // tmux is speaking over a PTY, so it sends CRLF.
        var parser = TmuxControlParser()
        XCTAssertEqual(
            parser.consume(Array("%window-add @5\r\n".utf8)),
            [.windowAdded(TmuxWindowID(rawValue: 5))]
        )
    }

    func testUnknownNotificationsArePreservedRatherThanDropped() {
        // A newer tmux says things this version does not act on. Keeping them
        // means a log shows what happened instead of silence.
        var parser = TmuxControlParser()
        XCTAssertEqual(
            parser.consume(Array("%subscription-changed foo bar\n".utf8)),
            [.unhandled(name: "subscription-changed", arguments: "foo bar")]
        )
    }

    func testPartialLineIsHeldBack() {
        var parser = TmuxControlParser()
        XCTAssertTrue(parser.consume(Array("%window-".utf8)).isEmpty)
        XCTAssertEqual(parser.unterminatedBytes, Array("%window-".utf8))
        XCTAssertEqual(parser.consume(Array("add @1\n".utf8)), [.windowAdded(TmuxWindowID(rawValue: 1))])
        XCTAssertTrue(parser.unterminatedBytes.isEmpty)
    }

    // MARK: - Escaping

    func testUnescapeHandlesMalformedInputWithoutLosingBytes() {
        // A trailing backslash, or one followed by non-octal digits, is not an
        // escape. Dropping it would silently corrupt output.
        XCTAssertEqual(TmuxControlParser.unescape("abc\\"), Array("abc\\".utf8))
        XCTAssertEqual(TmuxControlParser.unescape("a\\9z"), Array("a\\9z".utf8))
        XCTAssertEqual(TmuxControlParser.unescape("\\101"), [0x41])
        XCTAssertEqual(TmuxControlParser.unescape("\\000"), [0x00])
        XCTAssertEqual(TmuxControlParser.unescape("\\377"), [0xFF])
    }
}
