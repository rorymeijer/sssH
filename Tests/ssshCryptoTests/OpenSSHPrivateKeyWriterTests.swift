import XCTest
@testable import ssshCrypto

/// Written against `ssh-keygen`'s own output, not against this package's
/// parser. A round-trip through our own reader would pass just as happily with
/// two fields swapped; byte-for-byte equality with the tool everyone else uses
/// will not.
final class OpenSSHPrivateKeyWriterTests: XCTestCase {
    private var ed25519Key: OpenSSHPrivateKey {
        OpenSSHPrivateKey(
            material: .ed25519(
                seed: GeneratedKeyFixtures.ed25519Seed,
                publicKey: GeneratedKeyFixtures.ed25519PublicKey
            ),
            comment: GeneratedKeyFixtures.ed25519Comment
        )
    }

    private var rsaKey: OpenSSHPrivateKey {
        OpenSSHPrivateKey(
            material: .rsa(OpenSSHPrivateKey.RSAComponents(
                modulus: GeneratedKeyFixtures.rsaModulus,
                publicExponent: GeneratedKeyFixtures.rsaPublicExponent,
                privateExponent: GeneratedKeyFixtures.rsaPrivateExponent,
                coefficient: GeneratedKeyFixtures.rsaCoefficient,
                prime1: GeneratedKeyFixtures.rsaPrime1,
                prime2: GeneratedKeyFixtures.rsaPrime2
            )),
            comment: GeneratedKeyFixtures.rsaComment
        )
    }

    // MARK: - Byte-for-byte

    func testEd25519MatchesSSHKeygenExactly() throws {
        let written = try OpenSSHPrivateKeyWriter.armoredText(
            for: ed25519Key,
            checkInt: GeneratedKeyFixtures.ed25519CheckInt
        )
        XCTAssertEqual(written, GeneratedKeyFixtures.ed25519Plain)
    }

    func testRSAMatchesSSHKeygenExactly() throws {
        let written = try OpenSSHPrivateKeyWriter.armoredText(
            for: rsaKey,
            checkInt: GeneratedKeyFixtures.rsaCheckInt
        )
        XCTAssertEqual(written, GeneratedKeyFixtures.rsaPlain)
    }

    /// The ciphertext comes from an independent bcrypt_pbkdf and AES-CTR, so
    /// matching it re-checks this package's own versions of both — and
    /// `ssh-keygen -y -P hunter2` reads the same bytes.
    func testEncryptedEd25519MatchesTheReferenceCiphertext() throws {
        let written = try OpenSSHPrivateKeyWriter.armoredText(
            for: ed25519Key,
            encryption: .init(
                passphrase: Array("hunter2".utf8),
                rounds: 16,
                salt: Array(0..<16).map(UInt8.init)
            ),
            checkInt: GeneratedKeyFixtures.ed25519CheckInt
        )
        XCTAssertEqual(written, GeneratedKeyFixtures.ed25519Encrypted)
    }

    // MARK: - Public halves

    func testAuthorizedKeysLines() throws {
        XCTAssertEqual(
            try OpenSSHPrivateKeyWriter.authorizedKeysLine(for: ed25519Key),
            GeneratedKeyFixtures.ed25519PublicLine
        )
        XCTAssertEqual(
            try OpenSSHPrivateKeyWriter.authorizedKeysLine(for: rsaKey),
            GeneratedKeyFixtures.rsaPublicLine
        )
    }

    func testAuthorizedKeysLineWithoutACommentHasNoTrailingSpace() throws {
        let key = OpenSSHPrivateKey(
            material: .ed25519(
                seed: GeneratedKeyFixtures.ed25519Seed,
                publicKey: GeneratedKeyFixtures.ed25519PublicKey
            ),
            comment: "  "
        )
        let line = try OpenSSHPrivateKeyWriter.authorizedKeysLine(for: key)
        XCTAssertFalse(line.hasSuffix(" "))
        XCTAssertEqual(line.split(separator: " ").count, 2)
    }

    // MARK: - Round trips through the parser

    func testWrittenKeysParseBack() throws {
        for key in [ed25519Key, rsaKey] {
            let text = try OpenSSHPrivateKeyWriter.armoredText(for: key)
            let parsed = try OpenSSHPrivateKeyParser.parse(armoredText: text)
            XCTAssertEqual(parsed.comment, key.comment)
            XCTAssertEqual(parsed.keyType, key.keyType)
            XCTAssertEqual(parsed.publicKeyBlob, key.publicKeyBlob)
        }
    }

    func testEncryptedKeyRoundTripsWithItsPassphrase() throws {
        let text = try OpenSSHPrivateKeyWriter.armoredText(
            for: ed25519Key,
            encryption: .init(passphrase: Array("correct horse".utf8), rounds: 4)
        )
        let parsed = try OpenSSHPrivateKeyParser.parse(
            armoredText: text,
            passphrase: Array("correct horse".utf8)
        )
        guard case .ed25519(let seed, let publicKey) = parsed.material else {
            return XCTFail("expected an Ed25519 key")
        }
        XCTAssertEqual(seed, GeneratedKeyFixtures.ed25519Seed)
        XCTAssertEqual(publicKey, GeneratedKeyFixtures.ed25519PublicKey)

        XCTAssertThrowsError(try OpenSSHPrivateKeyParser.parse(
            armoredText: text,
            passphrase: Array("wrong".utf8)
        ))
    }

    func testEncryptedHeaderIsAdvertisedBeforeDecryption() throws {
        let text = try OpenSSHPrivateKeyWriter.armoredText(
            for: ed25519Key,
            encryption: .init(passphrase: Array("x".utf8), rounds: 4)
        )
        let header = try OpenSSHPrivateKeyParser.inspect(armoredText: text)
        XCTAssertTrue(header.isEncrypted)
        XCTAssertEqual(header.cipherName, "aes256-ctr")
        XCTAssertEqual(header.kdfName, "bcrypt")
        XCTAssertEqual(header.keyType, "ssh-ed25519")
    }

    // MARK: - Shape

    /// `ssh-keygen` checks the padding bytes and refuses anything else. Zeros
    /// are the obvious guess and are wrong.
    func testPrivateSectionIsPaddedWithAscendingBytes() throws {
        let container = try OpenSSHPrivateKeyWriter.container(
            for: ed25519Key,
            encryption: nil,
            checkInt: 1
        )
        var reader = SSHWireReader(Array(container.dropFirst(15)))
        _ = reader.readString() // cipher
        _ = reader.readString() // kdf
        _ = reader.readString() // kdf options
        _ = reader.readUInt32() // key count
        _ = reader.readString() // public blob
        let privateSection = try XCTUnwrap(reader.readString())

        XCTAssertEqual(privateSection.count % 8, 0, "the `none` cipher's block size is 8, not 16")
        var privateReader = SSHWireReader(privateSection)
        _ = privateReader.readUInt32() // first check integer
        _ = privateReader.readUInt32() // repeated check integer
        _ = privateReader.readString() // key type
        _ = privateReader.readString() // public key
        _ = privateReader.readString() // private key
        _ = privateReader.readString() // comment

        let padding = privateReader.readAllRemaining()
        let expectedPadding = (0..<padding.count).map { UInt8($0 + 1) }
        XCTAssertEqual(padding, expectedPadding)
    }

    func testMalformedMaterialIsRejected() {
        let short = OpenSSHPrivateKey(
            material: .ed25519(seed: [1, 2, 3], publicKey: GeneratedKeyFixtures.ed25519PublicKey),
            comment: "bad"
        )
        XCTAssertThrowsError(try OpenSSHPrivateKeyWriter.armoredText(for: short))
    }
}
