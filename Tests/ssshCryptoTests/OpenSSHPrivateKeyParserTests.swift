import Foundation
import XCTest
@testable import ssshCrypto

/// Round-trips real `openssh-key-v1` files back to the key material they were
/// built from. See ``OpenSSHKeyFixtures`` for where the ground truth comes
/// from.
final class OpenSSHPrivateKeyParserTests: XCTestCase {
    private let passphrase = OpenSSHKeyFixtures.passphrase

    private func hex(_ bytes: [UInt8]) -> String { OpenSSHKeyFixtures.hex(bytes) }

    // MARK: - Ed25519

    func testUnencryptedEd25519() throws {
        let key = try OpenSSHPrivateKeyParser.parse(armoredText: OpenSSHKeyFixtures.ed25519Plain)

        XCTAssertEqual(key.keyType, "ssh-ed25519")
        XCTAssertEqual(key.comment, "sssh@test")
        guard case .ed25519(let seed, let publicKey) = key.material else {
            return XCTFail("expected ed25519 material, got \(key.material)")
        }
        XCTAssertEqual(hex(seed), OpenSSHKeyFixtures.ed25519Plain_seed)
        XCTAssertEqual(hex(publicKey), OpenSSHKeyFixtures.ed25519Plain_public)
    }

    func testEncryptedEd25519() throws {
        let key = try OpenSSHPrivateKeyParser.parse(
            armoredText: OpenSSHKeyFixtures.ed25519Encrypted,
            passphrase: passphrase
        )

        guard case .ed25519(let seed, _) = key.material else {
            return XCTFail("expected ed25519 material")
        }
        // Same key pair as the unencrypted fixture, so decryption is proven by
        // the material matching rather than merely by parsing without error.
        XCTAssertEqual(hex(seed), OpenSSHKeyFixtures.ed25519Encrypted_seed)
        XCTAssertEqual(hex(seed), OpenSSHKeyFixtures.ed25519Plain_seed)
    }

    func testEncryptedWithAES128() throws {
        // `ssh-keygen -Z aes128-ctr`. The key length changes; the IV length
        // does not.
        let key = try OpenSSHPrivateKeyParser.parse(
            armoredText: OpenSSHKeyFixtures.ed25519EncryptedAES128,
            passphrase: passphrase
        )
        guard case .ed25519(let seed, _) = key.material else { return XCTFail("expected ed25519") }
        XCTAssertEqual(hex(seed), OpenSSHKeyFixtures.ed25519Plain_seed)
    }

    func testEncryptedWithMoreKDFRounds() throws {
        // `ssh-keygen -a 32`.
        let key = try OpenSSHPrivateKeyParser.parse(
            armoredText: OpenSSHKeyFixtures.ed25519EncryptedRounds32,
            passphrase: passphrase
        )
        guard case .ed25519(let seed, _) = key.material else { return XCTFail("expected ed25519") }
        XCTAssertEqual(hex(seed), OpenSSHKeyFixtures.ed25519Plain_seed)
    }

    // MARK: - RSA

    func testUnencryptedRSA() throws {
        let key = try OpenSSHPrivateKeyParser.parse(armoredText: OpenSSHKeyFixtures.rsaPlain)

        XCTAssertEqual(key.keyType, "ssh-rsa")
        guard case .rsa(let components) = key.material else {
            return XCTFail("expected RSA material, got \(key.material)")
        }
        // The private blob's field order is n, e, d, iqmp, p, q — not the
        // e, n of the public blob. Getting it wrong yields a key that parses
        // and then fails to authenticate, so each field is checked.
        XCTAssertEqual(hex(components.modulus), OpenSSHKeyFixtures.rsaPlain_modulus)
        XCTAssertEqual(hex(components.publicExponent), OpenSSHKeyFixtures.rsaPlain_publicExponent)
        XCTAssertEqual(hex(components.privateExponent), OpenSSHKeyFixtures.rsaPlain_privateExponent)
        XCTAssertEqual(hex(components.coefficient), OpenSSHKeyFixtures.rsaPlain_coefficient)
        XCTAssertEqual(hex(components.prime1), OpenSSHKeyFixtures.rsaPlain_prime1)
        XCTAssertEqual(hex(components.prime2), OpenSSHKeyFixtures.rsaPlain_prime2)
    }

    func testEncryptedRSA() throws {
        let key = try OpenSSHPrivateKeyParser.parse(
            armoredText: OpenSSHKeyFixtures.rsaEncrypted,
            passphrase: passphrase
        )
        guard case .rsa(let components) = key.material else { return XCTFail("expected RSA") }
        XCTAssertEqual(hex(components.modulus), OpenSSHKeyFixtures.rsaEncrypted_modulus)
        XCTAssertEqual(hex(components.prime1), OpenSSHKeyFixtures.rsaEncrypted_prime1)
    }

    // MARK: - ECDSA

    func testECDSACurves() throws {
        let cases: [(armored: String, type: String, scalar: String, publicKey: String, width: Int)] = [
            (OpenSSHKeyFixtures.ecdsap256Plain, "ecdsa-sha2-nistp256",
             OpenSSHKeyFixtures.ecdsap256Plain_scalar, OpenSSHKeyFixtures.ecdsap256Plain_public, 32),
            (OpenSSHKeyFixtures.ecdsap384Plain, "ecdsa-sha2-nistp384",
             OpenSSHKeyFixtures.ecdsap384Plain_scalar, OpenSSHKeyFixtures.ecdsap384Plain_public, 48),
            (OpenSSHKeyFixtures.ecdsap521Plain, "ecdsa-sha2-nistp521",
             OpenSSHKeyFixtures.ecdsap521Plain_scalar, OpenSSHKeyFixtures.ecdsap521Plain_public, 66),
        ]

        for testCase in cases {
            let key = try OpenSSHPrivateKeyParser.parse(armoredText: testCase.armored)
            XCTAssertEqual(key.keyType, testCase.type)

            let (scalar, publicKey): ([UInt8], [UInt8])
            switch key.material {
            case .ecdsaP256(let s, let p), .ecdsaP384(let s, let p), .ecdsaP521(let s, let p):
                (scalar, publicKey) = (s, p)
            default:
                XCTFail("expected ECDSA material for \(testCase.type)")
                continue
            }

            // The scalar is stored as an mpint, which drops leading zeros. A
            // curve scalar has a fixed width, so it must be padded back or
            // every library will reject it.
            XCTAssertEqual(scalar.count, testCase.width, "\(testCase.type) scalar width")
            XCTAssertEqual(hex(scalar), testCase.scalar)
            XCTAssertEqual(hex(publicKey), testCase.publicKey)
        }
    }

    func testEncryptedECDSA() throws {
        let key = try OpenSSHPrivateKeyParser.parse(
            armoredText: OpenSSHKeyFixtures.ecdsa256Encrypted,
            passphrase: passphrase
        )
        XCTAssertEqual(key.keyType, "ecdsa-sha2-nistp256")
        guard case .ecdsaP256(let scalar, _) = key.material else { return XCTFail("expected P-256") }
        XCTAssertEqual(scalar.count, 32)
    }

    // MARK: - Inspection

    func testInspectReadsTheHeaderWithoutAPassphrase() throws {
        let plain = try OpenSSHPrivateKeyParser.inspect(armoredText: OpenSSHKeyFixtures.ed25519Plain)
        XCTAssertEqual(plain, .init(keyType: "ssh-ed25519", cipherName: "none", kdfName: "none"))
        XCTAssertFalse(plain.isEncrypted)

        let encrypted = try OpenSSHPrivateKeyParser.inspect(armoredText: OpenSSHKeyFixtures.rsaEncrypted)
        XCTAssertEqual(encrypted.keyType, "ssh-rsa")
        XCTAssertTrue(encrypted.isEncrypted)
        XCTAssertEqual(encrypted.kdfName, "bcrypt")
    }

    // MARK: - Failures

    func testWrongPassphraseIsReportedAsSuch() {
        // There is no MAC in this format: the only signal is the pair of
        // matching check words. Reporting this as a generic parse failure would
        // send the user looking for a corrupt file.
        XCTAssertThrowsError(
            try OpenSSHPrivateKeyParser.parse(
                armoredText: OpenSSHKeyFixtures.ed25519Encrypted,
                passphrase: Array("definitely-not-it".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? OpenSSHPrivateKeyParser.Failure, .incorrectPassphrase)
        }
    }

    func testMissingPassphraseIsReportedAsSuch() {
        XCTAssertThrowsError(
            try OpenSSHPrivateKeyParser.parse(armoredText: OpenSSHKeyFixtures.ed25519Encrypted)
        ) { error in
            XCTAssertEqual(error as? OpenSSHPrivateKeyParser.Failure, .passphraseRequired)
        }
    }

    func testNonOpenSSHInputIsRejectedDistinctly() {
        // A PEM key is a plausible thing for a user to have, and the caller
        // wants to try other parsers rather than report an error.
        XCTAssertThrowsError(
            try OpenSSHPrivateKeyParser.parse(armoredText: "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----")
        ) { error in
            XCTAssertEqual(error as? OpenSSHPrivateKeyParser.Failure, .notOpenSSHFormat)
        }
        XCTAssertFalse(OpenSSHPrivateKeyParser.isOpenSSHFormat("hello"))
        XCTAssertTrue(OpenSSHPrivateKeyParser.isOpenSSHFormat(OpenSSHKeyFixtures.ed25519Plain))
    }

    func testTruncatedAndCorruptInput() {
        let truncated = String(OpenSSHKeyFixtures.ed25519Plain.dropLast(120)) + "\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertThrowsError(try OpenSSHPrivateKeyParser.parse(armoredText: truncated))

        let notBase64 = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        !!!! not base64 !!!!
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertThrowsError(try OpenSSHPrivateKeyParser.parse(armoredText: notBase64))

        let empty = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertThrowsError(try OpenSSHPrivateKeyParser.parse(armoredText: empty))
    }

    func testToleratesCRLFAndSurroundingNoise() throws {
        // Keys arrive pasted out of editors and chat clients.
        let messy = "junk before\n"
            + OpenSSHKeyFixtures.ed25519Plain.replacingOccurrences(of: "\n", with: "\r\n")
            + "\r\n\r\njunk after\n"

        let key = try OpenSSHPrivateKeyParser.parse(armoredText: messy)
        guard case .ed25519(let seed, _) = key.material else { return XCTFail("expected ed25519") }
        XCTAssertEqual(hex(seed), OpenSSHKeyFixtures.ed25519Plain_seed)
    }

    func testPublicKeyBlobIsPreserved() throws {
        // What goes into an authorized_keys line, so key generation and export
        // can round-trip without re-deriving the public half.
        let key = try OpenSSHPrivateKeyParser.parse(armoredText: OpenSSHKeyFixtures.ed25519Plain)
        var reader = SSHWireReader(key.publicKeyBlob)
        XCTAssertEqual(reader.readStringAsText(), "ssh-ed25519")
        XCTAssertEqual(reader.readString().map(hex), OpenSSHKeyFixtures.ed25519Plain_public)
    }
}
