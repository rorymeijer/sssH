import Foundation

/// Builds `openssh-key-v1` files for tests.
///
/// Assembled from the format's own rules rather than captured from
/// `ssh-keygen`, so it exercises the reader's handling of the encoding.
/// Compatibility with real `ssh-keygen` output is covered by the
/// integration run — see Integration/README.md.
enum OpenSSHKeyFixture {
    static func sshString(_ bytes: [UInt8]) -> [UInt8] {
        let length = UInt32(bytes.count)
        return [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ] + bytes
    }

    static func sshString(_ string: String) -> [UInt8] {
        sshString(Array(string.utf8))
    }

    static func uint32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }

    /// `openssh-key-v1` header plus one public key, which is all the
    /// inspector reads. The encrypted private section is represented by an
    /// opaque string, as it would be in a real file.
    static func blob(
        keyType: String,
        cipher: String = "none",
        kdf: String = "none",
        keyCount: UInt32 = 1
    ) -> [UInt8] {
        var bytes = Array("openssh-key-v1\0".utf8)
        bytes += sshString(cipher)
        bytes += sshString(kdf)
        bytes += sshString([])                                  // kdf options
        bytes += uint32(keyCount)
        bytes += sshString(sshString(keyType) + sshString([UInt8](repeating: 7, count: 32)))
        bytes += sshString([UInt8](repeating: 0, count: 64))     // private section
        return bytes
    }

    static func armored(keyType: String, cipher: String = "none", kdf: String = "none") -> String {
        armor(base64: Data(blob(keyType: keyType, cipher: cipher, kdf: kdf)).base64EncodedString())
    }

    static func armor(base64: String) -> String {
        // Real files wrap at 70 columns; wrapping here keeps the fixture
        // shaped like the thing users actually paste in.
        let wrapped = stride(from: 0, to: base64.count, by: 70).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(70, base64.count - offset))
            return String(base64[start..<end])
        }.joined(separator: "\n")

        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(wrapped)
        -----END OPENSSH PRIVATE KEY-----
        """
    }
}
