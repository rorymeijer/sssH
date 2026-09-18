import XCTest
@testable import ssshCore

final class PlainTextTests: XCTestCase {
    private func extract(_ text: String) -> String {
        PlainText.extract(from: Array(text.utf8)[...])
    }

    /// The bug this guards against is subtle and total: treating the `\r` of a
    /// `\r\n` as a line rewind deletes the line the `\n` is about to end, so
    /// every captured line comes out empty.
    func testCarriageReturnBeforeLineFeedIsALineEnding() {
        XCTAssertEqual(extract("done\r\n"), "done\n")
        XCTAssertEqual(extract("a\r\nb\r\n"), "a\nb\n")
    }

    /// A bare `\r` really does rewrite the line — that is how progress bars
    /// and spinners work, and collapsing them is the point.
    func testBareCarriageReturnRewritesTheLine() {
        XCTAssertEqual(extract("10%\r50%\r100%\r\ndone\r\n"), "100%\ndone\n")
    }

    func testBackspaceDeletesWithinTheLineOnly() {
        XCTAssertEqual(extract("abc\u{08}d"), "abd")
        // A backspace at the start of a line must not eat the newline before
        // it and join two lines together.
        XCTAssertEqual(extract("ab\n\u{08}c"), "ab\nc")
    }

    func testEscapeSequencesAreRemoved() {
        XCTAssertEqual(extract("\u{1B}[31mred\u{1B}[0m"), "red")
        XCTAssertEqual(extract("\u{1B}]0;title\u{07}text"), "text")
        XCTAssertEqual(extract("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\"), "link")
        XCTAssertEqual(extract("\u{1B}(Bplain"), "plain")
    }

    func testTabsSurviveAndOtherControlsDoNot() {
        XCTAssertEqual(extract("a\tb\u{07}c\u{00}d"), "a\tbcd")
    }

    /// 0x9D is the 8-bit OSC introducer. It is also the second byte of plenty
    /// of ordinary characters, so skipping from one loses real text.
    func testEightBitIntroducersDoNotEatText() {
        XCTAssertEqual(extract("عربى tail"), "عربى tail")
        XCTAssertEqual(extract("🎉 tail"), "🎉 tail")
    }

    func testUnterminatedSequenceDoesNotConsumeEverything() {
        // An OSC with no terminator is malformed; the text after it is still
        // text and must not disappear.
        XCTAssertEqual(extract("\u{1B}[31"), "")
        XCTAssertEqual(extract("before\u{1B}]0;never closed"), "before")
    }

    func testLinesDropsTheTrailingEmptyLine() {
        XCTAssertEqual(PlainText.lines(from: Array("a\nb\n".utf8)[...]), ["a", "b"])
        XCTAssertEqual(PlainText.lines(from: Array("a\nb".utf8)[...]), ["a", "b"])
        XCTAssertEqual(PlainText.lines(from: Array("".utf8)[...]), [])
    }
}
