import Logging
import NIOCore
import NIOSSH
import ssshCore

/// Frames SFTP packets on an SSH subsystem channel and matches replies to
/// requests.
///
/// Three things here are not optional:
///
/// 1. **Reassembly.** SFTP packets are length-prefixed and an SSH channel is a
///    byte stream, so a packet arrives split across reads and several packets
///    arrive in one. Parsing per read would work on a fast localhost link and
///    fail on a real one.
/// 2. **Correlation by request id.** Unlike channel requests, SFTP replies do
///    identify themselves, which is what makes it safe to have many reads in
///    flight — and having many reads in flight is the entire difference
///    between a usable transfer and a 200 kB/s one.
/// 3. **Failing everything outstanding when the channel dies.** An
///    `EventLoopPromise` that is never completed traps on deinit in debug
///    builds, and a transfer that hangs for ever is worse than one that fails.
final class SFTPChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let logger: Logger
    private var accumulator: ByteBuffer
    private var pending: [UInt32: EventLoopPromise<SFTPResponse>] = [:]
    private var nextRequestID: UInt32 = 1
    /// Completed when the server answers `SSH_FXP_INIT`.
    private var versionPromise: EventLoopPromise<UInt32>?
    /// Completed when the server accepts or refuses the `subsystem` request.
    private var subsystemPromise: EventLoopPromise<Void>?
    private var failure: Error?

    init(allocator: ByteBufferAllocator, logger: Logger) {
        self.logger = logger
        self.accumulator = allocator.buffer(capacity: 8 * 1024)
    }

    // MARK: - Sending

    /// Asks for the `sftp` subsystem and waits for the server's answer.
    ///
    /// The future from `triggerUserOutboundEvent` completes when the request
    /// has been *written*, not when it has been answered: the answer arrives
    /// later as a bare `ChannelSuccessEvent` or `ChannelFailureEvent`. Waiting
    /// on the write would make every "Subsystem sftp" that is commented out
    /// look like a working connection that then hangs.
    ///
    /// Must be called on the channel's event loop.
    func sendSubsystemRequest(on channel: Channel) -> EventLoopFuture<Void> {
        channel.eventLoop.assertInEventLoop()
        if let failure { return channel.eventLoop.makeFailedFuture(failure) }

        let promise = channel.eventLoop.makePromise(of: Void.self)
        subsystemPromise = promise

        channel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
        ).whenFailure { [weak self] error in
            guard let self, let pending = self.subsystemPromise else { return }
            self.subsystemPromise = nil
            pending.fail(error)
        }

        return promise.futureResult
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            completeSubsystemRequest(with: .success(()))
        case is ChannelFailureEvent:
            // The only channel request this handler sends is the subsystem
            // one, so a refusal can only mean the server has no SFTP.
            completeSubsystemRequest(with: .failure(SSHTransportError.unsupported(.sftp)))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func completeSubsystemRequest(with result: Result<Void, Error>) {
        guard let promise = subsystemPromise else {
            logger.debug("received a channel reply with no request outstanding")
            return
        }
        subsystemPromise = nil
        promise.completeWith(result)
    }

    /// Must be called on the channel's event loop.
    func sendInitialize(on channel: Channel) -> EventLoopFuture<UInt32> {
        channel.eventLoop.assertInEventLoop()
        if let failure { return channel.eventLoop.makeFailedFuture(failure) }

        let promise = channel.eventLoop.makePromise(of: UInt32.self)
        versionPromise = promise

        send(SFTPCodec.encodeInitialize(version: SFTPProtocol.version, allocator: channel.allocator), on: channel)

        return promise.futureResult
    }

    /// Must be called on the channel's event loop.
    func send(_ request: SFTPRequest, on channel: Channel) -> EventLoopFuture<SFTPResponse> {
        channel.eventLoop.assertInEventLoop()
        if let failure { return channel.eventLoop.makeFailedFuture(failure) }

        let id = nextRequestID
        // Wrapping is fine and is what every implementation does: ids only
        // have to be unique among the requests actually outstanding, and
        // nobody has four billion of those.
        nextRequestID &+= 1

        let promise = channel.eventLoop.makePromise(of: SFTPResponse.self)
        pending[id] = promise

        send(SFTPCodec.encode(request, id: id, allocator: channel.allocator), on: channel) { [weak self] error in
            guard let self, let promise = self.pending.removeValue(forKey: id) else { return }
            promise.fail(error)
        }

        return promise.futureResult
    }

    private func send(_ packet: ByteBuffer, on channel: Channel, onFailure: ((Error) -> Void)? = nil) {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenFailure { error in onFailure?(error) }
        channel.writeAndFlush(packet, promise: promise)
    }

    // MARK: - Receiving

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = channelData.data else { return }

        // stderr on an SFTP channel is not protocol data — it is whatever the
        // server's startup printed, which is exactly the "banner breaks sftp"
        // problem. Log it and carry on rather than feeding it to the parser.
        if channelData.type == .stdErr {
            let text = bytes.readString(length: bytes.readableBytes) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                logger.debug("sftp subsystem wrote to stderr", metadata: ["text": .string(trimmed)])
            }
            return
        }

        accumulator.writeBuffer(&bytes)
        parsePackets(context: context)
    }

    private func parsePackets(context: ChannelHandlerContext) {
        while true {
            // Peek the length without consuming it: a packet that has not all
            // arrived has to stay in the accumulator exactly as it was.
            guard let length: UInt32 = accumulator.getInteger(at: accumulator.readerIndex) else { return }
            guard length >= 1, length <= UInt32(SFTPCodec.maximumPacketLength) else {
                fail(context: context, with: SFTPError.protocolViolation("the server sent a packet of \(length) bytes"))
                return
            }
            let total = 4 + Int(length)
            guard accumulator.readableBytes >= total else { return }

            accumulator.moveReaderIndex(forwardBy: 4)
            guard var packet = accumulator.readSlice(length: Int(length)) else { return }
            handle(packet: &packet, context: context)
            discardReadBytesIfWorthwhile()
        }
    }

    /// Keeps the accumulator from growing for the life of a long transfer,
    /// without copying on every single packet.
    private func discardReadBytesIfWorthwhile() {
        if accumulator.readerIndex > 64 * 1024 {
            accumulator.discardReadBytes()
        }
    }

    private func handle(packet: inout ByteBuffer, context: ChannelHandlerContext) {
        guard let rawType: UInt8 = packet.readInteger(), let type = SFTPPacketType(rawValue: rawType) else {
            // An unknown type is survivable — the packet is framed, so it can
            // simply be skipped — but it means a reply nobody will ever get.
            logger.debug("ignoring an SFTP packet of unknown type")
            return
        }

        if type == .version {
            guard let version: UInt32 = packet.readInteger() else {
                fail(context: context, with: SFTPError.protocolViolation("the server's version reply was truncated"))
                return
            }
            versionPromise?.succeed(version)
            versionPromise = nil
            return
        }

        guard let id: UInt32 = packet.readInteger() else {
            fail(context: context, with: SFTPError.protocolViolation("an SFTP reply arrived with no request id"))
            return
        }
        guard let promise = pending.removeValue(forKey: id) else {
            // A reply to a request that was already failed, most likely by a
            // write error. Not worth tearing the channel down for.
            logger.debug("ignoring an SFTP reply with no request outstanding", metadata: ["id": .stringConvertible(id)])
            return
        }

        do {
            promise.succeed(try SFTPCodec.decodeResponse(type: type, from: &packet))
        } catch {
            promise.fail(error)
        }
    }

    // MARK: - Teardown

    func channelInactive(context: ChannelHandlerContext) {
        fail(context: context, with: SFTPError.connectionLost, closeChannel: false)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(context: context, with: error)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Anything still outstanding will never be answered now. Leaving the
        // promises uncompleted traps in debug builds and hangs in release.
        failOutstanding(with: failure ?? SFTPError.connectionLost)
    }

    private func fail(context: ChannelHandlerContext, with error: Error, closeChannel: Bool = true) {
        if failure == nil { failure = error }
        failOutstanding(with: error)
        if closeChannel {
            context.close(promise: nil)
        }
    }

    private func failOutstanding(with error: Error) {
        let outstanding = pending
        pending.removeAll()
        for promise in outstanding.values { promise.fail(error) }

        versionPromise?.fail(error)
        versionPromise = nil

        subsystemPromise?.fail(error)
        subsystemPromise = nil
    }

    // MARK: - Writing

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}
