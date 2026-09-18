import Foundation
import Logging
import NIOCore
import NIOSSH
import ssshCore

/// The three kinds of tunnel, on one SSH connection.
///
/// A thin front for the three forwarders. It exists so the app never holds a
/// `Channel`, an `EventLoop` or a `NIOSSHHandler`, which is the same rule that
/// keeps every other backend detail out of `ssshCore`.
final class NIOPortForwardService: PortForwardService, @unchecked Sendable {
    private let sshHandler: NIOSSHHandler
    private let sshEventLoop: EventLoop
    private let group: EventLoopGroup
    private let registry: RemoteForwardRegistry
    private let logger: Logger

    init(
        sshHandler: NIOSSHHandler,
        sshEventLoop: EventLoop,
        group: EventLoopGroup,
        registry: RemoteForwardRegistry,
        logger: Logger
    ) {
        self.sshHandler = sshHandler
        self.sshEventLoop = sshEventLoop
        self.group = group
        self.registry = registry
        self.logger = logger
    }

    func startLocalForward(_ forward: LocalPortForward) async throws -> any ActivePortForward {
        try await LocalPortForwarder.start(
            listenAddress: forward.listenAddress,
            listenPort: forward.listenPort,
            destination: .fixed(host: forward.remoteHost, port: forward.remotePort),
            sshHandler: sshHandler,
            sshEventLoop: sshEventLoop,
            group: group,
            logger: logger
        )
    }

    func startDynamicForward(_ forward: DynamicPortForward) async throws -> any ActivePortForward {
        try await LocalPortForwarder.start(
            listenAddress: forward.listenAddress,
            listenPort: forward.listenPort,
            destination: .socks,
            sshHandler: sshHandler,
            sshEventLoop: sshEventLoop,
            group: group,
            logger: logger
        )
    }

    func startRemoteForward(_ forward: RemotePortForward) async throws -> any ActivePortForward {
        try await RemotePortForwarder.start(
            forward,
            registry: registry,
            sshHandler: sshHandler,
            sshEventLoop: sshEventLoop,
            logger: logger
        )
    }
}
