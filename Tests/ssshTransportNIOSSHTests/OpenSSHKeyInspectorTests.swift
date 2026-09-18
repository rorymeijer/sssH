import Foundation
import XCTest
@testable import ssshTransportNIOSSH

/// The inspector reads only the plaintext header of an `openssh-key-v1` file,
/// which is what lets sssh say "this key needs a passphrase" or "sssh cannot
/// read ECDSA key files yet" instead of "could not load key".
///
/// The fixtures are assembled here from the format's own rules rather than
/// captured from `ssh-keygen`, so these tests cover the reader's handling of
/// the encoding. Compatibility with keys real `ssh-keygen` produces is covered
/// by the integration run against the sshd container — see
/// Integration/README.md.
final class OpenSSHKeyInspectorTests: XCTestCase {
    func testReadsAnUnencryptedEd25519Header() throws {
        let armored = OpenSSHKeyFixture.armored(keyType: "ssh-ed25519", cipher: "none", kdf: "none")
        let header = try XCTUnwrap(OpenSSHKeyInspector(armoredText: armored))

        XCTAssertEqual(header.keyType, "ssh-ed25519")
        XCTAssertEqual(header.cipherName, "none")
        XCTAssertEqual(header.kdfName, "none")
        XCTAssertFalse(header.isEncrypted)
    }

    func testReadsAnEncryptedHeader() throws {
        let armored = OpenSSHKeyFixture.armored(keyType: "ssh-ed25519", cipher: "aes256-ctr", kdf: "bcrypt")
        let header = try XCTUnwrap(OpenSSHKeyInspector(armoredText: armored))

        XCTAssertTrue(header.isEncrypted, "a cipher other than `none` is what makes a passphrase necessary")
        XCTAssertEqual(header.kdfName, "bcrypt")
    }

    func testReportsTheKeyTypeForFormatsWeCannotYetRead() throws {
        for keyType in ["ssh-rsa", "ecdsa-sha2-nistp256", "sk-ssh-ed25519@openssh.com"] {
            let header = try XCTUnwrap(OpenSSHKeyInspector(armoredText: OpenSSHKeyFixture.armored(keyType: keyType)))
            XCTAssertEqual(header.keyType, keyType)
        }
    }

    func testDetectsTheArmor() {
        XCTAssertTrue(OpenSSHKeyInspector.isOpenSSHFormat(OpenSSHKeyFixture.armored(keyType: "ssh-ed25519")))
        XCTAssertFalse(OpenSSHKeyInspector.isOpenSSHFormat("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----"))
        XCTAssertFalse(OpenSSHKeyInspector.isOpenSSHFormat(""))
    }

    func testToleratesCRLFAndStrayBlankLines() throws {
        let armored = OpenSSHKeyFixture.armored(keyType: "ssh-ed25519")
            .replacingOccurrences(of: "\n", with: "\r\n")
            + "\r\n\r\n"

        // Keys arrive pasted out of chat clients and editors; line-ending
        // cleanliness is not something a user should have to think about.
        let header = try XCTUnwrap(OpenSSHKeyInspector(armoredText: armored))
        XCTAssertEqual(header.keyType, "ssh-ed25519")
    }

    func testRejectsMalformedFiles() {
        XCTAssertNil(OpenSSHKeyInspector(armoredText: "not a key at all"))

        // Right armor, wrong magic.
        XCTAssertNil(OpenSSHKeyInspector(armoredText: OpenSSHKeyFixture.armor(
            base64: Data("this-is-not-openssh-key-v1".utf8).base64EncodedString()
        )))

        // Empty body.
        XCTAssertNil(OpenSSHKeyInspector(armoredText: OpenSSHKeyFixture.armor(base64: "")))

        // Truncated part-way through the header.
        let full = OpenSSHKeyFixture.blob(keyType: "ssh-ed25519")
        XCTAssertNil(OpenSSHKeyInspector(armoredText: OpenSSHKeyFixture.armor(
            base64: Data(full.prefix(20)).base64EncodedString()
        )))

        // A length field larger than the file: a corrupt or hostile file must
        // not make the reader run off the end.
        var absurd = Array("openssh-key-v1\0".utf8)
        absurd.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertNil(OpenSSHKeyInspector(armoredText: OpenSSHKeyFixture.armor(base64: Data(absurd).base64EncodedString())))

        // Zero keys in the container.
        XCTAssertNil(OpenSSHKeyInspector(armoredText: OpenSSHKeyFixture.armor(
            base64: Data(OpenSSHKeyFixture.blob(keyType: "ssh-ed25519", keyCount: 0)).base64EncodedString()
        )))
    }
}
