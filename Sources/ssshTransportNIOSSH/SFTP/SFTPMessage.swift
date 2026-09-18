import Foundation
import NIOCore
import ssshCore

/// SFTP protocol version 3, as in `draft-ietf-secsh-filexfer-02`.
///
/// Version 3 rather than 6 because it is what every server in existence
/// actually implements: OpenSSH — which is what almost everyone is connecting
/// to — has never shipped anything newer, and the later drafts' attribute model
/// is incompatible enough that supporting both is two implementations.
enum SFTPProtocol {
    static let version: UInt32 = 3
    /// Read and write in 32 KiB pieces. OpenSSH's default maximum packet is
    /// 256 KiB, but 32 KiB is what every server accepts and what `sftp(1)`
    /// itself uses, and the difference is not where transfer speed lives.
    static let preferredChunkSize = 32 * 1024
}

enum SFTPPacketType: UInt8 {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attributes = 105
    case extended = 200
    case extendedReply = 201
}

enum SFTPStatusCode: UInt32 {
    case ok = 0
    case endOfFile = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case operationUnsupported = 8
}

/// Open flags, which are the protocol's own and not the POSIX ones.
struct SFTPOpenFlags: OptionSet {
    let rawValue: UInt32

    static let read = SFTPOpenFlags(rawValue: 0x0000_0001)
    static let write = SFTPOpenFlags(rawValue: 0x0000_0002)
    static let append = SFTPOpenFlags(rawValue: 0x0000_0004)
    static let create = SFTPOpenFlags(rawValue: 0x0000_0008)
    static let truncate = SFTPOpenFlags(rawValue: 0x0000_0010)
    static let exclusive = SFTPOpenFlags(rawValue: 0x0000_0020)

    init(rawValue: UInt32) { self.rawValue = rawValue }

    init(_ mode: RemoteFileOpenMode) {
        var flags = SFTPOpenFlags(rawValue: 0)
        if mode.contains(.read) { flags.insert(.read) }
        if mode.contains(.write) { flags.insert(.write) }
        if mode.contains(.append) { flags.insert(.append) }
        if mode.contains(.create) { flags.insert(.create) }
        if mode.contains(.truncate) { flags.insert(.truncate) }
        if mode.contains(.exclusive) { flags.insert(.exclusive) }
        self = flags
    }
}

/// One request, in the form the handler writes.
enum SFTPRequest {
    case open(path: String, flags: SFTPOpenFlags, attributes: RemoteFileAttributes?)
    case close(handle: ByteBuffer)
    case read(handle: ByteBuffer, offset: UInt64, length: UInt32)
    case write(handle: ByteBuffer, offset: UInt64, data: ByteBuffer)
    case lstat(path: String)
    case fstat(handle: ByteBuffer)
    case setstat(path: String, attributes: RemoteFileAttributes)
    case fsetstat(handle: ByteBuffer, attributes: RemoteFileAttributes)
    case opendir(path: String)
    case readdir(handle: ByteBuffer)
    case remove(path: String)
    case mkdir(path: String, attributes: RemoteFileAttributes?)
    case rmdir(path: String)
    case realpath(path: String)
    case stat(path: String)
    case rename(from: String, to: String)
    case readlink(path: String)
    case symlink(linkPath: String, target: String)

    var type: SFTPPacketType {
        switch self {
        case .open: return .open
        case .close: return .close
        case .read: return .read
        case .write: return .write
        case .lstat: return .lstat
        case .fstat: return .fstat
        case .setstat: return .setstat
        case .fsetstat: return .fsetstat
        case .opendir: return .opendir
        case .readdir: return .readdir
        case .remove: return .remove
        case .mkdir: return .mkdir
        case .rmdir: return .rmdir
        case .realpath: return .realpath
        case .stat: return .stat
        case .rename: return .rename
        case .readlink: return .readlink
        case .symlink: return .symlink
        }
    }

    /// The path the request is about, kept so an error can name it. The
    /// protocol's own error replies carry only a status code and a free-text
    /// message, neither of which says which file failed.
    var path: String? {
        switch self {
        case .open(let path, _, _), .lstat(let path), .setstat(let path, _), .opendir(let path),
             .remove(let path), .mkdir(let path, _), .rmdir(let path), .realpath(let path),
             .stat(let path), .readlink(let path), .symlink(let path, _):
            return path
        case .rename(let from, _):
            return from
        case .close, .read, .write, .fstat, .fsetstat, .readdir:
            return nil
        }
    }

    func encodeBody(into buffer: inout ByteBuffer) {
        switch self {
        case .open(let path, let flags, let attributes):
            buffer.writeSFTPString(path)
            buffer.writeInteger(flags.rawValue)
            buffer.writeSFTPAttributes(attributes)
        case .close(let handle), .fstat(let handle), .readdir(let handle):
            buffer.writeSFTPBytes(handle)
        case .read(let handle, let offset, let length):
            buffer.writeSFTPBytes(handle)
            buffer.writeInteger(offset)
            buffer.writeInteger(length)
        case .write(let handle, let offset, let data):
            buffer.writeSFTPBytes(handle)
            buffer.writeInteger(offset)
            buffer.writeSFTPBytes(data)
        case .lstat(let path), .opendir(let path), .remove(let path), .rmdir(let path),
             .realpath(let path), .stat(let path), .readlink(let path):
            buffer.writeSFTPString(path)
        case .setstat(let path, let attributes):
            buffer.writeSFTPString(path)
            buffer.writeSFTPAttributes(attributes)
        case .fsetstat(let handle, let attributes):
            buffer.writeSFTPBytes(handle)
            buffer.writeSFTPAttributes(attributes)
        case .mkdir(let path, let attributes):
            buffer.writeSFTPString(path)
            buffer.writeSFTPAttributes(attributes)
        case .rename(let from, let to):
            buffer.writeSFTPString(from)
            buffer.writeSFTPString(to)
        case .symlink(let linkPath, let target):
            // Note the order. OpenSSH's server reads `targetpath` first and
            // then `linkpath`, contradicting the draft, and every client in
            // the world matches the server rather than the document.
            buffer.writeSFTPString(target)
            buffer.writeSFTPString(linkPath)
        }
    }
}

struct SFTPStatus: Hashable, Sendable {
    var code: SFTPStatusCode
    var message: String?

    /// Turns a status into the error the app will show, or `nil` when it is
    /// not an error at all.
    func asError(path: String?) -> SFTPError? {
        switch code {
        case .ok, .endOfFile:
            return nil
        case .noSuchFile:
            return .noSuchFile(path: path ?? "", serverMessage: message)
        case .permissionDenied:
            return .permissionDenied(path: path ?? "", serverMessage: message)
        case .failure:
            return .failure(path: path, serverMessage: message)
        case .badMessage:
            return .protocolViolation(message ?? "the server rejected the request as malformed")
        case .noConnection, .connectionLost:
            return .connectionLost
        case .operationUnsupported:
            return .unsupportedOperation(message ?? "the server does not support this operation")
        }
    }
}

struct SFTPNameEntry {
    var filename: String
    /// The `ls -l`-style line version 3 sends alongside each name. Worth
    /// keeping only as a fallback: it is the one place a file's type shows up
    /// when a server omits the permission bits.
    var longName: String
    var attributes: RemoteFileAttributes
}

enum SFTPResponse {
    case status(SFTPStatus)
    case handle(ByteBuffer)
    case data(ByteBuffer)
    case name([SFTPNameEntry])
    case attributes(RemoteFileAttributes)
    case extendedReply(ByteBuffer)
}

/// Framing, kept apart from the handler so it can be tested against a second
/// implementation's bytes rather than against itself.
enum SFTPCodec {
    /// A single packet may not exceed this. The protocol allows a 32-bit
    /// length; believing it would let one confused server make this allocate
    /// gigabytes. OpenSSH itself refuses anything over 256 KiB.
    static let maximumPacketLength = 512 * 1024

    static func encode(_ request: SFTPRequest, id: UInt32, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: 64)
        body.writeInteger(id)
        request.encodeBody(into: &body)
        return frame(type: request.type, body: body, allocator: allocator)
    }

    static func encodeInitialize(version: UInt32, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: 4)
        body.writeInteger(version)
        return frame(type: .initialize, body: body, allocator: allocator)
    }

    static func frame(type: SFTPPacketType, body: ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        var packet = allocator.buffer(capacity: body.readableBytes + 5)
        packet.writeInteger(UInt32(body.readableBytes + 1))
        packet.writeInteger(type.rawValue)
        var body = body
        packet.writeBuffer(&body)
        return packet
    }

    /// Decodes a reply body, with the type byte and request id already read.
    static func decodeResponse(type: SFTPPacketType, from packet: inout ByteBuffer) throws -> SFTPResponse {
        switch type {
        case .status:
            guard let rawCode: UInt32 = packet.readInteger() else {
                throw SFTPError.protocolViolation("a status reply carried no code")
            }
            // The message and language fields were added in version 3, and
            // some servers still omit them, so their absence is not an error.
            let message = packet.readSFTPString()
            let code = SFTPStatusCode(rawValue: rawCode) ?? .failure
            return .status(SFTPStatus(code: code, message: (message?.isEmpty ?? true) ? nil : message))

        case .handle:
            guard let handle = packet.readSFTPBytes() else {
                throw SFTPError.protocolViolation("a handle reply was truncated")
            }
            return .handle(handle)

        case .data:
            guard let data = packet.readSFTPBytes() else {
                throw SFTPError.protocolViolation("a data reply was truncated")
            }
            return .data(data)

        case .name:
            guard let count: UInt32 = packet.readInteger() else {
                throw SFTPError.protocolViolation("a name reply carried no count")
            }
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                guard let filename = packet.readSFTPString(),
                      let longName = packet.readSFTPString(),
                      var attributes = packet.readSFTPAttributes()
                else {
                    throw SFTPError.protocolViolation("a name reply was truncated")
                }
                if attributes.kind == .other, let first = longName.first,
                   let kind = RemoteFileAttributes.Kind(longNameTypeCharacter: first) {
                    // The server sent no permission bits. The `ls -l` line is
                    // the only other place the type appears, and a browser
                    // that cannot tell a directory from a file is not one.
                    attributes.kind = kind
                }
                entries.append(SFTPNameEntry(filename: filename, longName: longName, attributes: attributes))
            }
            return .name(entries)

        case .attributes:
            guard let attributes = packet.readSFTPAttributes() else {
                throw SFTPError.protocolViolation("an attributes reply was truncated")
            }
            return .attributes(attributes)

        case .extendedReply:
            return .extendedReply(packet.readSlice(length: packet.readableBytes) ?? ByteBuffer())

        default:
            throw SFTPError.protocolViolation("the server sent a request where a reply was expected")
        }
    }
}
