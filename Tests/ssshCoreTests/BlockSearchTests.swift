import XCTest
@testable import ssshCore

final class BlockSearchTests: XCTestCase {
    private func block(_ command: String, _ output: String, exitStatus: Int32?) -> CommandBlock {
        CommandBlock(command: command,
                     output: Array(output.utf8),
                     state: .finished(exitStatus: exitStatus))
    }

    private var blocks: [CommandBlock] {
        [
            block("make build", "compiling\nError: missing header\n", exitStatus: 2),
            block("ls", "Makefile\nsrc\n", exitStatus: 0),
            block("./deploy", "deploying\ndone\n", exitStatus: nil),
        ]
    }

    func testSearchesCommandsAndOutput() {
        let matches = BlockSearch.matches(in: blocks, query: "make")
        // Newest first: `ls`'s output mentions the Makefile, and the `make`
        // command itself is older.
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].field, .output)
        XCTAssertEqual(matches[0].line, "Makefile")
        XCTAssertEqual(matches[1].field, .command)
        XCTAssertEqual(matches[1].line, "make build")
    }

    func testSmartCase() {
        XCTAssertFalse(BlockSearch.isCaseSensitive(query: "error"))
        XCTAssertTrue(BlockSearch.isCaseSensitive(query: "Error"))
        XCTAssertEqual(BlockSearch.matches(in: blocks, query: "error").count, 1)
        XCTAssertEqual(BlockSearch.matches(in: blocks, query: "Error").count, 1)
        XCTAssertEqual(BlockSearch.matches(in: blocks, query: "ERROR").count, 0)
    }

    func testEveryOccurrenceOnALineIsFound() {
        let repeated = [block("x", "aa aa aa\n", exitStatus: 0)]
        XCTAssertEqual(BlockSearch.matches(in: repeated, query: "aa").count, 3)
    }

    func testEmptyQueryFindsNothing() {
        XCTAssertTrue(BlockSearch.matches(in: blocks, query: "   ").isEmpty)
    }

    func testLimitIsRespected() {
        let noisy = [block("x", String(repeating: "hit\n", count: 100), exitStatus: 0)]
        XCTAssertEqual(BlockSearch.matches(in: noisy, query: "hit", limit: 10).count, 10)
    }

    func testLineNumbersMatchOutputLines() {
        let matches = BlockSearch.matches(in: blocks, query: "missing")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].lineNumber, 1)
        XCTAssertEqual(blocks[0].outputLines[matches[0].lineNumber], "Error: missing header")
    }

    /// The rule the whole filter exists for: a command whose status nothing
    /// reported is unknown, and unknown is neither a failure nor a success.
    func testUnknownStatusIsNotAFailure() {
        var filter = CommandBlockFilter(outcome: .failed)
        XCTAssertTrue(filter.matches(blocks[0]))   // exit 2
        XCTAssertFalse(filter.matches(blocks[1]))  // exit 0
        XCTAssertFalse(filter.matches(blocks[2]))  // no status reported

        filter.outcome = .all
        XCTAssertTrue(blocks.allSatisfy(filter.matches))
    }

    func testRunningFilter() {
        let running = CommandBlock(command: "tail -f", state: .running)
        let filter = CommandBlockFilter(outcome: .running)
        XCTAssertTrue(filter.matches(running))
        XCTAssertFalse(filter.matches(blocks[0]))
    }

    func testFilterCombinesOutcomeAndQuery() {
        let filter = CommandBlockFilter(outcome: .failed, query: "header")
        XCTAssertTrue(filter.matches(blocks[0]))
        XCTAssertFalse(CommandBlockFilter(outcome: .failed, query: "nothing").matches(blocks[0]))
    }

    func testInactiveFilterReturnsEverythingUntouched() {
        var store = CommandBlockStore()
        for block in blocks { store.apply(.opened(block)) }
        XCTAssertEqual(store.filtered(by: CommandBlockFilter()).count, 3)
    }
}
