import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSH
import ssshCore

/// The swift-nio-ssh backed ``SSHTransport``.
///
/// ## Why this owns the pipeline
///
/// The obvious alternative was Citadel's `SSHClient`, which builds its
/// `NIOSSHHandler` internally with `inboundChildChannelInitializer: nil` and
/// keeps the handler private. That costs three things sssh needs: inbound
/// `forwarded-tcpip` channels (so `ssh -R` becomes impossible), control over
/// `autoRead` on session channels (so terminal backpressure becomes
/// impossible), and a PTY API gated `@available(macOS 15.0, *)` while the app
/// targets macOS 14. Owning the pipeline gets all three back.
///
/// Citadel is no longer a dependency at all: its key parsing was replaced by
/// `ssshCrypto` and its RSA — SHA-1 only, which OpenSSH refuses by default —
/// by ``SSHRSA``. See docs/PHASE-0-BACKEND-DECISION.md.
public final class NIOSSHTransport: SSHTransport, @unchecked Sendable {
    /// One live SSH connection: the socket, the SSH handler, and any bastion
    /// connections stacked underneath it.
    private struct Connection {
        var channel: Channel
        var sshHandler: NIOSSHHandler
        var info: SSHConnectionInfo
        /// Outermost bastion first. Kept alive for as long as this connection
        /// is, and torn down in reverse on disconnect.
        var jumpConnections: [Connection]
    }

    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let logger: Logger
    private let sinkConfiguration: SSHShellEventSink.Configuration

    private let lock = NSLock()
    private var connection: Connection?
    private var _currentState: SSHConnectionState = .idle
    private var stateContinuations: [UUID: AsyncStream<SSHConnectionState>.Continuation] = [:]

    public init(
        group: EventLoopGroup? = nil,
        logger: Logger = Logger(label: "nl.rorymeijer.sssh.transport"),
        sinkConfiguration: SSHShellEventSink.Configuration = .default
    ) {
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            // One thread is plenty: a single SSH connection is one socket, and
            // all of the CPU-bound work (terminal parsing, rendering) happens
            // elsewhere.
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
        self.logger = logger
        self.sinkConfiguration = sinkConfiguration
    }

    deinit {
        if ownsGroup {
            // Non-blocking on purpose: `syncShutdownGracefully` deadlocks when
            // the last reference happens to be released on one of the group's
            // own threads.
            group.shutdownGracefully { _ in }
        }
    }

    // MARK: - State

    public var currentState: SSHConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return _currentState
    }

    public func stateStream() -> AsyncStream<SSHConnectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            let state = _currentState
            stateContinuations[id] = continuation
            lock.unlock()

            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.stateContinuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    private func transition(to state: SSHConnectionState) {
        lock.lock()
        _currentState = state
        let continuations = Array(stateContinuations.values)
        lock.unlock()

        for continuation in continuations {
            continuation.yield(state)
        }
    }

    // MARK: - Connecting

    @discardableResult
    public func connect(to destination: SSHDestination, hostKeyPolicy: SSHKnownHostsPolicy) async throws -> SSHConnectionInfo {
        transition(to: .connecting)

        do {
            let connection = try await establish(destination, hostKeyPolicy: hostKeyPolicy)

            lock.lock()
            let existing = self.connection
            self.connection = connection
            lock.unlock()

            // A second `connect` on the same transport replaces the first.
            if let existing {
                await tearDown(existing)
            }

            observeUnexpectedClosure(of: connection)
            transition(to: .connected(connection.info))
            return connection.info
        } catch {
            transition(to: .disconnected(.failed(Self.describe(error))))
            throw error
        }
    }

    /// Dials one destination, first establishing any bastions it needs.
    ///
    /// - Parameter bastion: an already-established connection to tunnel
    ///   through, owned by the caller. Hops this call establishes itself are
    ///   returned inside the resulting `Connection` and torn down with it.
    private func establish(
        _ destination: SSHDestination,
        hostKeyPolicy: SSHKnownHostsPolicy,
        through bastion: Connection? = nil
    ) async throws -> Connection {
        // `ProxyJump a,b` means: reach `a` directly, reach `b` through `a`,
        // reach the destination through `b`. So each hop is dialled through the
        // one before it, not independently — and a hop may itself declare
        // further jumps, which the recursion handles.
        var chain: [Connection] = []
        var nearest = bastion

        for hop in destination.jumpHosts {
            do {
                let hopConnection = try await establish(hop, hostKeyPolicy: hostKeyPolicy, through: nearest)
                chain.append(hopConnection)
                nearest = hopConnection
            } catch {
                await tearDown(chain)
                throw error
            }
        }

        // A fresh delegate per attempt: it consumes its credential list as it
        // offers them, so a reused instance has nothing left to offer on a
        // reconnect. (Citadel's own reconnect logic has exactly this bug — see
        // docs/PHASE-0-BACKEND-DECISION.md.)
        let authenticationDelegate = CredentialAuthenticationDelegate(
            username: destination.username,
            credentials: destination.credentials
        )
        let hostKeyBridge = HostKeyBridge(endpoint: destination.endpoint, policy: hostKeyPolicy)

        var configuration = SSHClientConfiguration(
            userAuthDelegate: authenticationDelegate,
            serverAuthDelegate: hostKeyBridge
        )
        AlgorithmRegistration.apply(to: &configuration)

        transition(to: .authenticating)

        do {
            let (channel, sshHandler) = try await openSSHChannel(
                to: destination,
                through: nearest,
                configuration: configuration,
                authenticationDelegate: authenticationDelegate
            )

            guard let hostKey = hostKeyBridge.presentedKey else {
                // Cannot happen: key exchange completes before user auth. If it
                // ever did, refusing is the safe direction.
                throw SSHTransportError.channelRequestFailed("the handshake completed without a host key")
            }

            let info = SSHConnectionInfo(
                endpoint: destination.endpoint,
                username: destination.username,
                hostKey: hostKey,
                authenticatedWith: authenticationDelegate.authenticatedWith
            )

            logger.info("connected", metadata: [
                "endpoint": .string(destination.endpoint.description),
                "user": .string(destination.username),
                "auth": .string(info.authenticatedWith),
                "hostKey": .string(hostKey.displayFingerprint),
                "hops": .stringConvertible(chain.count),
            ])

            return Connection(channel: channel, sshHandler: sshHandler, info: info, jumpConnections: chain)
        } catch {
            await tearDown(chain)
            throw error
        }
    }

    /// Brings up one SSH connection, either on a fresh socket or inside a
    /// bastion's `direct-tcpip` channel.
    ///
    /// Both handlers are built here and installed by the channel initialiser,
    /// before any byte can be read. Two reasons, and both are bugs if ignored:
    /// adding `NIOSSHHandler` to a channel that is already reading loses the
    /// server's version string to the tail of the pipeline and hangs the
    /// handshake; and holding the instances directly avoids a
    /// pipeline lookup that fails if the server has already
    /// dropped the connection — which is exactly what a refused login looks
    /// like.
    private func openSSHChannel(
        to destination: SSHDestination,
        through bastion: Connection?,
        configuration: SSHClientConfiguration,
        authenticationDelegate: CredentialAuthenticationDelegate
    ) async throws -> (Channel, NIOSSHHandler) {
        // With `group: eventLoop` on the bootstrap, and a bastion's child
        // channel sharing its parent's loop, this is the loop the channel will
        // run on — so the handshake promise is created on the right one.
        let eventLoop = bastion?.channel.eventLoop ?? group.next()

        let sshHandler = NIOSSHHandler(
            role: .client(configuration),
            allocator: ByteBufferAllocator(),
            // Phase 5: an initializer here is what makes `ssh -R` possible,
            // because remote forwarding arrives as inbound `forwarded-tcpip`
            // channels. Nil means "refuse them", which is correct until there
            // is something to hand them to.
            inboundChildChannelInitializer: nil
        )
        let handshake = HandshakeHandler(eventLoop: eventLoop, authenticationDelegate: authenticationDelegate)

        let channel: Channel
        if let bastion {
            channel = try await openTunnelChannel(
                through: bastion,
                to: destination.endpoint,
                sshHandler: sshHandler,
                handshake: handshake
            )
        } else {
            channel = try await openSocketChannel(
                to: destination,
                on: eventLoop,
                sshHandler: sshHandler,
                handshake: handshake
            )
        }

        do {
            try await withTimeout(destination.connectTimeout, operation: "authentication") {
                try await handshake.authenticated.get()
            }
        } catch {
            try? await channel.close().get()
            throw error
        }

        return (channel, sshHandler)
    }

    private func openSocketChannel(
        to destination: SSHDestination,
        on eventLoop: EventLoop,
        sshHandler: NIOSSHHandler,
        handshake: HandshakeHandler
    ) async throws -> Channel {
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(.nanoseconds(destination.connectTimeout.nanosecondsClamped))
            // Interactive typing is latency-sensitive and the packets are tiny;
            // Nagle would batch keystrokes into visible lag.
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            // A belt to the SSH keep-alive's braces: this catches a peer that
            // has gone away without a FIN, such as a NAT dropping the flow.
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([sshHandler, handshake])
            }

        do {
            return try await bootstrap.connect(
                host: destination.endpoint.hostname,
                port: destination.endpoint.port
            ).get()
        } catch {
            throw SSHTransportError.unreachable(destination.endpoint, underlying: Self.describe(error))
        }
    }

    /// `ProxyJump`: a `direct-tcpip` channel on the bastion carrying a whole
    /// second SSH connection.
    private func openTunnelChannel(
        through bastion: Connection,
        to endpoint: SSHEndpoint,
        sshHandler: NIOSSHHandler,
        handshake: HandshakeHandler
    ) async throws -> Channel {
        let eventLoop = bastion.channel.eventLoop
        let bastionHandler = bastion.sshHandler

        let settings = SSHChannelType.DirectTCPIP(
            targetHost: endpoint.hostname,
            targetPort: endpoint.port,
            // Informational only; OpenSSH sends its own loopback address here.
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        )

        return try await eventLoop.flatSubmit {
            let created = eventLoop.makePromise(of: Channel.self)

            bastionHandler.createChannel(created, channelType: .directTCPIP(settings)) { channel, type in
                guard case .directTCPIP = type else {
                    return channel.eventLoop.makeFailedFuture(
                        SSHTransportError.channelRequestFailed("the bastion opened the wrong channel type")
                    )
                }
                return channel.pipeline.addHandlers([
                    // Unwraps the channel's framing so the nested
                    // NIOSSHHandler sees an ordinary byte stream.
                    SSHChannelDataCodec(),
                    sshHandler,
                    handshake,
                ])
            }

            return created.futureResult
        }.get()
    }

    /// Notices a connection dropping when nobody asked it to, so the session
    /// layer can decide whether to reconnect.
    private func observeUnexpectedClosure(of connection: Connection) {
        connection.channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }

            self.lock.lock()
            let isCurrent = self.connection?.channel === connection.channel
            if isCurrent { self.connection = nil }
            let state = self._currentState
            self.lock.unlock()

            guard isCurrent else { return }
            // A disconnect we initiated has already published its reason.
            if case .disconnected = state { return }

            self.transition(to: .disconnected(.remoteClosed))
        }
    }

    // MARK: - Channels

    public func openShell(_ configuration: SSHShellConfiguration) async throws -> any SSHShellSession {
        let connection = try requireConnection()
        return try await NIOSSHShellSession.open(
            on: connection.sshHandler,
            eventLoop: connection.channel.eventLoop,
            mode: .interactiveShell(configuration),
            channelOpenTimeout: .seconds(15),
            sinkConfiguration: sinkConfiguration,
            logger: logger
        )
    }

    public func execute(_ command: String, environment: [String: String] = [:]) async throws -> any SSHShellSession {
        let connection = try requireConnection()
        return try await NIOSSHShellSession.open(
            on: connection.sshHandler,
            eventLoop: connection.channel.eventLoop,
            mode: .command(command, environment: environment),
            channelOpenTimeout: .seconds(15),
            sinkConfiguration: sinkConfiguration,
            logger: logger
        )
    }

    public func openSFTP() async throws -> any SFTPService {
        // Phase 4.
        throw SSHTransportError.unsupported(.sftp)
    }

    public func portForwarding() async throws -> any PortForwardService {
        // Phase 5.
        throw SSHTransportError.unsupported(.localPortForwarding)
    }

    // MARK: - Keep-alive

    /// Sends one SSH-level probe and waits for the server's answer.
    ///
    /// OpenSSH uses a `keepalive@openssh.com` global request for this;
    /// swift-nio-ssh exposes no way to send an arbitrary global request, so we
    /// use the one it does expose: cancelling a TCP forward we never
    /// established. The server answers `REQUEST_FAILURE`, which is a complete
    /// round trip through key exchange, encryption and the server's main loop
    /// — exactly what we need to prove — and has no side effect. *Any* answer
    /// counts as alive; only silence counts as dead.
    public func sendKeepAliveProbe(timeout: Duration) async throws {
        let connection = try requireConnection()
        let eventLoop = connection.channel.eventLoop
        let sshHandler = connection.sshHandler

        let reply: EventLoopFuture<GlobalRequest.TCPForwardingResponse?> = try await eventLoop.submit {
            let promise = eventLoop.makePromise(of: Optional<GlobalRequest.TCPForwardingResponse>.self)
            sshHandler.sendTCPForwardingRequest(.cancel(host: "127.0.0.1", port: 0), promise: promise)
            return promise.futureResult
        }.get()

        do {
            try await withTimeout(timeout, operation: "keep-alive") {
                _ = try? await reply.get()
            }
        } catch {
            throw SSHTransportError.connectionLost(.keepAliveTimeout)
        }
    }

    // MARK: - Disconnecting

    public func disconnect() async {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        lock.unlock()

        transition(to: .disconnected(.userInitiated))

        if let connection {
            await tearDown(connection)
        }
    }

    private func tearDown(_ connection: Connection) async {
        try? await connection.channel.close().get()
        // Innermost first: closing a bastion out from under a tunnel it carries
        // produces spurious errors on the way down.
        await tearDown(connection.jumpConnections)
    }

    /// Tears down a bastion chain, innermost hop first.
    private func tearDown(_ chain: [Connection]) async {
        for connection in chain.reversed() {
            await tearDown(connection)
        }
    }

    private func requireConnection() throws -> Connection {
        lock.lock()
        defer { lock.unlock() }
        guard let connection, connection.channel.isActive else {
            throw SSHTransportError.notConnected
        }
        return connection
    }

    private static func describe(_ error: Error) -> String {
        if let transportError = error as? SSHTransportError {
            return String(describing: transportError)
        }
        return String(describing: error)
    }
}

/// Converts between an SSH channel's framed data and a plain byte stream, so a
/// nested SSH connection can run inside a `direct-tcpip` channel.
private final class SSHChannelDataCodec: ChannelDuplexHandler {
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

/// Races `operation` against a deadline.
///
/// `Task.sleep` is cancelled as soon as the operation wins, so this leaves no
/// timer behind — which matters when it is used on every keep-alive probe.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation name: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw SSHTransportError.timedOut(operation: name, after: duration)
        }

        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw SSHTransportError.timedOut(operation: name, after: duration)
        }
        return result
    }
}
