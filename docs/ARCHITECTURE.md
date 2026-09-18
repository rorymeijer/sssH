# Architecture

## Layering

```
  SwiftUI views · terminal hosts · file browser · tunnel UI      (Phase 1+)
                              │
                       SessionManager                            (Phase 1+)
          per-connection lifecycle, tabs/splits, restore
                              │
  ┌───────────────────────────┴───────────────────────────┐
  │  ssshCore — protocols and value types, pure Swift     │
  │    SSHTransport · SSHShellSession                     │
  │    SFTPService · PortForwardService                   │
  │    SSHKnownHostsPolicy · KeepAliveMonitor             │
  │    ReconnectPolicy · SSHShellEventStream              │
  └───────────────────────────┬───────────────────────────┘
                              │
         ssshTransportNIOSSH — the only module that
         knows about SwiftNIO, NIOSSH or Citadel
                              │
  Stores (SwiftData + CloudKit)   SecretsStore (Keychain / Secure Enclave)
                                                                 (Phase 6-7)
```

Three rules hold this together, and they are the three the brief calls
non-negotiable.

### The transport is replaceable

`ssshCore` declares `SSHTransport`, `SFTPService` and `PortForwardService` and
has no dependency on SwiftNIO, NIOSSH or Citadel — it depends only on
swift-log. No signature in it mentions `ByteBuffer`, `Channel` or
`EventLoop`; the terminal deals in `[UInt8]` and `ArraySlice<UInt8>`, which is
also what SwiftTerm deals in.

The app reaches a backend through `SSHTransportFactory`, and
`NIOSSHTransportFactory` is the only place a concrete backend is named.
`Tests/ssshCoreTests/FakeTransport.swift` implements the whole protocol with no
socket, which is the working proof that the seam is real rather than
decorative.

### Secrets stay out of the synced store

`SecretString` has no `Codable` conformance and its `description` is
`<redacted>`, so a secret cannot reach a log line, a crash report or a
SwiftData store through interpolation. Reading one requires calling
`reveal()`, which is deliberately conspicuous in review.

Transport types carry resolved secrets only for the duration of a handshake.
The synced model holds an opaque `authRef`; the secrets store resolves it.
Host-key *fingerprints* are not secrets and do sync, so trust follows the user
between devices.

### The UI is localisable

Nothing in `ssshCore` or `ssshTransportNIOSSH` produces user-facing prose.
`SSHTransportError` is a structured enum carrying the facts — which endpoint,
which credentials were tried, which methods the server accepts, which
capability is missing — and the app turns those into Dutch strings through the
String Catalog. That is why the error type has a
`SSHTransportError.Capability` enum rather than a message string: a missing
feature must be explainable in any language, and must not offer a pointless
retry.

The spike harness prints English to a developer's terminal, and is not part of
the app.

## Notes on the interesting parts

### Backpressure

`SSHShellEventStream` is a hand-written `AsyncSequence` rather than an
`AsyncThrowingStream`, because neither of that type's buffering policies is
acceptable for a terminal: unbounded buffering means `cat big.log` grows the
app's memory until SwiftTerm catches up, and `bufferingNewest` *drops bytes*,
which in a terminal stream means dropping escape sequences and corrupting the
display.

Instead the producer asks whether to keep reading. `ShellChannelHandler` turns
`autoRead` off and issues a read after each batch only while
`SSHShellEventSink.shouldContinueReading()` says yes; when the consumer falls
behind, reads stop, the SSH channel's pending-read buffer fills, the parent
socket stops being read, and TCP backpressure does the rest. When the consumer
drains past the low water mark the sink calls back and reads resume.

The buffering rules live in `ssshCore`, with no NIO types involved, so they are
unit-tested directly.

### Channel-request replies

`pty-req`, `shell` and `exec` are sent with `want_reply`, and SSH answers with
a bare `SSH_MSG_CHANNEL_SUCCESS`/`FAILURE` that identifies no request. Replies
arrive in order, so the only correct approach is a FIFO of promises, which is
what `ShellChannelHandler` keeps. A failed write removes its own promise from
the FIFO and fails it, because an uncompleted `EventLoopPromise` traps on
deinit in debug builds.

### Jump hosts

A `ProxyJump` hop is a whole second SSH connection running inside the bastion's
`direct-tcpip` channel: `SSHChannelDataCodec` unwraps the channel's framing
into a plain byte stream, and a nested `NIOSSHHandler` sits on top of it.
Chains work by recursion, and the bastion connections are torn down innermost
first.

### Why handlers go in the channel initializer

`NIOSSHHandler` must be in the pipeline before the channel reads anything, or
the server's version string is delivered to the tail of the pipeline and
dropped, hanging the handshake intermittently. See the corresponding section in
[PHASE-0-BACKEND-DECISION.md](PHASE-0-BACKEND-DECISION.md).
