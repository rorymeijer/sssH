import Citadel
import Crypto
import NIOSSH

/// Adds the algorithms swift-nio-ssh does not ship with.
///
/// NIOSSH's `register` functions mutate process-global tables, so registration
/// happens exactly once, before the first handshake. Without it we cannot talk
/// to a server that only offers an RSA host key or `diffie-hellman-group14-*`
/// — which still includes plenty of appliances and older LTS distributions.
enum AlgorithmRegistration {
    private static let once: Void = {
        // RSA host keys and RSA public-key authentication. Citadel implements
        // these over BoringSSL because NIOSSH deliberately omits RSA.
        NIOSSHAlgorithms.register(
            publicKey: Insecure.RSA.PublicKey.self,
            signature: Insecure.RSA.Signature.self
        )

        // Key exchange: NIOSSH bundles curve25519-sha256 only.
        NIOSSHAlgorithms.register(keyExchangeAlgorithm: DiffieHellmanGroup14Sha256.self)
        NIOSSHAlgorithms.register(keyExchangeAlgorithm: DiffieHellmanGroup14Sha1.self)

        // Transport protection: NIOSSH bundles the AES-GCM schemes only.
        NIOSSHAlgorithms.register(transportProtectionScheme: AES128CTR.self)
    }()

    /// Registers the extra algorithms and appends them to `configuration`'s
    /// preference lists.
    ///
    /// They are *appended*, so NIOSSH's bundled AES-GCM and curve25519 stay
    /// ahead of them: a modern server must never end up negotiating SHA-1
    /// because we listed it first.
    static func apply(to configuration: inout SSHClientConfiguration) {
        _ = once

        configuration.transportProtectionSchemes.append(AES128CTR.self)
        configuration.keyExchangeAlgorithms.append(DiffieHellmanGroup14Sha256.self)
        configuration.keyExchangeAlgorithms.append(DiffieHellmanGroup14Sha1.self)
    }
}
