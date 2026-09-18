import Crypto
import Foundation
import _CryptoExtras

/// Generates SSH keys on device.
///
/// On device is the whole point: a key generated anywhere else has been
/// somewhere else. Nothing here touches the network, and the private half is
/// handed straight to the Keychain — the caller gets the public line and a
/// reference, and has to go out of its way to see anything more.
public enum SSHKeyGenerator {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case ed25519
        /// Supported because people still have servers that will not take
        /// anything else, and because a key you cannot use is not security.
        case rsa2048
        case rsa4096

        public var id: String { rawValue }

        public var isRSA: Bool { self != .ed25519 }
    }

    public enum Failure: Error, LocalizedError {
        case generationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .generationFailed(let detail): return detail
            }
        }
    }

    public struct Generated: Sendable {
        public var privateKey: OpenSSHPrivateKey
        /// The armoured private key, encrypted when a passphrase was given.
        public var armoredPrivateKey: String
        /// The `ssh-ed25519 AAAA… comment` line for `authorized_keys`.
        public var publicLine: String
    }

    public static func generate(kind: Kind, comment: String, passphrase: [UInt8]? = nil) throws -> Generated {
        let material: OpenSSHPrivateKey.Material
        switch kind {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            material = .ed25519(
                seed: Array(key.rawRepresentation),
                publicKey: Array(key.publicKey.rawRepresentation)
            )
        case .rsa2048, .rsa4096:
            material = try rsaMaterial(bits: kind == .rsa2048 ? 2048 : 4096)
        }

        let key = OpenSSHPrivateKey(material: material, comment: comment)
        let encryption = passphrase.map { OpenSSHPrivateKeyWriter.Encryption(passphrase: $0) }
        return Generated(
            privateKey: key,
            armoredPrivateKey: try OpenSSHPrivateKeyWriter.armoredText(for: key, encryption: encryption),
            publicLine: try OpenSSHPrivateKeyWriter.authorizedKeysLine(for: key)
        )
    }

    /// RSA's components, in the six values OpenSSH stores.
    ///
    /// swift-crypto hands back PKCS#1 DER, which is the one form that has all
    /// six in it — the PKCS#8 and SPKI forms do not — so it is taken apart
    /// again here rather than asking for something that does not exist.
    private static func rsaMaterial(bits: Int) throws -> OpenSSHPrivateKey.Material {
        let key = try _RSA.Signing.PrivateKey(keySize: .init(bitCount: bits))
        let der = Array(key.derRepresentation)
        guard let components = try? OpenSSHPrivateKey.RSAComponents.fromPKCS1DER(der) else {
            throw Failure.generationFailed("the generated RSA key could not be decoded")
        }
        return .rsa(components)
    }
}
