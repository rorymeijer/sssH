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

/// A ``NIOSSHClientUserAuthenticationDelegate`` is an object that can provide a sequence of
/// SSH user authentication methods based on the the acceptable list from the server.
///
/// This protocol defines the interface that will be used by the user authentication state
/// machine to move forward with challenges. Implementers of this protocol are free to take
/// time to actually get responses: for example, for password authentication it is possible
/// that the application would like to provide a user-interactive password prompt. This is
/// enabled by allowing implementers to satisfy a promise, rather than requiring that they
/// synchronously provide a response.
public protocol NIOSSHClientUserAuthenticationDelegate {
    /// Called when ``NIOSSH`` would like to attempt to offer a new authentication method.
    ///
    /// The callback is provided the authentictation methods that the server is willing to accept in
    /// `availableMethods`. The delegate needs to provide an authentication offer by completing
    /// `nextChallengePromise`. If no further authentication offers are available (perhaps because the server
    /// has rejected them all) then this promise should be failed, which will terminate connection establishment.
    ///
    /// - parameters:
    ///     - availableMethods: The authentication methods the server is willing to accept.
    ///     - nextChallengePromise: An `EventLoopPromise` to be fulfilled with the next authentication offer.
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>)

    /// Called for each ``SSH_MSG_USERAUTH_INFO_REQUEST`` during a
    /// keyboard-interactive exchange (RFC 4256).
    ///
    /// Complete `responsePromise` with exactly one response per prompt, in the
    /// order the prompts were given. Taking time over it is expected — this is
    /// how a one-time code is asked for — and the connection waits.
    ///
    /// A challenge with **no** prompts must still be answered, with an empty
    /// array. The server is displaying text, not asking a question, and waiting
    /// for input that will never come deadlocks the connection.
    ///
    /// Failing the promise abandons the attempt and moves on to the next
    /// authentication method.
    ///
    /// - parameters:
    ///     - challenge: What the server is asking. Every string in it is
    ///       remote-controlled: display it, do not interpret it.
    ///     - responsePromise: An `EventLoopPromise` to be fulfilled with the responses.
    func respondToKeyboardInteractiveChallenge(_ challenge: NIOSSHKeyboardInteractiveChallenge, responsePromise: EventLoopPromise<[String]>)
}

public extension NIOSSHClientUserAuthenticationDelegate {
    /// Refuses the challenge.
    ///
    /// Defaulted so that adding keyboard-interactive support does not break a
    /// single existing conformance: a delegate written before this existed
    /// keeps compiling, and keeps declining the method exactly as it did.
    func respondToKeyboardInteractiveChallenge(_ challenge: NIOSSHKeyboardInteractiveChallenge, responsePromise: EventLoopPromise<[String]>) {
        responsePromise.fail(NIOSSHError.unsupportedUserAuthenticationMethod)
    }
}

/// One `SSH_MSG_USERAUTH_INFO_REQUEST`: what the server wants the user to answer.
public struct NIOSSHKeyboardInteractiveChallenge: Hashable {
    /// A short title, such as the PAM service name. Often empty.
    public var name: String

    /// Longer text to show above the prompts. Often empty.
    public var instruction: String

    /// The questions. May be empty, in which case this challenge is text to
    /// display and the response is an empty array.
    public var prompts: [Prompt]

    public init(name: String, instruction: String, prompts: [Prompt]) {
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }

    public struct Prompt: Hashable {
        /// The question, as written by the server.
        public var prompt: String

        /// Whether the answer may be echoed as it is typed. `false` for
        /// anything password- or code-like. A client that ignores this shows
        /// someone's one-time code to the room.
        public var echo: Bool

        public init(prompt: String, echo: Bool) {
            self.prompt = prompt
            self.echo = echo
        }
    }
}

extension NIOSSHKeyboardInteractiveChallenge {
    init(_ message: SSHMessage.UserAuthInfoRequestMessage) {
        self.name = message.name
        self.instruction = message.instruction
        self.prompts = message.prompts.map { Prompt(prompt: $0.prompt, echo: $0.echo) }
    }
}
