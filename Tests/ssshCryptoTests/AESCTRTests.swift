import Foundation
import XCTest
@testable import ssshCrypto

/// Vectors from FIPS-197 appendix C (the block cipher) and from `openssl enc`
/// (counter mode). Both are external ground truth: nothing here was produced
/// by the code under test.
final class AESCTRTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    private func hex(_ values: [UInt8]) -> String {
        values.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Block cipher

    func testFIPS197BlockVectors() throws {
        let vectors = [
            ("000102030405060708090a0b0c0d0e0f",
             "00112233445566778899aabbccddeeff",
             "69c4e0d86a7b0430d8cdb78070b4c55a"),
            ("000102030405060708090a0b0c0d0e0f1011121314151617",
             "00112233445566778899aabbccddeeff",
             "dda97ca4864cdfe06eaf70a0ec0d7191"),
            ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
             "00112233445566778899aabbccddeeff",
             "8ea2b7ca516745bfeafc49904b496089"),
        ]

        for (key, plaintext, expected) in vectors {
            let cipher = try AES(key: bytes(key))
            XCTAssertEqual(hex(cipher.encryptBlock(bytes(plaintext))), expected, "AES-\(key.count * 4)")
        }
    }

    // MARK: - Counter mode

    func testCounterModeVectors() throws {
        let vectors = [
            // All zeroes: catches a key schedule that silently produces nothing.
            ("0000000000000000000000000000000000000000000000000000000000000000",
             "00000000000000000000000000000000",
             "00000000000000000000000000000000",
             "dc95c078a2408989ad48a21492842087"),
            // SP 800-38A F.5.1, the canonical AES-128-CTR vector.
            ("2b7e151628aed2a6abf7158809cf4f3c",
             "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
             "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51",
             "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff"),
            ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
             "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
             "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710",
             "f9c1736f0dd61f5db354984533a1743e6472f117ef29985df0103a8d0fd808dfa9a43d1db74411899d7ee1098f5ea060bff7e76809bf7c35be309d8f1a0f6fb4"),
            // A counter one below the point where every byte carries: the
            // increment has to ripple through the whole block, not just the
            // low word.
            ("00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f",
             "fffffffffffffffffffffffffffffffe",
             "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
             "5175927513e751eb309f45bc2ef225f28316a53167b6de1a7575700693ffef279a8d652edf4dcc95276c4b5d53c9ac13"),
            // A partial trailing block: OpenSSH key sections are block-aligned,
            // but nothing in the implementation should depend on that.
            ("00112233445566778899aabbccddeeff",
             "0102030405060708090a0b0c0d0e0f10",
             "535353535353535353535353",
             "ec367aed3e2600f8b4e7b31b"),
        ]

        for (key, nonce, plaintext, expected) in vectors {
            let encrypted = try AESCTR.apply(bytes(plaintext), key: bytes(key), nonce: bytes(nonce))
            XCTAssertEqual(hex(encrypted), expected)

            // Counter mode is its own inverse.
            let decrypted = try AESCTR.apply(encrypted, key: bytes(key), nonce: bytes(nonce))
            XCTAssertEqual(hex(decrypted), plaintext)
        }
    }

    func testRejectsBadParameters() {
        XCTAssertThrowsError(try AESCTR.apply([0], key: [UInt8](repeating: 0, count: 20), nonce: [UInt8](repeating: 0, count: 16))) { error in
            XCTAssertEqual(error as? AESCTR.Failure, .unsupportedKeySize(20))
        }
        XCTAssertThrowsError(try AESCTR.apply([0], key: [UInt8](repeating: 0, count: 32), nonce: [0, 1, 2])) { error in
            XCTAssertEqual(error as? AESCTR.Failure, .invalidNonceSize(3))
        }
    }

    func testEmptyInputProducesEmptyOutput() throws {
        let output = try AESCTR.apply([], key: [UInt8](repeating: 0, count: 32), nonce: [UInt8](repeating: 0, count: 16))
        XCTAssertTrue(output.isEmpty)
    }
}
