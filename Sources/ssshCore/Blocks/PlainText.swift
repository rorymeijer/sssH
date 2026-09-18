import Foundation

/// Turns captured terminal bytes back into readable text.
///
/// Searching and copying need text, and terminal output is not text: it is text
/// interleaved with cursor movement, colour changes, title sets and whatever
/// else a program felt like emitting. This strips the sequences and applies the
/// handful of control characters that change what a line *says* rather than how
/// it looks.
///
/// It is deliberately not a terminal emulator. A program that draws by moving
/// the cursor around — `top`, `vim`, a progress bar that repositions rather
/// than returning — will not come out right, and cannot without a full screen
/// model. The block store avoids the worst of that by not capturing at all
/// while the alternate screen is active.
public enum PlainText {
    public static func extract(from bytes: ArraySlice<UInt8>) -> String {
        String(decoding: extractBytes(from: bytes), as: UTF8.self)
    }

    /// Lines, with trailing carriage returns and the final empty line removed.
    public static func lines(from bytes: ArraySlice<UInt8>) -> [String] {
        let text = extract(from: bytes)
        var result = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    static func extractBytes(from bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        /// Index in `out` where the current line starts, so that a carriage
        /// return can rewind to it.
        var lineStart = 0

        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            switch byte {
            case 0x1B: // ESC
                // Only the 7-bit forms. 0x9B and 0x9D are the 8-bit CSI and
                // OSC introducers, but a UTF-8 terminal never sends those and
                // 0x80–0x9F are continuation bytes of ordinary characters:
                // skipping from one would eat the rest of a line of Arabic.
                index = skipEscape(in: bytes, from: index)
                continue
            case 0x0A: // LF
                out.append(0x0A)
                lineStart = out.count
            case 0x0D: // CR
                // A CR immediately followed by LF is a line ending, not a
                // rewind: treating it as one would delete the line the LF is
                // about to terminate, which quietly empties every `\r\n`
                // terminated line in the capture.
                let next = bytes.index(after: index)
                if next < bytes.endIndex, bytes[next] == 0x0A {
                    break
                }
                // A bare CR does rewrite the line, which is how progress bars
                // and spinners work.
                out.removeSubrange(lineStart...)
            case 0x08: // BS
                if out.count > lineStart { out.removeLast() }
            case 0x09: // HT
                out.append(0x09)
            case 0x07, 0x00: // BEL, NUL
                break
            case 0x01...0x06, 0x0B...0x0C, 0x0E...0x1A, 0x1C...0x1F:
                break
            default:
                out.append(byte)
            }
            index = bytes.index(after: index)
        }
        return out
    }

    /// Returns the index just past the escape sequence starting at `start`.
    private static func skipEscape(in bytes: ArraySlice<UInt8>, from start: ArraySlice<UInt8>.Index) -> ArraySlice<UInt8>.Index {
        let next = bytes.index(after: start)
        guard next < bytes.endIndex else { return bytes.endIndex }
        switch bytes[next] {
        case 0x5B: // '[' CSI
            return skipCSI(in: bytes, from: bytes.index(after: next))
        case 0x5D: // ']' OSC
            return skipOSC(in: bytes, from: bytes.index(after: next))
        case 0x50, 0x58, 0x5E, 0x5F: // DCS, SOS, PM, APC — all ST-terminated
            return skipOSC(in: bytes, from: bytes.index(after: next))
        case 0x20...0x2F: // intermediate bytes: ESC ( B and friends
            var index = bytes.index(after: next)
            while index < bytes.endIndex, (0x20...0x2F).contains(bytes[index]) {
                index = bytes.index(after: index)
            }
            return index < bytes.endIndex ? bytes.index(after: index) : bytes.endIndex
        default:
            return bytes.index(after: next)
        }
    }

    private static func skipCSI(in bytes: ArraySlice<UInt8>, from start: ArraySlice<UInt8>.Index) -> ArraySlice<UInt8>.Index {
        var index = start
        while index < bytes.endIndex {
            let byte = bytes[index]
            if (0x40...0x7E).contains(byte) { return bytes.index(after: index) }
            if !(0x20...0x3F).contains(byte) { return index } // malformed; resume here
            index = bytes.index(after: index)
        }
        return bytes.endIndex
    }

    private static func skipOSC(in bytes: ArraySlice<UInt8>, from start: ArraySlice<UInt8>.Index) -> ArraySlice<UInt8>.Index {
        var index = start
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == 0x07 { return bytes.index(after: index) }           // BEL

            if byte == 0x1B {
                let next = bytes.index(after: index)
                if next < bytes.endIndex, bytes[next] == 0x5C {            // ESC \
                    return bytes.index(after: next)
                }
                return index // an unterminated OSC; resume at the ESC
            }
            index = bytes.index(after: index)
        }
        return bytes.endIndex
    }
}
