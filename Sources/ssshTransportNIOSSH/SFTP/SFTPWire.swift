import Foundation
import NIOCore
import ssshCore

/// SFTP's encoding, which is SSH's (RFC 4251) plus one attribute structure.
///
/// Reads return `nil` on a short or malformed buffer rather than trapping. A
/// server that sends a truncated packet is a server bug, and the right answer
/// is a protocol error the user can see, not a crash in a file browser.
extension ByteBuffer {
    // MARK: - Writing

    mutating func writeSFTPString(_ value: String) {
        let bytes = Array(value.utf8)
        writeInteger(UInt32(bytes.count))
        writeBytes(bytes)
    }

    mutating func writeSFTPBytes(_ value: ByteBuffer) {
        writeInteger(UInt32(value.readableBytes))
        var copy = value
        writeBuffer(&copy)
    }

    mutating func writeSFTPAttributes(_ attributes: RemoteFileAttributes?) {
        guard let attributes else {
            writeInteger(UInt32(0))
            return
        }

        var flags: UInt32 = 0
        if attributes.size != nil { flags |= SFTPAttributeFlags.size }
        if attributes.userID != nil, attributes.groupID != nil { flags |= SFTPAttributeFlags.userAndGroup }
        if attributes.permissions != nil { flags |= SFTPAttributeFlags.permissions }
        if attributes.accessedAt != nil, attributes.modifiedAt != nil { flags |= SFTPAttributeFlags.times }

        writeInteger(flags)
        if let size = attributes.size { writeInteger(size) }
        if let userID = attributes.userID, let groupID = attributes.groupID {
            writeInteger(userID)
            writeInteger(groupID)
        }
        if let permissions = attributes.permissions {
            // Version 3's `permissions` field is the whole of `st_mode`, so the
            // file-type bits have to be put back or a `setstat` that only means
            // to change the mode will tell the server the file is now a
            // regular file with mode 0.
            writeInteger(UInt32(permissions.rawValue) | attributes.kind.modeTypeBits)
        }
        if let accessedAt = attributes.accessedAt, let modifiedAt = attributes.modifiedAt {
            writeInteger(UInt32(clamping: Int64(accessedAt.timeIntervalSince1970)))
            writeInteger(UInt32(clamping: Int64(modifiedAt.timeIntervalSince1970)))
        }
    }

    // MARK: - Reading

    mutating func readSFTPBytes() -> ByteBuffer? {
        guard let length: UInt32 = readInteger() else { return nil }
        // A length field is 32 bits and an attacker — or a confused server —
        // can put anything in it. Trusting it before checking what is actually
        // present is how a parser turns into an allocation of 4 GB.
        guard length <= UInt32(readableBytes) else { return nil }
        return readSlice(length: Int(length))
    }

    mutating func readSFTPString() -> String? {
        guard let bytes = readSFTPBytes() else { return nil }
        // Filenames on a POSIX server are bytes, not text, and a server can
        // and does hand back names that are not valid UTF-8. Replacing the
        // invalid parts keeps the browser usable instead of hiding the file.
        return String(buffer: bytes)
    }

    mutating func readSFTPAttributes() -> RemoteFileAttributes? {
        guard let flags: UInt32 = readInteger() else { return nil }

        var size: UInt64?
        var userID: UInt32?
        var groupID: UInt32?
        var mode: UInt32?
        var accessedAt: Date?
        var modifiedAt: Date?

        if flags & SFTPAttributeFlags.size != 0 {
            guard let value: UInt64 = readInteger() else { return nil }
            size = value
        }
        if flags & SFTPAttributeFlags.userAndGroup != 0 {
            guard let user: UInt32 = readInteger(), let group: UInt32 = readInteger() else { return nil }
            userID = user
            groupID = group
        }
        if flags & SFTPAttributeFlags.permissions != 0 {
            guard let value: UInt32 = readInteger() else { return nil }
            mode = value
        }
        if flags & SFTPAttributeFlags.times != 0 {
            guard let accessed: UInt32 = readInteger(), let modified: UInt32 = readInteger() else { return nil }
            accessedAt = Date(timeIntervalSince1970: TimeInterval(accessed))
            modifiedAt = Date(timeIntervalSince1970: TimeInterval(modified))
        }
        if flags & SFTPAttributeFlags.extended != 0 {
            guard let count: UInt32 = readInteger() else { return nil }
            // Bounded by what is left rather than by the count, for the same
            // reason as the string length above.
            for _ in 0..<min(count, UInt32(readableBytes)) {
                guard readSFTPBytes() != nil, readSFTPBytes() != nil else { return nil }
            }
        }

        return RemoteFileAttributes(
            kind: RemoteFileAttributes.Kind(mode: mode),
            size: size,
            permissions: mode.map { POSIXPermissions(rawValue: UInt16($0 & 0o7777)) },
            userID: userID,
            groupID: groupID,
            modifiedAt: modifiedAt,
            accessedAt: accessedAt
        )
    }
}

enum SFTPAttributeFlags {
    static let size: UInt32 = 0x0000_0001
    static let userAndGroup: UInt32 = 0x0000_0002
    static let permissions: UInt32 = 0x0000_0004
    static let times: UInt32 = 0x0000_0008
    static let extended: UInt32 = 0x8000_0000
}

extension RemoteFileAttributes.Kind {
    /// From `st_mode`'s type bits. Absent permissions means the server did not
    /// say, which is `.other` rather than a guess.
    init(mode: UInt32?) {
        guard let mode else {
            self = .other
            return
        }
        switch mode & 0o170_000 {
        case 0o040_000: self = .directory
        case 0o100_000: self = .file
        case 0o120_000: self = .symlink
        default: self = .other
        }
    }

    /// The `st_mode` type bits to put back when writing attributes.
    var modeTypeBits: UInt32 {
        switch self {
        case .directory: return 0o040_000
        case .file: return 0o100_000
        case .symlink: return 0o120_000
        case .other: return 0
        }
    }

    /// From the first character of a version 3 `longname`, which is an
    /// `ls -l` line. Only used when the server sent no permission bits.
    init?(longNameTypeCharacter character: Character) {
        switch character {
        case "d": self = .directory
        case "-": self = .file
        case "l": self = .symlink
        case "b", "c", "p", "s": self = .other
        default: return nil
        }
    }
}
