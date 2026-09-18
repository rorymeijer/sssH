import Foundation

/// The seam that keeps the SSH backend replaceable.
///
/// Everything above this protocol — the session manager, the terminal hosts,
/// the file browser, the tunnel UI — is written against `SSHTransport` and the
/// sibling `SFTPService` / `PortForwardService` protocols, and must not import
/// the backend module. Swapping Citadel for libssh2 or a wrapped system `ssh`
/// then means adding one module and changing one factory.
///
/// Implementations are reference types with internal synchronisation: a
/// transport is shared between the UI, a keep-alive task, and the reconnect
/// supervisor.
public protocol SSHTransport: AnyObject, Sendable {
    var currentState: SSHConnectionState { get }

    /// Observes connection state. Single consumer; the session layer owns it
    /// and republishes to the UI.
    func stateStream() -> AsyncStream<SSHConnectionState>

    /// Performs the TCP connect, version exchange, key exchange (validating
    /// the host key through `hostKeyPolicy`) and user authentication.
    ///
    /// Fails closed: a rejected host key aborts before authentication, so no
    /// credential is ever offered to an unverified server.
    @discardableResult
    func connect(to destination: SSHDestination, hostKeyPolicy: SSHKnownHostsPolicy) async throws -> SSHConnectionInfo

    /// Opens an interactive shell on a new channel: `pty-req` followed by
    /// `shell`. Several shells may share one connection — that is what tabs
    /// and split panes against the same host use.
    func openShell(_ configuration: SSHShellConfiguration) async throws -> any SSHShellSession

    /// Runs a single command with no PTY, streaming stdout and stderr
    /// separately.
    func execute(_ command: String, environment: [String: String]) async throws -> any SSHShellSession

    /// An SFTP subsystem channel on this connection.
    func openSFTP() async throws -> any SFTPService

    /// Port-forwarding operations on this connection.
    func portForwarding() async throws -> any PortForwardService

    /// Sends one keep-alive probe and waits for the server's reply.
    ///
    /// Exposed rather than hidden inside the backend so that the reconnect
    /// supervisor can decide the policy, and so tests can drive liveness
    /// detection without waiting on a timer.
    func sendKeepAliveProbe(timeout: Duration) async throws

    func disconnect() async
}

/// Constructs transports. Injected so the app has exactly one place that names
/// a concrete backend.
public protocol SSHTransportFactory: Sendable {
    func makeTransport() -> any SSHTransport
}

public enum SSHConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case authenticating
    case connected(SSHConnectionInfo)
    /// Waiting to retry after an unexpected drop. `attempt` is 1-based.
    case reconnecting(attempt: Int, nextAttemptIn: Duration)
    case disconnected(SSHDisconnectReason)
}

public struct SSHConnectionInfo: Sendable, Equatable {
    public var endpoint: SSHEndpoint
    public var username: String
    /// The host key the server actually presented and we accepted.
    public var hostKey: SSHHostKey
    /// Diagnostic name of the credential that succeeded (never the secret).
    public var authenticatedWith: String
    public var connectedAt: Date

    public init(
        endpoint: SSHEndpoint,
        username: String,
        hostKey: SSHHostKey,
        authenticatedWith: String,
        connectedAt: Date = Date()
    ) {
        self.endpoint = endpoint
        self.username = username
        self.hostKey = hostKey
        self.authenticatedWith = authenticatedWith
        self.connectedAt = connectedAt
    }
}

public enum SSHDisconnectReason: Sendable, Equatable {
    /// The user closed the session.
    case userInitiated
    /// The remote shell exited and nothing else is using the connection.
    case remoteClosed
    /// Keep-alive probes went unanswered.
    case keepAliveTimeout
    /// The connection failed and the reason is worth showing.
    case failed(String)

    public var isUnexpected: Bool {
        switch self {
        case .userInitiated, .remoteClosed: return false
        case .keepAliveTimeout, .failed: return true
        }
    }
}

/// One interactive channel: a PTY-backed shell, or an `exec`'d command.
public protocol SSHShellSession: AnyObject, Sendable {
    /// Output, exit status and failures. Iterate exactly once.
    var events: SSHShellEventStream { get }

    /// The current PTY size as last requested, or `nil` for a channel with no PTY.
    var terminalSize: TerminalSize? { get }

    /// Writes to the remote stdin. Control bytes (0x03 for Ctrl-C, 0x04 for
    /// Ctrl-D) go through here: with a PTY it is the remote line discipline,
    /// not SSH, that turns them into signals.
    func write(_ bytes: ArraySlice<UInt8>) async throws

    /// Sends `window-change`. Cheap and reply-less, so it is safe to call on
    /// every layout pass, but the caller should still coalesce.
    func resize(to size: TerminalSize) async throws

    /// Sends an SSH `signal` channel request.
    func send(signal: SSHSignal) async throws

    /// Half-closes stdin without tearing the channel down.
    func sendEOF() async throws

    func close() async
}
