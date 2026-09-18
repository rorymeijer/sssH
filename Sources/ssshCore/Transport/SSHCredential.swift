import Foundation

/// A single authentication attempt the transport may offer to the server.
///
/// Secrets arrive here already resolved: the synced model stores an opaque
/// `authRef` and the secrets store hands the plaintext to the session layer,
/// which builds these values and drops them as soon as the handshake finishes.
/// Nothing in this type is persisted or logged.
public enum SSHCredential: Sendable {
    case password(SecretString)
    case privateKey(SSHPrivateKeyMaterial)

    /// `none` is a real SSH method: servers answer it with the list of methods
    /// they will accept, which is how we can tell the user *why* auth failed.
    case none

    /// Offering the running ssh-agent's identities.
    ///
    /// Not implemented by the Citadel backend — see
    /// docs/PHASE-0-BACKEND-DECISION.md. Kept in the enum so the surface does
    /// not change when a backend gains support, and so `switch` sites are
    /// forced to handle it.
    case agent

    /// PAM-style challenge/response, answered by the supplied handler.
    ///
    /// Not implemented by the Citadel backend: swift-nio-ssh has no
    /// `keyboard-interactive` support at all.
    case keyboardInteractive(SSHKeyboardInteractiveHandler)
}

extension SSHCredential {
    /// A description safe to log or show in a connection log: never includes
    /// key material, passphrases or passwords.
    public var diagnosticName: String {
        switch self {
        case .password: return "password"
        case .privateKey(let material): return "publickey(\(material.label ?? "unnamed"))"
        case .none: return "none"
        case .agent: return "agent"
        case .keyboardInteractive: return "keyboard-interactive"
        }
    }
}

/// An OpenSSH-format private key plus the passphrase needed to open it.
public struct SSHPrivateKeyMaterial: Sendable {
    /// The full `-----BEGIN OPENSSH PRIVATE KEY-----` armored text.
    public var openSSHPrivateKey: SecretString
    /// `nil` for an unencrypted key.
    public var passphrase: SecretString?
    /// Human-readable name for diagnostics only (e.g. the key's Keychain label).
    public var label: String?

    public init(openSSHPrivateKey: SecretString, passphrase: SecretString? = nil, label: String? = nil) {
        self.openSSHPrivateKey = openSSHPrivateKey
        self.passphrase = passphrase
        self.label = label
    }
}

/// Answers `keyboard-interactive` challenges.
public protocol SSHKeyboardInteractiveHandler: Sendable {
    func respond(to challenge: SSHKeyboardInteractiveChallenge) async throws -> [SecretString]
}

public struct SSHKeyboardInteractiveChallenge: Sendable {
    public var name: String
    public var instruction: String
    public var prompts: [Prompt]

    public struct Prompt: Sendable {
        public var text: String
        public var echo: Bool

        public init(text: String, echo: Bool) {
            self.text = text
            self.echo = echo
        }
    }

    public init(name: String, instruction: String, prompts: [Prompt]) {
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }
}

/// A string that will not be printed by accident.
///
/// `description`, `debugDescription` and the `Codable` conformance are all
/// deliberately absent or redacted, so a secret cannot end up in a log line, a
/// crash report or a SwiftData store through interpolation.
public struct SecretString: Sendable, ExpressibleByStringLiteral, CustomStringConvertible, CustomDebugStringConvertible {
    private let storage: String

    public init(_ value: String) {
        self.storage = value
    }

    public init(stringLiteral value: StringLiteralType) {
        self.storage = value
    }

    /// The only way to read the secret. Named to make call sites conspicuous
    /// in review.
    public func reveal() -> String { storage }

    public func revealBytes() -> [UInt8] { Array(storage.utf8) }

    public var isEmpty: Bool { storage.isEmpty }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}
