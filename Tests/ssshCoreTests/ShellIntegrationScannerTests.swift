import XCTest
@testable import ssshCore

/// The scanner's contract is exact: every byte in must come back out unless it
/// belonged to a marker sequence. Most of these cases are the ones that break
/// a naive per-chunk search — sequences split across reads, sequences that look
/// like markers and are not, and bytes that look like 8-bit introducers and are
/// really text.
final class ShellIntegrationScannerTests: XCTestCase {
    private func tokens(_ scanner: inout ShellIntegrationScanner, _ text: [UInt8]) -> [ShellIntegrationToken] {
        scanner.scan(text[...])
    }

    private func passthrough(_ tokens: [ShellIntegrationToken]) -> [UInt8] {
        tokens.reduce(into: [UInt8]()) { result, token in
            if case .bytes(let bytes) = token { result.append(contentsOf: bytes) }
        }
    }

    private func markers(_ tokens: [ShellIntegrationToken]) -> [ShellIntegrationMarker] {
        tokens.compactMap { if case .marker(let marker) = $0 { return marker } else { return nil } }
    }

    func testRecognisesEachOSC133Marker() {
        var scanner = ShellIntegrationScanner()
        let stream = Array("\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}\u{1B}]133;C\u{07}\u{1B}]133;D;3\u{07}".utf8)
        let result = tokens(&scanner, stream)
        XCTAssertEqual(markers(result), [.promptStart, .commandStart, .commandExecuted, .commandFinished(exitStatus: 3)])
        XCTAssertTrue(passthrough(result).isEmpty)
    }

    func testAcceptsStringTerminatorAsWellAsBell() {
        var scanner = ShellIntegrationScanner()
        let result = tokens(&scanner, Array("\u{1B}]133;D;0\u{1B}\\".utf8))
        XCTAssertEqual(markers(result), [.commandFinished(exitStatus: 0)])
        XCTAssertTrue(passthrough(result).isEmpty)
    }

    func testMarkerWithoutExitStatusReportsNil() {
        var scanner = ShellIntegrationScanner()
        let result = tokens(&scanner, Array("\u{1B}]133;D\u{07}".utf8))
        XCTAssertEqual(markers(result), [.commandFinished(exitStatus: nil)])
    }

    /// The case a per-chunk search gets wrong: a marker delivered one byte at
    /// a time, which is what a busy link produces.
    func testMarkerSplitAcrossEveryByteStillParses() {
        var scanner = ShellIntegrationScanner()
        let stream = Array("a\u{1B}]133;D;7\u{07}b".utf8)
        var found: [ShellIntegrationMarker] = []
        var bytes: [UInt8] = []
        for byte in stream {
            let result = scanner.scan([byte][...])
            found.append(contentsOf: markers(result))
            bytes.append(contentsOf: passthrough(result))
        }
        XCTAssertEqual(found, [.commandFinished(exitStatus: 7)])
        XCTAssertEqual(bytes, Array("ab".utf8))
    }

    func testNonMarkerOSCIsPassedThroughUnchanged() {
        var scanner = ShellIntegrationScanner()
        let stream = Array("\u{1B}]0;window title\u{07}hello".utf8)
        let result = tokens(&scanner, stream)
        XCTAssertTrue(markers(result).isEmpty)
        XCTAssertEqual(passthrough(result), stream)
    }

    func testColourSequencesArePassedThrough() {
        var scanner = ShellIntegrationScanner()
        let stream = Array("\u{1B}[31mred\u{1B}[0m".utf8)
        let result = tokens(&scanner, stream)
        XCTAssertTrue(markers(result).isEmpty)
        XCTAssertEqual(passthrough(result), stream)
    }

    /// Entering the alternate screen is a marker *and* still output: the
    /// emulator needs the bytes even though the segmenter needs the news.
    func testAlternateScreenIsReportedAndPassedThrough() {
        var scanner = ShellIntegrationScanner()
        let enter = Array("\u{1B}[?1049h".utf8)
        var result = tokens(&scanner, enter)
        XCTAssertEqual(markers(result), [.alternateScreen(active: true)])
        XCTAssertEqual(passthrough(result), enter)

        let leave = Array("\u{1B}[?1049l".utf8)
        result = tokens(&scanner, leave)
        XCTAssertEqual(markers(result), [.alternateScreen(active: false)])
        XCTAssertEqual(passthrough(result), leave)
    }

    func testOtherPrivateModesAreNotAlternateScreen() {
        var scanner = ShellIntegrationScanner()
        let result = tokens(&scanner, Array("\u{1B}[?25l".utf8))
        XCTAssertTrue(markers(result).isEmpty)
    }

    /// 0x9D is the 8-bit OSC introducer, and also a UTF-8 continuation byte.
    /// Treating it as an introducer eats the rest of the line whenever
    /// somebody's output contains Arabic or an emoji.
    func testEightBitIntroducersAreTreatedAsText() {
        var scanner = ShellIntegrationScanner()
        let stream: [UInt8] = [0x9D] + Array("133;D;7".utf8) + [0x9C]
        let result = tokens(&scanner, stream)
        XCTAssertTrue(markers(result).isEmpty)
        XCTAssertEqual(passthrough(result), stream)
    }

    func testUnterminatedSequenceIsReturnedByFlush() {
        var scanner = ShellIntegrationScanner()
        let first = tokens(&scanner, Array("a\u{1B}]133;Abc".utf8))
        XCTAssertEqual(passthrough(first), Array("a".utf8))
        let flushed = scanner.flush()
        XCTAssertTrue(markers(flushed).isEmpty)
        XCTAssertEqual(passthrough(flushed), Array("\u{1B}]133;Abc".utf8))
    }

    func testEscapeFollowedByEscapeDoesNotSwallowTheSecondSequence() {
        var scanner = ShellIntegrationScanner()
        let result = tokens(&scanner, Array("\u{1B}\u{1B}]133;A\u{07}".utf8))
        XCTAssertEqual(markers(result), [.promptStart])
        XCTAssertEqual(passthrough(result), [0x1B])
    }

    func testTwoByteEscapeSequenceIsPassedThrough() {
        var scanner = ShellIntegrationScanner()
        let stream = Array("x\u{1B}(Byz".utf8)
        let result = tokens(&scanner, stream)
        XCTAssertTrue(markers(result).isEmpty)
        XCTAssertEqual(passthrough(result), stream)
    }

    func testVSCodeCommandLineIsDecoded() {
        var scanner = ShellIntegrationScanner()
        // `\x22` is how VS Code escapes a double quote, and `\\` a backslash,
        // so that the command line stays one OSC payload.
        let payload = #"echo \x22hi\x22 \\ done"#
        let result = tokens(&scanner, Array("\u{1B}]633;E;\(payload)\u{07}".utf8))
        XCTAssertEqual(markers(result), [.commandLine(#"echo "hi" \ done"#)])
    }

    func testCommandLineMarkerIsIgnoredOnOSC133() {
        // `E` is VS Code's extension; 133 has no such field, and accepting it
        // there would mean trusting a field nothing defines.
        var scanner = ShellIntegrationScanner()
        let result = tokens(&scanner, Array("\u{1B}]133;E;rm -rf /\u{07}".utf8))
        XCTAssertTrue(markers(result).isEmpty)
    }

    func testUnrelatedOSCNumbersAreIgnored() {
        var scanner = ShellIntegrationScanner()
        let result = tokens(&scanner, Array("\u{1B}]1337;File=name\u{07}".utf8))
        XCTAssertTrue(markers(result).isEmpty)
    }
}
