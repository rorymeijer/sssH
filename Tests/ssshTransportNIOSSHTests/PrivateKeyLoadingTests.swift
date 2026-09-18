import Foundation
import XCTest
@testable import ssshCore
@testable import ssshCrypto
@testable import ssshTransportNIOSSH

/// The mapping from parsed key material to a NIOSSH signing key, and from
/// parse failures to errors a user can act on. Container parsing itself is
/// covered by `ssshCryptoTests` against real `openssl`-generated keys.
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

    func testLoadsEd25519() throws {
        // NIOSSHPrivateKey exposes no public accessor for its algorithm, so the
        // assertion is that the key loads at all — which is what the auth
        // delegate needs. That the *right* key came out is covered by
        // `ssshCryptoTests`, which compares the material byte for byte.
        _ = try PrivateKeyLoader.load(material(TransportKeyFixtures.ed25519Plain))
    }

    func testLoadsPassphraseProtectedEd25519() throws {
        _ = try PrivateKeyLoader.load(
            material(TransportKeyFixtures.ed25519Encrypted, passphrase: TransportKeyFixtures.passphrase)
        )
    }

    func testLoadsECDSA() throws {
        _ = try PrivateKeyLoader.load(material(TransportKeyFixtures.ecdsaP256Plain))
    }

    func testWrongPassphraseIsNamed() {
        XCTAssertEqual(
            problem(loading: TransportKeyFixtures.ed25519Encrypted, passphrase: "wrong"),
            .wrongPassphrase
        )
    }

    func testMissingPassphraseIsNamed() {
        XCTAssertEqual(problem(loading: TransportKeyFixtures.ed25519Encrypted), .passphraseRequired)
    }

    func testRSAIsReadButReportedUnusable() {
        // The file parses; what is missing is an rsa-sha2-* signer. The error
        // has to name the type so the UI can suggest converting the key rather
        // than leaving the user guessing.
        XCTAssertEqual(problem(loading: TransportKeyFixtures.rsaPlain), .unsupportedKeyType("ssh-rsa"))
    }

    func testGarbageIsMalformed() {
        XCTAssertEqual(problem(loading: "this is not a key"), .malformedKey)
    }
}
