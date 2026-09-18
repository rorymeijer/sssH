import NIOSSH

/// Adds the algorithms swift-nio-ssh does not ship with.
///
/// NIOSSH's `register` functions mutate process-global tables, so registration
/// happens exactly once, before the first handshake.
///
/// ## What sssh requires of a server
///
/// Key exchange `curve25519-sha256` and an AES-GCM cipher, which is every
/// OpenSSH from 6.5 (January 2014) onwards. Older `diffie-hellman-group14-*`
/// and `aes128-ctr` are **not** supported.
///
/// That is a deliberate narrowing. Implementing them means a key-exchange
/// conformance and a transport-protection conformance — several hundred lines
/// of handshake cryptography whose only real test is a live server of the kind
/// that needs them. A subtly wrong key exchange does not fail loudly; it
/// negotiates. Until that can be tested properly, refusing to connect is the
/// honest outcome, and the error says so.
enum AlgorithmRegistration {
    private static let once: Void = {
        // RSA, under the RFC 8332 names. SHA-512 first so it is preferred.
        // NIOSSH pairs one signature type with one key type per registration,
        // which is why there are two of each rather than one that does both.
        NIOSSHAlgorithms.register(
            publicKey: SSHRSASHA512PublicKey.self,
            signature: SSHRSASHA512Signature.self
        )
        NIOSSHAlgorithms.register(
            publicKey: SSHRSASHA256PublicKey.self,
            signature: SSHRSASHA256Signature.self
        )
    }()

    static func performOnce() {
        _ = once
    }

    /// Registers the extra algorithms. The configuration itself needs no
    /// change: NIOSSH picks up custom public-key algorithms from the global
    /// table, and sssh adds no ciphers or key exchanges.
    static func apply(to configuration: inout SSHClientConfiguration) {
        performOnce()
    }
}
