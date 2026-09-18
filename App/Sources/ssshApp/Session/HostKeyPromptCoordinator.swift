import Foundation
import Observation
import ssshCore

/// Bridges the transport's host-key question to a SwiftUI sheet.
///
/// The transport asks synchronously-from-its-point-of-view (`await`s an
/// answer) while the handshake is held open, which is exactly right: nothing is
/// sent to the server, and no credential is offered, until the user has decided
/// who they are talking to.
///
/// Prompts are queued. Connecting to several hosts at once must not drop a
/// question or show two sheets on top of each other, and a user who dismisses
/// the app mid-prompt must end up rejecting rather than accepting.
@MainActor
@Observable
final class HostKeyPromptCoordinator {
    struct PendingPrompt: Identifiable {
        let id = UUID()
        let prompt: SSHHostKeyPrompt
        /// Set to `nil` once answered, so an answer cannot be delivered twice.
        fileprivate var respond: ((SSHHostKeyDecision) -> Void)?

        var endpoint: SSHEndpoint {
            switch prompt {
            case .unknownHost(let endpoint, _), .mismatch(let endpoint, _, _): return endpoint
            }
        }

        var presentedKey: SSHHostKey {
            switch prompt {
            case .unknownHost(_, let key), .mismatch(_, let key, _): return key
            }
        }

        var isMismatch: Bool {
            if case .mismatch = prompt { return true }
            return false
        }

        var previouslyTrusted: [SSHHostKey] {
            if case .mismatch(_, _, let trusted) = prompt { return trusted }
            return []
        }
    }

    /// The prompt currently on screen, if any.
    private(set) var current: PendingPrompt?
    private var queue: [PendingPrompt] = []

    func answer(_ decision: SSHHostKeyDecision) {
        guard var prompt = current else { return }
        let respond = prompt.respond
        prompt.respond = nil
        current = nil
        respond?(decision)
        showNext()
    }

    /// Rejects every outstanding prompt. Called when the app is torn down or
    /// the user cancels everything: a pending connection must not be left
    /// waiting forever on an answer that will never come.
    func rejectAll() {
        let outstanding = ([current].compactMap { $0 }) + queue
        current = nil
        queue.removeAll()
        for prompt in outstanding {
            prompt.respond?(.reject)
        }
    }

    fileprivate func enqueue(_ prompt: PendingPrompt) {
        queue.append(prompt)
        showNext()
    }

    private func showNext() {
        guard current == nil, !queue.isEmpty else { return }
        current = queue.removeFirst()
    }
}

/// The ``SSHHostKeyVerifier`` the transport is given.
///
/// Separate from the coordinator because the transport calls it from a network
/// thread while the coordinator is main-actor state; this is the hop, and
/// nothing else.
struct InteractiveHostKeyVerifier: SSHHostKeyVerifier {
    let coordinator: HostKeyPromptCoordinator

    func evaluate(_ prompt: SSHHostKeyPrompt) async -> SSHHostKeyDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                // `resume` exactly once: the coordinator clears `respond` as it
                // delivers an answer, and `rejectAll` drains anything left.
                coordinator.enqueue(
                    HostKeyPromptCoordinator.PendingPrompt(prompt: prompt) { decision in
                        continuation.resume(returning: decision)
                    }
                )
            }
        }
    }
}

extension HostKeyPromptCoordinator.PendingPrompt {
    fileprivate init(prompt: SSHHostKeyPrompt, respond: @escaping (SSHHostKeyDecision) -> Void) {
        self.prompt = prompt
        self.respond = respond
    }
}
