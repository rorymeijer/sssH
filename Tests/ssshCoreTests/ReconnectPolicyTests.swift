import Foundation
import XCTest
@testable import ssshCore

final class ReconnectPolicyTests: XCTestCase {
    func testBackoffGrowsAndIsCapped() {
        let policy = ReconnectPolicy(
            initialDelay: .seconds(1),
            maximumDelay: .seconds(30),
            multiplier: 2,
            jitter: 0
        )

        XCTAssertEqual(policy.delay(forAttempt: 1, randomValue: 0).seconds, 1, accuracy: 0.001)
        XCTAssertEqual(policy.delay(forAttempt: 2, randomValue: 0).seconds, 2, accuracy: 0.001)
        XCTAssertEqual(policy.delay(forAttempt: 3, randomValue: 0).seconds, 4, accuracy: 0.001)
        XCTAssertEqual(policy.delay(forAttempt: 6, randomValue: 0).seconds, 30, accuracy: 0.001)
        XCTAssertEqual(policy.delay(forAttempt: 40, randomValue: 0).seconds, 30, accuracy: 0.001,
                       "a long-running reconnect must not overflow into an absurd delay")
    }

    func testJitterOnlyReducesTheDelay() {
        let policy = ReconnectPolicy(
            initialDelay: .seconds(10),
            maximumDelay: .seconds(10),
            multiplier: 2,
            jitter: 0.25
        )

        // Subtractive jitter keeps every delay inside [0.75 * cap, cap], which
        // is what stops twenty hosts reconnecting in lockstep without ever
        // exceeding the configured maximum.
        for random in stride(from: 0.0, through: 1.0, by: 0.1) {
            let delay = policy.delay(forAttempt: 1, randomValue: random).seconds
            XCTAssertLessThanOrEqual(delay, 10.0 + 0.001)
            XCTAssertGreaterThanOrEqual(delay, 7.5 - 0.001)
        }
    }

    func testAttemptLimits() {
        let unlimited = ReconnectPolicy()
        XCTAssertTrue(unlimited.shouldRetry(attempt: 1))
        XCTAssertTrue(unlimited.shouldRetry(attempt: 1_000))

        let never = ReconnectPolicy.never
        XCTAssertFalse(never.shouldRetry(attempt: 1))

        let thrice = ReconnectPolicy(maximumAttempts: 3)
        XCTAssertTrue(thrice.shouldRetry(attempt: 3))
        XCTAssertFalse(thrice.shouldRetry(attempt: 4))
    }

    func testJitterIsClamped() {
        XCTAssertEqual(ReconnectPolicy(jitter: 5).jitter, 1)
        XCTAssertEqual(ReconnectPolicy(jitter: -5).jitter, 0)
    }
}
