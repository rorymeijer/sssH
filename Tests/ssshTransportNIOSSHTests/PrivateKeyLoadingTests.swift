import Foundation
import XCTest
@testable import ssshCore
@testable import ssshTransportNIOSSH

/// These cover the decisions the loader makes *before* any crypto happens —
/// which is where the difference between a useful and a useless error message
/// is decided. Actually decrypting a real key is covered by the integration
/// run against the sshd container.
final class PrivateKeyLoadingTests: XCTestCase {
    private func material(_ text: String, passphrase: String? = nil) -> SSHPrivateKeyMaterial {
        SSHPrivateKeyMaterial(
            openSSHPrivateKey: SecretString(text),
            passphrase: passphrase.map(SecretString.init),
            label: "id_test"
        )
    }

    private func problem(loading text: String, passphrase: String? = nil) -> SSHTransportError.CredentialProblem? {
        do {
            _ = try PrivateKeyLoader.load(material(text, passphrase: passphrase))
            return nil
        } catch let error as SSHTransportError {
            guard case .credentialUnusable(_, let reason) = error else { return nil }
            return reason
        } catch {
            return nil
        }
    }

    func testAnUnreadableKeyTypeIsNamed() {
        // Naming the type is what lets the UI say "convert this key with
        // ssh-keygen" instead of "could not load key".
        XCTAssertEqual(
            problem(loading: OpenSSHKeyFixture.armored(keyType: "ssh-rsa")),
            .unsupportedKeyType("ssh-rsa")
        )
        XCTAssertEqual(
            problem(loading: OpenSSHKeyFixture.armored(keyType: "ecdsa-sha2-nistp256")),
            .unsupportedKeyType("ecdsa-sha2-nistp256")
        )
    }

    func testKeyTypeIsReportedBeforeAMissingPassphrase() {
        // Otherwise a user is asked for a passphrase and then told the key is
        // unsupported anyway.
        XCTAssertEqual(
            problem(loading: OpenSSHKeyFixture.armored(keyType: "ssh-rsa", cipher: "aes256-ctr", kdf: "bcrypt")),
            .unsupportedKeyType("ssh-rsa")
        )
    }

    func testEncryptedKeyWithoutAPassphraseAsksForOne() {
        XCTAssertEqual(
            problem(loading: OpenSSHKeyFixture.armored(keyType: "ssh-ed25519", cipher: "aes256-ctr", kdf: "bcrypt")),
            .passphraseRequired
        )
    }

    func testEncryptedKeyWithAWrongPassphraseSaysSo() {
        // The fixture's private section is zeroes, so decryption cannot produce
        // matching checksum words — which is exactly what a wrong passphrase
        // looks like.
        XCTAssertEqual(
            problem(
                loading: OpenSSHKeyFixture.armored(keyType: "ssh-ed25519", cipher: "aes256-ctr", kdf: "bcrypt"),
                passphrase: "not-the-passphrase"
            ),
            .wrongPassphrase
        )
    }

    func testGarbageIsMalformed() {
        XCTAssertEqual(problem(loading: "this is not a key"), .malformedKey)
        XCTAssertEqual(
            problem(loading: OpenSSHKeyFixture.armor(base64: Data("nope".utf8).base64EncodedString())),
            .malformedKey
        )
    }

    func testAPlainUnparsableOpenSSHKeyIsMalformedRatherThanAPassphraseProblem() {
        // Unencrypted but structurally broken: blaming the passphrase would
        // send the user looking for one that does not exist.
        XCTAssertEqual(
            problem(loading: OpenSSHKeyFixture.armored(keyType: "ssh-ed25519")),
            .malformedKey
        )
    }
}
