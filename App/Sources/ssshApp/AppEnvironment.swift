import Foundation
import Observation
import SwiftData
import ssshCore
import ssshTransportNIOSSH

/// Wires the app together.
///
/// This is the only type that names a concrete SSH backend
/// (`NIOSSHTransportFactory`) or a concrete secrets store
/// (`KeychainSecretsStore`). Everything else takes the protocol, which is what
/// makes the transport swappable and the session layer testable.
@MainActor
@Observable
final class AppEnvironment {
    let modelContainer: ModelContainer
    let sessions: SessionManager
    let hostKeyPrompts: HostKeyPromptCoordinator
    let credentialPrompts: CredentialPromptCoordinator
    let palette = CommandPaletteModel()
    /// Shared so the host editor writes to the same store the session layer
    /// reads from, rather than each making its own.
    let secretsStore: any SecretsStore
    let security: SecuritySettings
    let appLock: AppLock
    /// Which protection the device key actually has, for the settings screen
    /// to report honestly rather than claim.
    private(set) var keyProtection: AppSecurityKey.Protection?

    private let restoreStore = SessionRestoreStore()
    private let appSecurityKey: AppSecurityKey

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer

        let hostKeyPrompts = HostKeyPromptCoordinator()
        let credentialPrompts = CredentialPromptCoordinator()
        self.hostKeyPrompts = hostKeyPrompts
        self.credentialPrompts = credentialPrompts

        let security = SecuritySettings()
        self.security = security
        self.appLock = AppLock(settings: security)

        let appKey = AppSecurityKey()
        let secretsStore = KeychainSecretsStore(appKey: appKey, scope: security.secretScope)
        self.secretsStore = secretsStore
        self.appSecurityKey = appKey

        self.sessions = SessionManager(
            transportFactory: NIOSSHTransportFactory(),
            secretsStore: secretsStore,
            knownHosts: SwiftDataKnownHostsStore(container: modelContainer),
            hostKeyPrompts: hostKeyPrompts,
            credentialPrompts: credentialPrompts,
            modelContainer: modelContainer
        )
    }

    // MARK: - Terminal text size

    /// The size every terminal renders at, over and above whatever its profile
    /// says.
    ///
    /// An adjustment rather than a stored size, so that a host with a small
    /// profile font and one with a large one both get bigger when someone
    /// presses ⌘+. Kept per device in `UserDefaults`: how big text needs to be
    /// depends on the screen it is on, not on the account.
    private(set) var terminalFontSizeAdjustment: Double = UserDefaults.standard.double(forKey: "terminal.fontSizeAdjustment")

    func adjustTerminalFontSize(by delta: Double) {
        // Bounded, because a terminal at four points and a terminal at ninety
        // are both unusable and both reachable by holding a key down.
        terminalFontSizeAdjustment = min(24, max(-6, terminalFontSizeAdjustment + delta))
        UserDefaults.standard.set(terminalFontSizeAdjustment, forKey: "terminal.fontSizeAdjustment")
    }

    func resetTerminalFontSize() {
        terminalFontSizeAdjustment = 0
        UserDefaults.standard.set(0.0, forKey: "terminal.fontSizeAdjustment")
    }

    // MARK: - Security

    /// Finds out what the device key is actually protected by, and applies the
    /// secret scope the settings ask for.
    ///
    /// Both need the Keychain, so they happen once at launch rather than in
    /// `init`, which runs before there is a window to report a failure in.
    func prepareSecurity() async {
        keyProtection = try? await appSecurityKey.currentProtection()
        await applySecretScope()
    }

    /// Moves stored secrets into or out of iCloud Keychain to match the
    /// setting. Called when the switch changes, and at launch in case it was
    /// changed on another device — or interrupted last time.
    func applySecretScope() async {
        guard let store = secretsStore as? KeychainSecretsStore else { return }
        try? await store.setScope(security.secretScope)
    }

    // MARK: - Blocks and search

    /// Opens the block list and puts the cursor in its search field.
    ///
    /// Command-F in a terminal is ambiguous: it could search the scrollback or
    /// the commands. sssh searches the commands, because a hit there answers
    /// "which command produced this" as well as "where is this string", and a
    /// hit in a flat buffer answers only the second.
    func showBlocksAndSearch() {
        sessions.showsBlockInspector = true
        pendingBlockSearchFocus = true
    }

    /// Set by ``showBlocksAndSearch()`` and cleared by whichever block list
    /// takes the focus. A request that is consumed, rather than a flag that
    /// stays true: otherwise every later appearance of the list would steal
    /// the keyboard from the terminal.
    var pendingBlockSearchFocus = false

    // MARK: - Command palette

    func presentCommandPalette() {
        palette.present(with: paletteItems())
    }

    private func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []

        let hosts = (try? modelContainer.mainContext.fetch(
            FetchDescriptor<Host>(sortBy: [SortDescriptor(\Host.lastConnectedAt, order: .reverse)])
        )) ?? []

        for host in hosts where host.isConnectable {
            items.append(PaletteItem(
                kind: .host(host),
                title: host.displayName,
                subtitle: "\(host.username)@\(host.hostname)",
                symbol: "terminal",
                // Tags and the group are searchable but not shown: a palette
                // that cannot find a host by its tag stops being trusted.
                keywords: host.tags + [host.group?.name ?? ""],
                perform: { [weak self] in
                    _ = self?.sessions.open(host)
                }
            ))
        }

        if sessions.selectedTab != nil {
            items.append(PaletteItem(
                kind: .action,
                title: String(localized: "Splits naar rechts", comment: "Menu item: split the pane left-to-right"),
                subtitle: nil,
                symbol: "rectangle.split.2x1",
                keywords: ["split", "pane", "venster"],
                perform: { [weak self] in self?.sessions.splitFocusedPane(axis: .horizontal) }
            ))
            items.append(PaletteItem(
                kind: .action,
                title: String(localized: "Splits naar beneden", comment: "Menu item: split the pane top-to-bottom"),
                subtitle: nil,
                symbol: "rectangle.split.1x2",
                keywords: ["split", "pane", "venster"],
                perform: { [weak self] in self?.sessions.splitFocusedPane(axis: .vertical) }
            ))
            items.append(PaletteItem(
                kind: .action,
                title: String(localized: "Invoer naar alle vensters", comment: "Menu item: toggle broadcasting input to every pane"),
                subtitle: nil,
                symbol: "dot.radiowaves.left.and.right",
                keywords: ["broadcast", "uitzenden"],
                perform: { [weak self] in
                    guard let tab = self?.sessions.selectedTab else { return }
                    tab.broadcastsInput.toggle()
                }
            ))
            items.append(PaletteItem(
                kind: .action,
                title: String(localized: "Zoek in sessie…", comment: "Menu item: search the current session's commands and output"),
                subtitle: nil,
                symbol: "magnifyingglass",
                keywords: ["search", "zoeken", "blok", "block", "find"],
                perform: { [weak self] in self?.showBlocksAndSearch() }
            ))
            items.append(PaletteItem(
                kind: .action,
                title: String(localized: "Vergrendel sssh", comment: "Menu item that locks the app now"),
                subtitle: nil,
                symbol: "lock",
                keywords: ["lock", "vergrendel", "slot"],
                perform: { [weak self] in self?.appLock.lockNow() }
            ))
            items.append(PaletteItem(
                kind: .action,
                title: String(localized: "Fragmenten", comment: "Title of the snippet library"),
                subtitle: nil,
                symbol: "text.badge.plus",
                keywords: ["snippet", "fragment", "command", "opdracht"],
                perform: { [weak self] in self?.sessions.showsSnippets = true }
            ))
            items.append(PaletteItem(
                kind: .action,
                title: String(localized: "Tunnels", comment: "Section header: saved port forwards"),
                subtitle: nil,
                symbol: "point.3.filled.connected.trianglepath.dotted",
                keywords: ["port", "forward", "poort", "socks", "proxy", "tunnel"],
                perform: { [weak self] in self?.sessions.showsTunnels = true }
            ))
            items.append(PaletteItem(
                kind: .action,
                title: String(localized: "Bestanden", comment: "Title of the file browser"),
                subtitle: nil,
                symbol: "folder",
                keywords: ["sftp", "files", "bestanden", "upload", "download"],
                perform: { [weak self] in self?.sessions.showsFileBrowser = true }
            ))
            items.append(PaletteItem(
                kind: .action,
                title: String(localized: "Opdrachten", comment: "Menu item: toggle the command block list"),
                subtitle: nil,
                symbol: "list.bullet.rectangle",
                keywords: ["blocks", "blokken", "commands", "geschiedenis"],
                perform: { [weak self] in self?.sessions.showsBlockInspector.toggle() }
            ))
        }

        // Snippets in the palette, which is the fastest path from "I want to
        // restart nginx" to it happening. Only when there is a session to send
        // them to, and only the ones that apply to the host in front of you.
        if let feed = sessions.focusedFeed {
            let hostID = sessions.focusedHost?.persistentModelID
            let snippets = (try? modelContainer.mainContext.fetch(
                FetchDescriptor<Snippet>(sortBy: [SortDescriptor(\Snippet.useCount, order: .reverse)])
            )) ?? []

            for snippet in snippets where snippet.host == nil || snippet.host?.persistentModelID == hostID {
                // A snippet with placeholders opens the library rather than
                // running: the palette has nowhere to ask, and sending a
                // command with empty holes in it is worse than one more step.
                let needsValues = !snippet.parameters.isEmpty
                items.append(PaletteItem(
                    kind: .action,
                    title: snippet.name.isEmpty ? snippet.command : snippet.name,
                    subtitle: snippet.command,
                    symbol: needsValues ? "text.cursor" : "text.badge.plus",
                    keywords: snippet.keywords,
                    perform: { [weak self] in
                        guard let self else { return }
                        guard !needsValues else {
                            self.sessions.showsSnippets = true
                            return
                        }
                        feed.send(ArraySlice(snippet.input(with: [:])))
                        snippet.recordUse()
                    }
                ))
            }
        }

        return items
    }

    // MARK: - Session restore

    /// Reopens whatever was open when the app last quit.
    ///
    /// Connections are made fresh, with whatever authentication that needs,
    /// including prompts. A session cannot be resumed, only reopened, and
    /// showing a terminal that looks alive and is not would be worse than
    /// asking.
    func restoreSessions() {
        let snapshot = restoreStore.load()
        guard !snapshot.tabs.isEmpty else { return }

        let hosts = (try? modelContainer.mainContext.fetch(FetchDescriptor<Host>())) ?? []
        sessions.restore(snapshot, hosts: hosts)
    }

    func saveOpenSessions() {
        restoreStore.save(sessions.snapshot())
    }

    /// In-memory everything, for previews and tests. Named so that using it by
    /// accident is obvious in a diff.
    static func ephemeral() -> AppEnvironment {
        let container = try! ModelContainer(
            for: Host.self, HostGroup.self, KnownHostEntry.self, TerminalProfile.self, Tunnel.self,
            Snippet.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return AppEnvironment(modelContainer: container)
    }
}

enum ModelContainerFactory {
    /// The app's real store, in CloudKit's private database when sync is on.
    ///
    /// The schema was written to CloudKit's rules from Phase 1 — every
    /// attribute defaulted, no unique constraints — so turning this on needs
    /// no migration.
    ///
    /// Nothing in this store is a secret. Host names, ports, usernames,
    /// fingerprints, tunnels and snippets sync; private keys, passphrases and
    /// passwords are in the Keychain and the model holds only an opaque
    /// reference to them. That separation is the reason this can sync at all:
    /// CloudKit's private database is not end-to-end encrypted, and a key in
    /// it would be a key in a database Apple can read.
    ///
    /// Whether a store is CloudKit-backed is fixed when it is constructed, so
    /// the setting is read here and a change takes effect at the next launch.
    /// The settings screen says so rather than pretending otherwise.
    static func make(syncsConfiguration: Bool = SecuritySettings.syncsConfiguration()) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "sssh",
            cloudKitDatabase: syncsConfiguration ? .private("iCloud.nl.rorymeijer.sssh") : .none
        )
        return try ModelContainer(
            for: Host.self, HostGroup.self, KnownHostEntry.self, TerminalProfile.self, Tunnel.self,
            Snippet.self,
            configurations: configuration
        )
    }
}
