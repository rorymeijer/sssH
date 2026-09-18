import Foundation
@testable import ssshCore

/// A transport double.
///
/// It exists partly to test ``KeepAliveMonitor`` without a network, and partly
/// as a check on the protocol itself: if ``SSHTransport`` were hard to
/// implement without a socket, the layering would be wrong.
final class FakeTransport: SSHTransport, @unchecked Sendable {
    enum ProbeBehaviour: Sendable {
        case succeed
        case fail
        /// Fail the first `count` probes, then succeed.
        case failThenSucceed(count: Int)
    }

    private let lock = NSLock()
    private var _currentState: SSHConnectionState
    private var behaviour: ProbeBehaviour
    private var probeCount = 0

    enum ConnectBehaviour: Sendable {
        case succeed
        case fail
        case hostKeyRejected
    }

    private var connectBehaviour: ConnectBehaviour
    private var _connectAttempts = 0

    init(
        state: SSHConnectionState = .connected(.fake),
        probeBehaviour: ProbeBehaviour = .succeed,
        connectBehaviour: ConnectBehaviour = .succeed
    ) {
        self._currentState = state
        self.behaviour = probeBehaviour
        self.connectBehaviour = connectBehaviour
    }

    var connectAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return _connectAttempts
    }

    var currentState: SSHConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return _currentState
    }

    var probesSent: Int {
        lock.lock()
        defer { lock.unlock() }
        return probeCount
    }

    func set(state: SSHConnectionState) {
        lock.lock()
        _currentState = state
        lock.unlock()
    }

    func stateStream() -> AsyncStream<SSHConnectionState> {
        AsyncStream { $0.finish() }
    }

    @discardableResult
    func connect(to destination: SSHDestination, hostKeyPolicy: SSHKnownHostsPolicy) async throws -> SSHConnectionInfo {
        lock.lock()
        _connectAttempts += 1
        let behaviour = connectBehaviour
        lock.unlock()

        switch behaviour {
        case .succeed:
            set(state: .connected(.fake))
            return .fake
        case .fail:
            throw SSHTransportError.unreachable(destination.endpoint, underlying: "fake")
        case .hostKeyRejected:
            throw SSHTransportError.hostKeyRejected(
                destination.endpoint,
                presented: SSHHostKey(algorithm: "ssh-ed25519", wireFormat: [1])
            )
        }
    }

    func openShell(_ configuration: SSHShellConfiguration) async throws -> any SSHShellSession {
        throw SSHTransportError.unsupported(.sftp)
    }

    func execute(_ command: String, environment: [String: String]) async throws -> any SSHShellSession {
        throw SSHTransportError.unsupported(.sftp)
    }

    func openSFTP() async throws -> any SFTPService {
        throw SSHTransportError.unsupported(.sftp)
    }

    func portForwarding() async throws -> any PortForwardService {
        throw SSHTransportError.unsupported(.localPortForwarding)
    }

    func sendKeepAliveProbe(timeout: Duration) async throws {
        lock.lock()
        probeCount += 1
        let count = probeCount
        let behaviour = self.behaviour
        lock.unlock()

        switch behaviour {
        case .succeed:
            return
        case .fail:
            throw SSHTransportError.connectionLost(.keepAliveTimeout)
        case .failThenSucceed(let failures):
            if count <= failures {
                throw SSHTransportError.connectionLost(.keepAliveTimeout)
            }
        }
    }

    func disconnect() async {
        set(state: .disconnected(.userInitiated))
    }
}

extension SSHConnectionInfo {
    static let fake = SSHConnectionInfo(
        endpoint: SSHEndpoint(hostname: "fake.test"),
        username: "tester",
        hostKey: SSHHostKey(algorithm: "ssh-ed25519", wireFormat: [0], sha256Fingerprint: "SHA256:fake"),
        authenticatedWith: "password",
        connectedAt: Date(timeIntervalSince1970: 0)
    )
}
