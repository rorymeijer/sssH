import BigInt
import XCTest
@testable import ssshCrypto

/// The DER reader exists for one job: taking apart the PKCS#1 `RSAPrivateKey`
/// that key generation hands back. This fixture is a real 2048-bit key from
/// `openssl genrsa -traditional`, and the assertions are the arithmetic
/// relations that make an RSA key an RSA key — so a parse that silently swaps
/// two fields fails, which a byte comparison against itself would not.
final class DERReaderTests: XCTestCase {
    private static let pkcs1DER = hexBytes(
            "308204a40201000282010100f2f26aca481e6f1cedda8ddd6b9ce75fa0098382" +
            "f791415b73d79176732033c8ba91d96057d7623408315b84796927500f6a2bc5" +
            "07474274f3e21198763822d3c1015f70c3c54136f745a1ce3046e7c58bcedb02" +
            "59feb5760a7558e6f525439ada6a04dbd77387597f8a499a2bbda9ad1f6ec69e" +
            "5b268ce09277af37727aa2ab6de5a3884525eb1c570def0f7280e4bd01e834ed" +
            "4c709e1484df24fa220ad77be8c1dfc7e20cf924a5b79688fb8233526d587319" +
            "77e1003ebd979b27cd9db9a52f2c1e8adc0a78068a2be85014a89fbd4a9b5521" +
            "937cfc89470744e37568b6ff3a0c7a3710eeaf40951705cae5fc87b27a88aad1" +
            "0a7d80ed8cfae994a0c43b2b0203010001028201000a341d4116ab548e59fd0a" +
            "6548ce43b773f0c259bf4d15fa21d0e5769c9a372290976c924bce2b7d34f4e1" +
            "bb9c1fcafb655257b944377d768d01ab2c849691fbe3c8cb79e07709e8a59502" +
            "9936d4db8a23f791a2352669f7a5b3cd02923c38ed298c375d065cff4bc67c07" +
            "e05642f67be36c9321f681157c9f1a30bd3aed24a4ca9a5c8ec338a7d9774d4e" +
            "7ad00f000f45004c33b3217113a3c5045345ac3d055572512d299a9012aa0a90" +
            "973d86c821c60deb3a2e3d35db5509feb5a8d148db3728318441d3769e25098b" +
            "59ee15b94a29b3a3369e1797a47f24f1c75b9a898d102b49aef8c360fd6b2a7c" +
            "9abc3a64d29a62d516a5e6326292f3ab6c5efd1c0d02818100fe93709feb690f" +
            "be2d262ecacbe3db9448204ae79948b6c9c8a637598f2a45ffb55e950af64c7f" +
            "b1d5ae78fa7a8da95ad183b2e363af4655d15d241e0ec71d20e07c883bedacce" +
            "d4849db2c91d349441e24d644a4e2550a1dc5a9ba1afc0b53d7f4e1462c073a7" +
            "52d334075e98fdbc8100bd5805141956e63e360abf4c549d5f02818100f44e52" +
            "fbb7671934ab348c5022309451690b8eb0b524716617e97df23bc699fd106747" +
            "9fc8aae168924211cf39a9eedfbc39d2921c9f17bfd2da8d6448dd6e62bb17e0" +
            "abe7d5bcc3604fe7bad2d74b576a2ee2729c0d26cdb86301dd26706bd237b62e" +
            "2ffa23595400dc5d805bf511e0ddc835c7d32802560d809d8a00bb69b5028181" +
            "00d1930f6497a8260da99d8567edf1e7126b4e2a5bff149d660088d5882513e8" +
            "0c5a8342af8393f68bb01db1fa82699cc1e739444b6e051d2208f964825a2811" +
            "12bfbbc56b907e72c70165d1893f41c9cb7341c30e68c6cf5a70cd26d2349db0" +
            "96aff6d751749dc161adfd6713b95f299009cbd66a57e18468874e760a860c22" +
            "8102818100c5a63c52b37d709200d4e193cf25584948dff5d016ace6257fc102" +
            "89203d3bc5d6288874c7e71fb7f764067e8d9b62cb95bf7e1181a060996ba02f" +
            "75ebd16185f4f18b6de8812e572eab56c1f9e3fe6b3957b7129c17b3c6099fe8" +
            "19200921e20ffa8f0177b0738b97aab0e6b0fee338f6950c959ecaa6a1320954" +
            "eb1a4e856502818042cc0c1abe9d3065cbd7a74a1e2d8a23d61849dd00e81123" +
            "ed3e52d33b8d3972a7d28d447baa91a8fa038064256b3523de23a57141659fb4" +
            "1803291d077e41d3e4cf7d9eee57e892e81e96dafcf71b39192640d630e6bbf1" +
            "187ecdaf150b316da4679ce0f88e16c322d16c0aa30a1cda1db0410165c44699" +
            "e9e899cc2ffc5240"
        )

    private static func hexBytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    private func number(_ bytes: [UInt8]) -> BigUInt {
        BigUInt(Data(bytes))
    }

    func testReadsAGeneratedRSAKey() throws {
        let components = try OpenSSHPrivateKey.RSAComponents.fromPKCS1DER(Self.pkcs1DER)

        let n = number(components.modulus)
        let e = number(components.publicExponent)
        let d = number(components.privateExponent)
        let p = number(components.prime1)
        let q = number(components.prime2)
        let iqmp = number(components.coefficient)

        // 2048 bits with the top bit set is 256 bytes of magnitude, and the
        // reader strips DER's sign byte — so anything else means it did not.
        XCTAssertEqual(components.modulus.count, 256)
        XCTAssertNotEqual(components.modulus.first, 0)
        XCTAssertEqual(e, 65_537)
        // The three relations that hold for every RSA key and for no mistaken
        // reading of one.
        XCTAssertEqual(p * q, n)
        let greatestCommonDivisor = (p - 1).greatestCommonDivisor(with: q - 1)
        XCTAssertEqual((e * d) % ((p - 1) * (q - 1) / greatestCommonDivisor), 1)
        XCTAssertEqual((iqmp * q) % p, 1)
    }

    /// The round trip the app actually performs: generation hands back PKCS#1,
    /// the key is written as `openssh-key-v1`, and it has to come back the
    /// same.
    func testRoundTripsThroughTheOpenSSHWriter() throws {
        let components = try OpenSSHPrivateKey.RSAComponents.fromPKCS1DER(Self.pkcs1DER)
        let key = OpenSSHPrivateKey(material: .rsa(components), comment: "generated@test")

        let text = try OpenSSHPrivateKeyWriter.armoredText(for: key)
        let parsed = try OpenSSHPrivateKeyParser.parse(armoredText: text)

        guard case .rsa(let readBack) = parsed.material else {
            return XCTFail("expected an RSA key")
        }
        XCTAssertEqual(number(readBack.modulus), number(components.modulus))
        XCTAssertEqual(number(readBack.privateExponent), number(components.privateExponent))
        XCTAssertEqual(number(readBack.prime1), number(components.prime1))
        XCTAssertEqual(number(readBack.prime2), number(components.prime2))
        XCTAssertEqual(number(readBack.coefficient), number(components.coefficient))
        XCTAssertEqual(parsed.comment, "generated@test")
    }

    /// And back out to PKCS#1, which is what signing needs — the CRT exponents
    /// OpenSSH does not store have to be derived correctly for this to hold.
    func testDerivesTheCRTExponentsBackOut() throws {
        let components = try OpenSSHPrivateKey.RSAComponents.fromPKCS1DER(Self.pkcs1DER)
        let rewritten = try components.pkcs1DERRepresentation()
        let reread = try OpenSSHPrivateKey.RSAComponents.fromPKCS1DER(rewritten)
        XCTAssertEqual(number(reread.modulus), number(components.modulus))
        XCTAssertEqual(number(reread.coefficient), number(components.coefficient))
    }

    // MARK: - Malformed input

    func testRejectsTruncatedInput() {
        var reader = DERReader(Array(Self.pkcs1DER.prefix(8)))
        XCTAssertThrowsError(try {
            var sequence = try reader.readSequence()
            _ = try sequence.readInteger()
        }())
    }

    /// A length field is an allocation primitive if it is believed. Five
    /// length bytes is 2^40, and nothing this parser reads is that big.
    func testRejectsAnOverlongLengthField() {
        var reader = DERReader([0x30, 0x85, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try reader.readSequence()) { error in
            XCTAssertEqual(error as? DERReader.Failure, .invalidLength)
        }
    }

    func testRejectsALengthThatRunsPastTheEnd() {
        var reader = DERReader([0x30, 0x7F, 0x01, 0x02])
        XCTAssertThrowsError(try reader.readSequence()) { error in
            XCTAssertEqual(error as? DERReader.Failure, .truncated)
        }
    }

    func testRejectsTheWrongTag() {
        var reader = DERReader([0x02, 0x01, 0x00])
        XCTAssertThrowsError(try reader.readSequence()) { error in
            XCTAssertEqual(error as? DERReader.Failure, .unexpectedTag(0x02, expected: 0x30))
        }
    }

    /// No RSA component is negative, so a high bit with no sign byte in front
    /// of it means the input is not what it says it is.
    func testRejectsANegativeInteger() {
        var reader = DERReader([0x02, 0x01, 0x80])
        XCTAssertThrowsError(try reader.readInteger()) { error in
            XCTAssertEqual(error as? DERReader.Failure, .negativeInteger)
        }
    }
}
