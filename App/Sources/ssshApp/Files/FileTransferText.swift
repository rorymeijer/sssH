import Foundation
import ssshCore

/// Turns an SFTP failure into something worth showing a person.
///
/// The counterpart to ``ConnectionFailureText``, and in the app for the same
/// reason: ``SFTPError`` carries the facts — which path, what the server said —
/// and the phrasing belongs where the String Catalog is.
///
/// The server's own message is included where there is one. An sshd that says
/// "Disk quota exceeded" has told the user exactly what to do, and throwing
/// that away to show "the operation failed" helps nobody.
enum FileTransferText {
    static func describe(_ error: Error) -> String {
        guard let sftpError = error as? SFTPError else {
            if error is CancellationError {
                return String(localized: "Geannuleerd.", comment: "A transfer was cancelled by the user")
            }
            return String(localized: "Er is iets misgegaan: \(String(describing: error))",
                          comment: "Fallback when a failure has no better description")
        }

        switch sftpError {
        case .noSuchFile(let path, let serverMessage):
            return withServerMessage(
                String(localized: "\(path) bestaat niet (meer).",
                       comment: "An SFTP operation named a path the server does not have"),
                serverMessage
            )

        case .permissionDenied(let path, let serverMessage):
            return withServerMessage(
                String(localized: "Geen toegang tot \(path).",
                       comment: "The server refused an SFTP operation for lack of permission"),
                serverMessage
            )

        case .failure(let path, let serverMessage):
            let base = path.map {
                String(localized: "De server kon de bewerking op \($0) niet uitvoeren.",
                       comment: "The server refused an SFTP operation without saying why, naming the path")
            } ?? String(localized: "De server kon de bewerking niet uitvoeren.",
                        comment: "The server refused an SFTP operation without saying why")
            return withServerMessage(base, serverMessage)

        case .unsupportedOperation(let detail):
            return String(localized: "De server ondersteunt deze bewerking niet: \(detail).",
                          comment: "The server does not implement the requested SFTP operation")

        case .protocolViolation(let detail):
            return String(localized: "De server sprak het SFTP-protocol niet correct: \(detail).",
                          comment: "The server sent something the SFTP protocol does not allow")

        case .connectionLost:
            return String(localized: "De verbinding is weggevallen tijdens de overdracht.",
                          comment: "The SSH connection dropped during a transfer")

        case .unsupportedProtocolVersion(let version):
            return String(localized: "De server spreekt SFTP-versie \(Int(version)); sssH heeft minstens versie 3 nodig.",
                          comment: "The server offered an SFTP protocol version this client cannot speak")
        }
    }

    private static func withServerMessage(_ text: String, _ serverMessage: String?) -> String {
        guard let serverMessage, !serverMessage.isEmpty else { return text }
        return String(localized: "\(text) De server zegt: \(serverMessage)",
                      comment: "Appends the server's own explanation to a failure message")
    }

    /// `1,2 MB` and friends. `ByteCountFormatStyle` already knows the
    /// conventions of every locale the app ships in, which is more than a
    /// hand-rolled divide-by-1024 does.
    static func formatBytes(_ bytes: UInt64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    static func formatRate(_ bytesPerSecond: Double) -> String {
        let amount = UInt64(max(0, bytesPerSecond))
        return String(localized: "\(formatBytes(amount))/s",
                      comment: "A transfer rate, as bytes per second")
    }
}
