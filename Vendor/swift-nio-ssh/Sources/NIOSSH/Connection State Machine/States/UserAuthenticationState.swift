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

extension SSHConnectionStateMachine {
    /// The state of a state machine that is actively engaged in a user authentication operation.
    struct UserAuthenticationState {
        /// The role of the connection
        let role: SSHConnectionRole

        /// The packet parser.
        var parser: SSHPacketParser

        /// The packet serializer used by this state machine.
        var serializer: SSHPacketSerializer

        var remoteVersion: String

        var sessionIdentifier: ByteBuffer

        /// The backing state machine.
        var userAuthStateMachine: UserAuthenticationStateMachine

        let connectionAttributes: SSHConnectionStateMachine.Attributes

        init(sentNewKeysState state: SentNewKeysState) {
            self.role = state.role
            self.parser = state.parser
            self.serializer = state.serializer
            self.userAuthStateMachine = state.userAuthStateMachine
            self.remoteVersion = state.remoteVersion
            self.sessionIdentifier = state.sessionIdentifier
            self.connectionAttributes = state.connectionAttributes
        }

        /// Copies the authentication method in flight into the parser.
        ///
        /// SSH message IDs 60–79 mean different things per method, so the
        /// parser cannot resolve them on its own. Calling this after every
        /// authentication message is what keeps `SSH_MSG_USERAUTH_PK_OK` and
        /// `SSH_MSG_USERAUTH_INFO_REQUEST` — both ID 60 — from being confused
        /// for one another.
        mutating func synchroniseAuthMethodWithParser() {
            self.parser.userAuthMethodInFlight = self.userAuthStateMachine.methodInFlight
        }

        init(receivedNewKeysState state: ReceivedNewKeysState) {
            self.role = state.role
            self.parser = state.parser
            self.serializer = state.serializer
            self.userAuthStateMachine = state.userAuthStateMachine
            self.remoteVersion = state.remoteVersion
            self.sessionIdentifier = state.sessionIdentifier
            self.connectionAttributes = state.connectionAttributes
        }
    }
}

extension SSHConnectionStateMachine.UserAuthenticationState: AcceptsUserAuthMessages {}

extension SSHConnectionStateMachine.UserAuthenticationState: SendsUserAuthMessages {}
