import Foundation
import Observation
import ssshCore

/// Uploads and downloads, run one at a time per connection.
///
/// One at a time is deliberate. SFTP over a single SSH connection shares one
/// TCP stream, so running four transfers concurrently does not make them
/// faster — it makes all four slow and the progress bars meaningless. Depth
/// comes from pipelining reads *within* a transfer, which is where the speed
/// actually is.
@MainActor
@Observable
final class TransferQueue {
    private(set) var transfers: [FileTransfer] = []
    /// Bytes per second for the running transfer, for the status line.
    private(set) var currentRate: Double?
    private(set) var currentTimeRemaining: TimeInterval?

    /// A transfer that stopped on a collision and is waiting to be told what
    /// to do. One at a time, because asking about ten at once is a dialog
    /// nobody reads.
    private(set) var pendingCollision: FileTransfer?

    var activeCount: Int { transfers.filter { !$0.state.isTerminal }.count }
    var hasFinishedItems: Bool { transfers.contains { $0.state.isTerminal } }

    /// How many times a dropped transfer is retried before it stops asking.
    /// A reconnect can revive it; a permission error never will, and
    /// ``SFTPError/isWorthRetrying`` is what tells them apart.
    private static let maximumRetries = 3
    /// Reads in flight at once within a single transfer. Eight 32 KiB reads
    /// keep a long-latency link busy; more mostly buys reordering.
    private static let readDepth = 8

    private let session: TerminalSession
    private var runner: Task<Void, Never>?
    private var rateEstimator = TransferRateEstimator()
    private var cancelledIDs: Set<UUID> = []

    init(session: TerminalSession) {
        self.session = session
    }

    // MARK: - Enqueueing

    func enqueueDownload(of entry: RemoteFileEntry, from remoteDirectory: String, to localDirectory: String, policy: FileTransfer.CollisionPolicy = .ask) {
        guard entry.attributes.kind != .directory else {
            // Directory transfers are expanded by the caller, which has the
            // listing. Doing it here would mean a second recursive walk.
            return
        }
        transfers.append(FileTransfer(
            direction: .download,
            remotePath: RemotePath.appending(entry.name, to: remoteDirectory),
            localPath: RemotePath.appending(entry.name, to: localDirectory),
            totalBytes: entry.attributes.size,
            collisionPolicy: policy
        ))
        startIfIdle()
    }

    func enqueueUpload(of entry: RemoteFileEntry, from localDirectory: String, to remoteDirectory: String, policy: FileTransfer.CollisionPolicy = .ask) {
        guard entry.attributes.kind != .directory else { return }
        transfers.append(FileTransfer(
            direction: .upload,
            remotePath: RemotePath.appending(entry.name, to: remoteDirectory),
            localPath: RemotePath.appending(entry.name, to: localDirectory),
            totalBytes: entry.attributes.size,
            collisionPolicy: policy
        ))
        startIfIdle()
    }

    /// Walks a remote directory and queues every file under it, recreating the
    /// tree locally. Done here rather than in the view because it needs the
    /// SFTP channel and can take a while on a deep tree.
    func enqueueDownloadTree(of entry: RemoteFileEntry, from remoteDirectory: String, to localDirectory: String) async {
        let remoteRoot = RemotePath.appending(entry.name, to: remoteDirectory)
        let localRoot = RemotePath.appending(entry.name, to: localDirectory)
        do {
            let service = try await session.sftp()
            try await walk(remoteRoot, localRoot: localRoot, service: service)
            startIfIdle()
        } catch {
            transfers.append(FileTransfer(
                direction: .download,
                remotePath: remoteRoot,
                localPath: localRoot,
                state: .failed(FileTransferText.describe(error))
            ))
        }
    }

    private func walk(_ remotePath: String, localRoot: String, service: any SFTPService) async throws {
        try FileManager.default.createDirectory(atPath: localRoot, withIntermediateDirectories: true)
        var children: [RemoteFileEntry] = []
        for try await batch in service.listDirectory(at: remotePath) {
            children.append(contentsOf: batch)
        }
        for child in children {
            let childRemote = RemotePath.appending(child.name, to: remotePath)
            let childLocal = RemotePath.appending(child.name, to: localRoot)
            switch child.attributes.kind {
            case .directory:
                try await walk(childRemote, localRoot: childLocal, service: service)
            case .file:
                transfers.append(FileTransfer(
                    direction: .download,
                    remotePath: childRemote,
                    localPath: childLocal,
                    totalBytes: child.attributes.size
                ))
            case .symlink, .other:
                // Following links while walking a tree is how a backup ends up
                // copying `/` into a subdirectory of itself.
                continue
            }
        }
    }

    // MARK: - Control

    func cancel(_ transfer: FileTransfer) {
        cancelledIDs.insert(transfer.id)
        update(transfer.id) { item in
            guard !item.state.isTerminal else { return }
            item.state = .cancelled
            item.finishedAt = Date()
        }
        // The runner is deliberately not cancelled: the running transfer
        // notices its id in `cancelledIDs` at its next chunk, and the queue
        // carries on with the rest. Cancelling the runner would stop every
        // other transfer as well.
    }

    func cancelAll() {
        for transfer in transfers where !transfer.state.isTerminal {
            cancel(transfer)
        }
    }

    func retry(_ transfer: FileTransfer) {
        cancelledIDs.remove(transfer.id)
        update(transfer.id) { item in
            item.state = .waiting
            item.retryCount = 0
            item.finishedAt = nil
        }
        startIfIdle()
    }

    func clearFinished() {
        transfers.removeAll { $0.state.isTerminal }
    }

    /// Answers the collision the queue stopped on.
    func resolveCollision(with policy: FileTransfer.CollisionPolicy) {
        guard let pending = pendingCollision else { return }
        pendingCollision = nil
        guard policy != .ask else {
            update(pending.id) { $0.state = .cancelled }
            startIfIdle()
            return
        }
        update(pending.id) { item in
            item.collisionPolicy = policy
            item.state = .waiting
        }
        startIfIdle()
    }

    // MARK: - Running

    private func startIfIdle() {
        guard runner == nil, pendingCollision == nil else { return }
        runner = Task { [weak self] in
            await self?.drain()
            self?.runner = nil
        }
    }

    private func drain() async {
        while let next = transfers.first(where: { if case .waiting = $0.state { return true } else { return false } }) {
            if pendingCollision != nil { return }
            await run(next)
        }
        currentRate = nil
        currentTimeRemaining = nil
    }

    private func run(_ transfer: FileTransfer) async {
        rateEstimator.reset()
        update(transfer.id) { item in
            item.state = .running
            item.startedAt = item.startedAt ?? Date()
        }

        do {
            let service = try await session.sftp()
            switch transfer.direction {
            case .download:
                try await download(transfer, using: service)
            case .upload:
                try await upload(transfer, using: service)
            }
            update(transfer.id) { item in
                item.state = .finished
                item.finishedAt = Date()
            }
        } catch is CancellationError {
            update(transfer.id) { item in
                if !item.state.isTerminal { item.state = .cancelled }
                item.finishedAt = Date()
            }
        } catch is TransferCollision {
            // Not a failure: the queue is asking a question, and the transfer
            // goes back to waiting once it is answered.
            update(transfer.id) { $0.state = .paused }
            pendingCollision = current(transfer.id)
        } catch {
            let shouldRetry = (error as? SFTPError)?.isWorthRetrying == true
                && (current(transfer.id)?.retryCount ?? 0) < Self.maximumRetries
            update(transfer.id) { item in
                if shouldRetry {
                    item.retryCount += 1
                    item.state = .waiting
                } else {
                    item.state = .failed(FileTransferText.describe(error))
                    item.finishedAt = Date()
                }
            }
            if shouldRetry {
                // A dropped connection is coming back or it is not; either way
                // hammering it immediately helps nobody.
                try? await Task.sleep(for: .seconds(2))
            }
        }

        currentRate = nil
        currentTimeRemaining = nil
    }

    /// Raised when the destination already exists and the policy is `.ask`.
    private struct TransferCollision: Error {}

    // MARK: - Download

    private func download(_ transfer: FileTransfer, using service: any SFTPService) async throws {
        let fileManager = FileManager.default
        var startOffset: UInt64 = 0

        let attributes = try await service.attributes(of: transfer.remotePath)
        let totalBytes = attributes.size
        update(transfer.id) { $0.totalBytes = totalBytes }

        if fileManager.fileExists(atPath: transfer.localPath) {
            switch transfer.collisionPolicy {
            case .ask:
                throw TransferCollision()
            case .replace:
                try fileManager.removeItem(atPath: transfer.localPath)
            case .keepBoth:
                let directory = RemotePath.parent(of: transfer.localPath)
                let existing = Set((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
                let name = RemotePath.uniqueName(RemotePath.lastComponent(of: transfer.localPath), avoiding: existing)
                update(transfer.id) { $0.localPath = RemotePath.appending(name, to: directory) }
            case .resume:
                let existing = LocalFileBrowser.attributes(atPath: transfer.localPath)?.size ?? 0
                // A local file longer than the remote one is not a partial
                // download. Appending to it would produce a file that is
                // neither, so start over instead.
                startOffset = (totalBytes.map { existing < $0 } ?? false) ? existing : 0
                if startOffset == 0 { try fileManager.removeItem(atPath: transfer.localPath) }
            }
        }

        let localPath = current(transfer.id)?.localPath ?? transfer.localPath
        try fileManager.createDirectory(atPath: RemotePath.parent(of: localPath), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: localPath) {
            fileManager.createFile(atPath: localPath, contents: nil)
        }

        guard let output = FileHandle(forWritingAtPath: localPath) else {
            throw SFTPError.failure(path: localPath, serverMessage: nil)
        }
        defer { try? output.close() }
        try output.seek(toOffset: startOffset)

        let remote = try await service.openFile(at: transfer.remotePath, mode: .read)
        defer { Task { try? await remote.close() } }

        var offset = startOffset
        update(transfer.id) { $0.transferredBytes = startOffset }

        while true {
            try Task.checkCancellation()
            if cancelledIDs.contains(transfer.id) { throw CancellationError() }

            // Reads are issued ahead of being needed: on a link with 80 ms of
            // latency a strictly sequential read/write loop spends nearly all
            // its time waiting, and no chunk size fixes that.
            //
            // Each task fills its own range before returning. The protocol
            // allows a short read that is *not* the end of the file, so a task
            // that returned one would leave a hole in the middle of the
            // downloaded file — and only an empty read means end.
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
                // The group finishes out of order; the file does not.
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            var wrote = 0
            var reachedEnd = false
            for chunk in chunks {
                if chunk.isEmpty { reachedEnd = true; break }
                try output.write(contentsOf: Data(chunk))
                wrote += chunk.count
                // Short but not empty means this chunk ran into the end of the
                // file, so everything after it in this batch is past the end.
                if chunk.count < SFTPChunk.size { reachedEnd = true; break }
            }

            if wrote > 0 {
                offset += UInt64(wrote)
                report(transfer.id, transferred: offset, total: totalBytes)
            }
            if reachedEnd || wrote == 0 { break }
        }

        try output.synchronize()
    }

    // MARK: - Upload

    private func upload(_ transfer: FileTransfer, using service: any SFTPService) async throws {
        guard let input = FileHandle(forReadingAtPath: transfer.localPath) else {
            throw SFTPError.noSuchFile(path: transfer.localPath, serverMessage: nil)
        }
        defer { try? input.close() }

        let totalBytes = LocalFileBrowser.attributes(atPath: transfer.localPath)?.size
        update(transfer.id) { $0.totalBytes = totalBytes }

        var remotePath = transfer.remotePath
        var startOffset: UInt64 = 0
        var mode: RemoteFileOpenMode = [.write, .create, .truncate]

        if let existing = try? await service.attributes(of: remotePath) {
            switch transfer.collisionPolicy {
            case .ask:
                throw TransferCollision()
            case .replace:
                break
            case .keepBoth:
                let directory = RemotePath.parent(of: remotePath)
                var names: Set<String> = []
                for try await batch in service.listDirectory(at: directory) {
                    names.formUnion(batch.map(\.name))
                }
                let name = RemotePath.uniqueName(RemotePath.lastComponent(of: remotePath), avoiding: names)
                remotePath = RemotePath.appending(name, to: directory)
                update(transfer.id) { $0.remotePath = remotePath }
            case .resume:
                let remoteSize = existing.size ?? 0
                startOffset = (totalBytes.map { remoteSize < $0 } ?? false) ? remoteSize : 0
                // Without `truncate` the existing bytes stay, which is the
                // whole point of resuming.
                mode = startOffset > 0 ? [.write, .create] : [.write, .create, .truncate]
            }
        }

        let remote = try await service.openFile(at: remotePath, mode: mode)
        defer { Task { try? await remote.close() } }

        var offset = startOffset
        try input.seek(toOffset: startOffset)
        update(transfer.id) { $0.transferredBytes = startOffset }

        while true {
            try Task.checkCancellation()
            if cancelledIDs.contains(transfer.id) { throw CancellationError() }

            let data = try input.read(upToCount: SFTPChunk.size * 4) ?? Data()
            guard !data.isEmpty else { break }
            try await remote.write(Array(data), at: offset)
            offset += UInt64(data.count)
            report(transfer.id, transferred: offset, total: totalBytes)
        }
    }

    // MARK: - Bookkeeping

    private func report(_ id: UUID, transferred: UInt64, total: UInt64?) {
        update(id) { $0.transferredBytes = transferred }
        rateEstimator.record(transferred)
        currentRate = rateEstimator.bytesPerSecond
        currentTimeRemaining = rateEstimator.estimatedTimeRemaining(totalBytes: total)
    }

    private func current(_ id: UUID) -> FileTransfer? {
        transfers.first { $0.id == id }
    }

    private func update(_ id: UUID, _ body: (inout FileTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        body(&transfers[index])
    }
}

enum SFTPChunk {
    /// Matches what the transport sends per packet, so a read here is one
    /// round trip rather than one and a bit.
    static let size = 32 * 1024
}
