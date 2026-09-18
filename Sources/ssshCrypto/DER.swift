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

/// Reading DER, which this module needs in exactly one place: taking apart the
/// PKCS#1 `RSAPrivateKey` that swift-crypto hands back from key generation.
///
/// Deliberately minimal. A general DER parser is a large attack surface, and
/// the only input here is a structure this process just produced — so it reads
/// the two shapes it needs and refuses everything else, rather than being a
/// parser for a format it does not otherwise use.
public struct DERReader {
    private let bytes: [UInt8]
    private var offset: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    public enum Failure: Error, Equatable {
        case truncated
        case unexpectedTag(UInt8, expected: UInt8)
        /// A length in the long form with more than four bytes, or a length
        /// that runs past the end. Both mean the input is not what it claims.
        case invalidLength
        case negativeInteger
    }

    public var isAtEnd: Bool { offset >= bytes.count }

    /// Enters a SEQUENCE and returns a reader over its contents.
    public mutating func readSequence() throws -> DERReader {
        DERReader(try readValue(tag: 0x30))
    }

    /// An INTEGER as an unsigned big-endian magnitude, with DER's sign byte
    /// removed.
    public mutating func readInteger() throws -> [UInt8] {
        var value = try readValue(tag: 0x02)
        guard let first = value.first else { return [] }
        // A leading 0x00 is DER saying "this is positive"; a leading bit set
        // without it would be a negative number, which no key component is.
        if first == 0x00 {
            value.removeFirst()
        } else if first & 0x80 != 0 {
            throw Failure.negativeInteger
        }
        return value
    }

    private mutating func readValue(tag expected: UInt8) throws -> [UInt8] {
        guard offset < bytes.count else { throw Failure.truncated }
        let tag = bytes[offset]
        guard tag == expected else { throw Failure.unexpectedTag(tag, expected: expected) }
        offset += 1

        let length = try readLength()
        guard offset + length <= bytes.count else { throw Failure.truncated }
        let value = Array(bytes[offset..<(offset + length)])
        offset += length
        return value
    }

    private mutating func readLength() throws -> Int {
        guard offset < bytes.count else { throw Failure.truncated }
        let first = bytes[offset]
        offset += 1

        // Short form: the length is the byte.
        guard first & 0x80 != 0 else { return Int(first) }

        let count = Int(first & 0x7F)
        // Four bytes is 4 GB, which is already far past anything this parser
        // will ever be handed; more than that is a length field being used as
        // an allocation primitive.
        guard count >= 1, count <= 4, offset + count <= bytes.count else { throw Failure.invalidLength }

        var length = 0
        for _ in 0..<count {
            length = length << 8 | Int(bytes[offset])
            offset += 1
        }
        guard length >= 0, offset + length <= bytes.count else { throw Failure.invalidLength }
        return length
    }
}

public extension OpenSSHPrivateKey.RSAComponents {
    /// Reads a PKCS#1 `RSAPrivateKey`, keeping the six values OpenSSH stores
    /// and dropping `dP` and `dQ`, which it derives when it needs them.
    static func fromPKCS1DER(_ der: [UInt8]) throws -> OpenSSHPrivateKey.RSAComponents {
        var outer = DERReader(der)
        var sequence = try outer.readSequence()

        _ = try sequence.readInteger()                    // version
        let modulus = try sequence.readInteger()
        let publicExponent = try sequence.readInteger()
        let privateExponent = try sequence.readInteger()
        let prime1 = try sequence.readInteger()
        let prime2 = try sequence.readInteger()
        _ = try sequence.readInteger()                    // dP, derivable
        _ = try sequence.readInteger()                    // dQ, derivable
        let coefficient = try sequence.readInteger()

        return OpenSSHPrivateKey.RSAComponents(
            modulus: modulus,
            publicExponent: publicExponent,
            privateExponent: privateExponent,
            coefficient: coefficient,
            prime1: prime1,
            prime2: prime2
        )
    }
}
