import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSH
import ssshCore

/// Which remote forwards are live, and where each one goes locally.
///
/// It has to exist before the `NIOSSHHandler` does, because the handler's
/// inbound-channel initializer is where a `forwarded-tcpip` channel is matched
/// to a destination, and that closure is fixed at construction. Nothing else
/// in the connection is built this way; remote forwarding is the one feature
/// that needs a hook in place before anyone has asked for it.
final class RemoteForwardRegistry: @unchecked Sendable {
    struct Entry {
        var localHost: String
        var localPort: Int
        var counters: PortForwardCounters
    }

    private struct Key: Hashable {
        var host: String
        var port: Int
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    func register(bindAddress: String, boundPort: Int, localHost: String, localPort: Int, counters: PortForwardCounters) {
        lock.lock()
        entries[Key(host: bindAddress, port: boundPort)] = Entry(localHost: localHost, localPort: localPort, counters: counters)
        lock.unlock()
    }

    func unregister(bindAddress: String, boundPort: Int) {
        lock.lock()
        entries[Key(host: bindAddress, port: boundPort)] = nil
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    /// Finds the destination for an inbound `forwarded-tcpip` channel.
    ///
    /// Servers do not agree on what to put in `listeningHost`. OpenSSH echoes
    /// back what was asked for, so `""` stays `""` and `localhost` stays
    /// `localhost`; others normalise it to an address. Matching on the exact
    /// pair and then falling back to the port alone — but only when one
    /// forward owns that port — accepts the connection without ever sending it
    /// somewhere it was not meant to go.
    func destination(listeningHost: String, listeningPort: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }

        if let exact = entries[Key(host: listeningHost, port: listeningPort)] {
            return exact
        }
        let samePort = entries.filter { $0.key.port == listeningPort }
        guard samePort.count == 1 else { return nil }
        return samePort.first?.value
    }
}

/// Handles one inbound `forwarded-tcpip` channel.
enum RemoteForwardInbound {
    /// The `inboundChildChannelInitializer` for a connection.
    ///
    /// Returning a failed future is how a channel is refused, and refusing is
    /// the right answer for anything unexpected: a server that opens channels
    /// a client did not ask for is either broken or hostile, and there is
    /// nothing useful to do with one.
    static func makeInitializer(
        registry: RemoteForwardRegistry,
        group: EventLoopGroup,
        logger: Logger
    ) -> @Sendable (Channel, SSHChannelType) -> EventLoopFuture<Void> {
        { channel, channelType in
            guard case .forwardedTCPIP(let info) = channelType else {
                logger.debug("refusing an unexpected inbound channel")
                return channel.eventLoop.makeFailedFuture(SSHChannelError.inappropriateChannelType)
            }
            guard let entry = registry.destination(listeningHost: info.listeningHost, listeningPort: info.listeningPort) else {
                logger.debug("refusing a forwarded connection with no matching tunnel", metadata: [
                    "listening": .string("\(info.listeningHost):\(info.listeningPort)"),
                ])
                return channel.eventLoop.makeFailedFuture(SSHChannelError.inappropriateChannelType)
            }

            return open(channel: channel, to: entry, group: group, logger: logger)
        }
    }

    private static func open(
        channel: Channel,
        to entry: RemoteForwardRegistry.Entry,
        group: EventLoopGroup,
        logger: Logger
    ) -> EventLoopFuture<Void> {
        let (localGlue, sshGlue) = GlueHandler.matchedPair()

        // Same reasoning as the local forwarder: NIOSSH buffers a child
        // channel's inbound data until a read is asked for, so holding reads
        // off keeps whatever the remote client sends immediately until there
        // is a local socket to put it in.
        return channel.setOption(ChannelOptions.autoRead, value: false)
            .flatMap { channel.pipeline.addHandlers([SSHChannelDataCodec(), sshGlue]) }
            .flatMap {
                ClientBootstrap(group: group)
                    .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .channelInitializer { local in
                        local.pipeline.addHandlers([
                            ByteCountingHandler(counters: entry.counters),
                            localGlue,
                        ])
                    }
                    .connect(host: entry.localHost, port: entry.localPort)
            }
            .flatMap { _ in
                channel.setOption(ChannelOptions.autoRead, value: true)
            }
            .map {
                channel.read()
            }
            .flatMapError { error in
                logger.debug("a forwarded connection could not reach its local target", metadata: [
                    "target": .string("\(entry.localHost):\(entry.localPort)"),
                    "error": .string(String(describing: error)),
                ])
                // Refusing the channel is the honest answer, and it is what
                // the remote client needs in order to see a refused connection
                // rather than a hanging one.
                return channel.eventLoop.makeFailedFuture(
                    SSHTransportError.portForwardingFailed(
                        .localTargetUnreachable(
                            host: entry.localHost,
                            port: entry.localPort,
                            underlying: String(describing: error)
                        )
                    )
                )
            }
    }
}

/// `ssh -R`: the server listens, and connections arrive here.
final class RemotePortForwarder: ActivePortForward, @unchecked Sendable {
    let boundPort: Int
    var statistics: PortForwardStatistics { counters.snapshot }

    private let bindAddress: String
    private let registry: RemoteForwardRegistry
    private let counters: PortForwardCounters
    private let sshHandler: NIOSSHHandler
    private let sshEventLoop: EventLoop
    private let logger: Logger

    private init(
        bindAddress: String,
        boundPort: Int,
        registry: RemoteForwardRegistry,
        counters: PortForwardCounters,
        sshHandler: NIOSSHHandler,
        sshEventLoop: EventLoop,
        logger: Logger
    ) {
        self.bindAddress = bindAddress
        self.boundPort = boundPort
        self.registry = registry
        self.counters = counters
        self.sshHandler = sshHandler
        self.sshEventLoop = sshEventLoop
        self.logger = logger
    }

    static func start(
        _ forward: RemotePortForward,
        registry: RemoteForwardRegistry,
        sshHandler: NIOSSHHandler,
        sshEventLoop: EventLoop,
        logger: Logger
    ) async throws -> RemotePortForwarder {
        let response: GlobalRequest.TCPForwardingResponse?
        do {
            let promise = sshEventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            sshEventLoop.execute {
                sshHandler.sendTCPForwardingRequest(
                    .listen(host: forward.remoteBindAddress, port: forward.remoteBindPort),
                    promise: promise
                )
            }
            response = try await promise.futureResult.get()
        } catch {
            // A refusal here is nearly always the server's `GatewayPorts`
            // setting or the port already being taken there — both of which
            // the user can do something about, so they are worth separating
            // from a generic channel failure.
            throw SSHTransportError.portForwardingFailed(
                .serverRefusedListen(address: forward.remoteBindAddress, port: forward.remoteBindPort)
            )
        }

        // The bound port only comes back when 0 was asked for. Otherwise the
        // server is listening on exactly what was requested.
        let boundPort = response?.boundPort ?? forward.remoteBindPort
        let counters = PortForwardCounters()
        registry.register(
            bindAddress: forward.remoteBindAddress,
            boundPort: boundPort,
            localHost: forward.localHost,
            localPort: forward.localPort,
            counters: counters
        )

        logger.debug("remote forward listening", metadata: [
            "address": .string(forward.remoteBindAddress),
            "port": .stringConvertible(boundPort),
        ])

        return RemotePortForwarder(
            bindAddress: forward.remoteBindAddress,
            boundPort: boundPort,
            registry: registry,
            counters: counters,
            sshHandler: sshHandler,
            sshEventLoop: sshEventLoop,
            logger: logger
        )
    }

    func stop() async {
        // Unregister first. Between the cancel request and the server acting
        // on it, a connection can still arrive, and it should be refused
        // rather than forwarded to a tunnel the user has closed.
        registry.unregister(bindAddress: bindAddress, boundPort: boundPort)

        let promise = sshEventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        sshEventLoop.execute {
            self.sshHandler.sendTCPForwardingRequest(
                .cancel(host: self.bindAddress, port: self.boundPort),
                promise: promise
            )
        }
        // A server that does not answer the cancel has usually gone away, and
        // there is nothing further to do about it either way.
        _ = try? await promise.futureResult.get()
    }
}
