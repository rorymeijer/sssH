import Crypto
import Foundation
import NIOCore
import NIOSSH
import ssshCore

extension SSHHostKey {
    /// Converts a key as presented by NIOSSH into the transport-agnostic form.
    ///
    /// `wireFormat` is the `<algorithm><key blob>` encoding — byte-identical to
    /// what OpenSSH base64-encodes into `known_hosts`, so entries written by
    /// this app and by `ssh` are interchangeable.
    init(_ key: NIOSSHPublicKey) {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        let bytes = Array(buffer.readableBytesView)

        self.init(
            algorithm: Self.algorithmName(fromWireFormat: bytes) ?? "unknown",
            wireFormat: bytes,
            sha256Fingerprint: Self.fingerprint(ofWireFormat: bytes)
        )
    }

    /// OpenSSH's display form: `SHA256:` plus unpadded base64 of the digest.
    static func fingerprint(ofWireFormat bytes: [UInt8]) -> String {
        let digest = SHA256.hash(data: bytes)
        var base64 = Data(digest).base64EncodedString()
        while base64.hasSuffix("=") { base64.removeLast() }
        return "SHA256:" + base64
    }

    /// The leading SSH string of a host-key blob is its algorithm name.
    static func algorithmName(fromWireFormat bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        let length = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        guard length > 0, length <= 64, bytes.count >= 4 + Int(length) else { return nil }
        return String(decoding: bytes[4..<(4 + Int(length))], as: UTF8.self)
    }

    /// Parses one `known_hosts`-style key body (`<algorithm> <base64>`), as
    /// used by `~/.ssh/known_hosts` import in Phase 6.
    public static func parse(authorizedKeyRepresentation line: String) -> SSHHostKey? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let bytes = Array(blob)
        guard algorithmName(fromWireFormat: bytes) == String(fields[0]) else { return nil }
        return SSHHostKey(
            algorithm: String(fields[0]),
            wireFormat: bytes,
            sha256Fingerprint: fingerprint(ofWireFormat: bytes)
        )
    }
}

/// Bridges NIOSSH's promise-based host-key callback to the async
/// ``SSHKnownHostsPolicy``.
///
/// The handshake is blocked on `validationCompletePromise` while the user
/// decides, which is exactly the behaviour we want: no credential is offered
/// until the server's identity is settled. Fails closed — if the policy task
/// is cancelled or the app is torn down, the promise is failed rather than
/// left dangling, and NIOSSH aborts the connection.
final class HostKeyBridge: NIOSSHClientServerAuthenticationDelegate {
    private let endpoint: SSHEndpoint
    private let policy: SSHKnownHostsPolicy
    private let lock = NSLock()
    private var _presentedKey: SSHHostKey?

    init(endpoint: SSHEndpoint, policy: SSHKnownHostsPolicy) {
        self.endpoint = endpoint
        self.policy = policy
    }

    /// The key the server presented, available once validation has run. Used to
    /// populate `SSHConnectionInfo` and the "host key rejected" error.
    var presentedKey: SSHHostKey? {
        lock.lock()
        defer { lock.unlock() }
        return _presentedKey
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = SSHHostKey(hostKey)

        lock.lock()
        _presentedKey = key
        lock.unlock()

        let policy = self.policy
        let endpoint = self.endpoint

        Task {
            let accepted = await policy.validate(key, for: endpoint)
            if accepted {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(
                    SSHTransportError.hostKeyRejected(endpoint, presented: key)
                )
            }
        }
    }
}
