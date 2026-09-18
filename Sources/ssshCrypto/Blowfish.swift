import Foundation

/// Blowfish, in the shape `bcrypt` needs.
///
/// Not a general-purpose cipher: it exposes the two key-schedule variants that
/// the `bcrypt` password hash is built from (`expandState`, which mixes in a
/// salt, and `expand0State`, which does not) plus block encryption. Nothing
/// else in sssh should use it — it is a 64-bit block cipher from 1993 and is
/// here only because `bcrypt_pbkdf` is defined in terms of it.
///
/// See ``BcryptPBKDF`` for why that matters.
struct Blowfish {
    /// 16 rounds.
    private static let roundCount = 16

    /// The four S-boxes, concatenated. Keeping them in one array is what lets
    /// the Feistel function index them as `s[box * 256 + byte]` with no bounds
    /// arithmetic per box.
    private var s: [UInt32]
    /// 18 subkeys.
    private var p: [UInt32]

    init() {
        p = BlowfishInitialState.p
        s = BlowfishInitialState.s0 + BlowfishInitialState.s1 + BlowfishInitialState.s2 + BlowfishInitialState.s3
    }

    // MARK: - Block cipher

    /// The Feistel function: two S-box lookups added, XORed with a third, plus
    /// a fourth — all modulo 2^32.
    private func f(_ x: UInt32) -> UInt32 {
        let a = s[Int((x >> 24) & 0xFF)]
        let b = s[0x100 + Int((x >> 16) & 0xFF)]
        let c = s[0x200 + Int((x >> 8) & 0xFF)]
        let d = s[0x300 + Int(x & 0xFF)]
        return ((a &+ b) ^ c) &+ d
    }

    func encipher(_ block: (UInt32, UInt32)) -> (UInt32, UInt32) {
        var left = block.0
        var right = block.1

        left ^= p[0]

        // Each round XORs one half with the Feistel function of the other, then
        // the halves swap roles. Sixteen rounds is an even number of swaps, so
        // `left` and `right` are back to their original roles here — and the
        // cipher's defining quirk is that the *output* halves are then crossed
        // over anyway.
        var round = 1
        while round <= Self.roundCount {
            right ^= f(left) ^ p[round]
            swap(&left, &right)
            round += 1
        }

        return (right ^ p[Self.roundCount + 1], left)
    }

    /// Encrypts a block of 32-bit words in place, two words at a time.
    func encrypt(_ data: inout [UInt32]) {
        var index = 0
        while index + 1 < data.count {
            let (left, right) = encipher((data[index], data[index + 1]))
            data[index] = left
            data[index + 1] = right
            index += 2
        }
    }

    // MARK: - Key schedule

    /// Reads four bytes from `data`, wrapping around when it runs out, and
    /// advances `position`. This cyclic read is what lets a key shorter than
    /// the subkey array still fill it.
    ///
    /// ``BcryptPBKDF`` needs the same reader for the magic string it encrypts,
    /// which is what ``streamWordForMagic(_:position:)`` exposes.
    private static func streamWord(_ data: [UInt8], position: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            if position >= data.count { position = 0 }
            word = (word << 8) | UInt32(data[position])
            position += 1
        }
        return word
    }

    /// The cyclic word reader, for ``BcryptPBKDF``'s use on its magic string.
    static func streamWordForMagic(_ data: [UInt8], position: inout Int) -> UInt32 {
        streamWord(data, position: &position)
    }

    /// The salted key schedule ("expandstate" in the reference).
    mutating func expandState(salt: [UInt8], key: [UInt8]) {
        var keyPosition = 0
        for index in 0..<p.count {
            p[index] ^= Self.streamWord(key, position: &keyPosition)
        }

        var saltPosition = 0
        var block: (UInt32, UInt32) = (0, 0)

        var index = 0
        while index < p.count {
            block.0 ^= Self.streamWord(salt, position: &saltPosition)
            block.1 ^= Self.streamWord(salt, position: &saltPosition)
            block = encipher(block)
            p[index] = block.0
            p[index + 1] = block.1
            index += 2
        }

        index = 0
        while index < s.count {
            block.0 ^= Self.streamWord(salt, position: &saltPosition)
            block.1 ^= Self.streamWord(salt, position: &saltPosition)
            block = encipher(block)
            s[index] = block.0
            s[index + 1] = block.1
            index += 2
        }
    }

    /// The unsalted key schedule ("expand0state" in the reference), which is
    /// the standard Blowfish key setup.
    mutating func expand0State(key: [UInt8]) {
        var keyPosition = 0
        for index in 0..<p.count {
            p[index] ^= Self.streamWord(key, position: &keyPosition)
        }

        var block: (UInt32, UInt32) = (0, 0)

        var index = 0
        while index < p.count {
            block = encipher(block)
            p[index] = block.0
            p[index + 1] = block.1
            index += 2
        }

        index = 0
        while index < s.count {
            block = encipher(block)
            s[index] = block.0
            s[index + 1] = block.1
            index += 2
        }
    }
}
