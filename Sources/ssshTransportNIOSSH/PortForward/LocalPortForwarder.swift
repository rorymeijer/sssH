import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSH
import ssshCore

/// `ssh -L` and `ssh -D`: a local listener whose connections are carried over
/// the SSH connection.
///
/// Both are the same machinery. The only difference is where the destination
/// comes from — fixed for `-L`, negotiated per connection by SOCKS for `-D` —
/// so the listener, the accounting and the teardown are written once.
final class LocalPortForwarder: ActivePortForward, @unchecked Sendable {
    enum Destination {
        /// `-L`: every connection goes to the same place.
        case fixed(host: String, port: Int)
        /// `-D`: the client asks, over SOCKS5, where it wants to go.
        case socks
    }

    let boundPort: Int
    var statistics: PortForwardStatistics { counters.snapshot }

    private let listener: Channel
    private let counters: PortForwardCounters
    private let logger: Logger

    private init(listener: Channel, boundPort: Int, counters: PortForwardCounters, logger: Logger) {
        self.listener = listener
        self.boundPort = boundPort
        self.counters = counters
        self.logger = logger
    }

    static func start(
        listenAddress: String,
        listenPort: Int,
        destination: Destination,
        sshHandler: NIOSSHHandler,
        sshEventLoop: EventLoop,
        group: EventLoopGroup,
        logger: Logger
    ) async throws -> LocalPortForwarder {
        let counters = PortForwardCounters()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Half-close has to travel for a forwarded connection to behave
            // like a direct one; without this NIO turns an inbound EOF into a
            // full close and the reply to the last request is lost.
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { accepted in
                switch destination {
                case .fixed(let host, let port):
                    return connect(
                        accepted: accepted,
                        to: host,
                        port: port,
                        sshHandler: sshHandler,
                        sshEventLoop: sshEventLoop,
                        counters: counters,
                        logger: logger
                    )
                case .socks:
                    let handler = SOCKS5ServerHandler(
                        logger: logger
                    ) { channel, host, port, confirm in
                        connect(
                            accepted: channel,
                            to: host,
                            port: port,
                            sshHandler: sshHandler,
                            sshEventLoop: sshEventLoop,
                            counters: counters,
                            logger: logger,
                            beforeGluing: confirm
                        )
                    }
                    return accepted.pipeline.addHandler(handler)
                }
            }

        let listener: Channel
        do {
            listener = try await bootstrap.bind(host: listenAddress, port: listenPort).get()
        } catch {
            throw SSHTransportError.portForwardingFailed(
                .localBindFailed(address: listenAddress, port: listenPort, underlying: String(describing: error))
            )
        }

        // With port 0 the OS picks, and the caller has no other way to learn
        // which one it got.
        let bound = listener.localAddress?.port ?? listenPort
        logger.debug("local forward listening", metadata: [
            "address": .string(listenAddress),
            "port": .stringConvertible(bound),
        ])
        return LocalPortForwarder(listener: listener, boundPort: bound, counters: counters, logger: logger)
    }

    /// Opens the SSH side for one accepted connection and glues the two
    /// together.
    ///
    /// Three pieces of ordering here are load-bearing:
    ///
    /// 1. The hop onto the SSH connection's event loop is required, not
    ///    tidiness: `NIOSSHHandler.createChannel` is documented as not
    ///    thread-safe, and the accepted connection is on whichever loop the
    ///    listener handed it to.
    /// 2. The SSH channel starts with `autoRead` off. NIOSSH buffers a child
    ///    channel's inbound data until a read is requested, so this holds
    ///    whatever the far side sends immediately — an SMTP banner, an SSH
    ///    version string — until there is somewhere to put it. Without it,
    ///    that data is delivered to a pipeline whose glue has no partner yet
    ///    and is dropped, which looks exactly like a server that does not
    ///    answer.
    /// 3. `beforeGluing` runs between the channel opening and the two sides
    ///    being joined. SOCKS uses it to write its success reply, which has to
    ///    precede the first byte from the far side or the client parses the
    ///    banner as part of the reply.
    private static func connect(
        accepted: Channel,
        to host: String,
        port: Int,
        sshHandler: NIOSSHHandler,
        sshEventLoop: EventLoop,
        counters: PortForwardCounters,
        logger: Logger,
        beforeGluing: (@Sendable () -> EventLoopFuture<Void>)? = nil
    ) -> EventLoopFuture<Void> {
        let (localGlue, sshGlue) = GlueHandler.matchedPair()
        // The originator address is informational — servers log it and nothing
        // routes on it — but the message has no room for its absence.
        let originatorAddress = accepted.remoteAddress ?? unspecifiedOriginator

        let created = sshEventLoop.makePromise(of: Channel.self)
        sshEventLoop.execute {
            sshHandler.createChannel(
                created,
                channelType: .directTCPIP(SSHChannelType.DirectTCPIP(
                    targetHost: host,
                    targetPort: port,
                    originatorAddress: originatorAddress
                ))
            ) { channel, _ in
                channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                    channel.pipeline.addHandlers([SSHChannelDataCodec(), sshGlue])
                }
            }
        }

        return created.futureResult
            .flatMap { sshChannel -> EventLoopFuture<Channel> in
                let hook = beforeGluing?() ?? sshChannel.eventLoop.makeSucceededVoidFuture()
                return hook.map { sshChannel }
            }
            .flatMap { sshChannel -> EventLoopFuture<Void> in
                accepted.pipeline.addHandlers([
                    ByteCountingHandler(counters: counters),
                    localGlue,
                ]).flatMap {
                    // Now that there is a partner, let the buffered data
                    // through and hand the channel back to its own read loop.
                    sshChannel.setOption(ChannelOptions.autoRead, value: true)
                }.map {
                    sshChannel.read()
                }
            }
            .flatMapError { error in
                logger.debug("local forward could not open a channel", metadata: [
                    "target": .string("\(host):\(port)"),
                    "error": .string(String(describing: error)),
                ])
                // The server refused this one connection — a closed port on the
                // far side, most often. That is the connection's problem, not
                // the tunnel's, so the listener stays up.
                accepted.close(promise: nil)
                return accepted.eventLoop.makeFailedFuture(error)
            }
    }

    func stop() async {
        try? await listener.close().get()
    }

    /// Stands in when an accepted connection has no address to report, which
    /// happens on a Unix-domain socket and on a channel torn down between the
    /// accept and this line.
    private static let unspecifiedOriginator: SocketAddress = {
        // `SocketAddress(ipAddress:port:)` throws only on an address it cannot
        // parse, and this one is a literal in the source. There is no
        // non-throwing way to build one, and no sensible thing to substitute.
        try! SocketAddress(ipAddress: "0.0.0.0", port: 0)
    }()
}
