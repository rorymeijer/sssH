import XCTest
@testable import ssshCore

final class FileTransferTests: XCTestCase {
    func testFractionIsNilWhenTheSizeIsUnknown() {
        var transfer = FileTransfer(direction: .download, remotePath: "/a", localPath: "/b")
        // A progress bar has to show indeterminate rather than invent a total.
        XCTAssertNil(transfer.fractionCompleted)

        transfer.totalBytes = 100
        transfer.transferredBytes = 25
        XCTAssertEqual(transfer.fractionCompleted, 0.25)

        // A server that under-reported the size must not produce a bar past
        // the end of its track.
        transfer.transferredBytes = 400
        XCTAssertEqual(transfer.fractionCompleted, 1)
    }

    func testZeroLengthFileDoesNotDivideByZero() {
        let transfer = FileTransfer(direction: .upload, remotePath: "/a", localPath: "/b", totalBytes: 0)
        XCTAssertNil(transfer.fractionCompleted)
    }

    func testTerminalStates() {
        XCTAssertTrue(FileTransfer.State.finished.isTerminal)
        XCTAssertTrue(FileTransfer.State.cancelled.isTerminal)
        XCTAssertTrue(FileTransfer.State.failed("x").isTerminal)
        XCTAssertFalse(FileTransfer.State.waiting.isTerminal)
        XCTAssertFalse(FileTransfer.State.running.isTerminal)
        XCTAssertFalse(FileTransfer.State.paused.isTerminal)
    }

    func testNameComesFromTheRemotePath() {
        let transfer = FileTransfer(direction: .download, remotePath: "/var/log/nginx/access.log", localPath: "/tmp/x")
        XCTAssertEqual(transfer.name, "access.log")
    }

    // MARK: - Rate

    func testRateNeedsTwoSamplesAndSomeTime() throws {
        var estimator = TransferRateEstimator()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertNil(estimator.bytesPerSecond)

        estimator.record(0, at: start)
        XCTAssertNil(estimator.bytesPerSecond)

        // Two samples a hair apart say nothing useful about the link speed.
        estimator.record(1000, at: start.addingTimeInterval(0.01))
        XCTAssertNil(estimator.bytesPerSecond)

        estimator.record(2000, at: start.addingTimeInterval(2))
        XCTAssertEqual(try XCTUnwrap(estimator.bytesPerSecond), 1000, accuracy: 1)
    }

    /// The reason for a window: a link that was fast and is now slow must
    /// report the speed it is now, not the average since the transfer began.
    func testRateFollowsTheRecentWindowNotTheWholeTransfer() throws {
        var estimator = TransferRateEstimator(window: 5)
        let start = Date(timeIntervalSince1970: 0)

        // 10 MB/s for ten seconds.
        for second in 0...10 {
            estimator.record(UInt64(second) * 10_000_000, at: start.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(try XCTUnwrap(estimator.bytesPerSecond), 10_000_000, accuracy: 100_000)

        // Then it collapses to 100 kB/s.
        for second in 11...20 {
            estimator.record(100_000_000 + UInt64(second - 10) * 100_000, at: start.addingTimeInterval(Double(second)))
        }
        let rate = try XCTUnwrap(estimator.bytesPerSecond)
        XCTAssertLessThan(rate, 1_000_000, "the window should have forgotten the fast part")
    }

    func testEstimatedTimeRemaining() throws {
        var estimator = TransferRateEstimator()
        let start = Date(timeIntervalSince1970: 0)
        estimator.record(0, at: start)
        estimator.record(1_000_000, at: start.addingTimeInterval(1))

        let remaining = try XCTUnwrap(estimator.estimatedTimeRemaining(totalBytes: 5_000_000))
        XCTAssertEqual(remaining, 4, accuracy: 0.2)

        // Nothing to say when the size is unknown, or when it is already there.
        XCTAssertNil(estimator.estimatedTimeRemaining(totalBytes: nil))
        XCTAssertNil(estimator.estimatedTimeRemaining(totalBytes: 1_000_000))
    }

    /// A server can report a size smaller than what actually arrives. The
    /// estimator must not produce a negative or wildly large number from it.
    func testRateIgnoresACounterThatWentBackwards() {
        var estimator = TransferRateEstimator()
        let start = Date(timeIntervalSince1970: 0)
        estimator.record(1000, at: start)
        estimator.record(500, at: start.addingTimeInterval(1))
        XCTAssertNil(estimator.bytesPerSecond)
    }
}
