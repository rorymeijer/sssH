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

    /// Called once per established connection, after the shell is up.
    ///
    /// Separate from ``onShellOpened`` because it fires for a tmux session
    /// too, and because what it is for — restarting the tunnels that were
    /// meant to start automatically — has nothing to do with the shell. A
    /// reconnect is a new connection, so every listener on the old one is
    /// already gone and has to be rebuilt.
    var onConnectionEstablished: (() async -> Void)?

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
    let blocks = SessionBlocks()

    /// The tunnels running on this connection.
    ///
    /// `lazy` because it needs `self`, and `@ObservationIgnored` because the
    /// reference never changes — what the UI observes is the controller's own
    /// state, not this property.
    @ObservationIgnored private(set) lazy var tunnels = TunnelController(session: self)

    private var sftpService: (any SFTPService)?
    /// Held so that two browsers opening at once share one channel instead of
    /// racing to open two.
    private var sftpTask: Task<any SFTPService, Error>?

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
        blocks.finish()
        await tunnels.stopAll()
        await closeSFTP()
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

        let established = await MainActor.run { self.onConnectionEstablished }
        await established?()
    }

    private func handle(_ event: ConnectionSupervisor.Event) async {
        await MainActor.run {
            switch event {
            case .connecting(let attempt):
                retryingAt = nil
                state = attempt == 1 ? .connecting : .reconnecting(attempt: attempt, nextAttemptIn: .zero)
                if attempt > 1 {
                    // The SFTP channel belonged to the connection that just
                    // went away. Callers ask for it per operation, so dropping
                    // it here is all the next one needs to open a fresh one.
                    Task { await self.closeSFTP() }
                    // The tunnels went with it. There is nothing to cancel on
                    // a socket that is gone, so they are forgotten rather than
                    // stopped, and rebuilt when the connection comes back.
                    tunnels.connectionLost()
                }

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

    // MARK: - File transfer

    /// Opens an SFTP channel on this session's connection.
    ///
    /// One per session, shared by every file browser and every transfer:
    /// opening a channel per transfer works, but a queue of thirty files then
    /// opens thirty channels, and servers have limits.
    func sftp() async throws -> any SFTPService {
        if let sftpService { return sftpService }
        if let inFlight = sftpTask { return try await inFlight.value }

        let task = Task<any SFTPService, Error> { [transport] in
            try await transport.openSFTP()
        }
        sftpTask = task
        do {
            let service = try await task.value
            sftpService = service
            sftpTask = nil
            return service
        } catch {
            sftpTask = nil
            throw error
        }
    }

    /// The port-forwarding service for this connection.
    ///
    /// Not cached, unlike the SFTP channel: it holds no channel of its own, it
    /// is a handle on the connection's handler, and a stale one after a
    /// reconnect would be a tunnel that silently attaches to a socket that is
    /// gone.
    func portForwarding() async throws -> any PortForwardService {
        try await transport.portForwarding()
    }

    /// Runs one command on its own `exec` channel and returns what it printed
    /// to stdout.
    ///
    /// For the server monitor and other read-only sampling. Interactive work
    /// belongs in the shell; this channel has no PTY and merges nothing.
    func runCommand(_ command: String) async throws -> String {
        let channel = try await transport.execute(command, environment: [:])
        var bytes: [UInt8] = []
        for try await event in channel.events {
            switch event {
            case .output(let chunk):
                bytes.append(contentsOf: chunk)
            case .errorOutput, .exit:
                // stderr is login-script noise here, and the exit status does
                // not change what was printed.
                break
            }
        }
        await channel.close()
        return String(decoding: bytes, as: UTF8.self)
    }

    private func closeSFTP() async {
        sftpTask?.cancel()
        sftpTask = nil
        let service = sftpService
        sftpService = nil
        await service?.close()
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
            blocks.finish()
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        blocks.consumeOutput(bytes)
        output.deliver(bytes)
    }

    // MARK: - Input

    func send(_ bytes: ArraySlice<UInt8>) {
        blocks.consumeInput(bytes)
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
