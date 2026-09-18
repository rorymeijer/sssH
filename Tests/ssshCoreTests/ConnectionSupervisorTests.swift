import Foundation
import XCTest
@testable import ssshCore

/// Reconnection behaviour, driven with no network and no clock.
///
/// The cases that matter are the ones where retrying is *wrong*: a refused
/// host key, and a connection the user closed. Retrying either is worse than
/// not reconnecting at all — one re-prompts about a possible
/// man-in-the-middle, the other resurrects sessions people walked away from.
final class ConnectionSupervisorTests: XCTestCase {
    private let instantSleep: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .milliseconds(1))
    }

    private func destination(keepAlive: SSHKeepAlivePolicy = .disabled) -> SSHDestination {
        SSHDestination(
            endpoint: SSHEndpoint(hostname: "fake.test"),
            username: "tester",
            credentials: [],
            keepAlive: keepAlive
        )
    }

    private func policy() -> SSHKnownHostsPolicy {
        SSHKnownHostsPolicy(store: EmptyKnownHosts(), verifier: RejectingHostKeyVerifier())
    }

    func testConnectsAndReportsSuccess() async {
        let transport = FakeTransport(state: .idle)
        let recorder = EventRecorder()

        let supervisor = ConnectionSupervisor(
            transport: transport,
            destination: destination(),
            hostKeyPolicy: policy(),
            sleep: instantSleep,
            reestablish: {},
            onEvent: { await recorder.record($0) }
        )

        let connected = await supervisor.start()

        XCTAssertTrue(connected)
        let events = await recorder.events
        XCTAssertEqual(events, ["connecting(1)", "connected"])
    }

    func testReestablishRunsOnEveryConnection() async {
        let transport = FakeTransport(state: .idle)
        let counter = Counter()

        let supervisor = ConnectionSupervisor(
            transport: transport,
            destination: destination(),
            hostKeyPolicy: policy(),
            sleep: instantSleep,
            reestablish: { counter.increment() },
            onEvent: { _ in }
        )

        await supervisor.start()
        // Reopening the shell is the work that has to be redone; a supervisor
        // that reconnects without it leaves a live connection and a dead
        // terminal.
        XCTAssertEqual(counter.value, 1)

        await supervisor.reportConnectionLost(.keepAliveTimeout)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThanOrEqual(counter.value, 2)

        await supervisor.stop()
    }

    func testAnUnexpectedDropIsRetried() async {
        let transport = FakeTransport(state: .idle)
        let recorder = EventRecorder()

        let supervisor = ConnectionSupervisor(
            transport: transport,
            destination: destination(),
            hostKeyPolicy: policy(),
            sleep: instantSleep,
            reestablish: {},
            onEvent: { await recorder.record($0) }
        )

        await supervisor.start()
        await supervisor.reportConnectionLost(.keepAliveTimeout)
        try? await Task.sleep(for: .milliseconds(200))

        let events = await recorder.events
        XCTAssertTrue(events.contains { $0.hasPrefix("waitingToRetry") }, "\(events)")
        XCTAssertEqual(events.last, "connected")

        await supervisor.stop()
    }

    func testAnExpectedCloseIsNotRetried() async {
        let transport = FakeTransport(state: .idle)
        let recorder = EventRecorder()

        let supervisor = ConnectionSupervisor(
            transport: transport,
            destination: destination(),
            hostKeyPolicy: policy(),
            sleep: instantSleep,
            reestablish: {},
            onEvent: { await recorder.record($0) }
        )

        await supervisor.start()
        // The user typed `exit`. Reconnecting here would reopen a session they
        // deliberately ended.
        await supervisor.reportConnectionLost(.remoteClosed)
        try? await Task.sleep(for: .milliseconds(150))

        let events = await recorder.events
        XCTAssertFalse(events.contains { $0.hasPrefix("waitingToRetry") }, "\(events)")
        XCTAssertEqual(events.last, "stopped")
    }

    func testARefusedHostKeyIsNeverRetried() async {
        let transport = FakeTransport(state: .idle, connectBehaviour: .hostKeyRejected)
        let recorder = EventRecorder()

        let supervisor = ConnectionSupervisor(
            transport: transport,
            destination: destination(),
            hostKeyPolicy: policy(),
            sleep: instantSleep,
            reestablish: {},
            onEvent: { await recorder.record($0) }
        )

        let connected = await supervisor.start()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(connected)
        let events = await recorder.events
        // Retrying would prompt again about a possible man-in-the-middle, which
        // is how people learn to click through the warning.
        XCTAssertFalse(events.contains { $0.hasPrefix("waitingToRetry") }, "\(events)")
        XCTAssertEqual(transport.connectAttempts, 1)
    }

    func testGivesUpAfterTheConfiguredNumberOfAttempts() async {
        let transport = FakeTransport(state: .idle, connectBehaviour: .fail)
        let recorder = EventRecorder()

        let supervisor = ConnectionSupervisor(
            transport: transport,
            destination: destination(),
            hostKeyPolicy: policy(),
            policy: ReconnectPolicy(initialDelay: .milliseconds(1), maximumAttempts: 3),
            sleep: instantSleep,
            reestablish: {},
            onEvent: { await recorder.record($0) }
        )

        await supervisor.start()
        await supervisor.reportConnectionLost(.keepAliveTimeout)
        try? await Task.sleep(for: .milliseconds(300))

        let events = await recorder.events
        XCTAssertEqual(events.last, "gaveUp", "\(events)")
    }

    func testStoppingCancelsAPendingRetry() async {
        let transport = FakeTransport(state: .idle, connectBehaviour: .fail)
        let recorder = EventRecorder()

        let supervisor = ConnectionSupervisor(
            transport: transport,
            destination: destination(),
            hostKeyPolicy: policy(),
            policy: ReconnectPolicy(initialDelay: .seconds(30)),
            reestablish: {},
            onEvent: { await recorder.record($0) }
        )

        await supervisor.start()
        await supervisor.reportConnectionLost(.keepAliveTimeout)
        await supervisor.stop()
        try? await Task.sleep(for: .milliseconds(100))

        let events = await recorder.events
        XCTAssertFalse(events.contains("connected") && events.last == "connected")
    }

    // MARK: - Doubles

    private actor EventRecorder {
        private(set) var events: [String] = []

        func record(_ event: ConnectionSupervisor.Event) {
            switch event {
            case .connecting(let attempt): events.append("connecting(\(attempt))")
            case .connected: events.append("connected")
            case .waitingToRetry(let attempt, _): events.append("waitingToRetry(\(attempt))")
            case .gaveUp: events.append("gaveUp")
            case .stopped: events.append("stopped")
            }
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

    private struct EmptyKnownHosts: SSHKnownHostsStore {
        func trustedKeys(for endpoint: SSHEndpoint) async -> [SSHHostKey] { [] }
        func remember(_ key: SSHHostKey, for endpoint: SSHEndpoint) async throws {}
        func forget(_ key: SSHHostKey, for endpoint: SSHEndpoint) async throws {}
    }
}
