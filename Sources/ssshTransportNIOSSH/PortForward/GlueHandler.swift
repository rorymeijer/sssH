import NIOCore

/// Pipes two channels into each other, with backpressure in both directions.
///
/// A pair of these is what a tunnel actually is: everything read on one channel
/// is written to the other, and neither side is read from faster than the other
/// can be written to. Without that last part, forwarding a fast download
/// through a slow uplink buffers the whole file in the app.
///
/// The half-close handling matters as much as the backpressure. A forwarded
/// connection where one side has sent everything and is waiting for a reply —
/// which is every HTTP request — needs the EOF to travel, and it needs it to
/// travel as a half-close rather than as a full close, or the reply never
/// arrives.
final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    /// Set when this side was asked to read while its partner could not take
    /// more; the read is issued when the partner becomes writable again.
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Both directions have to go, or the pair keeps each other alive for
        // the life of the process.
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            // Half-close travels. A full close here would cut off the reply to
            // a request that has only just finished being sent.
            partner?.partnerWriteEOF()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            // Stop reading until the far side has drained. This is the whole
            // backpressure mechanism: the read is remembered rather than
            // dropped, and reissued from `channelWritabilityChanged`.
            pendingRead = true
        }
    }
}
