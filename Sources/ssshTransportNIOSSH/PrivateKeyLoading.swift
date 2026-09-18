import Crypto
import Foundation
import NIOSSH
import ssshCore
import ssshCrypto

/// Turns stored key material into something NIOSSH can sign with.
///
/// The container parsing is `ssshCrypto`'s job; this is only the mapping from
/// parsed material to a `NIOSSHPrivateKey`, plus turning every failure into an
/// error a user can act on.
///
/// ## Coverage
///
/// | key file | usable for authentication |
/// |---|---|
/// | `openssh-key-v1` ed25519, plain or passphrase-protected | yes |
/// | `openssh-key-v1` ECDSA P-256/384/521 | yes |
/// | PEM PKCS#8 / SEC1 P-256/384/521 | yes |
/// | `openssh-key-v1` RSA | **read, not yet usable** — see below |
///
/// ### Why RSA stops here
///
/// The file is parsed correctly; what is missing is a signer. NIOSSH omits RSA
/// entirely, and the two ways to add it both have a catch:
///
/// - Citadel's `Insecure.RSA` signs with SHA-1 under the name `ssh-rsa`, which
///   OpenSSH has refused by default since 8.8 (2021). It would authenticate
///   against almost nothing.
/// - Implementing `rsa-sha2-256`/`rsa-sha2-512` ourselves runs into NIOSSH's
///   custom-key API keying everything off one prefix string, while RFC 8332
///   deliberately separates the key-blob format name (`ssh-rsa`) from the
///   signature algorithm name (`rsa-sha2-*`). Getting that wrong produces
///   something that looks right and fails against real servers.
///
/// So this reports `unsupportedKeyType("ssh-rsa")` rather than half-working,
/// and the UI can tell the user to convert the key — which is a one-line
/// `ssh-keygen` away — while the proper fix is tracked in
/// docs/PHASE-0-BACKEND-DECISION.md.
enum PrivateKeyLoader {
    static func load(_ material: SSHPrivateKeyMaterial) throws -> NIOSSHPrivateKey {
        let text = material.openSSHPrivateKey.reveal()
        let label = material.label ?? "private key"

        if OpenSSHPrivateKeyParser.isOpenSSHFormat(text) {
            return try loadOpenSSH(text, material: material, label: label)
        }

        if let key = try? loadPEMECDSA(text) {
            return key
        }

        throw SSHTransportError.credentialUnusable(credential: label, reason: .malformedKey)
    }

    private static func loadOpenSSH(
        _ text: String,
        material: SSHPrivateKeyMaterial,
        label: String
    ) throws -> NIOSSHPrivateKey {
        let parsed: OpenSSHPrivateKey
        do {
            parsed = try OpenSSHPrivateKeyParser.parse(
                armoredText: text,
                passphrase: material.passphrase?.revealBytes()
            )
        } catch let failure as OpenSSHPrivateKeyParser.Failure {
            throw SSHTransportError.credentialUnusable(
                credential: label,
                reason: problem(for: failure)
            )
        }

        do {
            switch parsed.material {
            case .ed25519(let seed, _):
                return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
            case .ecdsaP256(let scalar, _):
                return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: scalar))
            case .ecdsaP384(let scalar, _):
                return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: scalar))
            case .ecdsaP521(let scalar, _):
                return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: scalar))
            case .rsa:
                throw SSHTransportError.credentialUnusable(
                    credential: label,
                    reason: .unsupportedKeyType(parsed.keyType)
                )
            }
        } catch let error as SSHTransportError {
            throw error
        } catch {
            // The container decoded but the scalar was not a valid key for its
            // curve — a corrupt file rather than a wrong passphrase, since the
            // check words already passed.
            throw SSHTransportError.credentialUnusable(credential: label, reason: .malformedKey)
        }
    }

    private static func problem(for failure: OpenSSHPrivateKeyParser.Failure) -> SSHTransportError.CredentialProblem {
        switch failure {
        case .passphraseRequired:
            return .passphraseRequired
        case .incorrectPassphrase:
            return .wrongPassphrase
        case .unsupportedKeyType(let type):
            return .unsupportedKeyType(type)
        case .unsupportedCipher(let name):
            // Worth naming: the remedy is `ssh-keygen -p -Z aes256-ctr`.
            return .unsupportedKeyType("encrypted with \(name)")
        case .unsupportedKDF(let name):
            return .unsupportedKeyType("key derivation \(name)")
        case .multipleKeys:
            return .malformedKey
        case .notOpenSSHFormat, .malformed:
            return .malformedKey
        }
    }

    /// PEM-armored NIST curve keys, which swift-crypto reads directly.
    /// Encrypted PEM is not supported by swift-crypto and is not attempted.
    private static func loadPEMECDSA(_ text: String) throws -> NIOSSHPrivateKey {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) {
            return NIOSSHPrivateKey(p256Key: key)
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) {
            return NIOSSHPrivateKey(p384Key: key)
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) {
            return NIOSSHPrivateKey(p521Key: key)
        }
        throw SSHTransportError.credentialUnusable(credential: "private key", reason: .malformedKey)
    }
}
