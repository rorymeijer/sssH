import Foundation

/// Just enough DER to write the two structures an RSA key needs.
///
/// Not a general ASN.1 encoder: it writes definite-length INTEGERs, SEQUENCEs,
/// BIT STRINGs, NULL and pre-encoded OIDs, which is the whole of PKCS#1 and
/// SubjectPublicKeyInfo. Anything more belongs in a real ASN.1 library.
public enum DER {
    /// An `INTEGER` holding an unsigned big-endian magnitude.
    ///
    /// DER integers are signed two's complement, so a value whose top bit is
    /// set needs a leading zero byte or it reads as negative. Getting this
    /// wrong produces a key that parses and then computes the wrong answer.
    public static func integer(_ magnitude: [UInt8]) -> [UInt8] {
        var value = magnitude
        while value.count > 1, value.first == 0 {
            value.removeFirst()
        }
        if value.isEmpty || value == [0] {
            return [0x02, 0x01, 0x00]
        }
        if value[0] & 0x80 != 0 {
            value.insert(0, at: 0)
        }
        return [0x02] + length(value.count) + value
    }

    public static func integer(_ value: Int) -> [UInt8] {
        guard value != 0 else { return [0x02, 0x01, 0x00] }
        var magnitude: [UInt8] = []
        var remaining = value
        while remaining > 0 {
            magnitude.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        }
        return integer(magnitude)
    }

    public static func sequence(_ contents: [[UInt8]]) -> [UInt8] {
        let body = contents.flatMap { $0 }
        return [0x30] + length(body.count) + body
    }

    /// A `BIT STRING` wrapping whole bytes, so the "unused bits" prefix is 0.
    public static func bitString(_ contents: [UInt8]) -> [UInt8] {
        let body = [0x00] + contents
        return [0x03] + length(body.count) + body
    }

    public static let null: [UInt8] = [0x05, 0x00]

    /// `1.2.840.113549.1.1.1`, pre-encoded. The only OID sssh writes.
    public static let rsaEncryptionOID: [UInt8] = [
        0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
    ]

    /// DER's definite-length form: short for under 128, otherwise a count of
    /// length bytes followed by the length itself.
    public static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 {
            return [UInt8(count)]
        }

        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
