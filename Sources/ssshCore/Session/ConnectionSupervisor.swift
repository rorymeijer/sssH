import Foundation

/// Keeps one connection up: probes it, notices when it dies, and reconnects
/// with backoff.
///
/// Written against ``SSHTransport`` only, so it is backend-agnostic and can be
/// driven in tests with no network and no clock. The session layer supplies the
/// work to redo after a reconnect — reopening the shell — because only it knows
/// what the connection was for.
///
/// ## What it deliberately does not do
///
/// Reconnect a session the user closed, or one that ended because the remote
/// shell exited. Those are not failures, and retrying them would resurrect
/// sessions people have walked away from. Only an *unexpected* drop is retried.
public actor ConnectionSupervisor {
    public enum Event: Sendable {
        case connecting(attempt: Int)
        case connected
        case waitingToRetry(attempt: Int, delay: Duration)
        case gaveUp(lastError: String)
        /// The connection dropped and will not be retried, because the drop was
        /// expected or the policy forbids it.
        case stopped(SSHDisconnectReason)
    }

    private let transport: any SSHTransport
    private let destination: SSHDestination
    private let hostKeyPolicy: SSHKnownHostsPolicy
    private let policy: ReconnectPolicy
    private let onEvent: @Sendable (Event) async -> Void
    /// Everything that has to be redone on a fresh connection: opening the
    /// shell, restoring the terminal size, restarting tunnels.
    private let reestablish: @Sendable () async throws -> Void
    private let sleep: @Sendable (Duration) async throws -> Void

    private var supervision: Task<Void, Never>?
    private var keepAlive: KeepAliveMonitor?
    private var isStopped = false
    private var lastError = ""

    public init(
        transport: any SSHTransport,
        destination: SSHDestination,
        hostKeyPolicy: SSHKnownHostsPolicy,
        policy: ReconnectPolicy = .default,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        reestablish: @escaping @Sendable () async throws -> Void,
        onEvent: @escaping @Sendable (Event) async -> Void
    ) {
        self.transport = transport
        self.destination = destination
        self.hostKeyPolicy = hostKeyPolicy
        self.policy = policy
        self.sleep = sleep
        self.reestablish = reestablish
        self.onEvent = onEvent
    }

    /// Connects, and keeps it connected.
    ///
    /// - Returns: whether the first connection succeeded. The caller usually
    ///   wants to know, because a first failure deserves different treatment
    ///   from a later drop.
    @discardableResult
    public func start() async -> Bool {
        guard supervision == nil, !isStopped else { return transport.currentState.isConnected }

        let connected = await attemptConnection(attempt: 1)
        if connected {
            beginWatching()
        }
        return connected
    }

    public func stop() async {
        isStopped = true
        supervision?.cancel()
        supervision = nil
        await keepAlive?.stop()
        keepAlive = nil
        await transport.disconnect()
    }

    /// Called by the session layer when it notices the connection has gone —
    /// a closed channel usually surfaces there first.
    public func reportConnectionLost(_ reason: SSHDisconnectReason) async {
        await connectionDied(reason)
    }

    // MARK: - Connecting

    private func attemptConnection(attempt: Int) async -> Bool {
        await onEvent(.connecting(attempt: attempt))

        do {
            try await transport.connect(to: destination, hostKeyPolicy: hostKeyPolicy)
            try await reestablish()
            await onEvent(.connected)
            return true
        } catch {
            lastError = String(describing: error)

            // A refused host key is never retried: the answer will not be
            // different in four seconds, and retrying would prompt again.
            if case SSHTransportError.hostKeyRejected = error {
                isStopped = true
                await onEvent(.stopped(.failed(lastError)))
                return false
            }

            await transport.disconnect()
            return false
        }
    }

    // MARK: - Watching

    private func beginWatching() {
        guard destination.keepAlive.isEnabled else { return }

        let monitor = KeepAliveMonitor(transport: transport, policy: destination.keepAlive) { [weak self] in
            await self?.connectionDied(.keepAliveTimeout)
        }
        keepAlive = monitor
        Task { await monitor.start() }
    }

    private func connectionDied(_ reason: SSHDisconnectReason) async {
        guard !isStopped else { return }

        await keepAlive?.stop()
        keepAlive = nil
        await transport.disconnect()

        guard reason.isUnexpected else {
            await onEvent(.stopped(reason))
            return
        }

        supervision?.cancel()
        supervision = Task { [weak self] in
            await self?.retryLoop()
        }
    }

    private func retryLoop() async {
        var attempt = 1

        while !Task.isCancelled, !isStopped, policy.shouldRetry(attempt: attempt) {
            let delay = policy.delay(forAttempt: attempt)
            await onEvent(.waitingToRetry(attempt: attempt, delay: delay))

            do {
                try await sleep(delay)
            } catch {
                return  // cancelled
            }

            guard !Task.isCancelled, !isStopped else { return }

            if await attemptConnection(attempt: attempt) {
                beginWatching()
                return
            }
            attempt += 1
        }

        if !isStopped {
            await onEvent(.gaveUp(lastError: lastError))
        }
    }
}

extension SSHConnectionState {
    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
