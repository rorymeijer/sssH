import Foundation

/// Remote file access over the SFTP subsystem.
///
/// Declared in Phase 0 so the file browser (Phase 4) is written against a
/// protocol from the start. Reads and writes are offset-based and streaming:
/// nothing here loads a whole file or a whole directory into memory, because
/// the app has to survive a 20 GB log and a directory with 100 000 entries.
public protocol SFTPService: AnyObject, Sendable {
    func realPath(of path: String) async throws -> String

    /// Streams a directory in server-sized batches.
    func listDirectory(at path: String) -> AsyncThrowingStream<[RemoteFileEntry], Error>

    func attributes(of path: String) async throws -> RemoteFileAttributes
    func setAttributes(_ attributes: RemoteFileAttributes, of path: String) async throws

    func createDirectory(at path: String, permissions: POSIXPermissions?) async throws
    func remove(at path: String) async throws
    func removeDirectory(at path: String) async throws
    func rename(from: String, to: String) async throws

    /// The raw target of a symlink, unresolved.
    func readLink(at path: String) async throws -> String
    func createSymbolicLink(at path: String, to target: String) async throws

    /// Opens a remote file. The handle is closed when the returned value is
    /// closed, not when it is deallocated — SFTP handles are a server
    /// resource and leaking them exhausts the session.
    func openFile(at path: String, mode: RemoteFileOpenMode) async throws -> any RemoteFileHandle

    func close() async
}

public extension RemoteFileAttributes {
    /// True for a directory, following nothing: a symlink to a directory is a
    /// symlink here. The browser resolves those itself, because resolving them
    /// in the transport would hide the loops.
    var isDirectory: Bool { kind == .directory }
}

/// One directory entry.
///
/// `Identifiable` by name, which is unique within a directory and nowhere else
/// — which is exactly the scope a file list uses it in.
public struct RemoteFileEntry: Hashable, Sendable, Identifiable {
    public var id: String { name }

    public var name: String
    public var attributes: RemoteFileAttributes
    /// For a symlink, the raw target as stored on the server. Resolving it is
    /// the browser's job, and it must not follow loops.
    public var symlinkTarget: String?

    public init(name: String, attributes: RemoteFileAttributes, symlinkTarget: String? = nil) {
        self.name = name
        self.attributes = attributes
        self.symlinkTarget = symlinkTarget
    }
}

public struct RemoteFileAttributes: Hashable, Sendable {
    public enum Kind: Sendable, Hashable {
        case file, directory, symlink, other
    }

    public var kind: Kind
    public var size: UInt64?
    public var permissions: POSIXPermissions?
    public var userID: UInt32?
    public var groupID: UInt32?
    public var modifiedAt: Date?
    public var accessedAt: Date?

    public init(
        kind: Kind,
        size: UInt64? = nil,
        permissions: POSIXPermissions? = nil,
        userID: UInt32? = nil,
        groupID: UInt32? = nil,
        modifiedAt: Date? = nil,
        accessedAt: Date? = nil
    ) {
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.userID = userID
        self.groupID = groupID
        self.modifiedAt = modifiedAt
        self.accessedAt = accessedAt
    }
}

public struct POSIXPermissions: Hashable, Sendable, CustomStringConvertible {
    /// The low 12 bits of `st_mode`: setuid/setgid/sticky plus rwx triplets.
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue & 0o7777
    }

    /// `rwxr-xr-x`-style rendering, as `ls -l` shows it.
    public var description: String {
        var out = ""
        for shift in stride(from: 6, through: 0, by: -3) {
            let bits = (rawValue >> UInt16(shift)) & 0o7
            out += (bits & 0o4) != 0 ? "r" : "-"
            out += (bits & 0o2) != 0 ? "w" : "-"
            out += (bits & 0o1) != 0 ? "x" : "-"
        }
        return out
    }
}

public struct RemoteFileOpenMode: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = RemoteFileOpenMode(rawValue: 1 << 0)
    public static let write = RemoteFileOpenMode(rawValue: 1 << 1)
    public static let append = RemoteFileOpenMode(rawValue: 1 << 2)
    public static let create = RemoteFileOpenMode(rawValue: 1 << 3)
    public static let truncate = RemoteFileOpenMode(rawValue: 1 << 4)
    public static let exclusive = RemoteFileOpenMode(rawValue: 1 << 5)
}

public protocol RemoteFileHandle: AnyObject, Sendable {
    func readAttributes() async throws -> RemoteFileAttributes
    /// Reads at most `length` bytes at `offset`. A short read is normal and
    /// does not mean end-of-file; an empty result does.
    func read(at offset: UInt64, length: Int) async throws -> [UInt8]
    func write(_ bytes: [UInt8], at offset: UInt64) async throws
    func close() async throws
}
