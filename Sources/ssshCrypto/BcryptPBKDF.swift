import Crypto
import Foundation

/// OpenBSD's `bcrypt_pbkdf`, the key-derivation function OpenSSH uses to turn
/// a passphrase into the key that encrypts a private key file.
///
/// It is PBKDF2's structure with `bcrypt` as the underlying hash, plus three
/// deviations that matter for interoperability and are easy to get subtly
/// wrong:
///
/// 1. The password and salt are collapsed with SHA-512 before they reach
///    `bcrypt`, which is what lets the 56-byte limit on a Blowfish key stop
///    being a limit.
/// 2. The magic string encrypted 64 times is `OxychromaticBlowfishSwatDynamite`
///    — longer than classic bcrypt's, giving a 256-bit block.
/// 3. Output bytes are **interleaved**, not concatenated. Classic PBKDF2 lets
///    an attacker who only needs the first half of the key material do half the
///    work; writing byte `i` of block `count` to `i * stride + count - 1`
///    forces the whole derivation.
///
/// Verified against the OpenBSD reference implementation: see
/// `Tests/ssshCryptoTests/BcryptPBKDFTests.swift`, whose vectors were produced
/// by compiling and running it.
public enum BcryptPBKDF {
    public enum Failure: Error, Equatable {
        case invalidParameters
    }

    /// The `bcrypt` hash is defined over 8 words of 32 bits.
    private static let hashSize = 32
    private static let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)

    /// - Parameters:
    ///   - rounds: OpenSSH writes this into the key file; `ssh-keygen` defaults
    ///     to 16 and allows more via `-a`.
    public static func derive(
        password: [UInt8],
        salt: [UInt8],
        rounds: Int,
        keyLength: Int
    ) throws -> [UInt8] {
        guard rounds >= 1,
              !password.isEmpty,
              !salt.isEmpty,
              keyLength > 0,
              keyLength <= hashSize * hashSize,
              salt.count <= 1 << 20
        else {
            throw Failure.invalidParameters
        }

        let stride = (keyLength + hashSize - 1) / hashSize
        let amount = (keyLength + stride - 1) / stride

        let collapsedPassword = Array(SHA512.hash(data: password))

        var key = [UInt8](repeating: 0, count: keyLength)
        var remaining = keyLength
        var count: UInt32 = 1

        while remaining > 0 {
            var countedSalt = salt
            countedSalt.append(contentsOf: [
                UInt8(truncatingIfNeeded: count >> 24),
                UInt8(truncatingIfNeeded: count >> 16),
                UInt8(truncatingIfNeeded: count >> 8),
                UInt8(truncatingIfNeeded: count),
            ])

            var collapsedSalt = Array(SHA512.hash(data: countedSalt))
            var intermediate = hash(password: collapsedPassword, salt: collapsedSalt)
            var block = intermediate

            // Each further round re-salts with the previous output and XORs in
            // the result, exactly as PBKDF2 does.
            for _ in 1..<rounds {
                collapsedSalt = Array(SHA512.hash(data: intermediate))
                intermediate = hash(password: collapsedPassword, salt: collapsedSalt)
                for index in 0..<hashSize {
                    block[index] ^= intermediate[index]
                }
            }

            var written = 0
            for index in 0..<min(amount, remaining) {
                let destination = index * stride + Int(count) - 1
                if destination >= keyLength { break }
                key[destination] = block[index]
                written += 1
            }

            remaining -= written
            count += 1
        }

        return key
    }

    /// One `bcrypt` hash of an already-SHA-512-collapsed password and salt.
    private static func hash(password: [UInt8], salt: [UInt8]) -> [UInt8] {
        var state = Blowfish()
        state.expandState(salt: salt, key: password)

        // 64 alternating unsalted expansions: this is the work factor that
        // makes each round expensive.
        for _ in 0..<64 {
            state.expand0State(key: salt)
            state.expand0State(key: password)
        }

        var position = 0
        var words = (0..<8).map { _ in Blowfish.streamWordForMagic(magic, position: &position) }

        for _ in 0..<64 {
            state.encrypt(&words)
        }

        // Little-endian, unlike everything else in SSH. This is what the
        // reference does, and interoperability is the only thing that matters.
        var output = [UInt8](repeating: 0, count: hashSize)
        for index in 0..<8 {
            output[4 * index + 3] = UInt8(truncatingIfNeeded: words[index] >> 24)
            output[4 * index + 2] = UInt8(truncatingIfNeeded: words[index] >> 16)
            output[4 * index + 1] = UInt8(truncatingIfNeeded: words[index] >> 8)
            output[4 * index + 0] = UInt8(truncatingIfNeeded: words[index])
        }
        return output
    }
}
