import Foundation
import Logging
import NIOCore

/// The SOCKS5 server side of `ssh -D`.
///
/// Only enough of RFC 1928 to be a proxy: no authentication, and `CONNECT`
/// only. `BIND` and `UDP ASSOCIATE` are refused, because neither can be
/// carried over an SSH `direct-tcpip` channel — there is nothing to implement
/// them with, and pretending otherwise would fail later and less clearly.
///
/// Authentication is deliberately absent rather than unimplemented. The
/// listener binds `127.0.0.1` by default, so the credential that matters is
/// already "can run code on this machine"; adding a username and password in
/// front of that would look like security without adding any.
final class SOCKS5ServerHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    /// Opens the tunnel for a negotiated destination. Succeeding means the
    /// channel is glued and this handler's job is done.
    ///
    /// `confirm` is called once the far side has accepted and before the two
    /// channels are joined, which is the only moment the success reply can be
    /// written: any earlier and a refused connection has already been reported
    /// as succeeding; any later and the far side's first bytes are ahead of
    /// the reply in the client's stream.
    typealias Connect = (
        _ channel: Channel,
        _ host: String,
        _ port: Int,
        _ confirm: @escaping @Sendable () -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void>

    private enum State {
        case awaitingGreeting
        case awaitingRequest
        case connecting
        case done
    }

    private static let version: UInt8 = 5
    private static let noAuthentication: UInt8 = 0x00
    private static let noAcceptableMethods: UInt8 = 0xFF
    private static let commandConnect: UInt8 = 0x01

    private enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case hostUnreachable = 0x04
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    private var state: State = .awaitingGreeting
    private var buffer: ByteBuffer?
    private let logger: Logger
    private let connect: Connect

    init(logger: Logger, connect: @escaping Connect) {
        self.logger = logger
        self.connect = connect
    }

    func handlerAdded(context: ChannelHandlerContext) {
        buffer = context.channel.allocator.buffer(capacity: 262)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        guard state != .done else {
            // Already glued; everything from here belongs to the tunnel.
            context.fireChannelRead(data)
            return
        }

        if buffer == nil { buffer = context.channel.allocator.buffer(capacity: 262) }
        buffer!.writeBuffer(&incoming)
        process(context: context)
    }

    private func process(context: ChannelHandlerContext) {
        while true {
            switch state {
            case .awaitingGreeting:
                guard let methods = readGreeting() else { return }
                guard methods.contains(Self.noAuthentication) else {
                    // Say so in the protocol's own terms and close. A client
                    // that insists on authentication gets a clear refusal
                    // rather than a dropped connection.
                    var reply = context.channel.allocator.buffer(capacity: 2)
                    reply.writeInteger(Self.version)
                    reply.writeInteger(Self.noAcceptableMethods)
                    context.writeAndFlush(NIOAny(reply)).whenComplete { _ in
                        context.close(promise: nil)
                    }
                    state = .done
                    return
                }
                var reply = context.channel.allocator.buffer(capacity: 2)
                reply.writeInteger(Self.version)
                reply.writeInteger(Self.noAuthentication)
                context.writeAndFlush(NIOAny(reply), promise: nil)
                state = .awaitingRequest

            case .awaitingRequest:
                guard let request = readRequest(context: context) else { return }
                state = .connecting
                openTunnel(to: request, context: context)
                return

            case .connecting, .done:
                return
            }
        }
    }

    // MARK: - Parsing

    /// `VER NMETHODS METHODS...`
    private func readGreeting() -> [UInt8]? {
        guard var working = self.buffer else { return nil }
        let saved = working
        guard let version: UInt8 = working.readInteger(), let count: UInt8 = working.readInteger() else {
            self.buffer = saved
            return nil
        }
        guard version == Self.version else {
            // Not SOCKS5. There is nothing to reply with that the peer would
            // understand, so the parse simply fails.
            return []
        }
        guard let methods = working.readBytes(length: Int(count)) else {
            self.buffer = saved
            return nil
        }
        self.buffer = working
        return methods
    }

    private struct Request {
        var host: String
        var port: Int
    }

    /// `VER CMD RSV ATYP DST.ADDR DST.PORT`
    private func readRequest(context: ChannelHandlerContext) -> Request? {
        guard var working = self.buffer else { return nil }
        let saved = working
        guard let version: UInt8 = working.readInteger(),
              let command: UInt8 = working.readInteger(),
              let _: UInt8 = working.readInteger(),
              let addressType: UInt8 = working.readInteger()
        else {
            self.buffer = saved
            return nil
        }

        guard version == Self.version else {
            fail(context: context, with: .generalFailure)
            return nil
        }
        guard command == Self.commandConnect else {
            // BIND and UDP ASSOCIATE cannot be carried over `direct-tcpip`.
            fail(context: context, with: .commandNotSupported)
            return nil
        }

        let host: String
        switch addressType {
        case 0x01:
            guard let octets = working.readBytes(length: 4) else { self.buffer = saved; return nil }
            host = octets.map(String.init).joined(separator: ".")
        case 0x03:
            guard let length: UInt8 = working.readInteger(),
                  let name = working.readString(length: Int(length))
            else {
                self.buffer = saved
                return nil
            }
            // A name, not an address: resolving it here would resolve it on
            // the wrong machine. The SSH server resolves it, which is the
            // whole point of a dynamic forward.
            host = name
        case 0x04:
            guard let octets = working.readBytes(length: 16) else { self.buffer = saved; return nil }
            host = Self.formatIPv6(octets)
        default:
            fail(context: context, with: .addressTypeNotSupported)
            return nil
        }

        guard let port: UInt16 = working.readInteger() else {
            self.buffer = saved
            return nil
        }
        self.buffer = working
        return Request(host: host, port: Int(port))
    }

    private static func formatIPv6(_ octets: [UInt8]) -> String {
        // The long form, without `::` compression. It is only ever handed
        // straight to the server as text, and the compressed form is where
        // hand-rolled IPv6 formatting goes wrong.
        stride(from: 0, to: 16, by: 2)
            .map { String(format: "%x", Int(octets[$0]) << 8 | Int(octets[$0 + 1])) }
            .joined(separator: ":")
    }

    // MARK: - Connecting

    private func openTunnel(to request: Request, context: ChannelHandlerContext) {
        let channel = context.channel
        let leftover = buffer
        buffer = nil
        let reply = Self.reply(.succeeded, allocator: channel.allocator)

        // Written from the channel rather than from this handler's context:
        // `confirm` runs on the SSH connection's event loop, and a
        // `ChannelHandlerContext` may only be touched on its own.
        // `Channel.writeAndFlush` hops for us.
        let confirm: @Sendable () -> EventLoopFuture<Void> = {
            channel.writeAndFlush(NIOAny(reply))
        }

        connect(channel, request.host, request.port, confirm)
            .hop(to: channel.eventLoop)
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.state = .done
                    // A client that put its first request bytes in the same
                    // packet as the SOCKS request would otherwise lose them,
                    // which is what makes a pipelined HTTP request through the
                    // proxy hang rather than fail.
                    if let leftover, leftover.readableBytes > 0 {
                        context.fireChannelRead(self.wrapInboundOut(leftover))
                        context.fireChannelReadComplete()
                    }
                    context.pipeline.removeHandler(self, promise: nil)
                case .failure(let error):
                    self.logger.debug("socks connect refused", metadata: [
                        "target": .string("\(request.host):\(request.port)"),
                        "error": .string(String(describing: error)),
                    ])
                    self.fail(context: context, with: .hostUnreachable)
                }
            }
    }

    private static func reply(_ code: Reply, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 10)
        buffer.writeInteger(version)
        buffer.writeInteger(code.rawValue)
        buffer.writeInteger(UInt8(0))
        // The bound address is reported as 0.0.0.0:0. The real one is on the
        // SSH server, this client never learns it, and no client in practice
        // looks at it for a CONNECT.
        buffer.writeInteger(UInt8(0x01))
        buffer.writeBytes([0, 0, 0, 0])
        buffer.writeInteger(UInt16(0))
        return buffer
    }

    private func fail(context: ChannelHandlerContext, with code: Reply) {
        state = .done
        buffer = nil
        let response = Self.reply(code, allocator: context.channel.allocator)
        context.writeAndFlush(NIOAny(response)).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
