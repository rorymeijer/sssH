import CoreTransferable
import Foundation
import ssshCore
import UniformTypeIdentifiers

extension UTType {
    /// A private type for dragging between the two panes.
    ///
    /// A private type rather than `public.file-url`, because a remote file has
    /// no URL: it exists on another machine and the only handle on it is a
    /// path plus the connection it belongs to. Advertising it as a file URL
    /// would let other apps accept a drop they cannot actually read.
    static let ssshFileSelection = UTType(exportedAs: "nl.rorymeijer.sssh.file-selection")
}

/// What a drag between the two panes carries.
struct DraggedFiles: Codable, Transferable {
    enum Origin: Codable, Hashable {
        /// The directory the files were dragged out of.
        case local(directory: String)
        case remote(directory: String, sessionID: UUID)
    }

    var origin: Origin
    var names: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ssshFileSelection)
    }
}

/// A drag out of the remote pane.
///
/// Carries the pane-to-pane selection unchanged, and additionally exports the
/// grabbed file itself so a drop in Finder or Files produces the file. The
/// download runs when the receiver asks for it — at drop time, not drag
/// time — because most drags end on the other pane, and downloading on every
/// drag would punish the common case.
struct DraggedRemoteFile: Transferable {
    /// The whole dragged selection, for the opposite pane.
    var selection: DraggedFiles
    /// The row the drag started on. A multi-file drag exports this one file
    /// to the outside world; the other names still travel in `selection`.
    var name: String
    var isFile: Bool
    var directory: String
    var session: TerminalSession

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.selection)
        FileRepresentation(exportedContentType: .data) { item in
            let url = try await RemoteFileExporter.download(item.name, from: item.directory, session: item.session)
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.isFile }
        .suggestedFileName { $0.name }
    }
}

/// Downloads one remote file to a temporary location, for drags that leave
/// the app.
///
/// Kept apart from ``TransferQueue`` on purpose: the queue is user-visible
/// state with progress, retries and collision prompts, and an outgoing drag
/// needs none of that — the receiver is blocked on the promise, so the only
/// job is to finish.
enum RemoteFileExporter {
    /// Reads in flight at once. Same figure and same reasoning as the
    /// transfer queue: eight 32 KiB reads keep a long-latency link busy.
    private static let readDepth = 8

    static func download(_ name: String, from directory: String, session: TerminalSession) async throws -> URL {
        let service = try await session.sftp()
        let remotePath = RemotePath.appending(name, to: directory)

        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("sssh-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        // String paths rather than URL appends: a POSIX filename can contain
        // `%`, `#` and `?`, and every one of those round-trips through URL
        // wrong. See RemotePath.
        let localPath = RemotePath.appending(name, to: container.path)
        FileManager.default.createFile(atPath: localPath, contents: nil)
        guard let output = FileHandle(forWritingAtPath: localPath) else {
            throw SFTPError.failure(path: localPath, serverMessage: nil)
        }
        defer { try? output.close() }

        let remote = try await service.openFile(at: remotePath, mode: .read)
        defer { Task { try? await remote.close() } }

        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            // The same pipelined shape as TransferQueue.download, for the
            // same reason: strictly sequential reads run at the speed of the
            // round trip. Each task fills its whole range before returning —
            // the protocol allows a short read that is not the end of the
            // file, and only an empty read means end.
            let chunks = try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { group in
                for index in 0..<Self.readDepth {
                    let base = offset + UInt64(index * SFTPChunk.size)
                    group.addTask {
                        var bytes: [UInt8] = []
                        while bytes.count < SFTPChunk.size {
                            let piece = try await remote.read(
                                at: base + UInt64(bytes.count),
                                length: SFTPChunk.size - bytes.count
                            )
                            if piece.isEmpty { break }
                            bytes.append(contentsOf: piece)
                        }
                        return (index, bytes)
                    }
                }
                var collected: [(Int, [UInt8])] = []
                for try await chunk in group { collected.append(chunk) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            var wrote = 0
            var reachedEnd = false
            for chunk in chunks {
                if chunk.isEmpty { reachedEnd = true; break }
                try output.write(contentsOf: Data(chunk))
                wrote += chunk.count
                if chunk.count < SFTPChunk.size { reachedEnd = true; break }
            }
            offset += UInt64(wrote)
            if reachedEnd || wrote == 0 { break }
        }

        try output.synchronize()
        return URL(fileURLWithPath: localPath)
    }
}
