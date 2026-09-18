import Foundation
import Logging
import NIOCore
import NIOSSH
import ssshCore

/// SFTP over an SSH subsystem channel.
///
/// Opens the channel, does the version handshake, and turns the protocol into
/// the ``SFTPService`` shape the app uses. Everything that touches the
/// handler's state hops onto the channel's event loop first: the request-id
/// map and the pending-reply table live there, and a file browser will happily
/// issue a dozen concurrent requests.
final class NIOSFTPService: SFTPService, @unchecked Sendable {
    private let channel: Channel
    private let handler: SFTPChannelHandler
    private let logger: Logger
    private let serverVersion: UInt32

    private init(channel: Channel, handler: SFTPChannelHandler, serverVersion: UInt32, logger: Logger) {
        self.channel = channel
        self.handler = handler
        self.serverVersion = serverVersion
        self.logger = logger
    }

    static func open(
        on sshHandler: NIOSSHHandler,
        eventLoop: EventLoop,
        allocator: ByteBufferAllocator,
        channelOpenTimeout: Duration,
        logger: Logger
    ) async throws -> NIOSFTPService {
        let handler = SFTPChannelHandler(allocator: allocator, logger: logger)

        let channel: Channel = try await eventLoop.flatSubmit {
            let created = eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(created, channelType: .session) { channel, _ in
                channel.pipeline.addHandler(handler)
            }
            let timeout = eventLoop.scheduleTask(in: .nanoseconds(channelOpenTimeout.nanosecondsClamped)) {
                created.fail(SSHTransportError.timedOut(operation: "channel-open", after: channelOpenTimeout))
            }
            created.futureResult.whenComplete { _ in timeout.cancel() }
            return created.futureResult
        }.get()

        do {
            try await requestSubsystem(on: channel, handler: handler)
            let version = try await handshake(on: channel, handler: handler, timeout: channelOpenTimeout)
            // Version 3 is the floor and, in practice, the ceiling. A server
            // offering less cannot be talked to; one offering more is required
            // by the drafts to fall back, and every one of them does.
            guard version >= SFTPProtocol.version else {
                throw SFTPError.unsupportedProtocolVersion(version)
            }
            logger.debug("sftp subsystem ready", metadata: ["version": .stringConvertible(version)])
            return NIOSFTPService(channel: channel, handler: handler, serverVersion: version, logger: logger)
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    /// `subsystem` is a channel request like `shell` or `exec`, and it is
    /// refused by every server that has `Subsystem sftp` commented out — which
    /// is a configuration the user can fix, so it is worth reporting as
    /// "this server has no SFTP" rather than as a generic failure.
    private static func requestSubsystem(on channel: Channel, handler: SFTPChannelHandler) async throws {
        let future: EventLoopFuture<Void> = try await channel.eventLoop.submit {
            handler.sendSubsystemRequest(on: channel)
        }.get()
        try await future.get()
    }

    private static func handshake(
        on channel: Channel,
        handler: SFTPChannelHandler,
        timeout: Duration
    ) async throws -> UInt32 {
        let future: EventLoopFuture<UInt32> = try await channel.eventLoop.submit {
            let version = handler.sendInitialize(on: channel)
            // A server that accepts the subsystem request and then says
            // nothing would otherwise leave the browser spinning for ever.
            let timeoutTask = channel.eventLoop.scheduleTask(in: .nanoseconds(timeout.nanosecondsClamped)) {
                channel.close(promise: nil)
            }
            version.whenComplete { _ in timeoutTask.cancel() }
            return version
        }.get()
        return try await future.get()
    }

    // MARK: - Requests

    private func send(_ request: SFTPRequest) async throws -> SFTPResponse {
        let future: EventLoopFuture<SFTPResponse> = try await channel.eventLoop.submit {
            self.handler.send(request, on: self.channel)
        }.get()
        let response = try await future.get()
        // A status reply to anything other than a write or a close is the
        // server saying no. Turning it into an error here means no call site
        // has to remember to check.
        if case .status(let status) = response, let error = status.asError(path: request.path) {
            throw error
        }
        return response
    }

    /// For requests whose *success* is a status reply.
    private func sendExpectingStatus(_ request: SFTPRequest) async throws {
        let response = try await send(request)
        guard case .status = response else {
            throw SFTPError.protocolViolation("the server answered with data where a status was expected")
        }
    }

    func realPath(of path: String) async throws -> String {
        let response = try await send(.realpath(path: path))
        guard case .name(let entries) = response, let first = entries.first else {
            throw SFTPError.protocolViolation("the server's realpath reply was empty")
        }
        return first.filename
    }

    func attributes(of path: String) async throws -> RemoteFileAttributes {
        // `lstat`, not `stat`: a browser has to be able to show that something
        // is a symlink, and `stat` resolves it away.
        let response = try await send(.lstat(path: path))
        guard case .attributes(let attributes) = response else {
            throw SFTPError.protocolViolation("the server's stat reply carried no attributes")
        }
        return attributes
    }

    func setAttributes(_ attributes: RemoteFileAttributes, of path: String) async throws {
        try await sendExpectingStatus(.setstat(path: path, attributes: attributes))
    }

    func createDirectory(at path: String, permissions: POSIXPermissions?) async throws {
        let attributes = permissions.map { RemoteFileAttributes(kind: .directory, permissions: $0) }
        try await sendExpectingStatus(.mkdir(path: path, attributes: attributes))
    }

    func remove(at path: String) async throws {
        try await sendExpectingStatus(.remove(path: path))
    }

    func removeDirectory(at path: String) async throws {
        try await sendExpectingStatus(.rmdir(path: path))
    }

    func rename(from: String, to: String) async throws {
        try await sendExpectingStatus(.rename(from: from, to: to))
    }

    func readLink(at path: String) async throws -> String {
        let response = try await send(.readlink(path: path))
        guard case .name(let entries) = response, let first = entries.first else {
            throw SFTPError.protocolViolation("the server's readlink reply was empty")
        }
        return first.filename
    }

    func createSymbolicLink(at path: String, to target: String) async throws {
        try await sendExpectingStatus(.symlink(linkPath: path, target: target))
    }

    // MARK: - Directories

    func listDirectory(at path: String) -> AsyncThrowingStream<[RemoteFileEntry], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var handle: ByteBuffer?
                do {
                    let opened = try await send(.opendir(path: path))
                    guard case .handle(let directoryHandle) = opened else {
                        throw SFTPError.protocolViolation("the server's opendir reply carried no handle")
                    }
                    handle = directoryHandle

                    while !Task.isCancelled {
                        let response = try await sendAllowingEndOfFile(.readdir(handle: directoryHandle))
                        switch response {
                        case .status(let status) where status.code == .endOfFile:
                            continuation.finish()
                            // The handle is a server resource; a browser that
                            // walks a deep tree without closing them runs the
                            // session out of file descriptors.
                            try? await closeHandle(directoryHandle)
                            return
                        case .name(let entries):
                            let converted = entries
                                // `.` and `..` are navigation, not contents,
                                // and every browser that shows them has to
                                // then special-case them everywhere else.
                                .filter { $0.filename != "." && $0.filename != ".." }
                                .map { entry in
                                    RemoteFileEntry(name: entry.filename, attributes: entry.attributes)
                                }
                            if !converted.isEmpty { continuation.yield(converted) }
                        default:
                            throw SFTPError.protocolViolation("the server answered readdir with something else")
                        }
                    }
                    try? await closeHandle(directoryHandle)
                    continuation.finish()
                } catch {
                    if let handle { try? await closeHandle(handle) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `readdir` and `read` answer "there is no more" with a status reply, so
    /// for those two the status is not automatically an error.
    private func sendAllowingEndOfFile(_ request: SFTPRequest) async throws -> SFTPResponse {
        let future: EventLoopFuture<SFTPResponse> = try await channel.eventLoop.submit {
            self.handler.send(request, on: self.channel)
        }.get()
        let response = try await future.get()
        if case .status(let status) = response, status.code != .endOfFile,
           let error = status.asError(path: request.path) {
            throw error
        }
        return response
    }

    private func closeHandle(_ handle: ByteBuffer) async throws {
        try await sendExpectingStatus(.close(handle: handle))
    }

    // MARK: - Files

    func openFile(at path: String, mode: RemoteFileOpenMode) async throws -> any RemoteFileHandle {
        let response = try await send(.open(path: path, flags: SFTPOpenFlags(mode), attributes: nil))
        guard case .handle(let handle) = response else {
            throw SFTPError.protocolViolation("the server's open reply carried no handle")
        }
        return NIOSFTPFileHandle(service: self, handle: handle, path: path)
    }

    fileprivate func read(handle: ByteBuffer, offset: UInt64, length: Int) async throws -> [UInt8] {
        let capped = UInt32(min(length, SFTPProtocol.preferredChunkSize))
        let response = try await sendAllowingEndOfFile(.read(handle: handle, offset: offset, length: capped))
        switch response {
        case .status(let status) where status.code == .endOfFile:
            return []
        case .data(var data):
            return data.readBytes(length: data.readableBytes) ?? []
        default:
            throw SFTPError.protocolViolation("the server answered a read with something else")
        }
    }

    fileprivate func write(handle: ByteBuffer, bytes: [UInt8], offset: UInt64) async throws {
        var written = 0
        while written < bytes.count {
            let size = min(SFTPProtocol.preferredChunkSize, bytes.count - written)
            var chunk = channel.allocator.buffer(capacity: size)
            chunk.writeBytes(bytes[written..<(written + size)])
            try await sendExpectingStatus(
                .write(handle: handle, offset: offset + UInt64(written), data: chunk)
            )
            written += size
        }
    }

    fileprivate func attributes(handle: ByteBuffer) async throws -> RemoteFileAttributes {
        let response = try await send(.fstat(handle: handle))
        guard case .attributes(let attributes) = response else {
            throw SFTPError.protocolViolation("the server's fstat reply carried no attributes")
        }
        return attributes
    }

    fileprivate func close(handle: ByteBuffer) async throws {
        try await closeHandle(handle)
    }

    func close() async {
        try? await channel.close().get()
    }
}

/// One open remote file.
///
/// Deliberately not closed in `deinit`: an SFTP handle is state on the server,
/// closing it is an async round trip, and a `deinit` cannot wait for one. The
/// caller closes it, and the transfer queue is written so that it always does.
private final class NIOSFTPFileHandle: RemoteFileHandle, @unchecked Sendable {
    private let service: NIOSFTPService
    private let handle: ByteBuffer
    private let path: String
    private let lock = NSLock()
    private var isClosed = false

    init(service: NIOSFTPService, handle: ByteBuffer, path: String) {
        self.service = service
        self.handle = handle
        self.path = path
    }

    func readAttributes() async throws -> RemoteFileAttributes {
        try checkOpen()
        return try await service.attributes(handle: handle)
    }

    func read(at offset: UInt64, length: Int) async throws -> [UInt8] {
        try checkOpen()
        return try await service.read(handle: handle, offset: offset, length: length)
    }

    func write(_ bytes: [UInt8], at offset: UInt64) async throws {
        try checkOpen()
        try await service.write(handle: handle, bytes: bytes, offset: offset)
    }

    func close() async throws {
        lock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        try await service.close(handle: handle)
    }

    /// Closing twice would free a handle the server may already have reused
    /// for a different file, and using one after close is a bug worth naming
    /// rather than a request worth sending.
    private func checkOpen() throws {
        lock.lock()
        defer { lock.unlock() }
        if isClosed {
            throw SFTPError.protocolViolation("the file \(path) was used after it was closed")
        }
    }
}
