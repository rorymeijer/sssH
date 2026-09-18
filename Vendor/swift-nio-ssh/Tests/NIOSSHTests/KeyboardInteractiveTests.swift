//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
@testable import NIOSSH
import XCTest

/// RFC 4256 keyboard-interactive authentication.
///
/// The central case is `testMessageID60IsResolvedByMethodInFlight`: ID 60 is
/// `SSH_MSG_USERAUTH_PK_OK` during a public-key exchange and
/// `SSH_MSG_USERAUTH_INFO_REQUEST` during a keyboard-interactive one, and
/// nothing in the byte stream says which. Everything else here is detail.
final class KeyboardInteractiveTests: XCTestCase {
    private func roundTrip(_ message: SSHMessage, methodInFlight: SSHUserAuthMethodInFlight) throws -> SSHMessage? {
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        buffer.writeSSHMessage(message)
        return try buffer.readSSHMessage(methodInFlight: methodInFlight)
    }

    // MARK: - Wire format

    func testInfoRequestRoundTrips() throws {
        let message = SSHMessage.userAuthInfoRequest(
            .init(
                name: "PAM",
                instruction: "Enter your verification code",
                languageTag: "",
                prompts: [
                    .init(prompt: "Password: ", echo: false),
                    .init(prompt: "Verification code: ", echo: false),
                ]
            )
        )
        XCTAssertEqual(try roundTrip(message, methodInFlight: .keyboardInteractive), message)
    }

    func testChallengeWithNoPromptsRoundTrips() throws {
        // A legal "display this text" exchange. An implementation that waits
        // for input here deadlocks the connection.
        let message = SSHMessage.userAuthInfoRequest(
            .init(name: "", instruction: "Your password expires tomorrow.", languageTag: "", prompts: [])
        )
        XCTAssertEqual(try roundTrip(message, methodInFlight: .keyboardInteractive), message)
    }

    func testEchoFlagSurvives() throws {
        let message = SSHMessage.userAuthInfoRequest(
            .init(name: "", instruction: "", languageTag: "", prompts: [
                .init(prompt: "Username: ", echo: true),
                .init(prompt: "Password: ", echo: false),
            ])
        )
        guard case .userAuthInfoRequest(let decoded)? = try roundTrip(message, methodInFlight: .keyboardInteractive) else {
            return XCTFail("did not decode")
        }
        XCTAssertEqual(decoded.prompts.map(\.echo), [true, false])
    }

    func testNonASCIISurvives() throws {
        let message = SSHMessage.userAuthInfoRequest(
            .init(name: "Aanmelden", instruction: "Voer je code in — één keer", languageTag: "nl", prompts: [
                .init(prompt: "Wachtwoord: ", echo: false),
            ])
        )
        XCTAssertEqual(try roundTrip(message, methodInFlight: .keyboardInteractive), message)
    }

    func testInfoResponseRoundTrips() throws {
        let message = SSHMessage.userAuthInfoResponse(.init(responses: ["hunter2", "123456"]))
        XCTAssertEqual(try roundTrip(message, methodInFlight: .keyboardInteractive), message)

        let empty = SSHMessage.userAuthInfoResponse(.init(responses: []))
        XCTAssertEqual(try roundTrip(empty, methodInFlight: .keyboardInteractive), empty)
    }

    func testRequestRoundTrips() throws {
        for submethods in ["", "pam"] {
            let message = SSHMessage.userAuthRequest(
                .init(username: "rory", service: "ssh-connection", method: .keyboardInteractive(submethods: submethods))
            )
            XCTAssertEqual(try roundTrip(message, methodInFlight: .none), message)
        }
    }

    /// The reason the parser has state at all.
    func testMessageID60IsResolvedByMethodInFlight() throws {
        let infoRequest = SSHMessage.userAuthInfoRequest(
            .init(name: "n", instruction: "i", languageTag: "", prompts: [.init(prompt: "p", echo: false)])
        )

        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        buffer.writeSSHMessage(infoRequest)
        let bytes = buffer

        // With keyboard-interactive in flight it decodes as written.
        var asInfoRequest = bytes
        XCTAssertEqual(try asInfoRequest.readSSHMessage(methodInFlight: .keyboardInteractive), infoRequest)

        // With public-key in flight the same bytes are read as a PK_OK, which
        // these are not — so it fails rather than silently misinterpreting.
        var asPKOK = bytes
        XCTAssertThrowsError(try asPKOK.readSSHMessage(methodInFlight: .publicKey))
    }

    // MARK: - Hostile input

    func testAbsurdPromptCountIsRejectedNotAllocated() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 32)
        buffer.writeInteger(SSHMessage.UserAuthInfoRequestMessage.id)
        buffer.writeSSHString("".utf8)
        buffer.writeSSHString("".utf8)
        buffer.writeSSHString("".utf8)
        buffer.writeInteger(UInt32.max)

        // A four-billion prompt claim in a twenty-byte message must not become
        // a four-billion element reservation.
        XCTAssertNil(try buffer.readSSHMessage(methodInFlight: .keyboardInteractive))
    }

    func testAbsurdResponseCountIsRejected() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 32)
        buffer.writeInteger(SSHMessage.UserAuthInfoResponseMessage.id)
        buffer.writeInteger(UInt32.max)
        XCTAssertNil(try buffer.readSSHMessage(methodInFlight: .keyboardInteractive))
    }

    func testTruncatedChallengeIsRejected() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeInteger(SSHMessage.UserAuthInfoRequestMessage.id)
        buffer.writeSSHString("".utf8)
        buffer.writeSSHString("".utf8)
        buffer.writeSSHString("".utf8)
        buffer.writeInteger(UInt32(2))
        buffer.writeSSHString("first".utf8)
        buffer.writeSSHBoolean(false)
        // The second prompt is missing its echo byte.
        buffer.writeSSHString("second".utf8)

        XCTAssertNil(try buffer.readSSHMessage(methodInFlight: .keyboardInteractive))
    }

    // MARK: - Advertised methods

    func testFailureMessageAdvertisesKeyboardInteractive() {
        // Before this, a server offering only keyboard-interactive looked like
        // a server offering nothing, and the error could not say what it wanted.
        let failure = SSHMessage.UserAuthFailureMessage(
            authentications: ["publickey", "keyboard-interactive"],
            partialSuccess: false
        )
        let methods = NIOSSHAvailableUserAuthenticationMethods(failure)

        XCTAssertTrue(methods.contains(.keyboardInteractive))
        XCTAssertTrue(methods.contains(.publicKey))
        XCTAssertFalse(methods.contains(.password))
    }

    func testMethodNamesRoundTrip() {
        let methods: NIOSSHAvailableUserAuthenticationMethods = [.keyboardInteractive, .password]
        XCTAssertEqual(Set(methods.strings), ["keyboard-interactive", "password"])
        XCTAssertTrue(NIOSSHAvailableUserAuthenticationMethods.all.contains(.keyboardInteractive))
    }

    // MARK: - State machine

    private final class ScriptedDelegate: NIOSSHClientUserAuthenticationDelegate {
        var offers: [NIOSSHUserAuthenticationOffer?]
        var answers: [[String]]
        private(set) var challenges: [NIOSSHKeyboardInteractiveChallenge] = []

        init(offers: [NIOSSHUserAuthenticationOffer?], answers: [[String]]) {
            self.offers = offers
            self.answers = answers
        }

        func nextAuthenticationType(
            availableMethods: NIOSSHAvailableUserAuthenticationMethods,
            nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
        ) {
            nextChallengePromise.succeed(offers.isEmpty ? nil : offers.removeFirst())
        }

        func respondToKeyboardInteractiveChallenge(
            _ challenge: NIOSSHKeyboardInteractiveChallenge,
            responsePromise: EventLoopPromise<[String]>
        ) {
            challenges.append(challenge)
            responsePromise.succeed(answers.isEmpty ? [] : answers.removeFirst())
        }
    }

    private func makeClientStateMachine(
        _ delegate: NIOSSHClientUserAuthenticationDelegate,
        loop: EmbeddedEventLoop
    ) throws -> UserAuthenticationStateMachine {
        var machine = UserAuthenticationStateMachine(
            role: .client(.init(userAuthDelegate: delegate, serverAuthDelegate: AcceptAllHostKeysDelegate())),
            loop: loop,
            sessionID: ByteBufferAllocator().buffer(capacity: 0)
        )
        machine.sendServiceRequest(.init(service: "ssh-userauth"))
        _ = try machine.receiveServiceAccept(.init(service: "ssh-userauth"))
        return machine
    }

    func testChallengeIsAnsweredAndTheParserIsTold() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let delegate = ScriptedDelegate(
            offers: [.init(username: "rory", serviceName: "ssh-connection", offer: .keyboardInteractive(.init()))],
            answers: [["123456"]]
        )
        var machine = try makeClientStateMachine(delegate, loop: loop)

        // Nothing method-specific is expected until a method is offered.
        XCTAssertEqual(machine.methodInFlight, .none)

        machine.sendUserAuthRequest(
            .init(username: "rory", service: "ssh-connection", method: .keyboardInteractive(submethods: ""))
        )
        XCTAssertEqual(machine.methodInFlight, .keyboardInteractive)

        let response = try machine.receiveUserAuthInfoRequest(
            .init(name: "", instruction: "", languageTag: "", prompts: [.init(prompt: "Code: ", echo: false)])
        )
        loop.run()

        let message = try XCTUnwrap(try response?.wait())
        XCTAssertEqual(message.responses, ["123456"])
        XCTAssertEqual(delegate.challenges.count, 1)
        XCTAssertEqual(delegate.challenges.first?.prompts.first?.echo, false)

        machine.sendUserAuthInfoResponse(message)
        try machine.receiveUserAuthSuccess()
        XCTAssertEqual(machine.methodInFlight, .none)
    }

    func testWrongNumberOfResponsesIsRejectedBeforeSending() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        // Two prompts, one answer: a protocol violation, and better caught here
        // than by the server.
        let delegate = ScriptedDelegate(
            offers: [.init(username: "rory", serviceName: "ssh-connection", offer: .keyboardInteractive(.init()))],
            answers: [["only-one"]]
        )
        var machine = try makeClientStateMachine(delegate, loop: loop)
        machine.sendUserAuthRequest(
            .init(username: "rory", service: "ssh-connection", method: .keyboardInteractive(submethods: ""))
        )

        let response = try machine.receiveUserAuthInfoRequest(
            .init(name: "", instruction: "", languageTag: "", prompts: [
                .init(prompt: "Password: ", echo: false),
                .init(prompt: "Code: ", echo: false),
            ])
        )
        loop.run()

        XCTAssertThrowsError(try response?.wait())
    }

    func testUnsolicitedChallengeIsRefused() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let delegate = ScriptedDelegate(offers: [nil], answers: [])
        var machine = try makeClientStateMachine(delegate, loop: loop)

        // No method offered, so a prompt here would let a server drive the
        // exchange.
        XCTAssertThrowsError(
            try machine.receiveUserAuthInfoRequest(
                .init(name: "", instruction: "", languageTag: "", prompts: [])
            )
        )
    }

    func testPromptLoopIsBounded() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let delegate = ScriptedDelegate(
            offers: [.init(username: "rory", serviceName: "ssh-connection", offer: .keyboardInteractive(.init()))],
            answers: Array(repeating: [], count: 100)
        )
        var machine = try makeClientStateMachine(delegate, loop: loop)
        machine.sendUserAuthRequest(
            .init(username: "rory", service: "ssh-connection", method: .keyboardInteractive(submethods: ""))
        )

        // A server that keeps asking must eventually be cut off, or it can pin
        // the client in a prompt loop for as long as it likes.
        var rounds = 0
        do {
            while rounds < 100 {
                let response = try machine.receiveUserAuthInfoRequest(
                    .init(name: "", instruction: "", languageTag: "", prompts: [])
                )
                loop.run()
                if let message = try response?.wait() {
                    machine.sendUserAuthInfoResponse(message)
                }
                rounds += 1
            }
            XCTFail("the prompt loop was never cut off")
        } catch {
            // Expected. The exact bound is an implementation choice; that there
            // is one, well before 100, is not.
            XCTAssertLessThan(rounds, 100)
            XCTAssertGreaterThan(rounds, 1)
        }
    }

    func testDefaultDelegateDeclinesRatherThanStalling() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        /// A delegate written before keyboard-interactive existed.
        struct LegacyDelegate: NIOSSHClientUserAuthenticationDelegate {
            func nextAuthenticationType(
                availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
            ) {
                nextChallengePromise.succeed(nil)
            }
        }

        let promise = loop.makePromise(of: [String].self)
        LegacyDelegate().respondToKeyboardInteractiveChallenge(
            .init(name: "", instruction: "", prompts: []),
            responsePromise: promise
        )
        loop.run()

        // Declining, not hanging: a stalled promise would wedge the connection.
        XCTAssertThrowsError(try promise.futureResult.wait())
    }
}
