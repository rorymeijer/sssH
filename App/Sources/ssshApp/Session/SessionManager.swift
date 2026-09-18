import Foundation
import Observation
import SwiftData
import ssshCore

/// Owns the open sessions and the tab strip.
///
/// One transport per session, not one per app: sessions to the same host are
/// independent connections in Phase 1. Sharing one connection between tabs is
/// what the transport's channel multiplexing is for, and it arrives with splits
/// in Phase 2 — doing it now would tangle tab lifetimes with connection
/// lifetimes before there is a UI that needs it.
@MainActor
@Observable
final class SessionManager {
    private(set) var sessions: [TerminalSession] = []
    var selectedSessionID: TerminalSession.ID?

    private let transportFactory: any SSHTransportFactory
    private let secretsStore: any SecretsStore
    private let knownHosts: any SSHKnownHostsStore
    private let hostKeyPrompts: HostKeyPromptCoordinator
    private let credentialPrompts: CredentialPromptCoordinator

    init(
        transportFactory: any SSHTransportFactory,
        secretsStore: any SecretsStore,
        knownHosts: any SSHKnownHostsStore,
        hostKeyPrompts: HostKeyPromptCoordinator,
        credentialPrompts: CredentialPromptCoordinator
    ) {
        self.transportFactory = transportFactory
        self.secretsStore = secretsStore
        self.knownHosts = knownHosts
        self.hostKeyPrompts = hostKeyPrompts
        self.credentialPrompts = credentialPrompts
    }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    // MARK: - Opening

    /// Opens a tab for `host` and starts connecting.
    ///
    /// The tab appears immediately, in its connecting state, rather than after
    /// the handshake: a host-key prompt or a password sheet has to have
    /// somewhere to belong, and a UI that does nothing for several seconds
    /// looks broken.
    @discardableResult
    func open(_ host: Host) -> TerminalSession {
        let session = makeSession(for: host)
        sessions.append(session)
        selectedSessionID = session.id

        Task { [weak self] in
            await self?.connect(session, host: host)
        }

        return session
    }

    private func makeSession(for host: Host) -> TerminalSession {
        let policy = SSHKnownHostsPolicy(
            store: knownHosts,
            verifier: InteractiveHostKeyVerifier(coordinator: hostKeyPrompts)
        )

        let configuration = SSHShellConfiguration(
            terminalType: .xterm256Color,
            // The real size arrives from SwiftTerm as soon as the view lays
            // out; this is only what the PTY is created with.
            initialSize: .default,
            environment: host.environment,
            startupCommand: host.startupCommand
        )

        return TerminalSession(
            hostDisplayName: host.displayName,
            endpoint: host.endpoint,
            transport: transportFactory.makeTransport(),
            hostKeyPolicy: policy,
            shellConfiguration: configuration
        )
    }

    private func connect(_ session: TerminalSession, host: Host) async {
        guard let credentials = await resolveCredentials(for: host) else {
            session.cancelBeforeConnecting()
            return
        }

        let resolved = await host.destination(credentials: credentials) { hop in
            // Each bastion authenticates separately. A hop whose secret is
            // missing contributes nothing rather than failing the whole chain
            // here — the server's own refusal is a better message than a guess.
            await self.storedCredentials(for: hop) ?? []
        }

        await session.connect(to: resolved)

        // A key whose passphrase is not stored shows up as a specific failure
        // rather than as a refusal, so it can be answered and retried once.
        if case .some(.credentialUnusable(let label, .passphraseRequired)) = session.transportFailure {
            let answer = await credentialPrompts.askForSecret(
                .passphrase(keyLabel: label),
                label: String(localized: "Wachtwoordzin", comment: "Field label in the passphrase prompt")
            )
            guard let answer, let passphrase = answer.values.first else {
                return
            }
            var retry = resolved
            retry.credentials = credentials.map { credential in
                guard case .privateKey(var material) = credential else { return credential }
                material.passphrase = passphrase
                return .privateKey(material)
            }
            if answer.remember {
                await rememberPassphrase(passphrase, for: host)
            }
            await session.retry(with: retry)
        }
    }

    // MARK: - Credentials

    private func resolveCredentials(for host: Host) async -> [SSHCredential]? {
        // Keyboard-interactive is always offered last. It costs nothing when
        // the server does not advertise it — the transport skips a credential
        // whose method the server will not take — and when it does, it is how
        // a one-time code gets asked for. Offering it before a stored key would
        // prompt someone who did not need prompting.
        let challenge = SSHCredential.keyboardInteractive(
            InteractiveKeyboardHandler(coordinator: credentialPrompts)
        )

        switch host.authenticationMethod {
        case .password, .privateKey:
            if let stored = await storedCredentials(for: host) {
                return stored + [challenge]
            }
            // The model says there is a secret but the Keychain does not have
            // it — a restored device, or a secret deleted out from under us.
            // Asking is better than failing with something inscrutable.
            guard let asked = await askForPassword(host: host) else { return nil }
            return asked + [challenge]

        case .askEveryTime:
            guard let asked = await askForPassword(host: host) else { return nil }
            return asked + [challenge]
        }
    }

    private func storedCredentials(for host: Host) async -> [SSHCredential]? {
        guard let reference = host.secretReference else { return nil }
        guard let secret = try? await secretsStore.secret(for: reference) else { return nil }
        return secret.credentials()
    }

    private func askForPassword(host: Host) async -> [SSHCredential]? {
        let answer = await credentialPrompts.askForSecret(
            .password(username: host.username, endpoint: host.endpoint),
            label: String(localized: "Wachtwoord", comment: "Field label in the password prompt")
        )
        guard let answer, let password = answer.values.first else { return nil }

        if answer.remember {
            let reference = host.secretReference ?? SecretReference.makeUnique()
            try? await secretsStore.store(.password(password), for: reference)
            host.secretReference = reference
            host.authenticationMethod = .password
            host.updatedAt = Date()
        }

        return [.password(password)]
    }

    private func rememberPassphrase(_ passphrase: SecretString, for host: Host) async {
        guard let reference = host.secretReference,
              let existing = try? await secretsStore.secret(for: reference),
              case .privateKey(let openSSH, _) = existing
        else {
            return
        }
        try? await secretsStore.store(
            .privateKey(openSSH: openSSH, passphrase: passphrase),
            for: reference
        )
    }

    // MARK: - Closing

    func close(_ session: TerminalSession) {
        sessions.removeAll { $0.id == session.id }

        if selectedSessionID == session.id {
            selectedSessionID = sessions.last?.id
        }

        Task { await session.disconnect() }
    }

    /// Closes the tab that is on screen. Bound to Command-W.
    func closeSelected() {
        guard let session = selectedSession else { return }
        close(session)
    }

    func closeAll() {
        let open = sessions
        sessions.removeAll()
        selectedSessionID = nil
        hostKeyPrompts.rejectAll()
        credentialPrompts.cancelAll()

        Task {
            for session in open {
                await session.disconnect()
            }
        }
    }
}
