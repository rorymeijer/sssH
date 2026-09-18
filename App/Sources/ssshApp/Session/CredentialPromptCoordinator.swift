import Foundation
import Observation
import ssshCore

/// Asks the user for a password or a key passphrase when one is not stored.
///
/// Two paths lead here, and both are deliberate rather than a fallback:
///
/// - a host set to "ask every time", which is what someone chooses when they do
///   not want a password on disk at all;
/// - a stored key whose passphrase is *not* stored, which is the safer way to
///   keep a key. That case is discovered by attempting the connection and
///   getting `passphraseRequired` back, rather than by inspecting the key file
///   up front — the transport already knows how to tell the difference, and
///   asking it is more reliable than guessing.
///
/// Answers are never written anywhere by this type. They live for one
/// connection attempt; persisting one is the caller's decision, which is what
/// `remember` reports.
@MainActor
@Observable
final class CredentialPromptCoordinator {
    enum Kind: Sendable {
        case password(username: String, endpoint: SSHEndpoint)
        case passphrase(keyLabel: String)
    }

    struct Answer: Sendable {
        var secret: SecretString
        /// Whether the user asked for this to be stored in the Keychain.
        var remember: Bool
    }

    struct PendingPrompt: Identifiable {
        let id = UUID()
        let kind: Kind
        /// Cleared as the answer is delivered, so it cannot be delivered twice.
        fileprivate var respond: ((Answer?) -> Void)?
    }

    private(set) var current: PendingPrompt?
    private var queue: [PendingPrompt] = []

    /// - Returns: the answer, or `nil` if the user cancelled.
    func ask(_ kind: Kind) async -> Answer? {
        await withCheckedContinuation { continuation in
            var prompt = PendingPrompt(kind: kind)
            prompt.respond = { continuation.resume(returning: $0) }
            queue.append(prompt)
            showNext()
        }
    }

    func submit(_ value: String, remember: Bool) {
        deliver(Answer(secret: SecretString(value), remember: remember))
    }

    func cancel() {
        deliver(nil)
    }

    /// Cancels everything outstanding, so a teardown cannot leave a connection
    /// attempt waiting on an answer that will never arrive.
    func cancelAll() {
        let outstanding = ([current].compactMap { $0 }) + queue
        current = nil
        queue.removeAll()
        for prompt in outstanding {
            prompt.respond?(nil)
        }
    }

    private func deliver(_ answer: Answer?) {
        guard var prompt = current else { return }
        let respond = prompt.respond
        prompt.respond = nil
        current = nil
        respond?(answer)
        showNext()
    }

    private func showNext() {
        guard current == nil, !queue.isEmpty else { return }
        current = queue.removeFirst()
    }
}
