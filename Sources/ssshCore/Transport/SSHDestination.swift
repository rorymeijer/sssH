import Foundation

/// A network endpoint an SSH connection is made to.
///
/// Deliberately free of anything app-model shaped: the `Host` SwiftData entity
/// is mapped onto this by the session layer, so the transport never sees the
/// persistence model.
public struct SSHEndpoint: Hashable, Sendable, CustomStringConvertible {
    public var hostname: String
    public var port: Int

    public init(hostname: String, port: Int = 22) {
        self.hostname = hostname
        self.port = port
    }

    public var description: String {
        port == 22 ? hostname : "\(hostname):\(port)"
    }

    /// The form OpenSSH writes into `known_hosts` for a non-default port.
    public var knownHostsKey: String {
        port == 22 ? hostname : "[\(hostname)]:\(port)"
    }
}

/// Everything needed to establish one SSH connection, including the chain of
/// bastions to tunnel through.
public struct SSHDestination: Sendable {
    public var endpoint: SSHEndpoint
    public var username: String

    /// Credentials to offer, in order. The transport tries each in turn and
    /// reports which one succeeded, mirroring OpenSSH's behaviour of walking
    /// its identity list.
    public var credentials: [SSHCredential]

    /// `ProxyJump` chain, outermost first: `jumpHosts[0]` is dialled directly,
    /// each subsequent hop is dialled through the previous one, and
    /// `endpoint` is reached through the last.
    public var jumpHosts: [SSHDestination]

    /// Environment variables to request on the session channel. Servers usually
    /// refuse anything outside their `AcceptEnv` list; failures are non-fatal.
    public var environment: [String: String]

    public var connectTimeout: Duration
    public var keepAlive: SSHKeepAlivePolicy

    public init(
        endpoint: SSHEndpoint,
        username: String,
        credentials: [SSHCredential],
        jumpHosts: [SSHDestination] = [],
        environment: [String: String] = [:],
        connectTimeout: Duration = .seconds(30),
        keepAlive: SSHKeepAlivePolicy = .default
    ) {
        self.endpoint = endpoint
        self.username = username
        self.credentials = credentials
        self.jumpHosts = jumpHosts
        self.environment = environment
        self.connectTimeout = connectTimeout
        self.keepAlive = keepAlive
    }
}

/// How aggressively to probe a connection that has gone quiet.
///
/// The probe is an SSH-level round trip, not a TCP keepalive, so it detects a
/// server that is reachable but wedged.
public struct SSHKeepAlivePolicy: Hashable, Sendable {
    /// How long the connection may be idle before a probe is sent.
    public var interval: Duration
    /// How long to wait for the reply to a single probe.
    public var timeout: Duration
    /// How many consecutive unanswered probes mean the connection is dead.
    public var missedProbesBeforeDisconnect: Int

    public init(interval: Duration, timeout: Duration, missedProbesBeforeDisconnect: Int) {
        self.interval = interval
        self.timeout = timeout
        self.missedProbesBeforeDisconnect = missedProbesBeforeDisconnect
    }

    /// Roughly OpenSSH's `ServerAliveInterval 30` / `ServerAliveCountMax 3`.
    public static let `default` = SSHKeepAlivePolicy(
        interval: .seconds(30),
        timeout: .seconds(15),
        missedProbesBeforeDisconnect: 3
    )

    public static let disabled = SSHKeepAlivePolicy(
        interval: .seconds(0),
        timeout: .seconds(0),
        missedProbesBeforeDisconnect: 0
    )

    public var isEnabled: Bool { interval > .zero && missedProbesBeforeDisconnect > 0 }
}
