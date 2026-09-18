import Foundation
import Observation
import ssshCore

/// One connection and the interactive shell on it, in the form the UI needs.
///
/// Main-actor isolated because everything it publishes drives SwiftUI, and
/// because terminal output has to reach SwiftTerm on the main thread anyway.
/// The network work all happens inside the transport, off-main, and arrives
/// here through `await`.
@MainActor
@Observable
final class TerminalSession: TerminalFeed {
    let id = UUID()
    let hostDisplayName: String
    let endpoint: SSHEndpoint

    private(set) var state: SSHConnectionState = .idle
    /// The title the remote shell asked for, via OSC 0/2. Falls back to the
    /// host's name so a tab is never blank.
    private(set) var remoteTitle: String?
    /// Set when something failed in a way worth showing. Cleared on a retry.
    private(set) var failure: String?
    private(set) var exit: SSHShellExit?
    /// The raw transport error behind ``failure``, kept so the session layer
    /// can act on a specific one — a missing key passphrase is answerable and
    /// retryable, where a refused password is not.
    private(set) var transportFailure: SSHTransportError?
    /// Non-nil while waiting out a reconnect backoff, for the UI to count down.
    private(set) var retryingAt: Date?

    var title: String { remoteTitle ?? hostDisplayName }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .connecting, .authenticating, .reconnecting: return true
        default: return false
        }
    }

    /// When false, this session does not read its own channel: something else
    /// does. tmux control mode is the reason — there the channel carries a
    /// protocol rather than terminal output, and the tmux controller consumes
    /// it. The event stream has one consumer, so this has to be a choice rather
    /// than both.
    private let readsOwnOutput: Bool

    /// Called each time a shell is opened, including after a reconnect, so a
    /// tmux controller can take the new channel over. A reconnect is exactly
    /// when tmux reattaches and replays its layout.
    var onShellOpened: ((any SSHShellSession) -> Void)?

    private let transport: any SSHTransport
    private let hostKeyPolicy: SSHKnownHostsPolicy
    private let shellConfiguration: SSHShellConfiguration
    private let reconnectPolicy: ReconnectPolicy

    private var shell: (any SSHShellSession)?
    private var supervisor: ConnectionSupervisor?
    private var outputTask: Task<Void, Never>?

    /// The size the terminal view last reported. Reapplied after a reconnect,
    /// because the new PTY is created at the configured default and the view
    /// will not necessarily lay out again to tell us.
    private var lastKnownSize: TerminalSize?

    private let output = PendingOutputBuffer()

    init(
        hostDisplayName: String,
        endpoint: SSHEndpoint,
        transport: any SSHTransport,
        hostKeyPolicy: SSHKnownHostsPolicy,
        shellConfiguration: SSHShellConfiguration,
        reconnectPolicy: ReconnectPolicy = .default,
        readsOwnOutput: Bool = true
    ) {
        self.hostDisplayName = hostDisplayName
        self.endpoint = endpoint
        self.transport = transport
        self.hostKeyPolicy = hostKeyPolicy
        self.shellConfiguration = shellConfiguration
        self.reconnectPolicy = reconnectPolicy
        self.readsOwnOutput = readsOwnOutput
    }

    // MARK: - Lifecycle

    /// Connects, and keeps the connection up for as long as the session is open.
    func connect(to destination: SSHDestination) async {
        guard supervisor == nil else { return }

        failure = nil
        transportFailure = nil
        exit = nil

        let supervisor = ConnectionSupervisor(
            transport: transport,
            destination: destination,
            hostKeyPolicy: hostKeyPolicy,
            policy: reconnectPolicy,
            reestablish: { [weak self] in
                try await self?.openShell()
            },
            onEvent: { [weak self] event in
                await self?.handle(event)
            }
        )
        self.supervisor = supervisor
        await supervisor.start()
    }

    /// A second attempt after the user supplied something the first was
    /// missing, such as a key passphrase.
    func retry(with destination: SSHDestination) async {
        await supervisor?.stop()
        supervisor = nil
        state = .idle
        await connect(to: destination)
    }

    /// The user cancelled before anything was attempted — a dismissed password
    /// sheet. Distinct from a failure, and shown as such.
    func cancelBeforeConnecting() {
        state = .disconnected(.userInitiated)
    }

    func disconnect() async {
        outputTask?.cancel()
        outputTask = nil

        await shell?.close()
        shell = nil

        await supervisor?.stop()
        supervisor = nil

        state = .disconnected(.userInitiated)
    }

    /// Opens the shell. Runs on every connection, including reconnections,
    /// which is why the size is reapplied here rather than only at startup.
    private func openShell() async throws {
        let shell = try await transport.openShell(shellConfiguration)
        await MainActor.run {
            self.shell = shell
            if self.readsOwnOutput {
                self.pumpOutput(from: shell)
            } else {
                self.onShellOpened?(shell)
            }
        }
        if let size = await MainActor.run(body: { self.lastKnownSize }) {
            try? await shell.resize(to: size)
        }
    }

    private func handle(_ event: ConnectionSupervisor.Event) async {
        await MainActor.run {
            switch event {
            case .connecting(let attempt):
                retryingAt = nil
                state = attempt == 1 ? .connecting : .reconnecting(attempt: attempt, nextAttemptIn: .zero)

            case .connected:
                retryingAt = nil
                failure = nil
                transportFailure = nil
                state = .connected(SSHConnectionInfo(
                    endpoint: endpoint,
                    username: "",
                    hostKey: SSHHostKey(algorithm: "", wireFormat: []),
                    authenticatedWith: ""
                ))

            case .waitingToRetry(let attempt, let delay):
                retryingAt = Date().addingTimeInterval(delay.seconds)
                state = .reconnecting(attempt: attempt, nextAttemptIn: delay)

            case .gaveUp(let lastError):
                retryingAt = nil
                failure = lastError
                state = .disconnected(.failed(lastError))

            case .stopped(let reason):
                retryingAt = nil
                if case .failed(let detail) = reason {
                    failure = detail
                }
                state = .disconnected(reason)
            }
        }
    }

    /// Records the real connection details once they are known. The supervisor
    /// reports success without them, because it does not carry them.
    func recordConnectionInfo(_ info: SSHConnectionInfo) {
        if case .connected = state {
            state = .connected(info)
        }
    }

    // MARK: - Output

    func attachOutput(_ sink: @escaping ([UInt8]) -> Void) {
        output.attach(sink)
    }

    func detachOutput() {
        output.detach()
    }

    func close() async {
        await disconnect()
    }

    /// What to show above this terminal.
    var statusBanner: TerminalStatus {
        if case .reconnecting(let attempt, _) = state {
            return .reconnecting(attempt: attempt, retryingAt: retryingAt)
        }
        if let failure {
            return .failed(failure)
        }
        if let exit, !exit.isSuccess {
            return .exited(exit)
        }
        return .none
    }

    private func pumpOutput(from shell: any SSHShellSession) {
        outputTask?.cancel()
        outputTask = Task { [weak self] in
            do {
                for try await event in shell.events {
                    guard let self else { return }
                    await MainActor.run { self.handle(event) }
                }
                // The stream ended without an error: the channel closed. Only
                // the supervisor decides whether that is worth reconnecting.
                await self?.reportChannelClosed(.remoteClosed)
            } catch {
                guard let self else { return }
                let description = ConnectionFailureText.describe(error)
                await MainActor.run { self.failure = description }
                await self.reportChannelClosed(.failed(description))
            }
        }
    }

    private func reportChannelClosed(_ reason: SSHDisconnectReason) async {
        // A shell that exited normally is not a connection failure, so it must
        // not trigger a reconnect: the user typed `exit`.
        let endedNormally = await MainActor.run { self.exit != nil }
        guard !endedNormally else {
            await MainActor.run { self.state = .disconnected(.remoteClosed) }
            return
        }
        await supervisor?.reportConnectionLost(reason)
    }

    private func handle(_ event: SSHShellEvent) {
        switch event {
        case .output(let bytes), .errorOutput(let bytes):
            deliver(bytes)
        case .exit(let exit):
            self.exit = exit
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        output.deliver(bytes)
    }

    // MARK: - Input

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let shell else { return }
        Task {
            do {
                try await shell.write(bytes)
            } catch {
                await MainActor.run { self.failure = ConnectionFailureText.describe(error) }
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        let size = TerminalSize(columns: columns, rows: rows)
        lastKnownSize = size

        guard let shell else { return }
        Task {
            // `resize(to:)` already ignores a size that has not changed, so a
            // live drag costs nothing beyond this hop.
            try? await shell.resize(to: size)
        }
    }

    func updateRemoteTitle(_ title: String) {
        remoteTitle = title.isEmpty ? nil : title
    }
}
