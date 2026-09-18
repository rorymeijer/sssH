import NIOCore
import NIOSSH

/// The ways an SSH channel can be wrong that this module has to name.
enum SSHChannelError: Error {
    /// Data arrived on a stream that should only ever carry the main one —
    /// stderr on a `direct-tcpip` channel, which the protocol does not allow.
    case invalidDataType
    /// The peer opened a channel of a type this client will not accept. A
    /// server that opens channels the client never asked for is either broken
    /// or hostile, and there is nothing useful to do with one.
    case inappropriateChannelType
}

/// Unwraps an SSH channel's framing into a plain byte stream, and wraps it
/// back on the way out.
///
/// Used wherever something that speaks bytes has to sit on top of an SSH
/// channel: a nested SSH connection through a jump host, a forwarded TCP
/// connection, a SOCKS proxy. Each of those would otherwise have to know about
/// `SSHChannelData`, and none of them has any business doing so.
final class SSHChannelDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data, case .channel = channelData.type else {
            // stderr on a direct-tcpip channel is a protocol violation.
            context.fireErrorCaught(SSHChannelError.invalidDataType)
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

