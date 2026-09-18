import Citadel
import Crypto
import Foundation
import NIOSSH
import ssshCore

/// Turns stored key material into something NIOSSH can sign with.
///
/// ## Coverage, and why it is what it is
///
/// Citadel exposes exactly one public OpenSSH private-key parser —
/// `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)` — even though it
/// implements the container format generically internally. So:
///
/// | key file | supported | how |
/// |---|---|---|
/// | `openssh-key-v1`, ed25519, plain or passphrase-protected | yes | Citadel |
/// | PEM PKCS#8 / SEC1 P-256/384/521 | yes | swift-crypto |
/// | `openssh-key-v1`, RSA or ECDSA | no | needs our own container parser |
/// | PKCS#1 `BEGIN RSA PRIVATE KEY` | no | as above |
///
/// The gap is not a protocol limitation: RSA *authentication* works (Citadel's
/// `Insecure.RSA` is registered with NIOSSH), only reading the file does not.
/// Closing it means parsing `openssh-key-v1` ourselves — bcrypt-pbkdf, AES-CTR,
/// then the per-algorithm key material — which is Phase 1 work tracked in
/// docs/PHASE-0-BACKEND-DECISION.md. Until then the error is specific, so the
/// user is told to convert the key rather than left guessing.
enum PrivateKeyLoader {
    static func load(_ material: SSHPrivateKeyMaterial) throws -> NIOSSHPrivateKey {
        let text = material.openSSHPrivateKey.reveal()
        let label = material.label ?? "private key"

        if OpenSSHKeyInspector.isOpenSSHFormat(text) {
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
        guard let header = OpenSSHKeyInspector(armoredText: text) else {
            throw SSHTransportError.credentialUnusable(credential: label, reason: .malformedKey)
        }

        // Key type before passphrase: telling someone to supply a passphrase
        // for a key we then refuse to read is a worse experience than saying
        // up front that the format is not supported.
        guard header.keyType == "ssh-ed25519" else {
            throw SSHTransportError.credentialUnusable(
                credential: label,
                reason: .unsupportedKeyType(header.keyType)
            )
        }

        if header.isEncrypted, material.passphrase == nil {
            throw SSHTransportError.credentialUnusable(credential: label, reason: .passphraseRequired)
        }

        // Citadel takes the passphrase bytes as the "decryption key" and runs
        // bcrypt-pbkdf over them itself.
        let decryptionKey = material.passphrase.map { Data($0.revealBytes()) }

        do {
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryptionKey)
            return NIOSSHPrivateKey(ed25519Key: key)
        } catch {
            // A parse failure on an encrypted key is overwhelmingly a wrong
            // passphrase: the container's checksum words are what fail to
            // match. On a plaintext key it is genuinely malformed.
            throw SSHTransportError.credentialUnusable(
                credential: label,
                reason: header.isEncrypted ? .wrongPassphrase : .malformedKey
            )
        }
    }

    /// PEM-armored NIST curve keys, which swift-crypto can read directly.
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
