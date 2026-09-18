import Foundation
import Observation
import SwiftData
import ssshCore

/// Owns the open tabs, the panes inside them, and the connections behind those.
///
/// One transport per pane rather than one per host: two panes on the same
/// server are independent connections, so one dropping does not take the other
/// with it. Sharing a connection between panes is what SSH channel
/// multiplexing is for, and it is the obvious optimisation — but it couples
/// their lifetimes, and a tab where closing one pane kills its neighbour is
/// worse than a second TCP connection.
@MainActor
@Observable
final class SessionManager {
    private(set) var tabs: [TerminalTab] = []
    var selectedTabID: TerminalTab.ID?

    private let transportFactory: any SSHTransportFactory
    private let secretsStore: any SecretsStore
    private let knownHosts: any SSHKnownHostsStore
    private let hostKeyPrompts: HostKeyPromptCoordinator
    private let credentialPrompts: CredentialPromptCoordinator
    private let modelContainer: ModelContainer

    init(
        transportFactory: any SSHTransportFactory,
        secretsStore: any SecretsStore,
        knownHosts: any SSHKnownHostsStore,
        hostKeyPrompts: HostKeyPromptCoordinator,
        credentialPrompts: CredentialPromptCoordinator,
        modelContainer: ModelContainer
    ) {
        self.transportFactory = transportFactory
        self.secretsStore = secretsStore
        self.knownHosts = knownHosts
        self.hostKeyPrompts = hostKeyPrompts
        self.credentialPrompts = credentialPrompts
        self.modelContainer = modelContainer
    }

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The pane the user is typing into, whatever kind it is.
    var focusedFeed: (any TerminalFeed)? {
        selectedTab?.focusedSession
    }

    /// The focused pane when it owns an SSH connection. A tmux pane does not,
    /// so this is nil there and callers that need a connection say so by
    /// asking for this one.
    var focusedSession: TerminalSession? {
        selectedTab?.focusedSession as? TerminalSession
    }

    /// Whether the command-block list is shown beside the terminal. Per window
    /// rather than per tab: it is a way of working, not a property of a
    /// connection.
    var showsBlockInspector = false

    /// Whether the file browser is open for the focused session.
    ///
    /// Only a direct session has one: a tmux pane shares its connection with
    /// the other panes and has no transport of its own to open an SFTP channel
    /// on, which is exactly what ``focusedSession`` being nil there means.
    var showsFileBrowser = false

    // MARK: - Opening

    /// Opens a tab for `host` and starts connecting.
    ///
    /// The tab appears immediately, in its connecting state, rather than after
    /// the handshake: a host-key prompt or a password sheet has to have
    /// somewhere to belong, and a UI that does nothing for several seconds
    /// looks broken.
    @discardableResult
    func open(_ host: Host) -> TerminalTab {
        let session = makeSession(for: host)
        let tab: TerminalTab

        if host.usesTmuxControlMode {
            // The channel carries tmux's control protocol rather than terminal
            // output, so the controller reads it and the session does not.
            let controller = TmuxSessionController()
            session.onShellOpened = { [weak controller] shell in
                controller?.attach(to: shell)
            }
            tab = TerminalTab(tmux: controller, hostID: host.persistentModelID)
        } else {
            tab = TerminalTab(session: session, hostID: host.persistentModelID)
        }

        tabs.append(tab)
        selectedTabID = tab.id

        Task { [weak self] in
            await self?.connect(session, host: host)
        }

        host.lastConnectedAt = Date()
        return tab
    }

    /// Splits the focused pane.
    ///
    /// In tmux mode this asks tmux, which owns the layout; the new pane arrives
    /// through `%layout-change`. Otherwise it opens another connection to the
    /// same host.
    func splitFocusedPane(axis: PaneLayout.Axis) {
        guard let tab = selectedTab else { return }

        if case .tmux = tab.mode {
            tab.requestTmuxSplit(axis: axis)
            return
        }

        guard let host = host(for: tab) else { return }
        let session = makeSession(for: host)
        guard tab.split(tab.focusedPane, with: session, axis: axis) != nil else { return }

        Task { [weak self] in
            await self?.connect(session, host: host)
        }
    }

    private func host(for tab: TerminalTab) -> Host? {
        guard let hostID = tab.hostID else { return nil }
        return modelContainer.mainContext.model(for: hostID) as? Host
    }

    private func makeSession(for host: Host) -> TerminalSession {
        let policy = SSHKnownHostsPolicy(
            store: knownHosts,
            verifier: InteractiveHostKeyVerifier(coordinator: hostKeyPrompts)
        )

        // In tmux mode the startup command *is* tmux: `new -A` attaches to the
        // named session if it exists and creates it if not, which is what makes
        // reconnecting land back where you were. The host's own startup command
        // still runs, inside tmux.
        let startupCommand: String?
        if host.usesTmuxControlMode {
            let name = host.tmuxSessionName.isEmpty ? "sssh" : host.tmuxSessionName
            startupCommand = "tmux -CC new -A -s \(name)"
        } else {
            startupCommand = host.startupCommand
        }

        let configuration = SSHShellConfiguration(
            terminalType: .xterm256Color,
            // The real size arrives from SwiftTerm as soon as the view lays
            // out; this is only what the PTY is created with.
            initialSize: .default,
            environment: host.environment,
            startupCommand: startupCommand
        )

        return TerminalSession(
            hostDisplayName: host.displayName,
            endpoint: host.endpoint,
            transport: transportFactory.makeTransport(),
            hostKeyPolicy: policy,
            shellConfiguration: configuration,
            readsOwnOutput: !host.usesTmuxControlMode
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

    func closeFocusedPane() {
        guard let tab = selectedTab else { return }
        if !tab.closePane(tab.focusedPane) {
            close(tab)
        }
    }

    func close(_ tab: TerminalTab) {
        tabs.removeAll { $0.id == tab.id }

        if selectedTabID == tab.id {
            selectedTabID = tabs.last?.id
        }

        Task { await tab.disconnectAll() }
    }

    /// Closes the tab that is on screen. Bound to Command-W.
    func closeSelected() {
        guard let tab = selectedTab else { return }
        close(tab)
    }

    func closeAll() {
        let open = tabs
        tabs.removeAll()
        selectedTabID = nil
        hostKeyPrompts.rejectAll()
        credentialPrompts.cancelAll()

        Task {
            for tab in open {
                await tab.disconnectAll()
            }
        }
    }

    // MARK: - Navigation

    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            selectedTabID = tabs.first?.id
            return
        }
        selectedTabID = tabs[(index + 1) % tabs.count].id
    }

    func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            selectedTabID = tabs.last?.id
            return
        }
        selectedTabID = tabs[(index - 1 + tabs.count) % tabs.count].id
    }

    // MARK: - Restore

    /// What the tabs currently are, in a form that survives a relaunch.
    func snapshot() -> SessionRestoreSnapshot {
        SessionRestoreSnapshot(
            tabs: tabs.compactMap { tab in
                guard let hostID = tab.hostID,
                      let host = modelContainer.mainContext.model(for: hostID) as? Host
                else {
                    return nil
                }
                return SessionRestoreSnapshot.Tab(
                    hostIdentifier: host.restoreIdentifier,
                    layout: tab.layout,
                    focusedPane: tab.focusedPane,
                    broadcastsInput: tab.broadcastsInput,
                    isSelected: tab.id == selectedTabID
                )
            }
        )
    }

    /// Reopens what `snapshot` recorded.
    ///
    /// The layout is restored but the *connections* are made fresh, with
    /// whatever authentication that needs — including prompts. A session cannot
    /// be resumed, only reopened, and pretending otherwise would show a
    /// terminal that looks alive and is not.
    func restore(_ snapshot: SessionRestoreSnapshot, hosts: [Host]) {
        let byIdentifier = Dictionary(
            hosts.map { ($0.restoreIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for storedTab in snapshot.tabs {
            guard let host = byIdentifier[storedTab.hostIdentifier] else { continue }

            let tab = open(host)
            tab.broadcastsInput = storedTab.broadcastsInput

            // Recreate the extra panes. The stored layout's pane identifiers
            // are not reused: they belong to sessions that no longer exist, and
            // matching them up would be pretending the old ones came back.
            let extraPanes = max(0, storedTab.layout.terminalCount - 1)
            for index in 0..<extraPanes {
                splitFocusedPaneForRestore(tab: tab, host: host, axis: storedTab.axis(at: index))
            }

            if storedTab.isSelected {
                selectedTabID = tab.id
            }
        }
    }

    private func splitFocusedPaneForRestore(tab: TerminalTab, host: Host, axis: PaneLayout.Axis) {
        let session = makeSession(for: host)
        guard tab.split(tab.focusedPane, with: session, axis: axis) != nil else { return }
        Task { [weak self] in
            await self?.connect(session, host: host)
        }
    }
}
