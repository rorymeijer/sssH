import Foundation
import XCTest
@testable import ssshCrypto

/// The DER that turns an OpenSSH RSA key into something a crypto library will
/// sign with.
///
/// The strong assertion is `testPKCS1DERIsByteIdenticalToOpenSSL`: the same key
/// encoded by `openssl rsa -traditional -outform DER` is in the fixtures, and
/// this must reproduce it exactly. Anything less — "openssl accepts it" — would
/// pass for an encoding that merely happens to parse.
final class RSAKeyEncodingTests: XCTestCase {
    private func components() throws -> OpenSSHPrivateKey.RSAComponents {
        let key = try OpenSSHPrivateKeyParser.parse(armoredText: OpenSSHKeyFixtures.rsaPlain)
        guard case .rsa(let components) = key.material else {
            throw XCTSkip("fixture is not an RSA key")
        }
        return components
    }

    func testPKCS1DERIsByteIdenticalToOpenSSL() throws {
        let der = try components().pkcs1DERRepresentation()
        XCTAssertEqual(OpenSSHKeyFixtures.hex(der), OpenSSHKeyFixtures.rsaPlainPKCS1DER)
    }

    /// OpenSSH stores neither CRT exponent, so both are derived. A wrong one
    /// produces a key that loads and then signs incorrectly — which is exactly
    /// the kind of bug a byte-for-byte comparison catches and a "does it parse"
    /// check does not.
    func testCRTExponentsAreDerived() throws {
        let der = try components().pkcs1DERRepresentation()

        // Nine INTEGERs: version, n, e, d, p, q, dP, dQ, qInv.
        var reader = DERTestReader(der)
        let sequence = try XCTUnwrap(reader.readTLV())
        XCTAssertEqual(sequence.tag, 0x30)

        var body = DERTestReader(sequence.value)
        var integers: [[UInt8]] = []
        while let element = body.readTLV() {
            XCTAssertEqual(element.tag, 0x02)
            integers.append(element.value)
        }
        XCTAssertEqual(integers.count, 9)
        XCTAssertEqual(integers[0], [0x00], "version must be 0 for a two-prime key")
    }

    func testSubjectPublicKeyInfoIsWellFormed() throws {
        let spki = try components().subjectPublicKeyInfoDERRepresentation()

        // swift-crypto reads RSA_PUBKEY, which is SubjectPublicKeyInfo, not a
        // bare PKCS#1 RSAPublicKey. Handing it the latter fails at load.
        var reader = DERTestReader(spki)
        let outer = try XCTUnwrap(reader.readTLV())
        XCTAssertEqual(outer.tag, 0x30)

        var body = DERTestReader(outer.value)
        let algorithm = try XCTUnwrap(body.readTLV())
        XCTAssertEqual(algorithm.tag, 0x30)
        XCTAssertTrue(algorithm.value.starts(with: DER.rsaEncryptionOID))

        let bitString = try XCTUnwrap(body.readTLV())
        XCTAssertEqual(bitString.tag, 0x03)
        XCTAssertEqual(bitString.value.first, 0x00, "whole bytes, so no unused bits")
    }

    // MARK: - DER primitives

    func testIntegerSignPadding() {
        // A magnitude whose top bit is set needs a leading zero or DER reads it
        // as negative — which silently produces the wrong number.
        XCTAssertEqual(DER.integer([0x80, 0x01]), [0x02, 0x03, 0x00, 0x80, 0x01])
        XCTAssertEqual(DER.integer([0x7F]), [0x02, 0x01, 0x7F])
    }

    func testIntegerStripsLeadingZeros() {
        XCTAssertEqual(DER.integer([0x00, 0x00, 0x7F]), [0x02, 0x01, 0x7F])
        XCTAssertEqual(DER.integer([]), [0x02, 0x01, 0x00])
        XCTAssertEqual(DER.integer([0x00]), [0x02, 0x01, 0x00])
    }

    func testLengthEncoding() {
        XCTAssertEqual(DER.length(0), [0x00])
        XCTAssertEqual(DER.length(127), [0x7F])
        // 128 crosses into the long form.
        XCTAssertEqual(DER.length(128), [0x81, 0x80])
        XCTAssertEqual(DER.length(300), [0x82, 0x01, 0x2C])
        XCTAssertEqual(DER.length(65_536), [0x83, 0x01, 0x00, 0x00])
    }

    func testSmallIntegers() {
        XCTAssertEqual(DER.integer(0), [0x02, 0x01, 0x00])
        XCTAssertEqual(DER.integer(1), [0x02, 0x01, 0x01])
        XCTAssertEqual(DER.integer(255), [0x02, 0x02, 0x00, 0xFF])
    }

    func testRejectsDegeneratePrimes() {
        var components = OpenSSHPrivateKey.RSAComponents(
            modulus: [1], publicExponent: [1], privateExponent: [1],
            coefficient: [1], prime1: [1], prime2: [1]
        )
        // p = 1 makes `d mod (p-1)` a division by zero. A corrupt key file
        // should not reach the arithmetic.
        XCTAssertThrowsError(try components.pkcs1DERRepresentation())

        components.prime1 = [0]
        XCTAssertThrowsError(try components.pkcs1DERRepresentation())
    }
}

/// A tiny DER reader, for assertions only.
private struct DERTestReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func readTLV() -> (tag: UInt8, value: [UInt8])? {
        guard offset < bytes.count else { return nil }
        let tag = bytes[offset]
        offset += 1

        guard offset < bytes.count else { return nil }
        var length = Int(bytes[offset])
        offset += 1

        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard offset + count <= bytes.count else { return nil }
            length = bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | Int($1) }
            offset += count
        }

        guard offset + length <= bytes.count else { return nil }
        let value = Array(bytes[offset..<(offset + length)])
        offset += length
        return (tag, value)
    }
}
