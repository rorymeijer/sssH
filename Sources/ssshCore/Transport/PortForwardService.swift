import Foundation

/// Local, remote and dynamic port forwarding.
///
/// Declared in Phase 0 so the tunnel model (Phase 5) has a stable seam. All
/// three are reachable: the transport owns its `NIOSSHHandler`, so inbound
/// `forwarded-tcpip` channels — which `-R` is built on — are available.
public protocol PortForwardService: AnyObject, Sendable {
    /// `ssh -L`: listen locally, forward each accepted connection to
    /// `remote` as seen from the SSH server.
    func startLocalForward(_ forward: LocalPortForward) async throws -> any ActivePortForward

    /// `ssh -R`: ask the server to listen and forward connections back to us.
    func startRemoteForward(_ forward: RemotePortForward) async throws -> any ActivePortForward

    /// `ssh -D`: a local SOCKS5 proxy whose connections are opened by the
    /// SSH server.
    func startDynamicForward(_ forward: DynamicPortForward) async throws -> any ActivePortForward
}

public struct LocalPortForward: Hashable, Sendable {
    /// Which local interface to bind. `127.0.0.1` unless the user asks for
    /// more, because binding `0.0.0.0` exposes the tunnel to the network.
    public var listenAddress: String
    /// `0` asks the OS to pick, reported back as `ActivePortForward.boundPort`.
    public var listenPort: Int
    public var remoteHost: String
    public var remotePort: Int

    public init(listenAddress: String = "127.0.0.1", listenPort: Int, remoteHost: String, remotePort: Int) {
        self.listenAddress = listenAddress
        self.listenPort = listenPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
}

public struct RemotePortForward: Hashable, Sendable {
    /// Address the *server* binds. Empty string means all interfaces, which
    /// most servers refuse unless `GatewayPorts` allows it.
    public var remoteBindAddress: String
    public var remoteBindPort: Int
    public var localHost: String
    public var localPort: Int

    public init(remoteBindAddress: String = "127.0.0.1", remoteBindPort: Int, localHost: String, localPort: Int) {
        self.remoteBindAddress = remoteBindAddress
        self.remoteBindPort = remoteBindPort
        self.localHost = localHost
        self.localPort = localPort
    }
}

public struct DynamicPortForward: Hashable, Sendable {
    public var listenAddress: String
    public var listenPort: Int

    public init(listenAddress: String = "127.0.0.1", listenPort: Int) {
        self.listenAddress = listenAddress
        self.listenPort = listenPort
    }
}

public protocol ActivePortForward: AnyObject, Sendable {
    /// The port actually bound, which differs from the requested one when `0`
    /// was asked for.
    var boundPort: Int { get }
    var statistics: PortForwardStatistics { get }
    func stop() async
}

public struct PortForwardStatistics: Hashable, Sendable {
    public var activeConnections: Int
    public var totalConnections: Int
    public var bytesSent: UInt64
    public var bytesReceived: UInt64

    public init(activeConnections: Int = 0, totalConnections: Int = 0, bytesSent: UInt64 = 0, bytesReceived: UInt64 = 0) {
        self.activeConnections = activeConnections
        self.totalConnections = totalConnections
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
    }
}
