import Foundation
import Observation
import ssshCore

/// The local half of the dual-pane browser.
///
/// Presents the same `RemoteFileEntry` shape as the remote side so the pane
/// view, the sort options and the selection logic are written once. The
/// alternative — a second parallel implementation of a file list — is how the
/// two sides end up sorting differently and behaving differently, and the user
/// has to learn both.
@MainActor
@Observable
final class LocalFileBrowser {
    private(set) var path: String
    private(set) var entries: [RemoteFileEntry] = []
    private(set) var failure: String?

    var options = DirectoryListingOptions()
    var selection: Set<String> = []

    var visibleEntries: [RemoteFileEntry] { options.apply(to: entries) }
    var selectedEntries: [RemoteFileEntry] { visibleEntries.filter { selection.contains($0.name) } }
    var canGoUp: Bool { path != "/" }
    var existingNames: Set<String> { Set(entries.map(\.name)) }

    private let fileManager = FileManager.default

    init(path: String? = nil) {
        // The sandbox decides what is actually reachable; Documents is the one
        // directory the app can always read and write on every platform.
        self.path = path
            ?? (try? fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).path)
            ?? fileManager.currentDirectoryPath
    }

    func open(_ newPath: String) {
        path = newPath
        selection.removeAll()
        reload()
    }

    func open(_ entry: RemoteFileEntry) {
        guard entry.attributes.kind == .directory else { return }
        open(RemotePath.appending(entry.name, to: path))
    }

    func goUp() {
        guard canGoUp else { return }
        open(RemotePath.parent(of: path))
    }

    func reload() {
        failure = nil
        do {
            let names = try fileManager.contentsOfDirectory(atPath: path)
            entries = names.compactMap { name in
                let full = RemotePath.appending(name, to: path)
                guard let attributes = Self.attributes(atPath: full) else { return nil }
                return RemoteFileEntry(name: name, attributes: attributes)
            }
        } catch {
            entries = []
            failure = error.localizedDescription
        }
    }

    func createDirectory(named name: String) {
        guard RemotePath.isValidComponent(name) else { return }
        do {
            try fileManager.createDirectory(atPath: RemotePath.appending(name, to: path), withIntermediateDirectories: false)
            reload()
        } catch {
            failure = error.localizedDescription
        }
    }

    func rename(_ entry: RemoteFileEntry, to name: String) {
        guard RemotePath.isValidComponent(name), name != entry.name else { return }
        do {
            try fileManager.moveItem(
                atPath: RemotePath.appending(entry.name, to: path),
                toPath: RemotePath.appending(name, to: path)
            )
            reload()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Moves to the trash where there is one, and deletes where there is not.
    ///
    /// iOS has no trash, so `trashItem` fails there; falling back rather than
    /// reporting an error is the behaviour people expect, and the local side
    /// is the one place a mistake is recoverable.
    func delete(_ entries: [RemoteFileEntry]) {
        for entry in entries {
            let target = URL(fileURLWithPath: RemotePath.appending(entry.name, to: path))
            do {
                #if os(macOS)
                try fileManager.trashItem(at: target, resultingItemURL: nil)
                #else
                try fileManager.removeItem(at: target)
                #endif
            } catch {
                failure = error.localizedDescription
            }
        }
        selection.removeAll()
        reload()
    }

    static func attributes(atPath path: String) -> RemoteFileAttributes? {
        let manager = FileManager.default
        guard let values = try? manager.attributesOfItem(atPath: path) else { return nil }

        let kind: RemoteFileAttributes.Kind
        switch values[.type] as? FileAttributeType {
        case .typeDirectory: kind = .directory
        case .typeRegular: kind = .file
        case .typeSymbolicLink: kind = .symlink
        default: kind = .other
        }

        return RemoteFileAttributes(
            kind: kind,
            size: (values[.size] as? NSNumber)?.uint64Value,
            permissions: (values[.posixPermissions] as? NSNumber).map { POSIXPermissions(rawValue: $0.uint16Value) },
            userID: (values[.ownerAccountID] as? NSNumber)?.uint32Value,
            groupID: (values[.groupOwnerAccountID] as? NSNumber)?.uint32Value,
            modifiedAt: values[.modificationDate] as? Date,
            accessedAt: nil
        )
    }
}
