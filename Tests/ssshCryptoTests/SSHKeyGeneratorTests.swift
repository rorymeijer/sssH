import XCTest
@testable import ssshCrypto

/// Generated keys have to be real keys, in the format everything else reads.
/// The writer's own tests pin the bytes against `ssh-keygen`; these check that
/// what generation produces is well-formed and internally consistent.
final class SSHKeyGeneratorTests: XCTestCase {
    func testGeneratesAnEd25519KeyThatRoundTrips() throws {
        let generated = try SSHKeyGenerator.generate(kind: .ed25519, comment: "rory@laptop")

        guard case .ed25519(let seed, let publicKey) = generated.privateKey.material else {
            return XCTFail("expected an Ed25519 key")
        }
        XCTAssertEqual(seed.count, 32)
        XCTAssertEqual(publicKey.count, 32)

        XCTAssertTrue(generated.publicLine.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        XCTAssertTrue(generated.publicLine.hasSuffix(" rory@laptop"))

        let parsed = try OpenSSHPrivateKeyParser.parse(armoredText: generated.armoredPrivateKey)
        XCTAssertEqual(parsed.comment, "rory@laptop")
        XCTAssertEqual(parsed.keyType, "ssh-ed25519")
        guard case .ed25519(let parsedSeed, _) = parsed.material else {
            return XCTFail("expected an Ed25519 key")
        }
        XCTAssertEqual(parsedSeed, seed)
    }

    /// Two calls must not produce the same key. Obvious, and the kind of thing
    /// a mistaken "deterministic for testing" change breaks silently.
    func testEveryKeyIsDifferent() throws {
        let first = try SSHKeyGenerator.generate(kind: .ed25519, comment: "a")
        let second = try SSHKeyGenerator.generate(kind: .ed25519, comment: "a")
        XCTAssertNotEqual(first.publicLine, second.publicLine)
    }

    func testGeneratesAnRSAKeyWithTheSixComponentsOpenSSHStores() throws {
        let generated = try SSHKeyGenerator.generate(kind: .rsa2048, comment: "rsa@laptop")

        guard case .rsa(let components) = generated.privateKey.material else {
            return XCTFail("expected an RSA key")
        }
        // 2048 bits with the top bit set.
        XCTAssertEqual(components.modulus.count, 256)
        XCTAssertEqual(components.publicExponent, [0x01, 0x00, 0x01])
        XCTAssertFalse(components.privateExponent.isEmpty)
        XCTAssertFalse(components.prime1.isEmpty)
        XCTAssertFalse(components.prime2.isEmpty)
        XCTAssertFalse(components.coefficient.isEmpty)

        XCTAssertTrue(generated.publicLine.hasPrefix("ssh-rsa AAAAB3NzaC1yc2E"))

        let parsed = try OpenSSHPrivateKeyParser.parse(armoredText: generated.armoredPrivateKey)
        XCTAssertEqual(parsed.keyType, "ssh-rsa")
        XCTAssertEqual(parsed.publicKeyBlob, generated.privateKey.publicKeyBlob)
    }

    /// A generated key has to be usable for signing, which means the CRT
    /// exponents OpenSSH does not store can be derived from what it does.
    func testGeneratedRSAKeyConvertsBackToPKCS1() throws {
        let generated = try SSHKeyGenerator.generate(kind: .rsa2048, comment: "rsa@laptop")
        guard case .rsa(let components) = generated.privateKey.material else {
            return XCTFail("expected an RSA key")
        }
        let der = try components.pkcs1DERRepresentation()
        let reread = try OpenSSHPrivateKey.RSAComponents.fromPKCS1DER(der)
        XCTAssertEqual(reread.modulus, components.modulus)
        XCTAssertEqual(reread.prime1, components.prime1)
        XCTAssertEqual(reread.prime2, components.prime2)
    }

    func testPassphraseProducesAnEncryptedFile() throws {
        let generated = try SSHKeyGenerator.generate(
            kind: .ed25519,
            comment: "protected@laptop",
            passphrase: Array("correct horse".utf8)
        )

        let header = try OpenSSHPrivateKeyParser.inspect(armoredText: generated.armoredPrivateKey)
        XCTAssertTrue(header.isEncrypted)
        XCTAssertEqual(header.cipherName, "aes256-ctr")

        // The public line is unaffected: encrypting the private half does not
        // change what goes on the server.
        XCTAssertTrue(generated.publicLine.hasPrefix("ssh-ed25519 "))

        let parsed = try OpenSSHPrivateKeyParser.parse(
            armoredText: generated.armoredPrivateKey,
            passphrase: Array("correct horse".utf8)
        )
        XCTAssertEqual(parsed.comment, "protected@laptop")

        XCTAssertThrowsError(try OpenSSHPrivateKeyParser.parse(
            armoredText: generated.armoredPrivateKey,
            passphrase: Array("wrong".utf8)
        ))
    }

    func testNoPassphraseProducesAnUnencryptedFile() throws {
        let generated = try SSHKeyGenerator.generate(kind: .ed25519, comment: "plain@laptop")
        let header = try OpenSSHPrivateKeyParser.inspect(armoredText: generated.armoredPrivateKey)
        XCTAssertFalse(header.isEncrypted)
        XCTAssertEqual(header.cipherName, "none")
    }

    func testEmptyCommentLeavesATwoFieldPublicLine() throws {
        let generated = try SSHKeyGenerator.generate(kind: .ed25519, comment: "")
        XCTAssertEqual(generated.publicLine.split(separator: " ").count, 2)
        XCTAssertFalse(generated.publicLine.hasSuffix(" "))
    }
}
