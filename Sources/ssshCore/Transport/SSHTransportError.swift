import Foundation

/// Failures the transport reports, in terms the UI can act on.
///
/// Every case carries enough to write a useful message without the UI having
/// to pattern-match on a backend's error strings. The messages themselves are
/// produced by the app's String Catalog, so nothing user-facing is hardcoded
/// here.
public enum SSHTransportError: Error, Sendable {
    /// TCP connect failed or timed out.
    case unreachable(SSHEndpoint, underlying: String?)

    /// The host key was refused — by the user, or by policy on mismatch.
    /// The connection is torn down before authentication.
    case hostKeyRejected(SSHEndpoint, presented: SSHHostKey)

    /// Every credential we offered was refused. `acceptedMethods` is what the
    /// server said it would take, which is the difference between "wrong
    /// password" and "this server wants 2FA and we cannot do that".
    case authenticationFailed(triedCredentials: [String], acceptedMethods: [String])

    /// The credential itself could not be used: an unparsable key file, a wrong
    /// passphrase, or a key type this backend cannot read.
    case credentialUnusable(credential: String, reason: CredentialProblem)

    /// The backend cannot do what was asked. Distinct from a runtime failure:
    /// this is a known gap, and the UI should say so rather than offer a retry.
    case unsupported(Capability)

    /// The channel or connection went away mid-operation.
    case connectionLost(SSHDisconnectReason)

    /// Used before `connect` succeeded, or after `disconnect`.
    case notConnected

    /// The server refused to open a channel or honour a request.
    case channelRequestFailed(String)

    case timedOut(operation: String, after: Duration)

    /// A tunnel could not be set up. Separate from `channelRequestFailed`
    /// because the three ways it goes wrong lead to three different things for
    /// the user to do, and a message cannot be branched on.
    case portForwardingFailed(PortForwardProblem)

    public enum PortForwardProblem: Sendable, Equatable {
        /// The local listener could not bind. Almost always the port being in
        /// use, or being below 1024 without the privileges to take it.
        case localBindFailed(address: String, port: Int, underlying: String?)
        /// The server refused to listen on our behalf. Usually its
        /// `GatewayPorts` setting, or the port already being taken there.
        case serverRefusedListen(address: String, port: Int)
        /// A connection arrived through a remote forward and the local
        /// destination would not take it.
        case localTargetUnreachable(host: String, port: Int, underlying: String?)
    }

    public enum CredentialProblem: Sendable, Equatable {
        case malformedKey
        case wrongPassphrase
        case passphraseRequired
        case unsupportedKeyType(String)
    }

    /// Things a backend may or may not be able to do. Named so the UI can
    /// explain the gap; see docs/PHASE-0-BACKEND-DECISION.md for the current
    /// answers.
    public enum Capability: String, Sendable, CaseIterable {
        case keyboardInteractiveAuthentication
        case agentForwarding
        case sftp
        case localPortForwarding
        case remotePortForwarding
        case dynamicPortForwarding
        case tmuxControlMode
        case rsaPrivateKeyFiles
        case ecdsaPrivateKeyFiles
        /// The server offers only `diffie-hellman-group14-*` or `aes128-ctr`,
        /// which sssh does not implement. See `AlgorithmRegistration`.
        case legacyKeyExchange
    }
}
