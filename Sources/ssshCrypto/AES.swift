import Foundation

/// AES in counter mode, enough to open an encrypted OpenSSH private key.
///
/// ## Why this exists at all
///
/// Reading a passphrase-protected `openssh-key-v1` file needs AES-CTR, and
/// swift-crypto exposes no raw block cipher: `Crypto` offers AEADs only, and
/// `_CryptoExtras` at the version this package resolves offers only RSA. The
/// alternatives were reaching into swift-crypto's private BoringSSL module
/// through an undeclared import — which breaks whenever SwiftPM tightens up —
/// or platform-specific code. A contained, tested implementation of the forward
/// cipher is the honest option.
///
/// Only the forward direction is implemented, because counter mode never needs
/// the inverse cipher: it encrypts a counter and XORs. That also means
/// encryption and decryption are the same operation, which is why there is one
/// function and not two.
///
/// ## What this is not
///
/// This is not a general-purpose AES, and nothing else in sssh should reach for
/// it. Bulk traffic is encrypted by swift-nio-ssh's AES-GCM, which is
/// BoringSSL-backed and constant-time. This implementation is table-driven and
/// therefore **not** constant-time with respect to the key: it is acceptable
/// here because it runs once, locally, on a key the user already possesses, and
/// there is no remote timing observer.
public enum AESCTR {
    public enum Failure: Error, Equatable {
        case unsupportedKeySize(Int)
        case invalidNonceSize(Int)
    }

    /// XORs `data` with the AES-CTR key stream. Encryption and decryption are
    /// the same operation.
    ///
    /// - Parameters:
    ///   - nonce: the initial 16-byte counter block. OpenSSH stores this as the
    ///     second half of the bcrypt-derived key material.
    public static func apply(
        _ data: [UInt8],
        key: [UInt8],
        nonce: [UInt8]
    ) throws -> [UInt8] {
        guard nonce.count == AES.blockSize else { throw Failure.invalidNonceSize(nonce.count) }
        let cipher = try AES(key: key)

        var counter = nonce
        var output = [UInt8]()
        output.reserveCapacity(data.count)

        var offset = 0
        while offset < data.count {
            let keyStream = cipher.encryptBlock(counter)
            let count = min(AES.blockSize, data.count - offset)
            for index in 0..<count {
                output.append(data[offset + index] ^ keyStream[index])
            }
            offset += count
            Self.increment(&counter)
        }

        return output
    }

    /// Big-endian increment of the whole 128-bit counter block, which is what
    /// SP 800-38A's standard incrementing function and OpenSSH both use.
    private static func increment(_ counter: inout [UInt8]) {
        var index = counter.count - 1
        while index >= 0 {
            let (value, overflow) = counter[index].addingReportingOverflow(1)
            counter[index] = value
            if !overflow { return }
            index -= 1
        }
    }
}

/// The AES forward cipher. Internal: ``AESCTR`` is the supported surface.
struct AES {
    static let blockSize = 16

    private let roundKeys: [UInt8]
    private let rounds: Int

    init(key: [UInt8]) throws {
        switch key.count {
        case 16: rounds = 10
        case 24: rounds = 12
        case 32: rounds = 14
        default: throw AESCTR.Failure.unsupportedKeySize(key.count)
        }
        roundKeys = Self.expandKey(key, rounds: rounds)
    }

    /// FIPS-197 §5.1. Straightforward round structure rather than the T-table
    /// form: this runs once per key-file open, so clarity beats throughput.
    func encryptBlock(_ input: [UInt8]) -> [UInt8] {
        var state = input

        addRoundKey(&state, round: 0)

        for round in 1..<rounds {
            subBytes(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(&state, round: round)
        }

        // The final round omits MixColumns.
        subBytes(&state)
        shiftRows(&state)
        addRoundKey(&state, round: rounds)

        return state
    }

    // MARK: - Round steps

    private func addRoundKey(_ state: inout [UInt8], round: Int) {
        let base = round * Self.blockSize
        for index in 0..<Self.blockSize {
            state[index] ^= roundKeys[base + index]
        }
    }

    private func subBytes(_ state: inout [UInt8]) {
        for index in 0..<Self.blockSize {
            state[index] = AESTables.sbox[Int(state[index])]
        }
    }

    /// The state is column-major: byte `r + 4c` is row `r`, column `c`. Row `r`
    /// is rotated left by `r`.
    private func shiftRows(_ state: inout [UInt8]) {
        var shifted = state
        for row in 1..<4 {
            for column in 0..<4 {
                shifted[row + 4 * column] = state[row + 4 * ((column + row) % 4)]
            }
        }
        state = shifted
    }

    private func mixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let base = 4 * column
            let a0 = state[base], a1 = state[base + 1], a2 = state[base + 2], a3 = state[base + 3]

            state[base]     = Self.xtime(a0) ^ (Self.xtime(a1) ^ a1) ^ a2 ^ a3
            state[base + 1] = a0 ^ Self.xtime(a1) ^ (Self.xtime(a2) ^ a2) ^ a3
            state[base + 2] = a0 ^ a1 ^ Self.xtime(a2) ^ (Self.xtime(a3) ^ a3)
            state[base + 3] = (Self.xtime(a0) ^ a0) ^ a1 ^ a2 ^ Self.xtime(a3)
        }
    }

    /// Multiplication by x in GF(2^8) modulo the AES polynomial.
    private static func xtime(_ value: UInt8) -> UInt8 {
        let shifted = value << 1
        return (value & 0x80) != 0 ? shifted ^ 0x1B : shifted
    }

    // MARK: - Key schedule

    /// FIPS-197 §5.2.
    private static func expandKey(_ key: [UInt8], rounds: Int) -> [UInt8] {
        let keyWords = key.count / 4
        let totalWords = 4 * (rounds + 1)
        var words = [[UInt8]]()
        words.reserveCapacity(totalWords)

        for index in 0..<keyWords {
            words.append(Array(key[(4 * index)..<(4 * index + 4)]))
        }

        var rcon: UInt8 = 1

        for index in keyWords..<totalWords {
            var word = words[index - 1]

            if index % keyWords == 0 {
                word = [word[1], word[2], word[3], word[0]]           // RotWord
                word = word.map { AESTables.sbox[Int($0)] }            // SubWord
                word[0] ^= rcon
                rcon = xtime(rcon)
            } else if keyWords > 6, index % keyWords == 4 {
                // AES-256 only: an extra SubWord a third of the way through.
                word = word.map { AESTables.sbox[Int($0)] }
            }

            let previous = words[index - keyWords]
            words.append((0..<4).map { previous[$0] ^ word[$0] })
        }

        return words.flatMap { $0 }
    }
}
