import Foundation

/// Probes a connection on a schedule and reports it dead when the server stops
/// answering.
///
/// Written against ``SSHTransport`` only, so it is backend-agnostic and can be
/// tested against a fake transport with no network at all. The transport does
/// the probing; the policy — how often, how long to wait, how many misses are
/// fatal — lives here, where the session layer can see and change it.
///
/// It reports rather than acts: deciding whether to reconnect belongs to the
/// session layer, which knows whether the user is looking at the session.
public actor KeepAliveMonitor {
    private let transport: any SSHTransport
    private let policy: SSHKeepAlivePolicy
    private let onConnectionDead: @Sendable () async -> Void
    private let sleep: @Sendable (Duration) async throws -> Void

    private var task: Task<Void, Never>?
    private var consecutiveMisses = 0

    /// - Parameter sleep: injected so tests can run the whole schedule
    ///   instantly instead of waiting on a clock.
    public init(
        transport: any SSHTransport,
        policy: SSHKeepAlivePolicy,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onConnectionDead: @escaping @Sendable () async -> Void
    ) {
        self.transport = transport
        self.policy = policy
        self.sleep = sleep
        self.onConnectionDead = onConnectionDead
    }

    /// Number of probes in a row that went unanswered. Exposed for tests and
    /// for a connection-quality indicator in the UI.
    public var missedProbes: Int { consecutiveMisses }

    public func start() {
        guard policy.isEnabled, task == nil else { return }

        task = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        consecutiveMisses = 0
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await sleep(policy.interval)
            } catch {
                return  // cancelled
            }

            guard !Task.isCancelled else { return }

            // Nothing to probe unless we are actually connected; a
            // reconnecting or idle transport is the session layer's problem.
            guard case .connected = transport.currentState else {
                consecutiveMisses = 0
                continue
            }

            do {
                try await transport.sendKeepAliveProbe(timeout: policy.timeout)
                consecutiveMisses = 0
            } catch is CancellationError {
                return
            } catch {
                consecutiveMisses += 1
                if consecutiveMisses >= policy.missedProbesBeforeDisconnect {
                    await onConnectionDead()
                    return
                }
            }
        }
    }
}
