import Foundation
import SwiftData
import ssshCore

/// A host key the user has chosen to trust.
///
/// Fingerprints are not secrets, so unlike credentials these do sync — which
/// is the point: trust decided on a Mac should not have to be decided again on
/// an iPad.
@Model
final class KnownHostEntry {
    /// OpenSSH's `known_hosts` form: `hostname`, or `[hostname]:port` for a
    /// non-default port.
    var hostKey: String = ""
    /// e.g. `ssh-ed25519`.
    var algorithm: String = ""
    /// The key's SSH wire encoding — what identity is actually compared on.
    /// Stored base64 because SwiftData handles `Data` better than `[UInt8]`.
    var wireFormatBase64: String = ""
    /// `SHA256:…`, cached for display so the UI never has to hash anything.
    var sha256Fingerprint: String = ""
    var trustedAt: Date = Date()
    /// Set when a key replaces one the user accepted before, so the UI can show
    /// "this changed on <date>" rather than silently overwriting history.
    var replacedKeyFingerprint: String?

    init(hostKey: String = "", algorithm: String = "", wireFormatBase64: String = "", sha256Fingerprint: String = "") {
        self.hostKey = hostKey
        self.algorithm = algorithm
        self.wireFormatBase64 = wireFormatBase64
        self.sha256Fingerprint = sha256Fingerprint
    }

    convenience init(endpoint: SSHEndpoint, key: SSHHostKey) {
        self.init(
            hostKey: endpoint.knownHostsKey,
            algorithm: key.algorithm,
            wireFormatBase64: Data(key.wireFormat).base64EncodedString(),
            sha256Fingerprint: key.sha256Fingerprint ?? ""
        )
    }

    var sshHostKey: SSHHostKey? {
        guard let data = Data(base64Encoded: wireFormatBase64) else { return nil }
        return SSHHostKey(
            algorithm: algorithm,
            wireFormat: Array(data),
            sha256Fingerprint: sha256Fingerprint.isEmpty ? nil : sha256Fingerprint
        )
    }
}
