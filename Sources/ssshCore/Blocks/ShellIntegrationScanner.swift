import Foundation

/// A semantic marker a shell emits to say where a prompt, a command and its
/// output begin and end.
///
/// These come from the FinalTerm/iTerm2 `OSC 133` convention, which every shell
/// integration script in circulation now emits, and from VS Code's `OSC 633`
/// superset, which adds the command line as text. Supporting both costs one
/// extra branch and covers what people actually have in their rc files.
public enum ShellIntegrationMarker: Hashable, Sendable {
    /// `OSC 133 ; A` — a new prompt is about to be drawn.
    case promptStart
    /// `OSC 133 ; B` — the prompt is finished; what follows is typed input.
    case commandStart
    /// `OSC 133 ; C` — the command was submitted; what follows is its output.
    case commandExecuted
    /// `OSC 133 ; D [; exit]` — the command finished.
    case commandFinished(exitStatus: Int32?)
    /// `OSC 633 ; E ; <command line>` — VS Code's report of what was run.
    ///
    /// Worth having because it is the only marker that states the command as
    /// text rather than leaving it to be recovered from the echo.
    case commandLine(String)
    /// The alternate screen buffer was entered or left (`CSI ? 1049 h` / `l`,
    /// and the older `47` and `1047` forms).
    ///
    /// Not a shell-integration marker at all, but the segmenter needs it: a
    /// full-screen program is not a command with output, and capturing one
    /// produces a block that is both enormous and meaningless.
    case alternateScreen(active: Bool)
}

/// One piece of a scanned stream, in order.
///
/// The scanner hands back bytes and markers interleaved rather than offsets
/// into the chunk it was given, because an escape sequence does not respect
/// chunk boundaries: an `OSC 133 ; D ; 0` routinely arrives split across two
/// TCP segments. Anything offset-based has to describe a marker that started
/// in a chunk the caller no longer has, and every way of expressing that is a
/// trap waiting for a slow link.
public enum ShellIntegrationToken: Sendable {
    /// Bytes that are not part of a marker sequence. Ordinary escape
    /// sequences — colours, cursor moves — come back here unchanged; only the
    /// sequences the scanner consumes are removed.
    case bytes([UInt8])
    case marker(ShellIntegrationMarker)
}

public struct ShellIntegrationScanner: Sendable {
    /// A partially-parsed escape sequence cannot be allowed to grow without
    /// bound: a stray `ESC ]` in binary output would otherwise make the scanner
    /// buffer the rest of the session looking for a terminator. Real OSC
    /// payloads used here are a few dozen bytes; VS Code's `E` marker carries a
    /// command line, so allow a generous line's worth and then give up.
    private static let maximumSequenceLength = 4096

    private enum State: Sendable {
        case ground
        /// Seen `ESC`, waiting to find out what kind of sequence this is.
        case escape
        /// Inside `OSC ... `, accumulating the payload.
        case osc
        /// Inside an OSC payload and just saw `ESC`: `ESC \` terminates it,
        /// anything else means the OSC was never closed.
        case oscEscape
        /// Inside `CSI ... `, accumulating parameter bytes.
        case csi
    }

    private var state: State = .ground
    /// The bytes of the sequence being accumulated, held back until it is
    /// known whether they are a marker (dropped) or ordinary output (passed
    /// through). This is also the only buffering the scanner does, which is
    /// what makes a sequence split across chunks work.
    private var held: [UInt8] = []
    /// The payload of the OSC or the parameters of the CSI, without the
    /// introducer.
    private var payload: [UInt8] = []
    /// Plain bytes accumulated since the last token, flushed when a marker
    /// fires or the chunk ends.
    private var plain: [UInt8] = []

    public init() {}

    /// Feed a chunk. Returns its bytes and markers, in order.
    ///
    /// Every byte the caller passes in comes back out as part of a
    /// ``ShellIntegrationToken/bytes(_:)`` unless it belonged to a marker
    /// sequence — except for bytes still inside an unfinished sequence, which
    /// come back with the chunk that completes it.
    public mutating func scan(_ bytes: ArraySlice<UInt8>) -> [ShellIntegrationToken] {
        var tokens: [ShellIntegrationToken] = []
        for byte in bytes {
            step(byte, into: &tokens)
        }
        flushPlain(into: &tokens)
        return tokens
    }

    /// Abandon any half-parsed sequence, returning its bytes. Used when the
    /// stream ends, so that nothing is silently swallowed.
    public mutating func flush() -> [ShellIntegrationToken] {
        var tokens: [ShellIntegrationToken] = []
        abandonSequence(into: &tokens)
        flushPlain(into: &tokens)
        return tokens
    }

    private mutating func flushPlain(into tokens: inout [ShellIntegrationToken]) {
        guard !plain.isEmpty else { return }
        tokens.append(.bytes(plain))
        plain.removeAll(keepingCapacity: true)
    }

    /// The sequence turned out not to be a marker: its bytes are output after
    /// all.
    private mutating func abandonSequence(into tokens: inout [ShellIntegrationToken]) {
        plain.append(contentsOf: held)
        held.removeAll(keepingCapacity: true)
        payload.removeAll(keepingCapacity: true)
        state = .ground
    }

    /// The sequence was a marker: its bytes are not output.
    private mutating func consumeSequence() {
        held.removeAll(keepingCapacity: true)
        payload.removeAll(keepingCapacity: true)
        state = .ground
    }

    private mutating func step(_ byte: UInt8, into tokens: inout [ShellIntegrationToken]) {
        switch state {
        case .ground:
            switch byte {
            case 0x1B: // ESC
                held.append(byte)
                state = .escape
            default:
                // The 8-bit C1 forms of CSI and OSC (0x9B, 0x9D) are
                // deliberately not recognised. A terminal in UTF-8 mode never
                // sends them, and 0x80–0x9F are continuation bytes of ordinary
                // characters — treating 0x9D as an OSC introducer would
                // silently swallow the rest of a line whenever someone typed
                // Arabic, or a box-drawing character, or an emoji.
                plain.append(byte)
            }

        case .escape:
            held.append(byte)
            switch byte {
            case 0x5D: // ']'
                state = .osc
            case 0x5B: // '['
                state = .csi
            case 0x1B:
                // Two ESCs in a row: the first was not a sequence after all.
                held.removeLast()
                abandonSequence(into: &tokens)
                held.append(byte)
                state = .escape
            default:
                // `ESC` plus one byte: a complete two-byte sequence, and never
                // a marker.
                abandonSequence(into: &tokens)
            }

        case .osc:
            held.append(byte)
            switch byte {
            case 0x07: // BEL
                emitOSC(into: &tokens)
            case 0x1B:
                state = .oscEscape
            case 0x18, 0x1A: // CAN, SUB — abort the sequence
                abandonSequence(into: &tokens)
            default:
                payload.append(byte)
                if held.count > Self.maximumSequenceLength {
                    abandonSequence(into: &tokens)
                }
            }

        case .oscEscape:
            if byte == 0x5C { // '\' — ST
                held.append(byte)
                emitOSC(into: &tokens)
            } else {
                // Never terminated. Give the bytes back and re-examine this
                // one from the ground state: it may start a sequence itself.
                held.removeLast() // the ESC that put us here
                abandonSequence(into: &tokens)
                step(0x1B, into: &tokens)
                step(byte, into: &tokens)
            }

        case .csi:
            held.append(byte)
            switch byte {
            case 0x20...0x3F:
                payload.append(byte)
                if held.count > Self.maximumSequenceLength {
                    abandonSequence(into: &tokens)
                }
            case 0x40...0x7E: // final byte
                emitCSI(final: byte, into: &tokens)
            default:
                abandonSequence(into: &tokens)
            }
        }
    }

    private mutating func emitOSC(into tokens: inout [ShellIntegrationToken]) {
        guard let marker = Self.marker(forOSCPayload: payload) else {
            abandonSequence(into: &tokens)
            return
        }
        flushPlain(into: &tokens)
        tokens.append(.marker(marker))
        consumeSequence()
    }

    private mutating func emitCSI(final: UInt8, into tokens: inout [ShellIntegrationToken]) {
        guard let marker = Self.alternateScreenMarker(parameters: payload, final: final) else {
            abandonSequence(into: &tokens)
            return
        }
        flushPlain(into: &tokens)
        tokens.append(.marker(marker))
        // The sequence is passed through as well: switching screens is the
        // emulator's business too, and a caller that forwards these bytes
        // must not have them removed.
        plain.append(contentsOf: held)
        consumeSequence()
    }

    private static func marker(forOSCPayload payload: [UInt8]) -> ShellIntegrationMarker? {
        // Payload is `<number> ; <fields...>`. Only 133 and 633 interest us;
        // window titles, hyperlinks and colours belong to the emulator.
        guard let semicolon = payload.firstIndex(of: 0x3B) else { return nil }
        let identifier = payload[..<semicolon]
        let isVSCode = identifier.elementsEqual([0x36, 0x33, 0x33]) // "633"
        guard isVSCode || identifier.elementsEqual([0x31, 0x33, 0x33]) else { return nil } // "133"

        let rest = payload[payload.index(after: semicolon)...]
        var fields = rest.split(separator: 0x3B, omittingEmptySubsequences: false)
        guard let kind = fields.first, kind.count == 1 else { return nil }
        fields.removeFirst()

        switch kind.first! {
        case 0x41: // 'A'
            return .promptStart
        case 0x42: // 'B'
            return .commandStart
        case 0x43: // 'C'
            return .commandExecuted
        case 0x44: // 'D'
            return .commandFinished(exitStatus: exitStatus(fields.first))
        case 0x45: // 'E' — VS Code only, and the only marker that states the
                   // command as text rather than leaving it to the echo.
            guard isVSCode else { return nil }
            // The command line may itself contain semicolons, so take
            // everything after the kind rather than the first field.
            guard rest.count > 1, rest[rest.index(rest.startIndex, offsetBy: 1)] == 0x3B else { return nil }
            guard let text = decodeCommandLine(Array(rest.dropFirst(2))) else { return nil }
            return .commandLine(text)
        default:
            return nil
        }
    }

    private static func alternateScreenMarker(parameters: [UInt8], final: UInt8) -> ShellIntegrationMarker? {
        // `CSI ? <n> h` sets a private mode, `l` resets it. Only the three
        // alternate-screen modes matter here.
        guard final == 0x68 || final == 0x6C else { return nil } // 'h' / 'l'
        guard parameters.first == 0x3F else { return nil }       // '?'
        // Several modes can be set at once: `CSI ? 1049 ; 25 h`.
        for parameter in parameters.dropFirst().split(separator: 0x3B, omittingEmptySubsequences: false) {
            guard let value = decimal(parameter), value == 47 || value == 1047 || value == 1049 else { continue }
            return .alternateScreen(active: final == 0x68)
        }
        return nil
    }

    private static func exitStatus(_ field: ArraySlice<UInt8>?) -> Int32? {
        guard let field, !field.isEmpty, let value = decimal(field) else { return nil }
        return Int32(clamping: value)
    }

    private static func decimal(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
            if value > 1 << 24 { return nil }
        }
        return value
    }

    /// VS Code escapes control characters in the command line as `\xNN`, and a
    /// literal backslash as `\\`, so that the OSC payload stays one line.
    private static func decodeCommandLine(_ bytes: [UInt8]) -> String? {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            guard byte == 0x5C, bytes.index(after: index) < bytes.endIndex else {
                out.append(byte)
                index = bytes.index(after: index)
                continue
            }
            let next = bytes[bytes.index(after: index)]
            if next == 0x5C {
                out.append(0x5C)
                index = bytes.index(index, offsetBy: 2)
            } else if next == 0x78, bytes.index(index, offsetBy: 3) < bytes.endIndex,
                      let high = hexDigit(bytes[bytes.index(index, offsetBy: 2)]),
                      let low = hexDigit(bytes[bytes.index(index, offsetBy: 3)]) {
                out.append(high << 4 | low)
                index = bytes.index(index, offsetBy: 4)
            } else {
                out.append(byte)
                index = bytes.index(after: index)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}
