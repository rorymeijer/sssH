# Vendored dependencies

## `swift-nio-ssh`

A fork of [Joannis/swift-nio-ssh](https://github.com/Joannis/swift-nio-ssh)
at 0.3.2 (itself a fork of apple/swift-nio-ssh that adds custom-algorithm
registration). Apache 2.0; `LICENSE.txt` is kept unchanged.

Vendored rather than pinned because sssh needs changes inside the library.
A fork of an SSH implementation is a real maintenance liability, so the
changes are kept small, separable, and written to be upstreamed — see
[../docs/KEYBOARD-INTERACTIVE-PLAN.md](../docs/KEYBOARD-INTERACTIVE-PLAN.md)
for the PR plan.

### What was changed, and why

**1. `keyboard-interactive` authentication (RFC 4256).**

The library had none: `NIOSSHUserAuthenticationOffer.Offer` had four cases and
no delegate could add a fifth. That rules out most two-factor setups, and —
worse — `NIOSSHAvailableUserAuthenticationMethods` silently dropped the method
name while parsing the server's failure message, so a server offering only
keyboard-interactive looked like a server offering nothing.

| File | Change |
|---|---|
| `SSHMessages.swift` | `UserAuthInfoRequestMessage` and `UserAuthInfoResponseMessage`; the `keyboardInteractive` request method; read and write. |
| `SSHPacketParser.swift` | Carries the authentication method in flight. |
| `User Authentication/SSHUserAuthMethodInFlight.swift` | New. The type that records it. |
| `User Authentication/UserAuthenticationMethod.swift` | The method name, the available-methods flag, the offer case. |
| `User Authentication/ClientUserAuthenticationDelegate.swift` | `respondToKeyboardInteractiveChallenge`, defaulted to declining, plus `NIOSSHKeyboardInteractiveChallenge`. |
| `User Authentication/UserAuthenticationStateMachine.swift` | The `awaitingInfoResponse` state and its transitions, the response-count check, the prompt-loop cap. |
| `Connection State Machine/` | Routing, and keeping the parser's in-flight method current. |
| `NIOSSHError.swift` | `unsupportedUserAuthenticationMethod`. |

The interesting part is that **`SSH_MSG_USERAUTH_INFO_REQUEST` and
`SSH_MSG_USERAUTH_PK_OK` are both message ID 60.** SSH reuses IDs 60–79 per
authentication method, so a stateless parser cannot resolve them. The parser
therefore gained exactly one piece of state — which method is in flight — set
by the state machine that already knows. That is the only state it has, and
`SSHUserAuthMethodInFlight` exists to document why.

**2. RFC 8332 RSA signature algorithms.**

`NIOSSHPublicKeyProtocol` gained `keyBlobPrefix`, defaulted to
`publicKeyPrefix`. RSA is the one algorithm where the two differ: the key blob
always says `"ssh-rsa"` even when the negotiated algorithm is
`"rsa-sha2-256"` or `"rsa-sha2-512"`. Conflating them produces a key blob that
looks plausible and that OpenSSH rejects — and since OpenSSH has refused
SHA-1 `ssh-rsa` by default since 8.8, getting this right is the difference
between RSA keys working and not.

Everything else keeps its existing behaviour, because the new requirement is
defaulted.

### Keeping the fork honest

- `Tests/NIOSSHTests/KeyboardInteractiveTests.swift` is new and covers the
  wire format, the ID-60 resolution, hostile prompt counts, and the state
  machine including the prompt-loop cap.
- The changes are additive. No existing conformance needs to change and no
  existing behaviour does.
- To diff against upstream: `git clone -b 0.3.2
  https://github.com/Joannis/swift-nio-ssh.git && diff -ru swift-nio-ssh/Sources
  Vendor/swift-nio-ssh/Sources`.
