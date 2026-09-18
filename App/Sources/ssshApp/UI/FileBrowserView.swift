import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import ssshCore

/// The file browser: local on the left, remote on the right, a transfer queue
/// underneath.
///
/// Dual-pane rather than a single pane with a "connect to" switcher, because
/// the whole job is moving things between two places, and a browser that shows
/// one of them at a time turns every copy into a navigation problem.
struct FileBrowserView: View {
    let session: TerminalSession

    @State private var remote: RemoteFileBrowser
    @State private var local = LocalFileBrowser()
    @State private var queue: TransferQueue
    @State private var showsQueue = true
    /// The file Quick Look is showing. For a remote file this is a temporary
    /// local copy, downloaded when the preview was asked for.
    @State private var previewURL: URL?
    /// A preview or local-edit that could not start. Transfer failures do not
    /// land here — those are the queue's to show.
    @State private var fileActionFailure: String?
    #if os(macOS)
    @State private var editor: RemoteFileEditor
    #endif
    /// Scales with the text size, so the queue still shows rows at the largest
    /// accessibility sizes instead of one clipped line.
    @ScaledMetric(relativeTo: .body) private var queueHeight: CGFloat = 200

    init(session: TerminalSession) {
        self.session = session
        _remote = State(initialValue: RemoteFileBrowser(session: session))
        let queue = TransferQueue(session: session)
        _queue = State(initialValue: queue)
        #if os(macOS)
        _editor = State(initialValue: RemoteFileEditor(session: session, queue: queue))
        #endif
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("Bestanden", comment: "Title of the file browser"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 520)
        #endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            HSplitPanes {
                LocalPane(
                    browser: local,
                    queue: queue,
                    remotePath: remote.path,
                    remoteEntries: remote.entries,
                    onPreview: { entry in
                        previewURL = URL(fileURLWithPath: RemotePath.appending(entry.name, to: local.path))
                    }
                ) {
                    Task { await remote.reload() }
                }
            } trailing: {
                RemotePane(
                    browser: remote,
                    queue: queue,
                    localPath: local.path,
                    session: session,
                    onPreview: { entry in
                        Task {
                            do {
                                previewURL = try await RemoteFileExporter.download(entry.name, from: remote.path, session: session)
                            } catch {
                                fileActionFailure = FileTransferText.describe(error)
                            }
                        }
                    },
                    onEditLocally: editLocally
                )
            }

            if showsQueue, !queue.transfers.isEmpty {
                Divider()
                TransferQueueView(queue: queue) {
                    Task { await remote.reload() }
                    local.reload()
                }
                .frame(height: queueHeight)
            }
        }
        .task {
            local.reload()
            await remote.start()
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showsQueue) {
                    Label {
                        Text("Overdrachten", comment: "Toggle that shows the transfer queue")
                    } icon: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
                .disabled(queue.transfers.isEmpty)
            }
        }
        .sheet(item: Binding(
            get: { queue.pendingCollision },
            set: { if $0 == nil { queue.resolveCollision(with: .ask) } }
        )) { transfer in
            CollisionPromptView(transfer: transfer) { policy in
                queue.resolveCollision(with: policy)
            }
        }
        .quickLookPreview($previewURL)
        .alert(
            Text("Bestand kan niet worden geopend", comment: "Title of the alert shown when a preview or local edit could not start"),
            isPresented: Binding(get: { fileActionFailure != nil }, set: { if !$0 { fileActionFailure = nil } })
        ) {
            Button(role: .cancel) { fileActionFailure = nil } label: {
                Text("OK", comment: "Dismiss button of an alert")
            }
        } message: {
            Text(fileActionFailure ?? "")
        }
    }

    /// Nil on iOS: there is no external editor to hand a file to there, and a
    /// menu item that cannot work is worse than no menu item.
    private var editLocally: ((RemoteFileEntry) -> Void)? {
        #if os(macOS)
        return { entry in
            Task {
                do {
                    try await editor.beginEditing(entry, in: remote.path)
                } catch {
                    fileActionFailure = FileTransferText.describe(error)
                }
            }
        }
        #else
        return nil
        #endif
    }
}

/// A side-by-side layout that becomes a tab switcher when there is not enough
/// width for two panes — which on an iPhone is always.
private struct HSplitPanes<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var showsRemote = true

    var body: some View {
        #if os(iOS)
        if sizeClass == .compact {
            VStack(spacing: 0) {
                Picker(selection: $showsRemote) {
                    Text("Dit apparaat", comment: "Picker option for the local side of the file browser").tag(false)
                    Text("Server", comment: "Picker option for the remote side of the file browser").tag(true)
                } label: {
                    Text("Kant", comment: "Accessibility label for the local/remote picker")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)

                if showsRemote { trailing } else { leading }
            }
        } else {
            HStack(spacing: 0) { leading; Divider(); trailing }
        }
        #else
        HStack(spacing: 0) { leading; Divider(); trailing }
        #endif
    }
}

// MARK: - Panes

private struct RemotePane: View {
    @Bindable var browser: RemoteFileBrowser
    let queue: TransferQueue
    let localPath: String
    /// The whole session rather than just its id: a drag that leaves the app
    /// downloads the file through this session when the drop lands.
    let session: TerminalSession
    let onPreview: (RemoteFileEntry) -> Void
    let onEditLocally: ((RemoteFileEntry) -> Void)?

    @State private var newFolderName = ""
    @State private var showsNewFolder = false
    @State private var renaming: RemoteFileEntry?
    @State private var deleting: [RemoteFileEntry] = []
    @State private var permissionTarget: RemoteFileEntry?

    var body: some View {
        FilePane(
            title: Text("Server", comment: "Title of the remote side of the file browser"),
            path: browser.path,
            entries: browser.visibleEntries,
            isLoading: browser.isLoading,
            failure: browser.failure.map { FileTransferText.describe($0) },
            selection: $browser.selection,
            options: $browser.options,
            canGoUp: browser.canGoUp,
            canGoBack: browser.canGoBack,
            onOpen: { entry in Task { await browser.open(entry) } },
            onNavigate: { path in Task { await browser.open(path) } },
            onUp: { Task { await browser.goUp() } },
            onBack: { Task { await browser.goBack() } },
            onHome: { Task { await browser.goHome() } },
            onReload: { Task { await browser.reload() } },
            onNewFolder: { showsNewFolder = true },
            onRename: { renaming = $0 },
            onDelete: { deleting = $0 },
            onPermissions: { permissionTarget = $0 },
            onPreview: onPreview,
            onEditLocally: onEditLocally,
            onTransfer: { entries in
                Task {
                    for entry in entries {
                        if entry.attributes.kind == .directory {
                            await queue.enqueueDownloadTree(of: entry, from: browser.path, to: localPath)
                        } else {
                            queue.enqueueDownload(of: entry, from: browser.path, to: localPath)
                        }
                    }
                }
            },
            transferLabel: Text("Download", comment: "Button that downloads the selected remote files"),
            transferSymbol: "arrow.down.circle",
            dragPayload: { entries, grabbed in
                DraggedRemoteFile(
                    selection: DraggedFiles(origin: .remote(directory: browser.path, sessionID: session.id),
                                            names: entries.map(\.name)),
                    name: grabbed.name,
                    isFile: grabbed.attributes.kind == .file,
                    directory: browser.path,
                    session: session
                )
            },
            onDropSelection: { dropped in
                // Only a drop from the local side is an upload. A drop from
                // this same pane is someone dragging within a directory, which
                // means nothing and must not queue a transfer to itself.
                guard case .local(let directory) = dropped.origin else { return false }
                for name in dropped.names {
                    guard let attributes = LocalFileBrowser.attributes(atPath: RemotePath.appending(name, to: directory)) else {
                        continue
                    }
                    let entry = RemoteFileEntry(name: name, attributes: attributes)
                    if attributes.kind == .directory {
                        Task { await queue.enqueueUploadTree(of: entry, from: directory, to: browser.path) }
                    } else {
                        queue.enqueueUpload(of: entry, from: directory, to: browser.path)
                    }
                }
                return true
            },
            onDropURLs: { urls in
                for url in urls where url.isFileURL {
                    let path = url.path
                    guard let attributes = LocalFileBrowser.attributes(atPath: path) else { continue }
                    let entry = RemoteFileEntry(name: RemotePath.lastComponent(of: path), attributes: attributes)
                    if attributes.kind == .directory {
                        Task { await queue.enqueueUploadTree(of: entry, from: RemotePath.parent(of: path), to: browser.path) }
                    } else {
                        queue.enqueueUpload(of: entry, from: RemotePath.parent(of: path), to: browser.path)
                    }
                }
                return true
            }
        )
        .alert(Text("Nieuwe map", comment: "Title of the new folder prompt"), isPresented: $showsNewFolder) {
            TextField(text: $newFolderName) {
                Text("Naam", comment: "Placeholder for a new folder's name")
            }
            Button {
                let name = newFolderName
                newFolderName = ""
                Task { await browser.createDirectory(named: name) }
            } label: {
                Text("Aanmaken", comment: "Button that creates a new folder")
            }
            Button(role: .cancel) { newFolderName = "" } label: {
                Text("Annuleer", comment: "Cancel button")
            }
        }
        .sheet(item: $renaming) { entry in
            RenamePromptView(currentName: entry.name) { newName in
                Task { await browser.rename(entry, to: newName) }
            }
        }
        .sheet(item: $permissionTarget) { entry in
            PermissionsEditorView(entry: entry) { permissions in
                Task { await browser.setPermissions(permissions, on: entry) }
            }
        }
        .confirmationDialog(
            Text("Verwijderen van de server?", comment: "Title of the remote delete confirmation"),
            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                let entries = deleting
                deleting = []
                Task { await browser.delete(entries) }
            } label: {
                Text("Verwijder \(deleting.count) item(s)", comment: "Confirms deleting N remote items")
            }
            Button(role: .cancel) { deleting = [] } label: {
                Text("Annuleer", comment: "Cancel button")
            }
        } message: {
            // No trash on someone else's machine. Saying so is the difference
            // between a confirmation people read and one they click through.
            Text("Dit kan niet ongedaan worden gemaakt: op een server is er geen prullenbak.",
                 comment: "Warning that remote deletion is permanent")
        }
    }
}

private struct LocalPane: View {
    @Bindable var browser: LocalFileBrowser
    let queue: TransferQueue
    let remotePath: String
    /// The remote pane's current listing, so a drop can find the attributes of
    /// what was dragged. The drag carries names, not sizes: a payload that
    /// carried the whole entry would go stale the moment the remote pane
    /// reloaded.
    let remoteEntries: [RemoteFileEntry]
    let onPreview: (RemoteFileEntry) -> Void
    let onUploadQueued: () -> Void

    @State private var newFolderName = ""
    @State private var showsNewFolder = false
    @State private var renaming: RemoteFileEntry?

    var body: some View {
        FilePane(
            title: Text("Dit apparaat", comment: "Title of the local side of the file browser"),
            path: browser.path,
            entries: browser.visibleEntries,
            isLoading: false,
            failure: browser.failure,
            selection: $browser.selection,
            options: $browser.options,
            canGoUp: browser.canGoUp,
            canGoBack: false,
            onOpen: { browser.open($0) },
            onNavigate: { browser.open($0) },
            onUp: { browser.goUp() },
            onBack: {},
            onHome: nil,
            onReload: { browser.reload() },
            onNewFolder: { showsNewFolder = true },
            onRename: { renaming = $0 },
            onDelete: { browser.delete($0) },
            onPermissions: nil,
            onPreview: onPreview,
            onEditLocally: nil,
            onTransfer: { entries in
                Task {
                    for entry in entries {
                        if entry.attributes.kind == .directory {
                            await queue.enqueueUploadTree(of: entry, from: browser.path, to: remotePath)
                        } else {
                            queue.enqueueUpload(of: entry, from: browser.path, to: remotePath)
                        }
                    }
                    onUploadQueued()
                }
            },
            transferLabel: Text("Upload", comment: "Button that uploads the selected local files"),
            transferSymbol: "arrow.up.circle",
            dragPayload: { entries, _ in
                DraggedFiles(origin: .local(directory: browser.path), names: entries.map(\.name))
            },
            onDropSelection: { dropped in
                guard case .remote(let directory, _) = dropped.origin else { return false }
                for name in dropped.names {
                    guard let entry = remoteEntries.first(where: { $0.name == name }) else { continue }
                    if entry.attributes.kind == .directory {
                        Task { await queue.enqueueDownloadTree(of: entry, from: directory, to: browser.path) }
                    } else {
                        queue.enqueueDownload(of: entry, from: directory, to: browser.path)
                    }
                }
                return true
            },
            onDropURLs: nil
        )
        .alert(Text("Nieuwe map", comment: "Title of the new folder prompt"), isPresented: $showsNewFolder) {
            TextField(text: $newFolderName) {
                Text("Naam", comment: "Placeholder for a new folder's name")
            }
            Button {
                let name = newFolderName
                newFolderName = ""
                browser.createDirectory(named: name)
            } label: {
                Text("Aanmaken", comment: "Button that creates a new folder")
            }
            Button(role: .cancel) { newFolderName = "" } label: {
                Text("Annuleer", comment: "Cancel button")
            }
        }
        .sheet(item: $renaming) { entry in
            RenamePromptView(currentName: entry.name) { newName in
                browser.rename(entry, to: newName)
            }
        }
    }
}
