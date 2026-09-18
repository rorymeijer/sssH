import Foundation
import XCTest
@testable import ssshCore

/// The sink is where terminal output can be silently corrupted, so these tests
/// are about two properties above all: nothing is lost, and nothing is
/// reordered — even when the consumer is slower than the producer.
final class SSHShellEventSinkTests: XCTestCase {
    func testDeliversEventsInOrder() async throws {
        let sink = SSHShellEventSink()
        let stream = sink.makeStream()

        for index in 0..<50 {
            sink.push(.output([UInt8(index)]))
        }
        sink.push(.exit(SSHShellExit(status: 0)))
        sink.finish()

        var received: [UInt8] = []
        var exit: SSHShellExit?
        for try await event in stream {
            switch event {
            case .output(let bytes): received.append(contentsOf: bytes)
            case .errorOutput: XCTFail("unexpected stderr event")
            case .exit(let status): exit = status
            }
        }

        XCTAssertEqual(received, Array(0..<50).map(UInt8.init))
        XCTAssertEqual(exit?.status, 0)
    }

    func testEventsQueuedBeforeFinishAreDeliveredBeforeTheError() async throws {
        let sink = SSHShellEventSink()
        let stream = sink.makeStream()

        struct Boom: Error {}
        sink.push(.output(Array("tail of the output".utf8)))
        sink.finish(throwing: Boom())

        var received: [UInt8] = []
        do {
            for try await event in stream {
                if case .output(let bytes) = event { received.append(contentsOf: bytes) }
            }
            XCTFail("expected the stream to throw")
        } catch is Boom {
            // Output produced immediately before a failure is exactly what a
            // user needs to see, so it must not be discarded with the error.
            XCTAssertEqual(String(decoding: received, as: UTF8.self), "tail of the output")
        }
    }

    func testReadsAreSuspendedAboveHighWaterMarkAndResumedBelowLow() async throws {
        let configuration = SSHShellEventSink.Configuration(highWaterMark: 100, lowWaterMark: 40)
        let sink = SSHShellEventSink(configuration: configuration)
        let stream = sink.makeStream()

        let demands = Counter()
        sink.onDemandForMoreData { demands.increment() }

        // Below the high water mark the producer is told to keep reading.
        sink.push(.output([UInt8](repeating: 0, count: 50)))
        XCTAssertTrue(sink.shouldContinueReading())

        // Crossing it stops reads, and no demand has been signalled yet.
        sink.push(.output([UInt8](repeating: 0, count: 60)))
        XCTAssertFalse(sink.shouldContinueReading())
        XCTAssertEqual(demands.value, 0)

        var iterator = stream.makeAsyncIterator()

        // Draining the first chunk leaves 60 buffered — still above the low
        // water mark of 40, so reads stay suspended.
        _ = try await iterator.next()
        XCTAssertEqual(demands.value, 0)

        // Draining the second drops to 0, which is at or below the low water
        // mark, so the producer is woken exactly once.
        _ = try await iterator.next()
        XCTAssertEqual(demands.value, 1)
    }

    func testShouldContinueReadingIsTrueWhenEmpty() {
        let sink = SSHShellEventSink(configuration: .init(highWaterMark: 10, lowWaterMark: 5))
        XCTAssertTrue(sink.shouldContinueReading())
    }

    func testPushAfterFinishIsDropped() async throws {
        let sink = SSHShellEventSink()
        let stream = sink.makeStream()

        sink.finish()
        sink.push(.output([1, 2, 3]))

        var count = 0
        for try await _ in stream { count += 1 }
        XCTAssertEqual(count, 0, "data arriving after teardown must not be replayed to a consumer that has been told the session ended")
    }

    func testConsumerWaitingIsResumedByALaterPush() async throws {
        let sink = SSHShellEventSink()
        let stream = sink.makeStream()

        let task = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        // Give the consumer time to park on an empty queue.
        try await Task.sleep(for: .milliseconds(50))
        sink.push(.output(Array("late".utf8)))

        let event = try await task.value
        guard case .output(let bytes) = event else { return XCTFail("expected output, got \(String(describing: event))") }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "late")
    }

    func testCancellingTheConsumerEndsTheStream() async throws {
        let sink = SSHShellEventSink()
        let stream = sink.makeStream()

        let task = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
}
