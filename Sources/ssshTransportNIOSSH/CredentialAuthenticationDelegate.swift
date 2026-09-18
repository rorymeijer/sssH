import Foundation
import NIOCore
import NIOSSH
import ssshCore

/// Offers the destination's credentials to the server in order, the way
/// OpenSSH walks its identity list.
///
/// One instance authenticates one connection. NIOSSH calls
/// `nextAuthenticationType` once per attempt, telling us which methods the
/// server will accept — except on the very first call, where it optimistically
/// passes `.all` because the server has not said yet. We therefore lead with a
/// `none` request: it costs one round trip and buys an accurate method list,
/// which is the difference between "wrong password" and "this server only
/// accepts public keys".
final class CredentialAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let lock = NSLock()

    // Guarded by `lock`.
    private var remaining: [SSHCredential]
    private var hasProbedWithNone = false
    private var triedNames: [String] = []
    private var lastAdvertisedMethods: NIOSSHAvailableUserAuthenticationMethods = .all
    /// The first credential-specific problem we hit (bad passphrase, unreadable
    /// key). Reported in preference to the generic "all methods failed",
    /// because it is the one the user can act on.
    private var firstCredentialProblem: Error?
    /// Set while a keyboard-interactive offer is outstanding, so challenges can
    /// be routed to the handler that asked for them.
    private var keyboardInteractiveHandler: (any SSHKeyboardInteractiveHandler)?
    /// The credential most recently offered. Once NIOSSH reports success it is
    /// by definition the one that worked, because a success ends the sequence.
    private var lastOfferedName: String?

    init(username: String, credentials: [SSHCredential]) {
        self.username = username
        // A `none` probe is added explicitly below, so strip any the caller
        // passed to avoid offering it twice.
        self.remaining = credentials.filter { if case .none = $0 { return false } else { return true } }
    }

    /// Diagnostic name of the credential that worked, once the handshake has
    /// succeeded.
    var authenticatedWith: String {
        lock.lock()
        defer { lock.unlock() }
        return lastOfferedName ?? "unknown"
    }

    /// The error to report when NIOSSH tells us authentication failed.
    func authenticationFailure() -> Error {
        lock.lock()
        defer { lock.unlock() }

        if let firstCredentialProblem {
            return firstCredentialProblem
        }
        return SSHTransportError.authenticationFailed(
            triedCredentials: triedNames,
            acceptedMethods: Self.names(of: lastAdvertisedMethods)
        )
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()

        // The first invocation carries `.all` rather than anything the server
        // said, so do not record it as advertised.
        if hasProbedWithNone {
            lastAdvertisedMethods = availableMethods
        }

        if !hasProbedWithNone {
            hasProbedWithNone = true
            triedNames.append("none")
            lastOfferedName = "none"
            lock.unlock()
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none)
            )
            return
        }

        while !remaining.isEmpty {
            let credential = remaining.removeFirst()

            guard let offer = makeOfferLocked(for: credential, availableMethods: availableMethods) else {
                continue
            }

            triedNames.append(credential.diagnosticName)
            lastOfferedName = credential.diagnosticName
            lock.unlock()
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer)
            )
            return
        }

        lock.unlock()
        // No offers left. NIOSSH turns a `nil` offer into a failed handshake;
        // failing the promise instead lets us attach a useful reason.
        nextChallengePromise.fail(authenticationFailure())
    }

    /// Must be called with `lock` held. Returns `nil` when this credential
    /// cannot be offered, recording why if the reason is worth reporting.
    private func makeOfferLocked(
        for credential: SSHCredential,
        availableMethods: NIOSSHAvailableUserAuthenticationMethods
    ) -> NIOSSHUserAuthenticationOffer.Offer? {
        switch credential {
        case .password(let password):
            guard availableMethods.contains(.password) else { return nil }
            return .password(.init(password: password.reveal()))

        case .privateKey(let material):
            guard availableMethods.contains(.publicKey) else { return nil }
            do {
                let key = try PrivateKeyLoader.load(material)
                return .privateKey(.init(privateKey: key))
            } catch {
                // Skip this identity but keep the reason: a wrong passphrase
                // should not be reported as "server refused us".
                if firstCredentialProblem == nil { firstCredentialProblem = error }
                triedNames.append("\(credential.diagnosticName) [unusable]")
                return nil
            }

        case .none:
            // Filtered out in `init`: the `none` probe is sent explicitly as
            // the first attempt, so offering it again here would waste a round
            // trip. Kept for exhaustiveness.
            return nil

        case .agent:
            if firstCredentialProblem == nil {
                firstCredentialProblem = SSHTransportError.unsupported(.agentForwarding)
            }
            return nil

        case .keyboardInteractive(let handler):
            guard availableMethods.contains(.keyboardInteractive) else { return nil }
            // Remember who answers; the challenges arrive on a separate
            // callback with nothing to identify the attempt.
            keyboardInteractiveHandler = handler
            return .keyboardInteractive(.init())
        }
    }

    // MARK: - Keyboard-interactive

    /// Answers one `SSH_MSG_USERAUTH_INFO_REQUEST`.
    ///
    /// The handler may take as long as it likes — this is where a one-time code
    /// is typed — and the connection waits. Failing the promise abandons
    /// keyboard-interactive and moves on to the next credential.
    func respondToKeyboardInteractiveChallenge(
        _ challenge: NIOSSHKeyboardInteractiveChallenge,
        responsePromise: EventLoopPromise<[String]>
    ) {
        lock.lock()
        let handler = keyboardInteractiveHandler
        lock.unlock()

        guard let handler else {
            responsePromise.fail(SSHTransportError.unsupported(.keyboardInteractiveAuthentication))
            return
        }

        // A challenge with no prompts is the server displaying text, not asking
        // a question. Answering immediately is required; waiting for input that
        // will never come would wedge the connection.
        guard !challenge.prompts.isEmpty else {
            responsePromise.succeed([])
            return
        }

        let request = SSHKeyboardInteractiveChallenge(
            name: challenge.name,
            instruction: challenge.instruction,
            prompts: challenge.prompts.map { .init(text: $0.prompt, echo: $0.echo) }
        )

        Task {
            do {
                let answers = try await handler.respond(to: request)
                responsePromise.succeed(answers.map { $0.reveal() })
            } catch {
                responsePromise.fail(error)
            }
        }
    }

    private static func names(of methods: NIOSSHAvailableUserAuthenticationMethods) -> [String] {
        var names: [String] = []
        if methods.contains(.publicKey) { names.append("publickey") }
        if methods.contains(.password) { names.append("password") }
        if methods.contains(.keyboardInteractive) { names.append("keyboard-interactive") }
        if methods.contains(.hostBased) { names.append("hostbased") }
        if names.isEmpty { names.append("none advertised") }
        return names
    }
}
