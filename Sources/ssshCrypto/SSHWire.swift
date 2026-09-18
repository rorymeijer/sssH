import Foundation

/// A forward-only reader for SSH's wire encoding (RFC 4251 §5).
///
/// Every length is attacker-controlled in the cases that matter — a key file
/// pasted from somewhere, a blob off the network — so every read is bounds
/// checked and returns `nil` rather than trapping. A parser built on this
/// cannot be made to read past the end of its input or to allocate on a
/// corrupt length field.
public struct SSHWireReader {
    private let bytes: [UInt8]
    private var offset: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { remaining == 0 }

    public mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, count <= remaining else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    public mutating func readUInt32() -> UInt32? {
        guard let slice = readBytes(4) else { return nil }
        return (UInt32(slice[0]) << 24) | (UInt32(slice[1]) << 16) | (UInt32(slice[2]) << 8) | UInt32(slice[3])
    }

    /// A 32-bit big-endian length followed by that many bytes.
    public mutating func readString() -> [UInt8]? {
        guard let length = readUInt32() else { return nil }
        // A length field claiming more than the whole input is corrupt; check
        // before converting to Int so a 4 GB claim cannot be allocated.
        guard length <= UInt32(clamping: remaining) else { return nil }
        return readBytes(Int(length))
    }

    public mutating func readStringAsText() -> String? {
        readString().map { String(decoding: $0, as: UTF8.self) }
    }

    /// An `mpint`: a string holding a signed big-endian integer.
    ///
    /// A positive value whose top bit is set carries a leading zero byte to
    /// keep it from reading as negative. That padding is stripped here, because
    /// every consumer in sssh wants the unsigned magnitude.
    public mutating func readMPInt() -> [UInt8]? {
        guard var value = readString() else { return nil }
        while value.first == 0 { value.removeFirst() }
        return value
    }

    public mutating func readAllRemaining() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[offset...])
    }
}

/// Builds SSH wire encoding. Used to reconstruct the blobs a key's
/// representation needs.
public struct SSHWireWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    /// Appends bytes with no length prefix.
    ///
    /// Almost nothing in SSH wire format is raw — a string carries its length,
    /// and reaching past that is how a parser and a writer stop agreeing. The
    /// exception this exists for is `openssh-key-v1\0`, the magic at the head
    /// of a private key file, which is a NUL-terminated C string rather than an
    /// SSH one. Anything else should use ``writeString(_:)``.
    public mutating func writeRaw(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    public mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    public mutating func writeString(_ value: [UInt8]) {
        writeUInt32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func writeString(_ value: String) {
        writeString(Array(value.utf8))
    }

    /// Writes an unsigned magnitude as an `mpint`, adding the leading zero byte
    /// when the top bit would otherwise make it negative.
    public mutating func writeMPInt(_ magnitude: [UInt8]) {
        var value = magnitude
        while value.first == 0 { value.removeFirst() }

        if value.isEmpty {
            writeUInt32(0)
            return
        }
        if value[0] & 0x80 != 0 {
            value.insert(0, at: 0)
        }
        writeString(value)
    }
}
