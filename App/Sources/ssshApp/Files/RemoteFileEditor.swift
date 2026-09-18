#if os(macOS)
import AppKit
import Foundation
import ssshCore

/// "Bewerk lokaal": downloads a remote file, opens it in its default app, and
/// queues an upload back to the server on every save.
///
/// The uploads go through the ordinary transfer queue rather than quietly in
/// the background, because a save that silently fails to reach the server is
/// the worst outcome this feature can have — the queue is where failures are
/// visible and retryable.
///
/// The watcher lives as long as the file browser does. That is a real limit —
/// a save after the browser closes is not uploaded — but it matches where the
/// queue lives, and an upload nobody can see would break the rule above.
@MainActor
final class RemoteFileEditor {
    private let session: TerminalSession
    private let queue: TransferQueue
    /// One watcher per remote path: asking to edit the same file twice
    /// replaces the watcher rather than uploading every save twice.
    private var watchers: [String: FileWatcher] = [:]

    init(session: TerminalSession, queue: TransferQueue) {
        self.session = session
        self.queue = queue
    }

    func beginEditing(_ entry: RemoteFileEntry, in remoteDirectory: String) async throws {
        let url = try await RemoteFileExporter.download(entry.name, from: remoteDirectory, session: session)
        let localDirectory = RemotePath.parent(of: url.path)
        let remotePath = RemotePath.appending(entry.name, to: remoteDirectory)

        watchers[remotePath]?.stop()
        watchers[remotePath] = FileWatcher(path: url.path) { [weak self] in
            guard let self,
                  let attributes = LocalFileBrowser.attributes(atPath: url.path)
            else { return }
            // `.replace` rather than `.ask`: the user chose to edit this exact
            // file, so "the destination exists" is the point, not a collision.
            self.queue.enqueueUpload(
                of: RemoteFileEntry(name: entry.name, attributes: attributes),
                from: localDirectory,
                to: remoteDirectory,
                policy: .replace
            )
        }
        NSWorkspace.shared.open(url)
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }
}

/// Watches one path and coalesces the burst of filesystem events a save
/// produces into a single callback.
@MainActor
private final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounce: Task<Void, Never>?

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        guard arm() else { return nil }
    }

    func stop() {
        debounce?.cancel()
        source?.cancel()
        source = nil
    }

    private func arm() -> Bool {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(self.source?.data ?? [])
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        // Most editors save atomically: write a temporary file, rename it over
        // the original. The watched descriptor then points at the *old* inode
        // and reports delete/rename, so the watch has to be re-armed on the
        // path — which is also why the path, not the descriptor, is stored.
        if events.contains(.delete) || events.contains(.rename) {
            source?.cancel()
            source = nil
        }
        scheduleChange()
    }

    private func scheduleChange() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            // Long enough to fold one save's burst of events into one upload,
            // short enough that the upload starts while the save is fresh.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            if self.source == nil {
                // The atomic-save rename has finished by now; watch the new
                // inode at the same path. Failing to re-arm still uploads
                // this save — it just stops watching afterwards.
                _ = self.arm()
            }
            self.onChange()
        }
    }
}
#endif
