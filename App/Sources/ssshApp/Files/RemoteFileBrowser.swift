import Foundation
import Observation
import ssshCore

/// One remote directory, as the browser shows it.
///
/// Every operation asks the session for the SFTP channel rather than holding
/// one, because a reconnect replaces it. Holding a channel here would mean a
/// browser that works until the Wi-Fi blinks and then reports "connection
/// lost" for ever.
@MainActor
@Observable
final class RemoteFileBrowser {
    private(set) var path: String = "/"
    private(set) var entries: [RemoteFileEntry] = []
    private(set) var isLoading = false
    private(set) var failure: SFTPError?
    /// The home directory, resolved once, for the "go home" button.
    private(set) var homePath: String?

    var options = DirectoryListingOptions()
    var selection: Set<String> = []

    var visibleEntries: [RemoteFileEntry] {
        options.apply(to: entries)
    }

    var selectedEntries: [RemoteFileEntry] {
        visibleEntries.filter { selection.contains($0.name) }
    }

    var canGoUp: Bool { path != RemotePath.root }
    var canGoBack: Bool { !history.isEmpty }

    /// Names already in this directory, for collision handling.
    var existingNames: Set<String> { Set(entries.map(\.name)) }

    private let session: TerminalSession
    private var loadTask: Task<Void, Never>?
    /// Where the user has been, so Back works. Forward is deliberately absent:
    /// a remote directory can be moved or deleted while you are away, and a
    /// forward stack full of paths that no longer exist is worse than none.
    private var history: [String] = []

    init(session: TerminalSession) {
        self.session = session
    }

    // MARK: - Navigation

    func start() async {
        guard homePath == nil else { return }
        do {
            let service = try await session.sftp()
            // `realpath(".")` is how the protocol says "where am I", and it is
            // the only portable way to find the home directory: there is no
            // `$HOME` on an SFTP channel, because there is no shell.
            let home = try await service.realPath(of: ".")
            homePath = home
            await open(home, recordingHistory: false)
        } catch {
            record(error)
        }
    }

    func open(_ newPath: String, recordingHistory: Bool = true) async {
        if recordingHistory, newPath != path {
            history.append(path)
            if history.count > 100 { history.removeFirst() }
        }
        path = newPath
        selection.removeAll()
        await reload()
    }

    func open(_ entry: RemoteFileEntry) async {
        let target = RemotePath.appending(entry.name, to: path)
        switch entry.attributes.kind {
        case .directory:
            await open(target)
        case .symlink:
            await followSymlink(at: target)
        case .file, .other:
            break
        }
    }

    /// Follows a link by asking the server what it resolves to rather than
    /// resolving it here. Textual resolution gets `a/b/..` wrong the moment
    /// `b` is itself a link, and a loop resolves textually for ever.
    private func followSymlink(at target: String) async {
        do {
            let service = try await session.sftp()
            let resolved = try await service.realPath(of: target)
            let attributes = try await service.attributes(of: resolved)
            guard attributes.kind == .directory else { return }
            await open(resolved)
        } catch {
            record(error)
        }
    }

    func goUp() async {
        guard canGoUp else { return }
        await open(RemotePath.parent(of: path))
    }

    func goBack() async {
        guard let previous = history.popLast() else { return }
        await open(previous, recordingHistory: false)
    }

    func goHome() async {
        guard let homePath else { return }
        await open(homePath)
    }

    // MARK: - Loading

    func reload() async {
        loadTask?.cancel()
        failure = nil
        isLoading = true

        let path = self.path
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let service = try await self.session.sftp()
                var collected: [RemoteFileEntry] = []
                for try await batch in service.listDirectory(at: path) {
                    if Task.isCancelled { return }
                    collected.append(contentsOf: batch)
                    // Published per batch rather than at the end: a directory
                    // with 100 000 entries takes many round trips, and a
                    // browser that shows nothing until the last one has
                    // arrived looks broken.
                    self.entries = collected
                }
                if Task.isCancelled { return }
                self.entries = collected
                self.isLoading = false
            } catch is CancellationError {
                return
            } catch {
                self.entries = []
                self.isLoading = false
                self.record(error)
            }
        }
        loadTask = task
        await task.value
    }

    private func record(_ error: Error) {
        failure = (error as? SFTPError) ?? .failure(path: path, serverMessage: nil)
    }

    // MARK: - Operations

    func createDirectory(named name: String) async {
        guard RemotePath.isValidComponent(name) else { return }
        await perform { service in
            try await service.createDirectory(at: RemotePath.appending(name, to: self.path), permissions: nil)
        }
    }

    func rename(_ entry: RemoteFileEntry, to name: String) async {
        guard RemotePath.isValidComponent(name), name != entry.name else { return }
        await perform { service in
            try await service.rename(
                from: RemotePath.appending(entry.name, to: self.path),
                to: RemotePath.appending(name, to: self.path)
            )
        }
    }

    /// Deletes what was selected.
    ///
    /// Directories go depth-first, because `rmdir` fails on a non-empty one —
    /// which is the right protocol behaviour, so the recursion belongs here.
    /// There is no trash on someone else's machine, which is why the caller
    /// confirms before calling this.
    func delete(_ entries: [RemoteFileEntry]) async {
        await perform { service in
            for entry in entries {
                let target = RemotePath.appending(entry.name, to: self.path)
                if entry.attributes.kind == .directory {
                    try await Self.removeTree(at: target, using: service)
                } else {
                    try await service.remove(at: target)
                }
            }
        }
    }

    func setPermissions(_ permissions: POSIXPermissions, on entry: RemoteFileEntry) async {
        await perform { service in
            // Only the mode goes out. Sending the size back would truncate the
            // file, and sending the timestamps back would quietly rewrite
            // them — version 3 has one attribute structure for everything, so
            // what is not included is what is not changed.
            let update = RemoteFileAttributes(kind: entry.attributes.kind, permissions: permissions)
            try await service.setAttributes(update, of: RemotePath.appending(entry.name, to: self.path))
        }
    }

    private static func removeTree(at path: String, using service: any SFTPService) async throws {
        var children: [RemoteFileEntry] = []
        for try await batch in service.listDirectory(at: path) {
            children.append(contentsOf: batch)
        }
        for child in children {
            let target = RemotePath.appending(child.name, to: path)
            if child.attributes.kind == .directory {
                try await removeTree(at: target, using: service)
            } else {
                try await service.remove(at: target)
            }
        }
        try await service.removeDirectory(at: path)
    }

    private func perform(_ body: (any SFTPService) async throws -> Void) async {
        do {
            let service = try await session.sftp()
            try await body(service)
            selection.removeAll()
            await reload()
        } catch {
            record(error)
        }
    }
}
