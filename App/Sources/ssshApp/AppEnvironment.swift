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

    private let restoreStore = SessionRestoreStore()

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer

        let hostKeyPrompts = HostKeyPromptCoordinator()
        let credentialPrompts = CredentialPromptCoordinator()
        self.hostKeyPrompts = hostKeyPrompts
        self.credentialPrompts = credentialPrompts

        let secretsStore = KeychainSecretsStore()
        self.secretsStore = secretsStore

        self.sessions = SessionManager(
            transportFactory: NIOSSHTransportFactory(),
            secretsStore: secretsStore,
            knownHosts: SwiftDataKnownHostsStore(container: modelContainer),
            hostKeyPrompts: hostKeyPrompts,
            credentialPrompts: credentialPrompts,
            modelContainer: modelContainer
        )
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return AppEnvironment(modelContainer: container)
    }
}

enum ModelContainerFactory {
    /// The app's real store.
    ///
    /// No CloudKit yet — that is Phase 7 — but the schema is already written to
    /// CloudKit's rules (every attribute defaulted, no unique constraints) so
    /// turning it on will not need a migration.
    static func make() throws -> ModelContainer {
        try ModelContainer(
            for: Host.self, HostGroup.self, KnownHostEntry.self, TerminalProfile.self, Tunnel.self,
            configurations: ModelConfiguration("sssh")
        )
    }
}
