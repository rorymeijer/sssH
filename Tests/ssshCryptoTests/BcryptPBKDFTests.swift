import Foundation
import XCTest
@testable import ssshCrypto

/// Vectors produced by compiling and running OpenBSD's own `bcrypt_pbkdf.c`
/// (as vendored by OpenSSH) — external ground truth, not a restatement of this
/// implementation.
final class BcryptPBKDFTests: XCTestCase {
    private func hex(_ values: [UInt8]) -> String {
        values.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    func testReferenceVectors() throws {
        let vectors: [(password: String, salt: [UInt8], rounds: Int, length: Int, expected: String)] = [
            ("password", Array("salt".utf8), 16, 48,
             "c339d704ec235f27690d3f12167c05a55bf86d572f270adbf9fe04c379da5f8c7942a939245dbb39ebe26fc2bd19b88b"),
            ("secret-pass", bytes("0102030405060708090a0b0c0d0e0f10"), 16, 48,
             "67ec9a5651ba0fe5c59e00c32ad3bec9b241f9836a6c0fad476ce6e7b089cbcb69f254ad7a7e4dd49dbac844172f043e"),
            // One round, and a key length exactly one hash block: the
            // interleaving arithmetic degenerates here and is easy to get wrong.
            ("a", Array("b".utf8), 1, 32,
             "9816e8eb03eabaa71a9e89805252fc02f4659b5d0a5f38f80d69854f8b13b48e"),
            // Two blocks of output, which is where the non-linear interleaving
            // actually shows up.
            ("passphrase", bytes("deadbeefcafebabe0011223344556677"), 24, 64,
             "76b6ac583151132488e6d8753d23a6ad7a1f17618e52184beb23f7543cb171f377a9c4a16993e9b703a6b79a3e5a89f38b4ac1450858415fdc413bc9b40ad1fc"),
        ]

        for vector in vectors {
            let derived = try BcryptPBKDF.derive(
                password: Array(vector.password.utf8),
                salt: vector.salt,
                rounds: vector.rounds,
                keyLength: vector.length
            )
            XCTAssertEqual(hex(derived), vector.expected, "\(vector.password)/\(vector.rounds)/\(vector.length)")
        }
    }

    func testRoundsChangeTheOutput() throws {
        // Cheap guard against the round loop being skipped, which would leave
        // the KDF looking fine while being trivially cheap to brute-force.
        let first = try BcryptPBKDF.derive(password: Array("p".utf8), salt: Array("s".utf8), rounds: 1, keyLength: 32)
        let second = try BcryptPBKDF.derive(password: Array("p".utf8), salt: Array("s".utf8), rounds: 2, keyLength: 32)
        XCTAssertNotEqual(first, second)
    }

    func testRejectsBadParameters() {
        let salt = Array("salt".utf8)
        let password = Array("password".utf8)

        XCTAssertThrowsError(try BcryptPBKDF.derive(password: password, salt: salt, rounds: 0, keyLength: 32))
        XCTAssertThrowsError(try BcryptPBKDF.derive(password: [], salt: salt, rounds: 1, keyLength: 32))
        XCTAssertThrowsError(try BcryptPBKDF.derive(password: password, salt: [], rounds: 1, keyLength: 32))
        XCTAssertThrowsError(try BcryptPBKDF.derive(password: password, salt: salt, rounds: 1, keyLength: 0))
    }
}
