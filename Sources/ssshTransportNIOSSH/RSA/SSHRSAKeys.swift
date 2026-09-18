import Crypto
import Foundation
import NIOCore
import NIOSSH
import _CryptoExtras
import ssshCrypto

/// RSA public-key authentication and host-key verification, under the RFC 8332
/// algorithm names.
///
/// ## Why this is here rather than in a dependency
///
/// swift-nio-ssh deliberately omits RSA. The obvious substitute, Citadel's
/// `Insecure.RSA`, signs with SHA-1 under the name `ssh-rsa` — which OpenSSH
/// has refused by default since 8.8 (2021), so it authenticates against almost
/// nothing. These types implement `rsa-sha2-512` and `rsa-sha2-256` instead,
/// over swift-crypto's `_RSA.Signing`.
///
/// ## The detail that makes RSA awkward
///
/// RFC 8332 separates two names that every other algorithm shares: the
/// *negotiated* algorithm (`rsa-sha2-512`) and the identifier *inside the key
/// blob*, which is always `ssh-rsa`. NIOSSH conflated them, so the vendored
/// fork gained `keyBlobPrefix` for exactly this. Writing `rsa-sha2-512` into
/// the blob produces something that looks right and that OpenSSH rejects.
///
/// Two key types exist rather than one because NIOSSH pairs one signature type
/// with one key type at registration. They differ only in which digest they
/// sign with; either can *verify* both, because the signature says which it is.
enum SSHRSA {
    /// Turns the components out of a key file into a signing key.
    static func privateKey(from components: OpenSSHPrivateKey.RSAComponents) throws -> _RSA.Signing.PrivateKey {
        try _RSA.Signing.PrivateKey(derRepresentation: Data(components.pkcs1DERRepresentation()))
    }

    /// Reads the `mpint e`, `mpint n` pair that follows `ssh-rsa` in a key blob.
    static func readPublicKey(from buffer: inout ByteBuffer) throws -> (key: _RSA.Signing.PublicKey, exponent: [UInt8], modulus: [UInt8]) {
        guard let exponent = buffer.readSSHMPInt(), let modulus = buffer.readSSHMPInt() else {
            throw SSHRSAError.malformedKeyBlob
        }
        // swift-crypto refuses anything under 1024 bits, which also rules out
        // the degenerate blobs a hostile server might send.
        let key = try _RSA.Signing.PublicKey(
            derRepresentation: Data(OpenSSHPrivateKey.RSAComponents.subjectPublicKeyInfo(
                modulus: modulus,
                publicExponent: exponent
            ))
        )
        return (key, exponent, modulus)
    }
}

enum SSHRSAError: Error, Equatable {
    case malformedKeyBlob
    case malformedSignature
    case signingFailed
}

/// Which SHA-2 digest an RSA signature uses. The whole difference between
/// `rsa-sha2-256` and `rsa-sha2-512`.
enum SSHRSADigest: String {
    case sha256 = "rsa-sha2-256"
    case sha512 = "rsa-sha2-512"

    func signature(for data: some DataProtocol, with key: _RSA.Signing.PrivateKey) throws -> _RSA.Signing.RSASignature {
        switch self {
        case .sha256:
            return try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
        case .sha512:
            return try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
        }
    }

    func isValid(_ signature: _RSA.Signing.RSASignature, for data: some DataProtocol, with key: _RSA.Signing.PublicKey) -> Bool {
        switch self {
        case .sha256:
            return key.isValidSignature(signature, for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
        case .sha512:
            return key.isValidSignature(signature, for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
        }
    }
}

// MARK: - Signatures

/// The shared body of both signature types. An SSH signature blob is just the
/// raw PKCS#1 v1.5 signature as an SSH string; the algorithm name lives in the
/// enclosing structure.
protocol SSHRSASignatureProtocol: NIOSSHSignatureProtocol {
    static var digest: SSHRSADigest { get }
    var bytes: [UInt8] { get }
    init(bytes: [UInt8])
}

extension SSHRSASignatureProtocol {
    var rawRepresentation: Data { Data(bytes) }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHStringBytes(bytes)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let value = buffer.readSSHStringBytes() else {
            throw SSHRSAError.malformedSignature
        }
        return Self(bytes: value)
    }
}

struct SSHRSASHA512Signature: SSHRSASignatureProtocol {
    static let signaturePrefix = SSHRSADigest.sha512.rawValue
    static let digest = SSHRSADigest.sha512
    var bytes: [UInt8]
    init(bytes: [UInt8]) { self.bytes = bytes }
}

struct SSHRSASHA256Signature: SSHRSASignatureProtocol {
    static let signaturePrefix = SSHRSADigest.sha256.rawValue
    static let digest = SSHRSADigest.sha256
    var bytes: [UInt8]
    init(bytes: [UInt8]) { self.bytes = bytes }
}

// MARK: - Public keys

/// The shared body of both public key types.
protocol SSHRSAPublicKeyProtocol: NIOSSHPublicKeyProtocol {
    var key: _RSA.Signing.PublicKey { get }
    var exponent: [UInt8] { get }
    var modulus: [UInt8] { get }
    init(key: _RSA.Signing.PublicKey, exponent: [UInt8], modulus: [UInt8])
}

extension SSHRSAPublicKeyProtocol {
    /// RFC 4253: the blob is `mpint e`, `mpint n` — exponent first, which is
    /// the reverse of the order the private blob uses.
    var rawRepresentation: Data {
        var buffer = ByteBufferAllocator().buffer(capacity: modulus.count + exponent.count + 16)
        buffer.writeSSHMPInt(exponent)
        buffer.writeSSHMPInt(modulus)
        return Data(buffer.readableBytesView)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        var written = buffer.writeSSHMPInt(exponent)
        written += buffer.writeSSHMPInt(modulus)
        return written
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        let parsed = try SSHRSA.readPublicKey(from: &buffer)
        return Self(key: parsed.key, exponent: parsed.exponent, modulus: parsed.modulus)
    }

    /// Verifies against whichever digest the *signature* says it used.
    ///
    /// This is why one key type can stand in for the other: an `ssh-rsa` blob
    /// off the wire is decoded by whichever type was registered first, and the
    /// server may then sign with either algorithm.
    func isValidSignature(_ signature: NIOSSHSignatureProtocol, for data: some DataProtocol) -> Bool {
        let digest: SSHRSADigest
        let bytes: [UInt8]

        switch signature {
        case let signature as SSHRSASHA512Signature:
            digest = SSHRSASHA512Signature.digest
            bytes = signature.bytes
        case let signature as SSHRSASHA256Signature:
            digest = SSHRSASHA256Signature.digest
            bytes = signature.bytes
        default:
            // Not an RSA signature at all.
            return false
        }

        guard let parsed = try? _RSA.Signing.RSASignature(rawRepresentation: Data(bytes)) else {
            return false
        }
        return digest.isValid(parsed, for: data, with: key)
    }
}

struct SSHRSASHA512PublicKey: SSHRSAPublicKeyProtocol {
    static let publicKeyPrefix = SSHRSADigest.sha512.rawValue
    /// Always `ssh-rsa`, whatever the negotiated name. RFC 8332 §3.
    static let keyBlobPrefix = "ssh-rsa"

    var key: _RSA.Signing.PublicKey
    var exponent: [UInt8]
    var modulus: [UInt8]

    init(key: _RSA.Signing.PublicKey, exponent: [UInt8], modulus: [UInt8]) {
        self.key = key
        self.exponent = exponent
        self.modulus = modulus
    }
}

struct SSHRSASHA256PublicKey: SSHRSAPublicKeyProtocol {
    static let publicKeyPrefix = SSHRSADigest.sha256.rawValue
    static let keyBlobPrefix = "ssh-rsa"

    var key: _RSA.Signing.PublicKey
    var exponent: [UInt8]
    var modulus: [UInt8]

    init(key: _RSA.Signing.PublicKey, exponent: [UInt8], modulus: [UInt8]) {
        self.key = key
        self.exponent = exponent
        self.modulus = modulus
    }
}

// MARK: - Private keys

/// The shared body of both private key types.
protocol SSHRSAPrivateKeyProtocol: NIOSSHPrivateKeyProtocol {
    associatedtype Signature: SSHRSASignatureProtocol
    associatedtype Public: SSHRSAPublicKeyProtocol

    var key: _RSA.Signing.PrivateKey { get }
    var exponent: [UInt8] { get }
    var modulus: [UInt8] { get }
}

extension SSHRSAPrivateKeyProtocol {
    var publicKey: NIOSSHPublicKeyProtocol {
        Public(key: key.publicKey, exponent: exponent, modulus: modulus)
    }

    func signature(for data: some DataProtocol) throws -> NIOSSHSignatureProtocol {
        do {
            let signature = try Signature.digest.signature(for: data, with: key)
            return Signature(bytes: Array(signature.rawRepresentation))
        } catch {
            throw SSHRSAError.signingFailed
        }
    }
}

struct SSHRSASHA512PrivateKey: SSHRSAPrivateKeyProtocol {
    typealias Signature = SSHRSASHA512Signature
    typealias Public = SSHRSASHA512PublicKey

    static let keyPrefix = SSHRSADigest.sha512.rawValue

    var key: _RSA.Signing.PrivateKey
    var exponent: [UInt8]
    var modulus: [UInt8]
}

struct SSHRSASHA256PrivateKey: SSHRSAPrivateKeyProtocol {
    typealias Signature = SSHRSASHA256Signature
    typealias Public = SSHRSASHA256PublicKey

    static let keyPrefix = SSHRSADigest.sha256.rawValue

    var key: _RSA.Signing.PrivateKey
    var exponent: [UInt8]
    var modulus: [UInt8]
}

// MARK: - Wire helpers

extension ByteBuffer {
    /// An SSH `mpint`, stripped of the sign padding the wire format adds.
    mutating func readSSHMPInt() -> [UInt8]? {
        guard let value = readSlice(length: Int(readInteger(as: UInt32.self) ?? 0)) else {
            return nil
        }
        var bytes = Array(value.readableBytesView)
        while bytes.first == 0 { bytes.removeFirst() }
        return bytes
    }

    @discardableResult
    mutating func writeSSHMPInt(_ magnitude: [UInt8]) -> Int {
        var value = magnitude
        while value.first == 0 { value.removeFirst() }

        if value.isEmpty {
            return writeInteger(UInt32(0))
        }
        // A leading zero keeps a value whose top bit is set from reading as
        // negative.
        if value[0] & 0x80 != 0 {
            value.insert(0, at: 0)
        }

        var written = writeInteger(UInt32(value.count))
        written += writeBytes(value)
        return written
    }
}

// MARK: - Wire helpers

/// NIOSSH has `writeSSHString`/`readSSHString` on `ByteBuffer`, but they are
/// `internal` to that module and this is a different one. The format is not
/// worth a dependency: a 32-bit big-endian length, then that many bytes.
private extension ByteBuffer {
    @discardableResult
    mutating func writeSSHStringBytes(_ bytes: [UInt8]) -> Int {
        var written = writeInteger(UInt32(bytes.count))
        written += writeBytes(bytes)
        return written
    }

    /// Reads one, or returns `nil` and leaves the reader index alone. A
    /// half-consumed buffer would be worse than no read at all: the caller
    /// would have no way to retry once the rest of the bytes arrive.
    mutating func readSSHStringBytes() -> [UInt8]? {
        guard let length = getInteger(at: readerIndex, as: UInt32.self),
              readableBytes >= MemoryLayout<UInt32>.size + Int(length)
        else {
            return nil
        }
        moveReaderIndex(forwardBy: MemoryLayout<UInt32>.size)
        return readBytes(length: Int(length))
    }
}
