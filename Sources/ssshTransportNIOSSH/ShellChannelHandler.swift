import Logging
import NIOCore
import NIOSSH
import ssshCore

/// The pipeline handler for one interactive channel.
///
/// It does four things that together are what "a working interactive shell"
/// means, and each of them is a place a naive implementation goes wrong:
///
/// 1. **Converts** between `ByteBuffer` (what the terminal deals in) and
///    `SSHChannelData`, keeping the extended-data stream separate.
/// 2. **Correlates channel-request replies.** `pty-req` and `shell` are sent
///    with `want_reply`, and the answers come back as bare
///    `ChannelSuccessEvent`/`ChannelFailureEvent` user events with nothing
///    identifying which request they answer — SSH replies in order, so the
///    only correct approach is a FIFO of promises.
/// 3. **Applies backpressure.** `autoRead` is turned off, and each read is
///    issued only while the consumer is keeping up. Without this, `cat
///    big.log` buffers the whole file in the app while SwiftTerm parses.
/// 4. **Reports how the shell ended** — `exit-status`, `exit-signal`, or the
///    channel simply going away — as the last event on the stream, so nothing
///    above has to guess.
final class ShellChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let sink: SSHShellEventSink
    private let logger: Logger

    /// Promises for channel requests sent with `want_reply`, oldest first.
    private var pendingReplies: CircularBuffer<EventLoopPromise<Void>> = []
    private var pendingExit = SSHShellExit()
    private var hasFinished = false

    init(sink: SSHShellEventSink, logger: Logger) {
        self.sink = sink
        self.logger = logger
    }

    // MARK: - Request/reply correlation

    /// Sends a channel request with `want_reply` and returns a future for the
    /// server's answer.
    ///
    /// Must be called on the channel's event loop. Registering the promise
    /// before the write is what makes the FIFO correct; failing it when the
    /// write itself fails is what stops an uncompleted `EventLoopPromise` from
    /// tripping NIO's leak precondition.
    func sendRequestExpectingReply(_ event: Any, on channel: Channel) -> EventLoopFuture<Void> {
        let eventLoop = channel.eventLoop
        eventLoop.assertInEventLoop()

        let promise = eventLoop.makePromise(of: Void.self)
        pendingReplies.append(promise)

        channel.triggerUserOutboundEvent(event).whenFailure { [weak self] error in
            self?.failIfStillPending(promise, error: error)
        }

        return promise.futureResult
    }

    private func failIfStillPending(_ promise: EventLoopPromise<Void>, error: Error) {
        guard let index = pendingReplies.firstIndex(where: { $0.futureResult === promise.futureResult }) else {
            // Already answered or already failed by `finish`.
            return
        }
        pendingReplies.remove(at: index)
        promise.fail(error)
    }

    private func completeNextReply(with result: Result<Void, Error>) {
        guard let promise = pendingReplies.popFirst() else {
            logger.debug("received a channel reply with no request outstanding")
            return
        }
        promise.completeWith(result)
    }

    // MARK: - ChannelDuplexHandler

    func handlerAdded(context: ChannelHandlerContext) {
        // Remote EOF must not tear the channel down: a shell can close its
        // stdout while the exit status is still on its way, and dropping the
        // channel there loses the exit code.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
        // Reads are driven by demand from the consumer. See `channelReadComplete`.
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = channelData.data else {
            // NIOSSH only ever produces byteBuffer payloads for these channel
            // types; anything else is a protocol violation worth surfacing.
            finish(throwing: SSHTransportError.channelRequestFailed("non-byte-buffer channel data"))
            return
        }

        let bytes = Array(buffer.readableBytesView)
        guard !bytes.isEmpty else { return }

        switch channelData.type {
        case .channel:
            sink.push(.output(bytes))
        case .stdErr:
            sink.push(.errorOutput(bytes))
        default:
            logger.debug("ignoring data on unknown extended stream", metadata: ["type": "\(channelData.type)"])
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        // Ask for more only while the consumer is draining. When it falls
        // behind, the sink stops us here and calls back (via
        // `onDemandForMoreData`) once it has room, which is what turns
        // consumer slowness into TCP backpressure instead of unbounded memory.
        if sink.shouldContinueReading() {
            context.read()
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            completeNextReply(with: .success(()))

        case is ChannelFailureEvent:
            completeNextReply(with: .failure(
                SSHTransportError.channelRequestFailed("server refused a channel request")
            ))

        case let status as SSHChannelRequestEvent.ExitStatus:
            pendingExit.status = Int32(truncatingIfNeeded: status.exitStatus)

        case let signal as SSHChannelRequestEvent.ExitSignal:
            pendingExit.signal = signal.signalName

        case let channelEvent as ChannelEvent:
            // Remote EOF. Data is done, but the exit status may still be on its
            // way, so this is noted and not acted on.
            if channelEvent == .inputClosed {
                logger.trace("remote closed its output")
            } else {
                context.fireUserInboundEventTriggered(event)
            }

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(throwing: error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(throwing: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Covers a pipeline torn down without `channelInactive` (for example
        // the parent connection dropping underneath us).
        finish(throwing: nil)
    }

    /// Terminates the stream exactly once, delivering the exit event first so a
    /// consumer always learns the exit status before the stream ends.
    private func finish(throwing error: Error?) {
        guard !hasFinished else { return }
        hasFinished = true

        while let promise = pendingReplies.popFirst() {
            promise.fail(error ?? SSHTransportError.connectionLost(.remoteClosed))
        }

        if error == nil {
            sink.push(.exit(pendingExit))
        }
        sink.finish(throwing: error)
    }
}
