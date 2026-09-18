import Foundation
import XCTest
@testable import ssshCore
@testable import ssshTransportNIOSSH

/// Fingerprint formatting and `known_hosts` parsing, pinned against values
/// computed independently (SHA-256 of the key blob, base64 with the padding
/// stripped — exactly what `ssh-keygen -lf` prints).
final class HostKeyFormattingTests: XCTestCase {
    /// A well-formed `ssh-ed25519` key blob: the SSH string "ssh-ed25519"
    /// followed by a 32-byte public key of 0x00...0x1f.
    private let blob: [UInt8] = [
        0, 0, 0, 11, 115, 115, 104, 45, 101, 100, 50, 53, 53, 49, 57,
        0, 0, 0, 32,
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    ]
    private let expectedFingerprint = "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA"
    private let expectedBase64 = "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"

    func testFingerprintMatchesOpenSSHFormat() {
        XCTAssertEqual(SSHHostKey.fingerprint(ofWireFormat: blob), expectedFingerprint)
        XCTAssertFalse(expectedFingerprint.hasSuffix("="), "OpenSSH strips base64 padding")
    }

    func testAlgorithmIsReadFromTheLeadingSSHString() {
        XCTAssertEqual(SSHHostKey.algorithmName(fromWireFormat: blob), "ssh-ed25519")
    }

    func testAlgorithmNameRejectsMalformedBlobs() {
        XCTAssertNil(SSHHostKey.algorithmName(fromWireFormat: []))
        XCTAssertNil(SSHHostKey.algorithmName(fromWireFormat: [0, 0, 0]))
        // Truncated: claims 11 bytes of name but supplies 3.
        XCTAssertNil(SSHHostKey.algorithmName(fromWireFormat: [0, 0, 0, 11, 1, 2, 3]))
        // A length field from a corrupt file must not be trusted.
        XCTAssertNil(SSHHostKey.algorithmName(fromWireFormat: [0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3]))
    }

    func testAuthorizedKeyRepresentationRoundTrips() throws {
        let key = SSHHostKey(algorithm: "ssh-ed25519", wireFormat: blob, sha256Fingerprint: expectedFingerprint)
        XCTAssertEqual(key.authorizedKeyRepresentation, "ssh-ed25519 \(expectedBase64)")

        let parsed = try XCTUnwrap(SSHHostKey.parse(authorizedKeyRepresentation: key.authorizedKeyRepresentation))
        XCTAssertEqual(parsed, key)
        XCTAssertEqual(parsed.sha256Fingerprint, expectedFingerprint)
    }

    func testParseToleratesATrailingComment() throws {
        let line = "ssh-ed25519 \(expectedBase64) host@example.test"
        let parsed = try XCTUnwrap(SSHHostKey.parse(authorizedKeyRepresentation: line))
        XCTAssertEqual(parsed.algorithm, "ssh-ed25519")
    }

    func testParseRejectsAnAlgorithmThatDisagreesWithTheBlob() {
        // A line claiming to be RSA while carrying an ed25519 blob is the shape
        // of a tampered known_hosts entry; accepting it would let an attacker
        // pick which stored key a connection is compared against.
        let line = "ssh-rsa \(expectedBase64)"
        XCTAssertNil(SSHHostKey.parse(authorizedKeyRepresentation: line))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(SSHHostKey.parse(authorizedKeyRepresentation: ""))
        XCTAssertNil(SSHHostKey.parse(authorizedKeyRepresentation: "ssh-ed25519"))
        XCTAssertNil(SSHHostKey.parse(authorizedKeyRepresentation: "ssh-ed25519 not-base64!!"))
    }
}
