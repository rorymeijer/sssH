import Foundation
import Observation
import ssshCore

/// Asks the user for whatever a connection needs that is not stored.
///
/// Three things arrive here, and all three are deliberate rather than
/// fallbacks:
///
/// - a host set to "ask every time", chosen by someone who does not want a
///   password on disk at all;
/// - a stored key whose passphrase is *not* stored, which is the safer way to
///   keep a key. Discovered by attempting the connection and getting
///   `passphraseRequired` back, rather than by inspecting the key file — the
///   transport already knows how to tell, and asking it beats guessing;
/// - a keyboard-interactive challenge, which is how most servers ask for a
///   one-time code. Those have any number of fields, which is why this type is
///   field-based rather than having one text box.
///
/// Answers are never written anywhere by this type. They live for one
/// connection attempt; persisting one is the caller's decision, which is what
/// `remember` reports.
@MainActor
@Observable
final class CredentialPromptCoordinator {
    struct Field: Identifiable {
        let id = UUID()
        var label: String
        /// `false` for a password-like field. Comes straight from the server's
        /// `echo` flag for a challenge; a field that ignores it shows someone's
        /// one-time code to the room.
        var echo: Bool
    }

    enum Kind {
        case password(username: String, endpoint: SSHEndpoint)
        case passphrase(keyLabel: String)
        /// RFC 4256. `name` and `instruction` are written by the server and are
        /// displayed, never interpreted.
        case challenge(name: String, instruction: String)
    }

    struct Answer {
        /// One value per field, in order.
        var values: [SecretString]
        /// Whether the user asked for this to be stored in the Keychain. Never
        /// offered for a challenge: a one-time code is worthless tomorrow, and
        /// storing it would be actively misleading.
        var remember: Bool
    }

    struct PendingPrompt: Identifiable {
        let id = UUID()
        let kind: Kind
        let fields: [Field]
        /// Cleared as the answer is delivered, so it cannot be delivered twice.
        fileprivate var respond: ((Answer?) -> Void)?

        var allowsRemembering: Bool {
            if case .challenge = kind { return false }
            return true
        }
    }

    private(set) var current: PendingPrompt?
    private var queue: [PendingPrompt] = []

    /// - Returns: the answer, or `nil` if the user cancelled.
    func ask(_ kind: Kind, fields: [Field]) async -> Answer? {
        await withCheckedContinuation { continuation in
            var prompt = PendingPrompt(kind: kind, fields: fields)
            prompt.respond = { continuation.resume(returning: $0) }
            queue.append(prompt)
            showNext()
        }
    }

    /// Convenience for the single-field cases.
    func askForSecret(_ kind: Kind, label: String) async -> Answer? {
        await ask(kind, fields: [Field(label: label, echo: false)])
    }

    func submit(_ values: [String], remember: Bool) {
        deliver(Answer(values: values.map(SecretString.init(_:)), remember: remember))
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

/// Answers keyboard-interactive challenges by putting them on screen.
///
/// Separate from the coordinator because the transport calls this from a
/// network thread while the coordinator is main-actor state.
struct InteractiveKeyboardHandler: SSHKeyboardInteractiveHandler {
    let coordinator: CredentialPromptCoordinator

    struct Cancelled: Error {}

    func respond(to challenge: SSHKeyboardInteractiveChallenge) async throws -> [SecretString] {
        let fields = challenge.prompts.map {
            CredentialPromptCoordinator.Field(label: $0.text, echo: $0.echo)
        }

        let answer = await coordinator.ask(
            .challenge(name: challenge.name, instruction: challenge.instruction),
            fields: fields
        )

        guard let answer else {
            // Abandons keyboard-interactive and lets the transport move on to
            // the next credential, rather than hanging.
            throw Cancelled()
        }
        return answer.values
    }
}
