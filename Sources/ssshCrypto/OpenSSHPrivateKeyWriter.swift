import Foundation

/// Writes `openssh-key-v1`, the counterpart to ``OpenSSHPrivateKeyParser``.
///
/// Needed because sssh generates keys on device, and a key it cannot write out
/// in the format every other tool reads is a key the user cannot copy to a
/// server, back up, or move to another client. A file this produces is loaded
/// by `ssh`, `ssh-keygen` and every library in circulation.
///
/// Two details are easy to get wrong and are both load-bearing:
///
/// - **RSA's field order differs between the public blob and the private
///   half.** The public blob is `e, n`; the private half is
///   `n, e, d, iqmp, p, q`. Writing either in the other's order produces a file
///   that parses and then fails to sign.
/// - **The private section is padded with 1, 2, 3, …** to a multiple of the
///   cipher's block size — eight for an unencrypted key. Zero padding is the
///   obvious guess and `ssh-keygen` rejects it.
public enum OpenSSHPrivateKeyWriter {
    public enum Failure: Error, Equatable {
        case unsupportedKeyType(String)
        case malformedMaterial(String)
    }

    /// Encryption for the written file.
    public struct Encryption {
        public var passphrase: [UInt8]
        /// bcrypt_pbkdf rounds. OpenSSH's own default is 16, and raising it
        /// costs the user a wait on every unlock for protection against an
        /// attacker who already has the file.
        public var rounds: UInt32
        /// Sixteen bytes, as `ssh-keygen` uses. Injected so a test can pin it;
        /// callers pass nothing and get a fresh random one.
        public var salt: [UInt8]

        public init(passphrase: [UInt8], rounds: UInt32 = 16, salt: [UInt8]? = nil) {
            self.passphrase = passphrase
            self.rounds = rounds
            self.salt = salt ?? (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
    }

    /// PEM-armoured `openssh-key-v1`, ready to write to `~/.ssh/id_ed25519`.
    ///
    /// - Parameter checkInt: the pair of identical integers OpenSSH puts at the
    ///   start of the private section to tell a wrong passphrase from a
    ///   corrupt file. Injected only so a test can produce a byte-exact file.
    public static func armoredText(
        for key: OpenSSHPrivateKey,
        encryption: Encryption? = nil,
        checkInt: UInt32? = nil
    ) throws -> String {
        let container = try container(for: key, encryption: encryption, checkInt: checkInt)
        return armour(container)
    }

    static func container(
        for key: OpenSSHPrivateKey,
        encryption: Encryption?,
        checkInt: UInt32?
    ) throws -> [UInt8] {
        let publicBlob = try publicKeyBlob(for: key)
        var privateSection = try privateSection(for: key, checkInt: checkInt ?? UInt32.random(in: 0...UInt32.max))

        var writer = SSHWireWriter()
        // AUTH_MAGIC: a NUL-terminated C string, not a length-prefixed SSH
        // string. It is the one raw field in the container.
        writer.writeRaw(Array("openssh-key-v1".utf8) + [0])

        if let encryption {
            // 32 bytes of AES key and 16 of IV, which is the layout
            // `aes256-ctr` implies and what every implementation derives.
            let derived = try BcryptPBKDF.derive(
                password: encryption.passphrase,
                salt: encryption.salt,
                rounds: Int(encryption.rounds),
                keyLength: 48
            )
            let blockSize = 16
            pad(&privateSection, to: blockSize)

            var kdfOptions = SSHWireWriter()
            kdfOptions.writeString(encryption.salt)
            kdfOptions.writeUInt32(encryption.rounds)

            writer.writeString("aes256-ctr")
            writer.writeString("bcrypt")
            writer.writeString(kdfOptions.bytes)
            writer.writeUInt32(1)
            writer.writeString(publicBlob)
            writer.writeString(try AESCTR.apply(
                privateSection,
                key: Array(derived[0..<32]),
                nonce: Array(derived[32..<48])
            ))
        } else {
            // Block size 8 for the `none` cipher, which is what OpenSSH uses
            // and not the 16 an AES habit would suggest.
            pad(&privateSection, to: 8)

            writer.writeString("none")
            writer.writeString("none")
            writer.writeString([])
            writer.writeUInt32(1)
            writer.writeString(publicBlob)
            writer.writeString(privateSection)
        }

        return writer.bytes
    }

    /// The `ssh-ed25519 AAAA… comment` line, which is what gets copied to a
    /// server's `authorized_keys` — and, by design, the only half that ever
    /// leaves the device by default.
    public static func authorizedKeysLine(for key: OpenSSHPrivateKey) throws -> String {
        let blob = try publicKeyBlob(for: key)
        let encoded = Data(blob).base64EncodedString()
        let comment = key.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return comment.isEmpty ? "\(key.keyType) \(encoded)" : "\(key.keyType) \(encoded) \(comment)"
    }

    // MARK: - Sections

    static func publicKeyBlob(for key: OpenSSHPrivateKey) throws -> [UInt8] {
        switch key.material {
        case .ed25519(_, let publicKey):
            guard publicKey.count == 32 else {
                throw Failure.malformedMaterial("an Ed25519 public key must be 32 bytes")
            }
        case .rsa:
            break
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            // Readable, but not written: generating one would mean offering a
            // key type that is worse than Ed25519 on every axis people care
            // about, and existing ECDSA files are read, not rewritten.
            throw Failure.unsupportedKeyType(key.keyType)
        }
        return key.material.publicKeyBlob
    }

    private static func privateSection(for key: OpenSSHPrivateKey, checkInt: UInt32) throws -> [UInt8] {
        var writer = SSHWireWriter()
        writer.writeUInt32(checkInt)
        writer.writeUInt32(checkInt)

        switch key.material {
        case .ed25519(let seed, let publicKey):
            guard seed.count == 32, publicKey.count == 32 else {
                throw Failure.malformedMaterial("an Ed25519 key needs a 32-byte seed and a 32-byte public key")
            }
            writer.writeString("ssh-ed25519")
            writer.writeString(publicKey)
            // OpenSSH stores seed‖public as one 64-byte "private key", which
            // is what libsodium's secret key is.
            writer.writeString(seed + publicKey)
        case .rsa(let components):
            writer.writeString("ssh-rsa")
            writer.writeMPInt(components.modulus)
            writer.writeMPInt(components.publicExponent)
            writer.writeMPInt(components.privateExponent)
            writer.writeMPInt(components.coefficient)
            writer.writeMPInt(components.prime1)
            writer.writeMPInt(components.prime2)
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            // Unreachable: `publicKeyBlob(for:)` refuses these first. Kept so
            // that adding a key type to `Material` is a compile error here
            // rather than a silently unwritable key.
            throw Failure.unsupportedKeyType(key.keyType)
        }

        writer.writeString(key.comment)
        return writer.bytes
    }

    /// 1, 2, 3, … — not zeros. `ssh-keygen` checks these bytes and refuses a
    /// file padded any other way.
    private static func pad(_ bytes: inout [UInt8], to blockSize: Int) {
        var counter: UInt8 = 1
        while bytes.count % blockSize != 0 {
            bytes.append(counter)
            counter &+= 1
        }
    }

    // MARK: - Armour

    static func armour(_ container: [UInt8]) -> String {
        let encoded = Data(container).base64EncodedString()
        var lines = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var index = encoded.startIndex
        // 70 characters per line, which is what `ssh-keygen` emits. Nothing
        // requires it, but a file that looks byte-for-byte like the tool's own
        // output is one fewer thing to wonder about in a diff.
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 70, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        lines.append("-----END OPENSSH PRIVATE KEY-----")
        return lines.joined(separator: "\n") + "\n"
    }
}
