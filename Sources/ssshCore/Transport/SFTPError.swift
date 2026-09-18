import Foundation

/// What went wrong on the remote side of an SFTP operation.
///
/// Structured rather than a message, for the same reason
/// ``SSHTransportError`` is: the app has to be able to say it in Dutch, and to
/// decide what to offer next. "Permission denied" leads to a different offer
/// than "no such file", and a string cannot be branched on.
///
/// The server's own message is carried along where it sent one, because an
/// sshd that explains itself is worth quoting — but it is never the only thing
/// the caller has to work with.
public enum SFTPError: Error, Hashable, Sendable {
    case noSuchFile(path: String, serverMessage: String?)
    case permissionDenied(path: String, serverMessage: String?)
    /// The server said no without saying why. This is what most servers send
    /// for "directory not empty", "disk full" and "invalid name" alike.
    case failure(path: String?, serverMessage: String?)
    case unsupportedOperation(String)
    /// The server sent something the protocol does not allow. A bug on one
    /// side or the other, and never worth retrying.
    case protocolViolation(String)
    /// The channel went away mid-operation.
    case connectionLost
    /// The server offered a protocol version this client cannot speak.
    case unsupportedProtocolVersion(UInt32)

    /// The path the operation was about, when there was one.
    public var path: String? {
        switch self {
        case .noSuchFile(let path, _), .permissionDenied(let path, _):
            return path
        case .failure(let path, _):
            return path
        case .unsupportedOperation, .protocolViolation, .connectionLost, .unsupportedProtocolVersion:
            return nil
        }
    }

    public var serverMessage: String? {
        switch self {
        case .noSuchFile(_, let message), .permissionDenied(_, let message), .failure(_, let message):
            return message
        case .unsupportedOperation, .protocolViolation, .connectionLost, .unsupportedProtocolVersion:
            return nil
        }
    }

    /// Whether trying the same thing again could plausibly work. A transfer
    /// queue uses this to decide between retrying and stopping; retrying a
    /// permission error forever is how a queue becomes a spinner nobody
    /// trusts.
    public var isWorthRetrying: Bool {
        switch self {
        case .connectionLost:
            return true
        case .noSuchFile, .permissionDenied, .failure, .unsupportedOperation,
             .protocolViolation, .unsupportedProtocolVersion:
            return false
        }
    }
}
