import Crypto
import Foundation

/// A private key read out of an `openssh-key-v1` file.
///
/// Deliberately not a signing key: this module's job is to decrypt and decode,
/// and turning the material into something that can sign belongs to whichever
/// layer knows which SSH library is in use. That keeps the parser free of
/// SwiftNIO and testable on its own.
public struct OpenSSHPrivateKey {
    public enum Material {
        /// `seed` is the 32-byte Ed25519 seed. OpenSSH stores seed‖public key
        /// as one 64-byte blob; the two are separated here because that is what
        /// every library's initialiser actually wants.
        case ed25519(seed: [UInt8], publicKey: [UInt8])
        case ecdsaP256(privateScalar: [UInt8], publicKey: [UInt8])
        case ecdsaP384(privateScalar: [UInt8], publicKey: [UInt8])
        case ecdsaP521(privateScalar: [UInt8], publicKey: [UInt8])
        case rsa(RSAComponents)
    }

    /// RSA's private values as OpenSSH stores them, as unsigned big-endian
    /// magnitudes.
    ///
    /// Note what is *not* here: `dp`, `dq`. OpenSSH does not store them, so
    /// anything wanting a full CRT key has to derive them — which needs
    /// big-integer arithmetic and is the consumer's problem, not the parser's.
    public struct RSAComponents {
        public var modulus: [UInt8]           // n
        public var publicExponent: [UInt8]    // e
        public var privateExponent: [UInt8]   // d
        public var coefficient: [UInt8]       // iqmp = q^-1 mod p
        public var prime1: [UInt8]            // p
        public var prime2: [UInt8]            // q

        public init(
            modulus: [UInt8],
            publicExponent: [UInt8],
            privateExponent: [UInt8],
            coefficient: [UInt8],
            prime1: [UInt8],
            prime2: [UInt8]
        ) {
            self.modulus = modulus
            self.publicExponent = publicExponent
            self.privateExponent = privateExponent
            self.coefficient = coefficient
            self.prime1 = prime1
            self.prime2 = prime2
        }
    }

    public var material: Material
    /// The comment `ssh-keygen` wrote, usually `user@host`.
    public var comment: String
    /// The public-key blob exactly as it appears in the file, which is what
    /// goes into an `authorized_keys` line.
    public var publicKeyBlob: [UInt8]
    /// e.g. `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`.
    public var keyType: String

    /// As read from a file: the blob and the type are taken from the file
    /// rather than derived, because a file is the authority on what it says.
    public init(material: Material, comment: String, publicKeyBlob: [UInt8], keyType: String) {
        self.material = material
        self.comment = comment
        self.publicKeyBlob = publicKeyBlob
        self.keyType = keyType
    }

    /// As freshly generated: the blob and the type follow from the material,
    /// because there is no file yet to disagree with.
    public init(material: Material, comment: String) {
        self.init(
            material: material,
            comment: comment,
            publicKeyBlob: material.publicKeyBlob,
            keyType: material.keyType
        )
    }
}

public extension OpenSSHPrivateKey.Material {
    var keyType: String {
        switch self {
        case .ed25519: return "ssh-ed25519"
        case .ecdsaP256: return "ecdsa-sha2-nistp256"
        case .ecdsaP384: return "ecdsa-sha2-nistp384"
        case .ecdsaP521: return "ecdsa-sha2-nistp521"
        case .rsa: return "ssh-rsa"
        }
    }

    /// The public half in SSH's own encoding — the thing that goes into an
    /// `authorized_keys` line, and the only half that leaves the device by
    /// default.
    var publicKeyBlob: [UInt8] {
        var writer = SSHWireWriter()
        switch self {
        case .ed25519(_, let publicKey):
            writer.writeString("ssh-ed25519")
            writer.writeString(publicKey)
        case .ecdsaP256(_, let publicKey):
            writer.writeString("ecdsa-sha2-nistp256")
            writer.writeString("nistp256")
            writer.writeString(publicKey)
        case .ecdsaP384(_, let publicKey):
            writer.writeString("ecdsa-sha2-nistp384")
            writer.writeString("nistp384")
            writer.writeString(publicKey)
        case .ecdsaP521(_, let publicKey):
            writer.writeString("ecdsa-sha2-nistp521")
            writer.writeString("nistp521")
            writer.writeString(publicKey)
        case .rsa(let components):
            // `e` then `n` — the opposite order to the private half, which is
            // the single easiest thing to get wrong in this format.
            writer.writeString("ssh-rsa")
            writer.writeMPInt(components.publicExponent)
            writer.writeMPInt(components.modulus)
        }
        return writer.bytes
    }
}

/// Reads `openssh-key-v1` files: the format `ssh-keygen` has written by default
/// since OpenSSH 7.8, for every key type.
///
/// ## Why sssh has its own
///
/// The obvious dependency, Citadel, parses this container generically
/// internally but exposed only one entry point — Ed25519 — so RSA and ECDSA
/// key files could not be read at all. Since people do still carry an `id_rsa`
/// that other tools share, the choice was between telling them to convert it
/// and implementing the container. This is the container, and Citadel is no
/// longer a dependency.
///
/// ## Supported
///
/// | | |
/// |---|---|
/// | key types | ed25519, RSA, ECDSA P-256/384/521 |
/// | ciphers | none, aes128-ctr, aes192-ctr, aes256-ctr |
/// | KDF | none, bcrypt |
///
/// `aes256-cbc` needs the inverse block cipher, and
/// `chacha20-poly1305@openssh.com` and `aes256-gcm@openssh.com` use OpenSSH's
/// own AEAD framing; all three are reported by name rather than as a generic
/// failure, because the remedy (`ssh-keygen -p -Z aes256-ctr`) is something a
/// user can act on.
public enum OpenSSHPrivateKeyParser {
    public enum Failure: Error, Equatable {
        case notOpenSSHFormat
        case malformed(String)
        case unsupportedCipher(String)
        case unsupportedKDF(String)
        case passphraseRequired
        case incorrectPassphrase
        case unsupportedKeyType(String)
        /// The format allows several keys per file; `ssh-keygen` has never
        /// written one, and guessing which to use would be worse than saying so.
        case multipleKeys(Int)
    }

    /// What can be learned without a passphrase.
    public struct Header: Equatable {
        public var keyType: String
        public var cipherName: String
        public var kdfName: String

        public var isEncrypted: Bool { cipherName != "none" }
    }

    private static let magic = Array("openssh-key-v1\0".utf8)
    private static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let endMarker = "-----END OPENSSH PRIVATE KEY-----"

    public static func isOpenSSHFormat(_ text: String) -> Bool {
        text.contains(beginMarker)
    }

    /// Reads the plaintext header, which is readable even for an encrypted key.
    ///
    /// This is what lets sssh say "this key needs a passphrase" or "sssh cannot
    /// read this key type" before prompting, instead of after.
    public static func inspect(armoredText text: String) throws -> Header {
        let blob = try decodeArmor(text)
        var reader = SSHWireReader(blob)

        guard let magicBytes = reader.readBytes(magic.count), magicBytes == magic else {
            throw Failure.malformed("missing openssh-key-v1 magic")
        }
        guard let cipher = reader.readStringAsText(),
              let kdf = reader.readStringAsText(),
              reader.readString() != nil,                 // kdf options
              let keyCount = reader.readUInt32()
        else {
            throw Failure.malformed("truncated header")
        }
        guard keyCount == 1 else { throw Failure.multipleKeys(Int(keyCount)) }
        guard let publicKeyBlob = reader.readString() else {
            throw Failure.malformed("truncated public key")
        }

        var publicKeyReader = SSHWireReader(publicKeyBlob)
        guard let keyType = publicKeyReader.readStringAsText() else {
            throw Failure.malformed("public key has no type")
        }

        return Header(keyType: keyType, cipherName: cipher, kdfName: kdf)
    }

    /// Decrypts and decodes the key.
    ///
    /// - Parameter passphrase: required when ``inspect(armoredText:)`` reports
    ///   the key encrypted. Passed as bytes because a passphrase is not
    ///   necessarily valid UTF-8 once it has been through somebody's keyboard
    ///   layout, and OpenSSH treats it as opaque.
    public static func parse(armoredText text: String, passphrase: [UInt8]? = nil) throws -> OpenSSHPrivateKey {
        let blob = try decodeArmor(text)
        var reader = SSHWireReader(blob)

        guard let magicBytes = reader.readBytes(magic.count), magicBytes == magic else {
            throw Failure.malformed("missing openssh-key-v1 magic")
        }
        guard let cipherName = reader.readStringAsText(),
              let kdfName = reader.readStringAsText(),
              let kdfOptions = reader.readString(),
              let keyCount = reader.readUInt32()
        else {
            throw Failure.malformed("truncated header")
        }
        guard keyCount == 1 else { throw Failure.multipleKeys(Int(keyCount)) }
        guard let publicKeyBlob = reader.readString(),
              let encryptedSection = reader.readString()
        else {
            throw Failure.malformed("truncated body")
        }

        let cipher = try Cipher(name: cipherName)
        let privateSection = try decrypt(
            encryptedSection,
            cipher: cipher,
            kdfName: kdfName,
            kdfOptions: kdfOptions,
            passphrase: passphrase
        )

        return try decodePrivateSection(
            privateSection,
            publicKeyBlob: publicKeyBlob,
            blockSize: cipher.blockSize
        )
    }

    // MARK: - Armor

    private static func decodeArmor(_ text: String) throws -> [UInt8] {
        guard let begin = text.range(of: beginMarker),
              let end = text.range(of: endMarker),
              begin.upperBound <= end.lowerBound
        else {
            throw Failure.notOpenSSHFormat
        }

        // Tolerate CRLF, stray blank lines and the indentation a key picks up
        // when it is pasted into a chat client.
        let base64 = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard !base64.isEmpty, let data = Data(base64Encoded: String(base64)) else {
            throw Failure.malformed("body is not valid base64")
        }
        return Array(data)
    }

    // MARK: - Decryption

    private struct Cipher {
        var name: String
        var keyLength: Int
        var ivLength: Int
        var blockSize: Int

        init(name: String) throws {
            switch name {
            case "none":
                self = Cipher(name: name, keyLength: 0, ivLength: 0, blockSize: 8)
            case "aes128-ctr":
                self = Cipher(name: name, keyLength: 16, ivLength: 16, blockSize: 16)
            case "aes192-ctr":
                self = Cipher(name: name, keyLength: 24, ivLength: 16, blockSize: 16)
            case "aes256-ctr":
                self = Cipher(name: name, keyLength: 32, ivLength: 16, blockSize: 16)
            default:
                throw Failure.unsupportedCipher(name)
            }
        }

        private init(name: String, keyLength: Int, ivLength: Int, blockSize: Int) {
            self.name = name
            self.keyLength = keyLength
            self.ivLength = ivLength
            self.blockSize = blockSize
        }
    }

    private static func decrypt(
        _ section: [UInt8],
        cipher: Cipher,
        kdfName: String,
        kdfOptions: [UInt8],
        passphrase: [UInt8]?
    ) throws -> [UInt8] {
        guard cipher.name != "none" else {
            guard kdfName == "none" else { throw Failure.unsupportedKDF(kdfName) }
            return section
        }

        guard kdfName == "bcrypt" else { throw Failure.unsupportedKDF(kdfName) }

        guard let passphrase, !passphrase.isEmpty else {
            throw Failure.passphraseRequired
        }

        var optionsReader = SSHWireReader(kdfOptions)
        guard let salt = optionsReader.readString(), let rounds = optionsReader.readUInt32() else {
            throw Failure.malformed("unreadable bcrypt parameters")
        }
        // An absurd round count in a hostile file would otherwise be a denial
        // of service; ssh-keygen's default is 16 and its own maximum is far
        // below this.
        guard rounds >= 1, rounds <= 10_000 else {
            throw Failure.malformed("implausible bcrypt round count \(rounds)")
        }

        let derived: [UInt8]
        do {
            derived = try BcryptPBKDF.derive(
                password: passphrase,
                salt: salt,
                rounds: Int(rounds),
                keyLength: cipher.keyLength + cipher.ivLength
            )
        } catch {
            throw Failure.malformed("key derivation failed")
        }

        do {
            return try AESCTR.apply(
                section,
                key: Array(derived[0..<cipher.keyLength]),
                nonce: Array(derived[cipher.keyLength...])
            )
        } catch {
            throw Failure.malformed("decryption failed")
        }
    }

    // MARK: - Private section

    private static func decodePrivateSection(
        _ section: [UInt8],
        publicKeyBlob: [UInt8],
        blockSize: Int
    ) throws -> OpenSSHPrivateKey {
        var reader = SSHWireReader(section)

        guard let check1 = reader.readUInt32(), let check2 = reader.readUInt32() else {
            throw Failure.malformed("truncated private section")
        }
        // The two random check words are written identically and only match
        // after a correct decryption. This is the *only* signal that a
        // passphrase was wrong — there is no MAC — so it must not be treated as
        // a generic parse failure.
        guard check1 == check2 else {
            throw Failure.incorrectPassphrase
        }

        guard let keyType = reader.readStringAsText() else {
            throw Failure.malformed("private section has no key type")
        }

        let material = try readMaterial(keyType: keyType, from: &reader)

        guard let comment = reader.readStringAsText() else {
            throw Failure.malformed("truncated comment")
        }

        try verifyPadding(reader.readAllRemaining(), blockSize: blockSize)

        return OpenSSHPrivateKey(
            material: material,
            comment: comment,
            publicKeyBlob: publicKeyBlob,
            keyType: keyType
        )
    }

    private static func readMaterial(
        keyType: String,
        from reader: inout SSHWireReader
    ) throws -> OpenSSHPrivateKey.Material {
        switch keyType {
        case "ssh-ed25519":
            guard let publicKey = reader.readString(), let combined = reader.readString() else {
                throw Failure.malformed("truncated ed25519 key")
            }
            // OpenSSH stores the libsodium layout: 32-byte seed then the public
            // key again.
            guard publicKey.count == 32, combined.count == 64 else {
                throw Failure.malformed("ed25519 key has the wrong size")
            }
            guard Array(combined[32...]) == publicKey else {
                throw Failure.malformed("ed25519 private key does not match its public half")
            }
            return .ed25519(seed: Array(combined[0..<32]), publicKey: publicKey)

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard let curveName = reader.readStringAsText(),
                  let point = reader.readString(),
                  let scalar = reader.readMPInt()
            else {
                throw Failure.malformed("truncated ECDSA key")
            }
            guard keyType.hasSuffix(curveName) else {
                throw Failure.malformed("ECDSA curve \(curveName) does not match key type \(keyType)")
            }

            switch curveName {
            case "nistp256":
                return .ecdsaP256(privateScalar: leftPad(scalar, to: 32), publicKey: point)
            case "nistp384":
                return .ecdsaP384(privateScalar: leftPad(scalar, to: 48), publicKey: point)
            case "nistp521":
                return .ecdsaP521(privateScalar: leftPad(scalar, to: 66), publicKey: point)
            default:
                throw Failure.unsupportedKeyType(keyType)
            }

        case "ssh-rsa":
            // Note the order: the private blob is n, e, d, iqmp, p, q — not the
            // e, n of the public blob.
            guard let n = reader.readMPInt(),
                  let e = reader.readMPInt(),
                  let d = reader.readMPInt(),
                  let iqmp = reader.readMPInt(),
                  let p = reader.readMPInt(),
                  let q = reader.readMPInt()
            else {
                throw Failure.malformed("truncated RSA key")
            }
            return .rsa(OpenSSHPrivateKey.RSAComponents(
                modulus: n,
                publicExponent: e,
                privateExponent: d,
                coefficient: iqmp,
                prime1: p,
                prime2: q
            ))

        default:
            throw Failure.unsupportedKeyType(keyType)
        }
    }

    /// An `mpint` drops leading zeros, but a scalar for a fixed curve has a
    /// fixed width, so restore it.
    private static func leftPad(_ value: [UInt8], to width: Int) -> [UInt8] {
        guard value.count < width else { return value }
        return [UInt8](repeating: 0, count: width - value.count) + value
    }

    /// The private section is padded to the cipher's block size with the bytes
    /// 1, 2, 3, … Checking it catches a decryption that produced plausible
    /// leading bytes by chance.
    private static func verifyPadding(_ padding: [UInt8], blockSize: Int) throws {
        guard padding.count < blockSize else {
            throw Failure.malformed("private section has \(padding.count) trailing bytes")
        }
        for (index, byte) in padding.enumerated() where byte != UInt8(truncatingIfNeeded: index + 1) {
            throw Failure.malformed("bad padding")
        }
    }
}
