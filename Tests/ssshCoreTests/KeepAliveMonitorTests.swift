import Foundation
import XCTest
@testable import ssshCore

final class KeepAliveMonitorTests: XCTestCase {
    /// Time is injected, so the whole schedule runs instantly instead of
    /// taking `interval * missesAllowed` seconds of wall clock.
    private let instantSleep: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .milliseconds(1)) }

    func testReportsDeathAfterTheConfiguredNumberOfMissedProbes() async throws {
        let transport = FakeTransport(probeBehaviour: .fail)
        let died = Expectation()

        let monitor = KeepAliveMonitor(
            transport: transport,
            policy: SSHKeepAlivePolicy(interval: .seconds(1), timeout: .seconds(1), missedProbesBeforeDisconnect: 3),
            sleep: instantSleep,
            onConnectionDead: { await died.fulfil() }
        )

        await monitor.start()
        try await died.wait(timeout: .seconds(5))

        XCTAssertEqual(transport.probesSent, 3, "it must not give up early, nor keep probing after declaring death")
        await monitor.stop()
    }

    func testASuccessfulProbeResetsTheMissCounter() async throws {
        // Two failures, a success, then failures forever: with a limit of 3 the
        // connection must survive the first pair.
        let transport = FakeTransport(probeBehaviour: .failThenSucceed(count: 2))
        let died = Expectation()

        let monitor = KeepAliveMonitor(
            transport: transport,
            policy: SSHKeepAlivePolicy(interval: .seconds(1), timeout: .seconds(1), missedProbesBeforeDisconnect: 3),
            sleep: instantSleep,
            onConnectionDead: { await died.fulfil() }
        )

        await monitor.start()

        // Let a number of probes go through; all should be answered after the
        // first two.
        try await Task.sleep(for: .milliseconds(200))
        await monitor.stop()

        let missed = await monitor.missedProbes
        XCTAssertFalse(died.isFulfilled)
        XCTAssertEqual(missed, 0)
    }

    func testDoesNotProbeWhileDisconnected() async throws {
        let transport = FakeTransport(state: .disconnected(.userInitiated), probeBehaviour: .fail)
        let died = Expectation()

        let monitor = KeepAliveMonitor(
            transport: transport,
            policy: .default,
            sleep: instantSleep,
            onConnectionDead: { await died.fulfil() }
        )

        await monitor.start()
        try await Task.sleep(for: .milliseconds(100))
        await monitor.stop()

        XCTAssertEqual(transport.probesSent, 0, "probing a transport that is not connected would report a false death")
        XCTAssertFalse(died.isFulfilled)
    }

    func testDisabledPolicyNeverProbes() async throws {
        let transport = FakeTransport(probeBehaviour: .fail)
        let monitor = KeepAliveMonitor(
            transport: transport,
            policy: .disabled,
            sleep: instantSleep,
            onConnectionDead: {}
        )

        await monitor.start()
        try await Task.sleep(for: .milliseconds(100))
        await monitor.stop()

        XCTAssertEqual(transport.probesSent, 0)
    }

    // MARK: - Helpers

    private final class Expectation: @unchecked Sendable {
        private let lock = NSLock()
        private var fulfilled = false

        func fulfil() {
            lock.lock()
            fulfilled = true
            lock.unlock()
        }

        var isFulfilled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fulfilled
        }

        func wait(timeout: Duration) async throws {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if isFulfilled { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw Timeout()
        }

        struct Timeout: Error {}
    }
}
