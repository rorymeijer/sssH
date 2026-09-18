# Adding `keyboard-interactive` to swift-nio-ssh

## Status

**Implemented** in `Vendor/swift-nio-ssh`, following this design, with tests in
`Tests/NIOSSHTests/KeyboardInteractiveTests.swift`. Still uncompiled, like the
rest of the repository; the wire format was verified against the RFC
independently of the Swift.

This document is kept as the design record and as the basis of the upstream
pull requests. The caution at the end still stands — an authentication state
machine is the one thing here that cannot be checked without a live server, so
this is the code to run first once there is a toolchain.

## Why it matters

`keyboard-interactive` (RFC 4256) is how most servers do TOTP and PAM-driven
two-factor authentication. swift-nio-ssh has no support for it at all:
`NIOSSHUserAuthenticationOffer.Offer` has exactly four cases — `privateKey`,
`password`, `hostBased`, `none` — and a custom
`NIOSSHClientUserAuthenticationDelegate` cannot add a fifth, because that enum
is the delegate's only output. Grepping the library for "keyboard" returns
nothing.

It is worse than a missing feature. `NIOSSHAvailableUserAuthenticationMethods.init(_:)`
*silently drops* methods it does not implement while parsing the server's
`SSH_MSG_USERAUTH_FAILURE`, so a server offering only `keyboard-interactive`
looks to sssh like a server offering nothing at all. The error message cannot
even name what the server actually wants.

## The protocol

Three messages, on top of the ordinary `SSH_MSG_USERAUTH_REQUEST`.

**Request** (RFC 4256 §3.1) — the method-specific tail of message 50:

```
string    "keyboard-interactive"
string    language tag        (deprecated; send empty)
string    submethods          (usually empty)
```

**`SSH_MSG_USERAUTH_INFO_REQUEST`** (message 60, §3.2):

```
string    name
string    instruction
string    language tag        (deprecated)
uint32    num-prompts
  string    prompt[i]
  boolean   echo[i]
```

**`SSH_MSG_USERAUTH_INFO_RESPONSE`** (message 61, §3.4):

```
uint32    num-responses
  string    response[i]
```

Two details that are easy to miss and both matter:

- `num-prompts` may be **zero**. That is a legal
  "display this text to the user" exchange, and it requires an immediate
  response with zero responses. An implementation that waits for user input
  here deadlocks.
- `num-responses` **must** equal `num-prompts`. Sending a different count is a
  protocol violation.

## The blocker, and how to solve it

**`SSH_MSG_USERAUTH_INFO_REQUEST` is message ID 60. So is
`SSH_MSG_USERAUTH_PK_OK`.** SSH reuses IDs 60–79 per authentication method, and
which one a byte means depends on the method currently in flight.

swift-nio-ssh's parser is stateless and hard-codes the mapping — in
`Sources/NIOSSH/SSHMessages.swift`, `readSSHMessage()` has
`case SSHMessage.UserAuthPKOKMessage.id: … return .userAuthPKOK(message)`.
Parsing an `INFO_REQUEST` as a `PK_OK` fails, because a public-key blob is not a
prompt list.

Two ways out.

### Option A — thread one bit into the parser (recommended)

`SSHPacketParser` gains

```swift
/// Which authentication method's method-specific message IDs (60–79) are
/// currently meaningful. SSH reuses those IDs per method, so the parser
/// cannot resolve them without knowing what is in flight.
var userAuthMethodInFlight: UserAuthMethodContext = .none
```

and `readSSHMessage()` takes it as a parameter. `SSHConnectionStateMachine`
already owns both the parser and the user-auth state machine, so it sets the
value when a request is sent and clears it on success or failure.

Small, local, and the type name documents *why* the bit exists. It does put one
piece of state into a parser that had none, which is the cost.

### Option B — defer the decision to the state machine

Parse ID 60 into a new case carrying the raw payload, and let the connection
state machine — which knows the auth state — decode it into either message.
Keeps the parser stateless, at the price of changing how an existing message is
handled and moving decoding somewhere less obvious.

**Recommendation: A.** It is the smaller diff, and the reviewer's question
("why does a parser have state?") has a good answer that generalises to every
other method-specific ID.

## Touch points

| File | Change |
|---|---|
| `SSHMessages.swift` | Two message structs; `SSHMessage` cases; read and write; ID-60 disambiguation. |
| `SSHPacketParser.swift` | Carry the in-flight method; pass it to `readSSHMessage` (two call sites). |
| `UserAuthenticationMethod.swift` | `NIOSSHAvailableUserAuthenticationMethods.keyboardInteractive`; parse `"keyboard-interactive"` in `init(_ message:)` — **this alone fixes the misleading error message**, and is worth landing even on its own. |
| `UserAuthenticationMethod.swift` | `Offer.keyboardInteractive(KeyboardInteractive)` with its submethods. |
| `ClientUserAuthenticationDelegate.swift` | New callback, below. |
| `UserAuthenticationStateMachine.swift` | `receiveUserAuthInfoRequest` and `sendUserAuthInfoResponse`; a new `awaitingInfoResponse` state. |
| `SSHConnectionStateMachine.swift` | Route messages 60/61 while authenticating; keep the parser's in-flight method current. |

## Public API

```swift
public extension NIOSSHUserAuthenticationOffer.Offer {
    struct KeyboardInteractive {
        /// Usually empty. A comma-separated hint such as "pam" or "bsdauth".
        public var submethods: String
        public init(submethods: String = "")
    }
}

public struct NIOSSHKeyboardInteractiveChallenge {
    public var name: String
    public var instruction: String
    public var prompts: [Prompt]

    public struct Prompt {
        public var prompt: String
        /// `false` for a password-like prompt. A UI that ignores this shows
        /// someone's TOTP code on a projector.
        public var echo: Bool
    }
}

public protocol NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    )

    /// Called for each `SSH_MSG_USERAUTH_INFO_REQUEST`.
    ///
    /// Complete the promise with exactly one response per prompt, in order.
    /// A challenge with no prompts must still be answered, with an empty
    /// array — it is the server displaying text, not asking a question.
    ///
    /// A default implementation fails the promise, so existing conformances
    /// keep compiling and keep refusing the method.
    func respondToKeyboardInteractiveChallenge(
        _ challenge: NIOSSHKeyboardInteractiveChallenge,
        responsePromise: EventLoopPromise<[String]>
    )
}
```

The defaulted requirement is what makes this a non-breaking change: every
existing delegate compiles unchanged and behaves exactly as before.

## State machine

Client side, added to `UserAuthenticationStateMachine`:

```
awaitingResponses(n)
  ──receiveUserAuthInfoRequest──▶  awaitingInfoResponse(n)   [ask the delegate]
awaitingInfoResponse(n)
  ──sendUserAuthInfoResponse────▶  awaitingResponses(n)
  ──receiveUserAuthSuccess──────▶  authenticationSucceeded
  ──receiveUserAuthFailure──────▶  ask for the next method
```

Rules the implementation must enforce, each of which is a real failure mode:

1. **An `INFO_REQUEST` outside `awaitingResponses`/`awaitingInfoResponse` is a
   protocol error.** Accepting one earlier would let a server prompt before any
   method was offered.
2. **Bound the exchange.** A server may legitimately send several
   `INFO_REQUEST`s in a row; it may also send them forever. Cap the count
   (OpenSSH uses 16) and fail the attempt beyond it, or a hostile server pins a
   client in a prompt loop.
3. **Response count must equal prompt count**, checked before sending.
4. **Never log prompts or responses.** Prompts can contain anything the server
   chooses and responses are one-time codes.
5. **Treat `name` and `instruction` as untrusted display text.** They are
   attacker-controlled: no markup interpretation, and bound the length before
   rendering.

## Tests

The library's `Tests/NIOSSHTests` has the harness for all of this already:

- Round-trip encode/decode for both messages, including zero prompts, several
  prompts, mixed `echo`, and non-ASCII text.
- Parser: ID 60 resolves to `PK_OK` during publickey and to `INFO_REQUEST`
  during keyboard-interactive — the central point of the change.
- State machine: the success path; a mismatched response count; an
  `INFO_REQUEST` arriving in a state that forbids it; the prompt-loop cap.
- `NIOSSHAvailableUserAuthenticationMethods` parses `"keyboard-interactive"`
  out of a failure message.
- End-to-end against the embedded test server with a delegate that answers a
  two-prompt challenge.

## Upstreaming

Three PRs, smallest first, so that value lands even if the largest stalls:

1. **Recognise the method name** in `NIOSSHAvailableUserAuthenticationMethods`.
   A handful of lines. Fixes the "server offers nothing" misreport on its own,
   with no new API.
2. **Message types and parser disambiguation**, with round-trip tests. No public
   API change beyond the new enum cases.
3. **The delegate callback and state machine.** The one that needs discussion.

If (3) is rejected or stalls, the fallback is a vendored fork pinned by commit,
carrying only these changes, with the risk stated in the dependency notes — a
fork of an authentication state machine is a real maintenance liability and
should be a last resort, not a first move.

## Wiring in sssh, once it exists

Small, because the seams are already there:

- `SSHCredential.keyboardInteractive(SSHKeyboardInteractiveHandler)` and
  `SSHKeyboardInteractiveChallenge` already exist in `ssshCore`, defined in
  Phase 0 precisely so this would not change the transport's surface.
- `CredentialAuthenticationDelegate` stops reporting
  `.unsupported(.keyboardInteractiveAuthentication)` and starts offering the
  method, implementing the new NIOSSH callback by forwarding to the handler.
- The app adds a challenge sheet — several fields, `echo` deciding between
  `TextField` and `SecureField` — alongside the existing credential prompt.

## Why this is not written yet

This environment has no Swift toolchain and no route to one, so the change
could be written but not compiled, let alone tested against a real server.

Everything else delivered so far was written blind because it could be checked
another way: the cryptography against OpenBSD's own implementation and
`openssl`, the transport against the libraries' actual sources. **An
authentication state machine cannot be checked that way.** The failure mode of
a subtly wrong one is not a compile error — it is a client that authenticates
when it should not, hangs, or leaks a one-time code into the wrong message. A
plausible-looking 400-line diff to that, in the dependency graph of an app that
holds people's SSH keys, is worth less than nothing.

So: this document, and the implementation in a session that can run
`swift test`. The design above is not the hard part; verifying it is.
