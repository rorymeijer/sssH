# Phase 0 — SSH backend decision

Brief §3 asks for the riskiest assumption to be de-risked first: that a
pure-Swift SSH stack can drive a robust *interactive* PTY session, not just
one-shot `exec`. This is the report on that, and on which backend the rest of
sssh is built against.

## Verdict

**Stay pure-Swift, but drive swift-nio-ssh directly rather than through
Citadel's `SSHClient`.** Citadel stays in the dependency graph for the things
it is genuinely good at. No libssh2, no wrapped `/usr/bin/ssh`.

Concretely, `ssshTransportNIOSSH` owns the `NIOSSHHandler` and the channel
pipeline, and uses Citadel as a library for:

| From Citadel | Why NIOSSH cannot |
|---|---|
| `Insecure.RSA` public key + signature | swift-nio-ssh deliberately omits RSA entirely |
| `DiffieHellmanGroup14Sha256` / `…Sha1` | NIOSSH bundles only `curve25519-sha256` |
| `AES128CTR` | NIOSSH bundles only the AES-GCM schemes |
| `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)` | NIOSSH has no OpenSSH private-key parser, and this one handles bcrypt-pbkdf + AES-CTR |

Without these, sssh could not connect to an appliance offering an RSA host key,
or open a passphrase-protected `id_ed25519`. They are not optional.

## Why not Citadel's `SSHClient`

Citadel has a perfectly good `withPTY` API, and the obvious plan was to use it.
Three things ruled it out, all traceable to Citadel constructing its
`NIOSSHHandler` internally and keeping it private:

1. **`ssh -R` becomes impossible.** Citadel builds its handler with
   `inboundChildChannelInitializer: nil`, which rejects every inbound channel.
   Remote forwarding works by the *server* opening `forwarded-tcpip` channels
   back to the client, so with that initializer nil there is no code path for
   `-R` to exist — and `-R` is a v1 requirement (§5.4). `sendTCPForwardingRequest`
   is public on `NIOSSHHandler`, so the request can be sent; the connections it
   causes would simply be refused.

2. **No backpressure on session channels.** `autoRead` on an `SSHChildChannel`
   is inherited from the parent and then settable in the channel initializer —
   which Citadel owns. Its TTY API buffers into an unbounded
   `AsyncThrowingStream`, so `cat big.log` grows the app's memory until
   SwiftTerm catches up. §9 asks for the opposite.

3. **`withPTY` is `@available(macOS 15.0, *)`**, on `main` as well as on
   0.9.2, while the brief targets macOS 14. This one alone would have forced a
   choice between raising the deployment target and forking.

Owning the pipeline fixes all three, and costs one thing (below).

### What owning the pipeline costs

**Citadel's SFTP client becomes unreachable.** `SFTPClient.setupChannelHanders`
and `SSHClient.init` are both internal, so an `SFTPClient` can only be obtained
from a Citadel-owned connection. Phase 4 therefore has to choose between:

- **(preferred)** a small upstream PR to Citadel exposing SFTP over a
  caller-supplied `NIOSSHHandler`, plus `inboundChildChannelInitializer` — both
  are additive and useful to every Citadel user; or
- our own SFTP client. The protocol is not large, and Citadel's message
  encoder/decoder is a good model, but it is real work.

`openSFTP()` currently throws `SSHTransportError.unsupported(.sftp)` behind the
`SFTPService` protocol, so nothing above the transport needs to change when it
lands. This is the one decision in Phase 0 that could reasonably go either way,
and it is deliberately deferred rather than pre-empted.

## What the harness checks

`sssh-ptyspike` (see `Integration/README.md`) opens a real PTY-backed shell and
asserts on each item §3 lists, plus a few the brief implies:

| Check | What it proves |
|---|---|
| shell reaches a prompt | `pty-req` + `shell` accepted, bidirectional streaming works |
| `tty` names a pseudo-terminal | a PTY really was allocated, not an `exec` channel |
| `TERM` is `xterm-256color` | the terminal type in `pty-req` reached the shell |
| `stty size` matches `pty-req` | initial geometry propagated |
| resize changes `stty size` | `window-change` reaches the remote PTY |
| Ctrl-C interrupts `sleep` | 0x03 on the PTY becomes SIGINT remotely; PTY modes are sane |
| 60 000 lines arrive intact | the backpressure path loses nothing |
| `vim` takes the terminal over | a full-screen application works |
| `htop` redraws | so does a continuously-redrawing one |
| `tmux` attaches and detaches | plain tmux works inside the PTY |
| a second shell on one connection | channel multiplexing, which tabs and splits need |
| keep-alive probe round-trips | liveness detection works at the SSH layer |
| `exit` reports `exit-status 0` | clean teardown, exit status not lost |

The suite distinguishes **fail** from **skip** (the remote host lacks the
program) and from **gap** (known not to work, and known why), so a green run
never depends on somebody remembering which failures were expected.

### Verification status — read this before trusting the table

The code in this repository was written against the actual sources of
Citadel 0.9.2, `Joannis/swift-nio-ssh` 0.3.2 and SwiftTerm, all read directly.
Every API it calls was confirmed to exist with the signature used, and the
library limitations listed here were established by reading the
implementations, not from documentation.

**It has not been compiled or executed.** The environment this was built in has
no Swift toolchain and no access to one: `download.swift.org` and the Docker
image CDN are both blocked by the network policy, and Swift is not packaged for
the distribution. So expect the first `swift build` on a real machine to turn up
ordinary compile errors — a wrong label, a Sendable warning, a `Duration`
conversion — and treat the check table above as *what the harness asserts*,
not as a result that has been observed. The harness exists precisely so that
running it produces the real answer in one command:

```sh
docker compose -f Integration/docker-compose.yml up --build -d
swift build && ./Integration/run-spike.sh
```

## Library limitations found, and what they mean

These are the things worth knowing before building features on top. Each was
confirmed by reading the source.

### `keyboard-interactive` authentication does not exist in swift-nio-ssh

`NIOSSHUserAuthenticationOffer.Offer` has exactly four cases — `privateKey`,
`password`, `hostBased`, `none`. There is no `keyboard-interactive` case, and a
custom `NIOSSHClientUserAuthenticationDelegate` cannot add one, because the
delegate's only output is that enum. Grepping the whole library for "keyboard"
returns nothing.

This matters more than it first looks: `keyboard-interactive` is how most
servers do TOTP and PAM-driven 2FA, and §5.1 asks for it. Worse, NIOSSH's
parser *silently drops* methods it does not implement while reading the
server's `SSH_MSG_USERAUTH_FAILURE`, so a server that offers only
`keyboard-interactive` looks to us like a server that offers nothing — the
error message cannot even name the real requirement.

Options, in order of preference:

1. Implement it in swift-nio-ssh and upstream it. The message flow
   (`SSH_MSG_USERAUTH_INFO_REQUEST`/`RESPONSE`) is small and well specified,
   and the state machine has a natural place for it. This is the only option
   that actually delivers the feature.
2. Ship without it and say so in the UI: "this server requires
   keyboard-interactive authentication, which sssh cannot do yet."
   `SSHTransportError.unsupported(.keyboardInteractiveAuthentication)` already
   carries exactly that.

`SSHCredential.keyboardInteractive` and its handler protocol are defined now, so
adding support later does not change the transport's surface.

**Recommendation:** treat (1) as a Phase 1 task with a real chance of being
rejected upstream, and design the auth UI so (2) is not embarrassing. This is
the largest gap between the brief and what a pure-Swift stack can do today, and
it is worth an explicit decision rather than a surprise.

### ssh-agent forwarding is not implemented

Neither library has it. Reading identities from a local agent is a separate
(and easier) job from forwarding the agent to the remote host; on iOS there is
no agent to talk to anyway. Reported as
`SSHTransportError.unsupported(.agentForwarding)`.

### Only ed25519 OpenSSH private-key *files* can be read

Citadel's `openssh-key-v1` container parser is generic over key type
internally, but the only public entry point is
`Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)`. So:

| Key file | Readable |
|---|---|
| `openssh-key-v1` ed25519, plain or passphrase-protected | yes |
| PEM PKCS#8 / SEC1 P-256/384/521 | yes, via swift-crypto |
| `openssh-key-v1` RSA or ECDSA | **no** |
| PKCS#1 `BEGIN RSA PRIVATE KEY` | **no** |

Note this is a *file-reading* gap, not a protocol gap: RSA authentication
itself works fine once a key is in hand, because Citadel's `Insecure.RSA` is
registered with NIOSSH. Closing it means writing the container parser
ourselves — armor, bcrypt-pbkdf, AES-CTR, then per-algorithm key material,
maybe 300 lines with the bcrypt primitive being the only awkward part. Given
how many people still carry an `id_rsa`, this should be Phase 1 work.
`PrivateKeyLoader` already reports `.unsupportedKeyType("ssh-rsa")` by name so
the UI can tell the user to convert the key rather than leaving them guessing.

### Keep-alive has to be improvised

OpenSSH sends a `keepalive@openssh.com` global request. NIOSSH exposes no way
to send an arbitrary global request — the only public one is
`sendTCPForwardingRequest`. So `sendKeepAliveProbe` cancels a TCP forward that
was never established: the server answers `REQUEST_FAILURE`, which is a
complete round trip through key exchange, decryption and the server's main
loop, and has no side effect. Any answer counts as alive; only silence counts
as dead. Combined with `SO_KEEPALIVE` at the socket level this detects both a
dead peer and a wedged one.

It works, and it is slightly distasteful. A one-line addition to NIOSSH for
arbitrary global requests would be the clean fix and is worth upstreaming.

### Citadel's own reconnect logic is unusable

`SSHClient.connect(host:…, reconnect:)` stores the `SSHAuthenticationMethod`
*instance* and reuses it on reconnect — but that class consumes its
`implementations` array with `removeFirst()` and never resets it from
`allImplementations`. So the second authentication attempt with the same
instance has nothing left to offer and fails. We therefore do our own
reconnection (`ReconnectPolicy` + `KeepAliveMonitor`), which we wanted anyway
for backoff, jitter and session restore.

The same trap applies to our own code, which is why
`CredentialAuthenticationDelegate` is constructed fresh for every connection
attempt rather than stored.

### `exit-signal` is delivered, `signal` requests usually are not

NIOSSH surfaces both `SSHChannelRequestEvent.ExitStatus` and `ExitSignal`, so
we can always report how a shell ended. Sending a `signal` request is also
supported — but OpenSSH's sshd has never implemented receiving one, so it will
be refused on the servers that matter. This is why the terminal must send
Ctrl-C as byte 0x03 through the PTY and not as an SSH signal. The harness
records this as a *gap* rather than a failure, so the suite documents which
server does what without turning red.

### Adding `NIOSSHHandler` to an already-reading channel loses the handshake

Not a limitation so much as a trap worth writing down. `NIOSSHHandler.handlerAdded`
initializes when the channel is already active, so adding it late *looks*
fine — but with `autoRead` on (the default), the server's version string can
arrive before the handler is installed, hit the tail of the pipeline, and be
dropped. The handshake then hangs until it times out, intermittently, more
often against a fast server such as a container on loopback.

Every handler is therefore installed in the channel initializer, before any
byte can be read — for the direct socket and for the nested connection inside
a `direct-tcpip` channel alike.

## Fallbacks, and why they were not needed

The brief's fallback plan was libssh2 or a wrapped system `ssh` on macOS. Neither
is needed: everything §3 lists is reachable with the pure-Swift stack once the
pipeline is ours. For the record, had it been needed:

- **libssh2** has a well-trodden interactive PTY, but it is blocking-by-default
  and would need a thread per session, it has no built-in SFTP concurrency, and
  it drags a C dependency and its own OpenSSL/mbedTLS choice into an app that
  syncs keys through the Secure Enclave.
- **Wrapping `/usr/bin/ssh`** would be the most compatible option of all
  (`keyboard-interactive`, agent forwarding, `ProxyJump`, everything), but it
  is macOS-only — iOS cannot spawn processes — so it could only ever be a
  second backend, not the backend.

`SSHTransport`, `SFTPService` and `PortForwardService` are protocols with no
SwiftNIO types in their signatures, so either remains a drop-in if a reason to
reconsider appears. A useful consequence: `Tests/ssshCoreTests/FakeTransport.swift`
implements the whole transport protocol with no socket at all, which is the
practical test of whether the seam is real.

## One unexpected win

`NIOSSHPrivateKey(secureEnclaveP256Key:)` exists. An SSH key can therefore be
generated inside the Secure Enclave and used for authentication without its
private half ever existing in memory — which is a stronger guarantee than §7
asks for, and worth building the key-management UI around in Phase 7.

## Summary of follow-ups this phase created

| # | Task | Phase | Notes |
|---|---|---|---|
| 1 | Write an `openssh-key-v1` parser for RSA and ECDSA key files | 1 | Users have `id_rsa`. Needs bcrypt-pbkdf. |
| 2 | Decide `keyboard-interactive`: upstream it, or ship without it and say so | 1 | Needs a product decision, not just code. |
| 3 | SFTP: upstream a Citadel change, or write our own client | 4 | Preference is upstream; both are viable. |
| 4 | Remote forwarding via `inboundChildChannelInitializer` | 5 | The pipeline is already ours, so this is now just work. |
| 5 | Upstream arbitrary global requests to NIOSSH for a proper keep-alive | later | Current probe works; this is cleanliness. |
| 6 | Investigate tmux control mode (`-CC`) | 2 | Plain tmux is verified; `-CC` is a protocol on top and unexamined. |
