import Foundation
import ssshCore

/// What the open tabs were, in a form that survives a relaunch.
///
/// Stored in the app's support directory rather than in SwiftData: it is
/// window state, not user data. It should not sync — the tabs open on a Mac
/// have no business reopening on a phone — and losing it should cost nothing.
struct SessionRestoreSnapshot: Codable {
    struct Tab: Codable {
        /// Hosts are matched by a stable field rather than by
        /// `PersistentIdentifier`, which is not stable across launches or
        /// devices.
        var hostIdentifier: String
        var layout: PaneLayout
        var focusedPane: PaneID
        var broadcastsInput: Bool
        var isSelected: Bool

        /// The axis of the `index`-th split, outermost first, so restoring can
        /// rebuild roughly the shape that was there.
        ///
        /// "Roughly": the panes are new connections, so their identities differ
        /// and an exact rebuild would be a fiction. Getting the count and the
        /// orientation right is what people actually notice.
        func axis(at index: Int) -> PaneLayout.Axis {
            var axes: [PaneLayout.Axis] = []
            collectAxes(from: layout, into: &axes)
            return index < axes.count ? axes[index] : .horizontal
        }

        private func collectAxes(from node: PaneLayout, into axes: inout [PaneLayout.Axis]) {
            guard case .split(let split) = node else { return }
            axes.append(split.axis)
            collectAxes(from: split.first, into: &axes)
            collectAxes(from: split.second, into: &axes)
        }
    }

    var tabs: [Tab]
    var savedAt = Date()

    static let empty = SessionRestoreSnapshot(tabs: [])
}

/// Reads and writes the restore snapshot.
///
/// Every failure is swallowed deliberately. Session restore is a convenience:
/// a corrupt file, a missing directory or a sandbox denial should mean "open
/// with no tabs", never a launch failure or an error the user has to dismiss.
struct SessionRestoreStore {
    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.url = base
                .appendingPathComponent("sssh", isDirectory: true)
                .appendingPathComponent("open-sessions.json")
        }
    }

    func load() -> SessionRestoreSnapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(SessionRestoreSnapshot.self, from: data)
        else {
            return .empty
        }
        return snapshot
    }

    func save(_ snapshot: SessionRestoreSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            // Atomic, so a crash mid-write leaves the previous snapshot rather
            // than a truncated one.
            try data.write(to: url, options: .atomic)
        } catch {
            // Deliberately ignored; see the type's documentation.
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
