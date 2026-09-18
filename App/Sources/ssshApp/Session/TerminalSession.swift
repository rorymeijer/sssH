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
final class TerminalSession: Identifiable {
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

    /// The raw transport error behind ``failure``, kept so the session layer
    /// can act on a specific one — a missing key passphrase is answerable and
    /// retryable, where a refused password is not.
    private(set) var transportFailure: SSHTransportError?

    private let transport: any SSHTransport
    private let hostKeyPolicy: SSHKnownHostsPolicy
    private let shellConfiguration: SSHShellConfiguration
    /// Set when a connection is attempted; a retry reuses it.
    private var destination: SSHDestination?

    private var shell: (any SSHShellSession)?
    private var outputTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var keepAlive: KeepAliveMonitor?

    /// Where terminal output goes once a view is attached.
    private var outputSink: (([UInt8]) -> Void)?
    /// Output that arrived before a view attached.
    ///
    /// A connection can come up before its view is on screen — a restored
    /// session, or a fast localhost connect — and the login banner and first
    /// prompt would otherwise be lost, leaving an apparently dead terminal.
    private var pendingOutput: [UInt8] = []
    private static let pendingOutputLimit = 1 << 20

    init(
        hostDisplayName: String,
        endpoint: SSHEndpoint,
        transport: any SSHTransport,
        hostKeyPolicy: SSHKnownHostsPolicy,
        shellConfiguration: SSHShellConfiguration
    ) {
        self.hostDisplayName = hostDisplayName
        self.endpoint = endpoint
        self.transport = transport
        self.hostKeyPolicy = hostKeyPolicy
        self.shellConfiguration = shellConfiguration
    }

    // MARK: - Lifecycle

    func connect(to destination: SSHDestination) async {
        guard case .idle = state else { return }
        self.destination = destination
        await attemptConnection(destination)
    }

    /// A second attempt after the user supplied something the first was
    /// missing, such as a key passphrase.
    func retry(with destination: SSHDestination) async {
        self.destination = destination
        state = .idle
        await attemptConnection(destination)
    }

    /// The user cancelled before anything was attempted — a dismissed password
    /// sheet. Distinct from a failure, and shown as such.
    func cancelBeforeConnecting() {
        state = .disconnected(.userInitiated)
    }

    private func attemptConnection(_ destination: SSHDestination) async {
        failure = nil
        transportFailure = nil
        exit = nil
        observeTransportState()

        do {
            try await transport.connect(to: destination, hostKeyPolicy: hostKeyPolicy)
            let shell = try await transport.openShell(shellConfiguration)
            self.shell = shell
            pumpOutput(from: shell)
            startKeepAlive(policy: destination.keepAlive)
        } catch {
            transportFailure = error as? SSHTransportError
            failure = ConnectionFailureText.describe(error)
            state = .disconnected(.failed(failure ?? ""))
            // Tear the connection down rather than leaving a half-open socket
            // behind a failed handshake.
            await transport.disconnect()
        }
    }

    func disconnect() async {
        outputTask?.cancel()
        stateTask?.cancel()
        outputTask = nil
        stateTask = nil

        await keepAlive?.stop()
        keepAlive = nil

        await shell?.close()
        shell = nil
        await transport.disconnect()
    }

    private func observeTransportState() {
        stateTask?.cancel()
        let stream = transport.stateStream()
        stateTask = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                await MainActor.run { self.state = state }
            }
        }
    }

    private func startKeepAlive(policy: SSHKeepAlivePolicy) {
        guard policy.isEnabled else { return }
        let monitor = KeepAliveMonitor(
            transport: transport,
            policy: policy
        ) { [weak self] in
            // Reporting only. Deciding whether to reconnect is Phase 2's job,
            // and doing it from here would reconnect sessions the user has
            // already walked away from.
            await MainActor.run {
                self?.state = .disconnected(.keepAliveTimeout)
            }
        }
        keepAlive = monitor
        Task { await monitor.start() }
    }

    // MARK: - Output

    /// Called by the terminal view when it appears.
    func attachOutput(_ sink: @escaping ([UInt8]) -> Void) {
        outputSink = sink
        if !pendingOutput.isEmpty {
            let buffered = pendingOutput
            pendingOutput.removeAll()
            sink(buffered)
        }
    }

    func detachOutput() {
        outputSink = nil
    }

    private func pumpOutput(from shell: any SSHShellSession) {
        outputTask?.cancel()
        outputTask = Task { [weak self] in
            do {
                for try await event in shell.events {
                    guard let self else { return }
                    await MainActor.run { self.handle(event) }
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    self.failure = ConnectionFailureText.describe(error)
                    self.state = .disconnected(.failed(self.failure ?? ""))
                }
            }
        }
    }

    private func handle(_ event: SSHShellEvent) {
        switch event {
        case .output(let bytes), .errorOutput(let bytes):
            deliver(bytes)
        case .exit(let exit):
            self.exit = exit
            state = .disconnected(.remoteClosed)
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        if let outputSink {
            outputSink(bytes)
            return
        }
        // No view yet. Keep a bounded amount: a runaway process writing to a
        // detached session must not grow this without limit, and the oldest
        // output is the least useful when the view finally appears.
        pendingOutput.append(contentsOf: bytes)
        if pendingOutput.count > Self.pendingOutputLimit {
            pendingOutput.removeFirst(pendingOutput.count - Self.pendingOutputLimit)
        }
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
        guard let shell else { return }
        let size = TerminalSize(columns: columns, rows: rows)
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
