import Foundation

/// Reads the unencrypted header of an `openssh-key-v1` file.
///
/// The header is plaintext even for an encrypted key, which lets us answer two
/// questions before attempting a parse: which algorithm the key uses, and
/// whether a passphrase is needed. That turns "could not load key" into
/// "this key needs a passphrase" or "sssh cannot read ECDSA key files yet" —
/// the difference between a dead end and an actionable message.
struct OpenSSHKeyInspector {
    /// e.g. `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`.
    let keyType: String
    /// `none` for an unencrypted key.
    let cipherName: String
    /// `none` or `bcrypt`.
    let kdfName: String

    var isEncrypted: Bool { cipherName != "none" }

    private static let magic = Array("openssh-key-v1\0".utf8)
    private static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let endMarker = "-----END OPENSSH PRIVATE KEY-----"

    static func isOpenSSHFormat(_ text: String) -> Bool {
        text.contains(beginMarker)
    }

    /// - Returns: `nil` when the text is not a well-formed `openssh-key-v1`
    ///   file. A `nil` here means "malformed", not "unsupported".
    init?(armoredText text: String) {
        guard let body = Self.base64Body(of: text), let blob = Data(base64Encoded: body) else { return nil }

        var reader = ByteReader(Array(blob))
        guard let magic = reader.take(Self.magic.count), Array(magic) == Self.magic else { return nil }
        guard let cipher = reader.takeSSHString(),
              let kdf = reader.takeSSHString(),
              reader.takeSSHString() != nil,          // kdf options
              let keyCount = reader.takeUInt32(), keyCount >= 1,
              let publicKeyBlob = reader.takeSSHString()
        else { return nil }

        var publicKeyReader = ByteReader(Array(publicKeyBlob))
        guard let keyType = publicKeyReader.takeSSHString() else { return nil }

        self.keyType = String(decoding: keyType, as: UTF8.self)
        self.cipherName = String(decoding: cipher, as: UTF8.self)
        self.kdfName = String(decoding: kdf, as: UTF8.self)
    }

    /// Strips the PEM armor and all whitespace, tolerating CRLF line endings
    /// and files that were pasted with trailing blank lines.
    private static func base64Body(of text: String) -> String? {
        guard let begin = text.range(of: beginMarker), let end = text.range(of: endMarker), begin.upperBound <= end.lowerBound else {
            return nil
        }
        let body = text[begin.upperBound..<end.lowerBound]
        let compacted = body.filter { !$0.isWhitespace }
        return compacted.isEmpty ? nil : compacted
    }
}

/// A minimal forward-only reader for SSH wire encoding.
private struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    mutating func takeUInt32() -> UInt32? {
        guard let slice = take(4) else { return nil }
        return slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// An SSH string: a 32-bit big-endian length followed by that many bytes.
    mutating func takeSSHString() -> ArraySlice<UInt8>? {
        guard let length = takeUInt32() else { return nil }
        // Guard against a length field from a corrupt file asking us to read
        // gigabytes.
        guard length <= UInt32(bytes.count) else { return nil }
        return take(Int(length))
    }
}
