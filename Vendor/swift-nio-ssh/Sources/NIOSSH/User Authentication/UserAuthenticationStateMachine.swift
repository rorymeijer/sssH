//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

struct UserAuthenticationStateMachine {
    private var state: State
    private var delegate: UserAuthDelegate
    private let loop: EventLoop
    private var sessionID: ByteBuffer

    /// Which method's method-specific message IDs (60–79) the parser should
    /// currently expect. Read by ``SSHConnectionStateMachine`` after every
    /// message, because a byte in that range cannot be parsed without it.
    private(set) var methodInFlight: SSHUserAuthMethodInFlight = .none

    /// How many `SSH_MSG_USERAUTH_INFO_REQUEST`s the current keyboard-interactive
    /// attempt has produced.
    private var keyboardInteractiveRounds = 0

    /// A server may legitimately ask several questions in a row — a password,
    /// then a one-time code — but it may also ask forever. OpenSSH stops at
    /// this many, and so do we: without a bound, a hostile server can pin a
    /// client in a prompt loop indefinitely.
    private static let maximumKeyboardInteractiveRounds = 16

    // TODO: The server SHOULD limit the number of authentication attempts the client may make.
    init(role: SSHConnectionRole, loop: EventLoop, sessionID: ByteBuffer) {
        self.state = .idle
        self.delegate = UserAuthDelegate(role: role)
        self.loop = loop
        self.sessionID = sessionID
    }

    fileprivate static let serviceName: String = "ssh-userauth"

    fileprivate static let nextServiceName: String = "ssh-connection"
}

private extension UserAuthenticationStateMachine {
    enum State {
        /// In this state, we have not received any user auth messages yet
        case idle
        case awaitingServiceAcceptance
        case awaitingNextRequest
        case awaitingResponses(Int)
        /// A keyboard-interactive challenge arrived and the delegate is being
        /// asked for answers. The payload is the number of authentication
        /// responses still outstanding, carried through so the state can be
        /// restored exactly when the answer is sent.
        case awaitingInfoResponse(Int)
        case authenticationSucceeded
        case authenticationFailed
    }
}

private extension UserAuthenticationStateMachine {
    static let protocolName = "userauth"
}

// MARK: Receiving Messages

extension UserAuthenticationStateMachine {
    /// A ServiceRequest message was received from the remote peer.
    mutating func receiveServiceRequest(_ message: SSHMessage.ServiceRequestMessage) throws -> SSHMessage.ServiceAcceptMessage? {
        switch (self.delegate, self.state) {
        case (.server, .idle):
            guard message.service == Self.serviceName else {
                throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "unexpected service request: \(message)")
            }

            self.state = .awaitingServiceAcceptance
            return .init(service: Self.serviceName)

        case (.server, .awaitingServiceAcceptance),
             (.server, .awaitingNextRequest),
             (.server, .awaitingResponses),
             // Client-only state: a server never sends an info request, so it
             // can never be waiting for the answer. Thrown rather than
             // asserted — a peer must not be able to crash us if that ever
             // stops being true.
             (.server, .awaitingInfoResponse):
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "unexpected state for service request: \(message)")

        case (.server, .authenticationSucceeded):
            // We ignore messages after authentication succeeded.
            return nil

        case (.server, .authenticationFailed):
            // TODO(cory): We should be limiting the maximum number of authentication attempts.
            preconditionFailure("Servers cannot enter authentication failed")

        case (.client, _):
            // Clients may never receive user service request messages.
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "server sent service request: \(message)")
        }
    }

    /// A ServiceAccept message was received from the remote peer.
    mutating func receiveServiceAccept(_ message: SSHMessage.ServiceAcceptMessage) throws -> EventLoopFuture<SSHMessage.UserAuthRequestMessage?>? {
        switch (self.delegate, self.state) {
        case (.client(let delegate), .awaitingServiceAcceptance):
            guard message.service == Self.serviceName else {
                throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "unexpected service accept: \(message)")
            }

            // Cool, we can begin the auth dance.
            self.state = .awaitingNextRequest
            return self.requestNextAuthRequest(methods: .all, delegate: delegate)
        case (.client, .authenticationSucceeded):
            // We should ignore all further auth messages in this state.
            return nil
        case (.client, .idle):
            // Server sent a service accept but we didn't ask them to!
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "unsolicited service accept message: \(message)")
        case (.client, .awaitingNextRequest),
             (.client, .awaitingResponses),
             (.client, .awaitingInfoResponse),
             (.client, .authenticationFailed):
            // In these states we aren't expecting a service accept message
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "unsolicited service accept message: \(message)")
        case (.server, _):
            // Servers may never receive user auth success messages.
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "client sent user auth success")
        }
    }

    /// A UserAuthRequest message was received from the remote peer.
    mutating func receiveUserAuthRequest(_ message: SSHMessage.UserAuthRequestMessage) throws -> EventLoopFuture<NIOSSHUserAuthenticationResponseMessage>? {
        guard message.service == Self.nextServiceName else {
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "requested unsupported service: \(message.service)")
        }

        switch (self.delegate, self.state) {
        case (.server(let delegate), .awaitingNextRequest):
            self.state = .awaitingResponses(1)
            return self.nextAuthResponse(request: message, delegate: delegate)

        case (.server(let delegate), .awaitingResponses(let pending)):
            self.state = .awaitingResponses(pending + 1)
            return self.nextAuthResponse(request: message, delegate: delegate)

        case (.server, .idle), (.server, .awaitingServiceAcceptance):
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "user auth request before service accepted")

        case (.server, .awaitingInfoResponse):
            // Client-only state, as above.
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "user auth request while awaiting a keyboard-interactive response")

        case (.server, .authenticationSucceeded):
            // We ignore messages after authentication succeeded.
            return nil

        case (.server, .authenticationFailed):
            // TODO(cory): We should be limiting the maximum number of authentication attempts.
            preconditionFailure("Servers cannot enter authentication failed")

        case (.client, _):
            // Clients may never receive user auth request messages.
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "server sent user auth request")
        }
    }

    /// We've received a user auth success message.
    ///
    /// If this method completes without throwing, user auth has completed.
    mutating func receiveUserAuthSuccess() throws {
        switch (self.delegate, self.state) {
        case (.client, .awaitingResponses):
            // Great, we got a response, and it's a success! Disregard all future responses
            self.methodInFlight = .none
            self.state = .authenticationSucceeded
        case (.client, .authenticationSucceeded):
            // We should ignore all further auth messages in this state.
            break
        case (.client, .idle), (.client, .awaitingServiceAcceptance):
            // Server sent a user auth success but we didn't ask them to!
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "unsolicited auth success message")
        case (.client, .awaitingInfoResponse):
            // The server accepted us while we were still composing an answer.
            // Unusual but harmless, and refusing it would drop a working
            // connection.
            self.methodInFlight = .none
            self.state = .authenticationSucceeded
        case (.client, .awaitingNextRequest), (.client, .authenticationFailed):
            // In these states we believe we received all our auth responses, so this is wrong.
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "unsolicited auth success message")
        case (.server, _):
            // Servers may never receive user auth success messages.
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "client sent user auth success")
        }
    }

    mutating func receiveUserAuthFailure(_ message: SSHMessage.UserAuthFailureMessage) throws -> EventLoopFuture<SSHMessage.UserAuthRequestMessage?>? {
        switch (self.delegate, self.state) {
        case (.client(let delegate), .awaitingResponses(let responseCount)):
            // Ok, the server didn't like that much. Let's try another one.
            self.methodInFlight = .none
            self.state = .awaitingNextRequest
            precondition(responseCount == 1, "We don't support parallel authentication attempts yet!")
            return self.requestNextAuthRequest(methods: .init(message), delegate: delegate)
        case (.client(let delegate), .awaitingInfoResponse):
            // The server gave up on the keyboard-interactive exchange while we
            // were answering. Abandon it and move to the next method.
            self.methodInFlight = .none
            self.state = .awaitingNextRequest
            return self.requestNextAuthRequest(methods: .init(message), delegate: delegate)
        case (.client, .authenticationSucceeded):
            // We should ignore all further auth messages in this state.
            return nil
        case (.client, .idle), (.client, .awaitingServiceAcceptance):
            // Server sent a user auth success but we didn't ask them to!
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "server sent user auth failure unprompted")
        case (.client, .awaitingNextRequest), (.client, .authenticationFailed):
            // In these states we believe we received all our auth responses, so this is wrong.
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "unsolicited auth failure message")
        case (.server, _):
            // Servers may never receive user auth failure messages.
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "client sent user auth failure")
        }
    }

    /// An `SSH_MSG_USERAUTH_INFO_REQUEST` was received (RFC 4256 §3.2).
    ///
    /// - Returns: a future response to send, or `nil` if the message should be
    ///   ignored because authentication is already over.
    mutating func receiveUserAuthInfoRequest(
        _ message: SSHMessage.UserAuthInfoRequestMessage
    ) throws -> EventLoopFuture<SSHMessage.UserAuthInfoResponseMessage>? {
        switch (self.delegate, self.state) {
        case (.client(let delegate), .awaitingResponses(let responseCount)):
            guard self.methodInFlight == .keyboardInteractive else {
                // Only reachable if the parser resolved ID 60 one way and the
                // state machine believes another, which would be a bug here
                // rather than a badly behaved server.
                throw NIOSSHError.protocolViolation(
                    protocolName: Self.protocolName,
                    violation: "info request received outside a keyboard-interactive exchange"
                )
            }

            self.keyboardInteractiveRounds += 1
            guard self.keyboardInteractiveRounds <= Self.maximumKeyboardInteractiveRounds else {
                throw NIOSSHError.protocolViolation(
                    protocolName: Self.protocolName,
                    violation: "server sent more than \(Self.maximumKeyboardInteractiveRounds) keyboard-interactive prompts"
                )
            }

            self.state = .awaitingInfoResponse(responseCount)

            let promise = self.loop.makePromise(of: [String].self)
            delegate.respondToKeyboardInteractiveChallenge(
                NIOSSHKeyboardInteractiveChallenge(message),
                responsePromise: promise
            )

            let promptCount = message.prompts.count
            return promise.futureResult.flatMapThrowing { responses in
                // RFC 4256 §3.4 requires exactly one response per prompt.
                // Sending a different count is a protocol violation, and it is
                // better caught here than by the server.
                guard responses.count == promptCount else {
                    throw NIOSSHError.protocolViolation(
                        protocolName: Self.protocolName,
                        violation: "keyboard-interactive answered \(responses.count) of \(promptCount) prompts"
                    )
                }
                return SSHMessage.UserAuthInfoResponseMessage(responses: responses)
            }

        case (.client, .authenticationSucceeded):
            // Late message after we are already in. Ignore it, as we do for
            // every other auth message in this state.
            return nil

        case (.client, .idle),
             (.client, .awaitingServiceAcceptance),
             (.client, .awaitingNextRequest),
             (.client, .awaitingInfoResponse),
             (.client, .authenticationFailed):
            // Prompting before we offered a method, or while we are already
            // answering, would let a server drive the exchange.
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "unsolicited keyboard-interactive info request"
            )

        case (.server, _):
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "client sent a keyboard-interactive info request"
            )
        }
    }

    mutating func receiveUserAuthBanner(_: SSHMessage.UserAuthBannerMessage) throws {
        switch (self.delegate, self.state) {
        case (.client, .idle), (.client, .authenticationSucceeded):
            // Server sent a user auth success but we didn't ask them to!
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "server sent user auth banner at the wrong time")
        case (.server, _):
            // Servers may never receive user auth banner messages.
            throw NIOSSHError.protocolViolation(protocolName: Self.protocolName, violation: "client sent user auth banner")
        default:
            // In all other instances, receiving user auth banner is legal and must be dealt with by client
            return
        }
    }
}

// MARK: Sending Messages

extension UserAuthenticationStateMachine {
    mutating func sendServiceRequest(_ message: SSHMessage.ServiceRequestMessage) {
        switch (self.delegate, self.state) {
        case (.client, .idle):
            precondition(message.service == Self.serviceName)
            self.state = .awaitingServiceAcceptance
        case (.client, .awaitingServiceAcceptance):
            preconditionFailure("Duplicate service request")
        case (.client, .awaitingNextRequest),
             (.client, .awaitingResponses),
             (.client, .awaitingInfoResponse),
             (.client, .authenticationSucceeded),
             (.client, .authenticationFailed):
            preconditionFailure("May not send service request in \(self.state)")
        case (.server, _):
            preconditionFailure("Servers may not send service requests")
        }
    }

    mutating func sendServiceAccept(_ message: SSHMessage.ServiceAcceptMessage) {
        switch (self.delegate, self.state) {
        case (.server, .awaitingServiceAcceptance):
            precondition(message.service == Self.serviceName)
            self.state = .awaitingNextRequest
        case (.server, .idle):
            preconditionFailure("Cannot accept a service that hasn't been requested")
        case (.server, .awaitingNextRequest),
             (.server, .awaitingResponses),
             (.server, .awaitingInfoResponse),
             (.server, .authenticationSucceeded),
             (.server, .authenticationFailed):
            preconditionFailure("May not send service request in \(self.state)")
        case (.client, _):
            preconditionFailure("Clients may not send service acceptance")
        }
    }

    mutating func sendUserAuthRequest(_ message: SSHMessage.UserAuthRequestMessage) {
        switch (self.delegate, self.state) {
        case (.client, .awaitingNextRequest):
            // Remember the method so the parser can resolve message IDs 60–79,
            // and reset the prompt budget: the cap is per attempt, not per
            // connection.
            switch message.method {
            case .keyboardInteractive:
                self.methodInFlight = .keyboardInteractive
                self.keyboardInteractiveRounds = 0
            case .publicKey:
                self.methodInFlight = .publicKey
            case .password, .none:
                self.methodInFlight = .none
            }
            self.state = .awaitingResponses(1)
        case (.client, .idle),
             (.client, .awaitingServiceAcceptance):
            preconditionFailure("Sent an auth request without asking us first")
        case (.client, .awaitingResponses), (.client, .awaitingInfoResponse):
            // TODO(cory): We could probably support parallel auth attempts if we wanted to.
            preconditionFailure("Attempted to send a user auth request while we were waiting for a response to the last one.")
        case (.client, .authenticationSucceeded):
            preconditionFailure("Attempted to send a user auth request after auth succeeded")
        case (.client, .authenticationFailed):
            preconditionFailure("Attempted to send a user auth request after auth failed")
        case (.server, _):
            // Servers may never send user auth request messages.
            preconditionFailure("Servers may not authenticate")
        }
    }

    mutating func sendUserAuthInfoResponse(_: SSHMessage.UserAuthInfoResponseMessage) {
        switch (self.delegate, self.state) {
        case (.client, .awaitingInfoResponse(let responseCount)):
            // Back to waiting on the server, which will either ask again,
            // accept, or reject.
            self.state = .awaitingResponses(responseCount)
        case (.client, _):
            preconditionFailure("Sent a keyboard-interactive response in \(self.state)")
        case (.server, _):
            preconditionFailure("Servers may not send keyboard-interactive responses")
        }
    }

    mutating func sendUserAuthPKOK(_: SSHMessage.UserAuthPKOKMessage) {
        switch (self.delegate, self.state) {
        case (.server, .idle),
             (.server, .awaitingServiceAcceptance):
            preconditionFailure("Server sent an auth response prior to receiving an auth request")
        case (.server, .awaitingNextRequest):
            preconditionFailure("Too many auth responses sent")
        case (.server, .awaitingResponses(let responseCount)):
            if responseCount > 1 {
                self.state = .awaitingResponses(responseCount - 1)
            } else {
                self.state = .awaitingNextRequest
            }
        case (.server, .authenticationSucceeded):
            preconditionFailure("Authentication already succeeded, further messages are unnecessary.")
        case (.server, .awaitingInfoResponse):
            preconditionFailure("Servers never send keyboard-interactive info requests, so can never await one's response")
        case (.server, .authenticationFailed):
            preconditionFailure("Servers can never enter authenticationFailed")
        case (.client, _):
            preconditionFailure("Clients never send auth responses")
        }
    }

    mutating func sendUserAuthSuccess() {
        self.sendUserAuthResponseMessage(success: true)
    }

    mutating func sendUserAuthFailure(_: SSHMessage.UserAuthFailureMessage) {
        self.sendUserAuthResponseMessage(success: false)
    }

    mutating func sendUserAuthBanner(_: SSHMessage.UserAuthBannerMessage) {
        /*
         Relevant passage from RFC 4252:

         The SSH server may send an SSH_MSG_USERAUTH_BANNER message at any
         time after this authentication protocol starts and before
         authentication is successful.  This message contains text to be
         displayed to the client user before authentication is attempted.  The
         format is as follows:
         */
        switch (self.delegate, self.state) {
        case (.server, .idle):
            preconditionFailure("Banner sent before authentication protocol start")
        case (.server, .authenticationSucceeded):
            preconditionFailure("Banner sent after authentication suceeded")
        case (.server, _):
            break
        case (.client, _):
            preconditionFailure("Clients never send auth responses")
        }
    }

    private mutating func sendUserAuthResponseMessage(success: Bool) {
        switch (self.delegate, self.state) {
        case (.server, .idle),
             (.server, .awaitingServiceAcceptance):
            preconditionFailure("Server sent an auth response prior to receiving an auth request")
        case (.server, .awaitingNextRequest):
            preconditionFailure("Too many auth responses sent")
        case (.server, .awaitingResponses(let responseCount)):
            if success {
                self.state = .authenticationSucceeded
            } else if responseCount > 1 {
                self.state = .awaitingResponses(responseCount - 1)
            } else {
                self.state = .awaitingNextRequest
            }
        case (.server, .authenticationSucceeded):
            preconditionFailure("Authentication already succeeded, further messages are unnecessary.")
        case (.server, .awaitingInfoResponse):
            preconditionFailure("Servers never send keyboard-interactive info requests, so can never await one's response")
        case (.server, .authenticationFailed):
            preconditionFailure("Servers can never enter authenticationFailed")
        case (.client, _):
            preconditionFailure("Clients never send auth responses")
        }
    }
}

// MARK: Client authentication methods

extension UserAuthenticationStateMachine {
    /// Called to begin authentication in the state machine.
    func beginAuthentication() -> SSHMessage.ServiceRequestMessage? {
        switch (self.delegate, self.state) {
        case (.client, .idle):
            return SSHMessage.ServiceRequestMessage(service: Self.serviceName)
        case (.client, .awaitingServiceAcceptance),
             (.client, .awaitingNextRequest),
             (.client, .awaitingResponses),
             (.client, .awaitingInfoResponse),
             (.client, .authenticationSucceeded),
             (.client, .authenticationFailed):
            // TODO(cory): We could probably support parallel auth attempts if we wanted to.
            preconditionFailure("Cannot start authentication twice, state: \(self.state)")
        case (.server, _):
            return nil
        }
    }

    /// Called when the last call to obtain an authentication request returned nil.
    mutating func noFurtherMethods() {
        switch (self.delegate, self.state) {
        case (.client, .awaitingNextRequest):
            self.state = .authenticationFailed
        case (.client, .idle),
             (.client, .awaitingServiceAcceptance):
            preconditionFailure("Ran out of auth methods before asking for any")
        case (.client, .awaitingResponses),
             (.client, .awaitingInfoResponse),
             (.client, .authenticationSucceeded),
             (.client, .authenticationFailed):
            // TODO(cory): We could probably support parallel auth attempts if we wanted to.
            preconditionFailure("Request for further auth failed when no such request should be outstanding")
        case (.server, _):
            preconditionFailure("Servers may not authenticate")
        }
    }
}

// MARK: Interacting with client delegate

private extension UserAuthenticationStateMachine {
    func requestNextAuthRequest(methods: NIOSSHAvailableUserAuthenticationMethods, delegate: NIOSSHClientUserAuthenticationDelegate) -> EventLoopFuture<SSHMessage.UserAuthRequestMessage?> {
        let promise = self.loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: methods, nextChallengePromise: promise)

        // The explicit capture list is here to force a copy of the buffer, rather than capturing self.
        return promise.futureResult.flatMapThrowing { [sessionID = self.sessionID] request in
            try request.map { try SSHMessage.UserAuthRequestMessage(request: $0, sessionID: sessionID) }
        }
    }
}

// MARK: Interacting with server delegate

private extension UserAuthenticationStateMachine {
    func nextAuthResponse(request: SSHMessage.UserAuthRequestMessage, delegate: NIOSSHServerUserAuthenticationDelegate) -> EventLoopFuture<NIOSSHUserAuthenticationResponseMessage> {
        switch request.method {
        case .password(let password):
            let request = NIOSSHUserAuthenticationRequest(username: request.username, serviceName: request.service, request: .password(.init(password: password)))
            let promise = self.loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
            delegate.requestReceived(request: request, responsePromise: promise)
            let supportedMethods = delegate.supportedAuthenticationMethods

            return promise.futureResult.map { outcome in
                .init(outcome, supportedMethods: supportedMethods)
            }

        case .publicKey(.known(key: let key, signature: .some(let signature))):
            // This is a direct request to auth, just pass it through.
            let dataToSign = UserAuthSignablePayload(sessionIdentifier: sessionID, userName: request.username, serviceName: request.service, publicKey: key)
            let supportedMethods = delegate.supportedAuthenticationMethods

            guard key.isValidSignature(signature, for: dataToSign) else {
                // Whoops, signature not valid.
                return self.loop.makeSucceededFuture(.failure(.init(authentications: supportedMethods.strings, partialSuccess: false)))
            }

            // Signature is valid, ask if the delegate is happy.
            let request = NIOSSHUserAuthenticationRequest(username: request.username, serviceName: request.service, request: .publicKey(.init(publicKey: key)))
            let promise = self.loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
            delegate.requestReceived(request: request, responsePromise: promise)

            return promise.futureResult.map { outcome in
                .init(outcome, supportedMethods: supportedMethods)
            }

        case .publicKey(.known(key: let key, signature: .none)):
            // This is a weird wrinkle in public key auth: it's a request to ask whether a given key is valid, but not to validate that key itself.
            // For now we do a shortcut: we just say that all keys are acceptable, rather than ask the delegate.
            return self.loop.makeSucceededFuture(.publicKeyOK(.init(key: key)))

        case .publicKey(.unknown):
            // We don't known the algorithm, the auth attempt has failed.
            return self.loop.makeSucceededFuture(.failure(.init(authentications: delegate.supportedAuthenticationMethods.strings, partialSuccess: false)))

        case .keyboardInteractive:
            // This fork added keyboard-interactive for the client only.
            // `NIOSSHServerUserAuthenticationDelegate` has no way to run the
            // prompt exchange, so a server built on this cannot service the
            // request: fail it, and advertise what the delegate does support.
            // Succeeding here without asking the delegate anything would be
            // authenticating a user nobody agreed to authenticate.
            return self.loop.makeSucceededFuture(.failure(.init(authentications: delegate.supportedAuthenticationMethods.strings, partialSuccess: false)))

        case .none:
            let request = NIOSSHUserAuthenticationRequest(username: request.username, serviceName: request.service, request: .none)
            let promise = self.loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
            delegate.requestReceived(request: request, responsePromise: promise)
            let supportedMethods = delegate.supportedAuthenticationMethods

            return promise.futureResult.map { outcome in
                .init(outcome, supportedMethods: supportedMethods)
            }
        }
    }
}
