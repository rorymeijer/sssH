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
  │    PaneLayout · ConnectionSupervisor · PaletteScoring │
  │    TmuxControlParser · TmuxLayoutParser               │
  └───────────────────────────┬───────────────────────────┘
                              │
         ssshTransportNIOSSH — the only module that
         knows about SwiftNIO or NIOSSH
                              │
  Stores (SwiftData + CloudKit)   SecretsStore (Keychain / Secure Enclave)
                                                                 (Phase 6-7)
```

Three rules hold this together, and they are the three the brief calls
non-negotiable.

### The transport is replaceable

`ssshCore` declares `SSHTransport`, `SFTPService` and `PortForwardService` and
has no dependency on SwiftNIO or NIOSSH — it depends only on swift-log. No signature in it mentions `ByteBuffer`, `Channel` or
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
The synced model holds an opaque `SecretReference`; the secrets store resolves it.
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

### The pane tree

A tab's layout is a binary split tree (`PaneLayout`), not a list of rectangles.
Splitting replaces a leaf with a branch; closing a pane collapses its branch
into the sibling. That is why `PaneLayout.removing(_:)` returns `PaneLayout??`:
the outer optional says whether the pane was found in this subtree at all, and
the inner one distinguishes "found it, and nothing is left here" from "found it,
here is the subtree that remains". Flattening the two would make closing the
last pane of a tab indistinguishable from closing a pane that was never there.

### tmux control mode

With `usesTmuxControlMode`, sssh runs `tmux -CC` on the far side instead of a
plain shell. tmux then speaks a line protocol on stdout, and its windows and
panes become sssh tabs and splits — so a dropped connection loses the terminal,
not the work.

Two things about `TmuxControlParser` look odd and are deliberate:

- It is byte-based, and `%output` is decoded **without ever constructing a
  `String`**. tmux escapes only its own delimiters and passes every other byte
  through, so a pane emitting Latin-1, a partial UTF-8 sequence, or raw binary
  would be corrupted by a round trip through `String`. The bytes go to the
  terminal emulator exactly as they arrived.
- Replies are matched to commands by a FIFO, not by the number in `%begin`.
  tmux's numbering is a timestamp-and-counter pair that is not predictable from
  the client side; what *is* guaranteed is that blocks come back in the order
  the commands were sent.

`send-keys -H` (hex) is used for all input, because the quoting rules for
literal keys have edge cases that arbitrary terminal input will find.

### Reconnecting

`ConnectionSupervisor` owns the reconnect loop, and refuses to retry in two
cases:

- **`.hostKeyRejected`** — retrying re-prompts the user about a possible
  man-in-the-middle until they click through it. Fail closed means staying
  closed.
- **an expected close** (the shell exited, or the user disconnected) —
  reconnecting would resurrect a session the user ended.

Everything else is retried with the capped, jittered backoff in
`ReconnectPolicy`. The jitter is subtractive so that a delay never exceeds the
cap, which matters when the cap is what the user was promised.

### Command blocks

`CommandBlockSegmenter` turns a terminal stream into commands with their
output. It has two modes, and which one is running is shown to the user rather
than guessed at silently.

With **shell integration** the shell emits `OSC 133` (and possibly VS Code's
`OSC 633`), so the boundaries and the exit status are exact. sssh offers the
snippet and the user pastes it in; it never edits a remote `.bashrc` itself.
Doing that would be an edit to a machine the user opened a session to work on,
not a convenience.

Without it, the **fallback** cuts a block where the user pressed Return. Three
decisions there are worth stating, because each replaces something that looks
simpler and is wrong:

- The command text comes from the line the remote **echoed**, not from the
  keystrokes. Pressing Up recalls a command without typing a character of it,
  and tab completion types four characters of a twenty-character path.
- The prompt is separated from the command by remembering how much of the line
  was already drawn when the user first typed into it. Detecting a prompt by
  pattern is a losing game: real prompts contain git branches, hostnames,
  timestamps, emoji and colour, and a regexp that survives them also matches
  half the output of `grep`.
- A Return **arms** a cut; the echoed newline performs it. Cutting on the
  keystroke puts the boundary ahead of the output it belongs to on a slow link,
  and a paste of ten lines arrives as ten Returns at once. Only one is armed, so
  a paste becomes one block rather than nine blocks whose "commands" are really
  output lines.

Neither mode captures anything while the alternate screen buffer is active.
`vim` is not a command with output, and a byte log of one is unreadable:
reconstructing what it displayed needs a screen model, not a transcript. The
block says its output was truncated rather than pretending it is complete.

Two things the scanner does deliberately:

- It is a **token stream**, not a search for markers with offsets into a chunk.
  An `OSC 133 ; D ; 0` routinely arrives split across two reads, and an
  offset-based API has to describe a marker that started in a chunk the caller
  no longer has.
- It does **not** recognise the 8-bit C1 introducers (`0x9B`, `0x9D`). A
  terminal in UTF-8 mode never sends them, and those bytes are continuation
  bytes of ordinary characters: treating `0x9D` as an OSC introducer swallows
  the rest of a line whenever somebody's output contains Arabic or an emoji.

Search runs over blocks rather than over a flat scrollback, because a hit in a
block also answers which command produced it and whether that command failed.
It happens entirely on device. There are no AI features here and none are
planned: no suggestions, no explanations, no cloud call to explain a command.

### SFTP

swift-nio-ssh has no SFTP, so sssh has its own: version 3 of
`draft-ietf-secsh-filexfer`, over an SSH `subsystem` channel. Version 3 rather
than a later draft because it is what servers actually implement — OpenSSH has
never shipped anything newer — and the later drafts' attribute model is
different enough that supporting both is two implementations.

The pieces that are not obvious:

- **The channel handler reassembles.** SFTP packets are length-prefixed and an
  SSH channel is a byte stream, so packets arrive split and coalesced. Parsing
  per read works on localhost and fails on a real link.
- **Replies are matched by request id**, which SFTP has and channel requests do
  not. That is what makes it safe to have several reads in flight, and several
  reads in flight is the whole difference between a usable transfer and one
  that runs at the speed of the round trip.
- **The `subsystem` request is answered asynchronously.** The future from
  `triggerUserOutboundEvent` completes when the request is *written*; the answer
  arrives later as a bare `ChannelSuccessEvent`. Waiting on the write makes
  every commented-out `Subsystem sftp` look like a connection that then hangs.
- **stderr on the channel is not protocol data.** It is whatever the server's
  login scripts printed — the classic "a banner breaks sftp" problem — and it
  is logged rather than parsed.
- **Attributes carry the file-type bits.** In version 3 the `permissions` field
  is the whole of `st_mode`, so a `setstat` that means to change only the mode
  has to put the type bits back, or it tells the server the directory is now a
  regular file.
- **`symlink` sends target before linkpath**, contradicting the draft and
  matching OpenSSH's server — which is what every client does, because the
  server is what exists.

The wire format is tested against byte strings generated by Paramiko rather
than by round-tripping our own encoder, which would pass just as happily with
the field order reversed.

### The file browser

Dual-pane, and both panes are the same view. The local side presents its
contents as `RemoteFileEntry` so that sorting, filtering, selection and drag
all have one implementation; the genuine differences — only the remote side has
permissions, only the local side has a trash — are parameters.

`RemotePath` exists because `URL` cannot be used here. A POSIX filename is an
arbitrary byte string, and `%`, `#`, `?` and newlines are all legal in one.
Every one of those round-trips through `URL` wrong, and it shows up as "the
browser cannot open that one directory".

Transfers run one at a time per connection. SFTP over one SSH connection shares
one TCP stream, so four concurrent transfers are not faster — they are four
slow ones with meaningless progress bars. The depth is inside a transfer
instead, where several reads are in flight at once. Each of those reads fills
its own range before returning: the protocol allows a short read that is *not*
the end of the file, and a task that returned one would leave a hole in the
middle of the downloaded file.

Overwrite, keep-both and resume are always asked, never chosen. Resume only
applies when the partial file is shorter than the source; a longer one is not a
partial transfer, it is a different file.

### Port forwarding

All three kinds — `-L`, `-R` and `-D` — are one mechanism with three sources
for the destination, so the listener, the accounting and the teardown are
written once.

The parts that are load-bearing rather than incidental:

- **`GlueHandler` carries backpressure and half-close.** Without backpressure,
  forwarding a fast download through a slow uplink buffers the whole thing in
  the app. Without half-close travelling as a half-close, every HTTP request
  through the tunnel loses its reply: the client finishes sending, the EOF
  becomes a full close, and the response never arrives.
- **The SSH child channel starts with `autoRead` off.** NIOSSH buffers a child
  channel's inbound data until a read is asked for, which holds whatever the
  far side sends immediately — an SMTP banner, an SSH version string — until
  there is somewhere to put it. Without that, the data is delivered to a
  pipeline whose glue has no partner yet and is dropped, which looks exactly
  like a server that does not answer.
- **SOCKS writes its success reply between the channel opening and the two
  sides being joined.** Earlier, and a refused connection has already been
  reported as succeeding; later, and the far side's first bytes are ahead of
  the reply in the client's stream.
- **Bytes that arrive in the same packet as the SOCKS request are replayed.**
  Losing them is what makes a pipelined request through the proxy hang rather
  than fail.
- **The remote-forward registry exists before the `NIOSSHHandler` does.** `-R`
  arrives as inbound `forwarded-tcpip` channels, and the initializer that
  accepts them is fixed when the handler is built. Anything not in the registry
  is refused — which is also the right answer to a server opening channels
  nobody asked for.
- **An inexact registry match is only accepted when one tunnel owns the port.**
  Servers disagree about what to echo back in `listeningHost`, but guessing
  between two tunnels would hand someone's connection to the wrong service.

A tunnel belongs to the connection underneath it. A reconnect does not resume
one; it rebuilds the ones marked to start automatically, because the listeners
on the old connection are already gone.

`127.0.0.1` is the default bind address everywhere, and binding anything else
is called out in the editor and again in the status list. The difference is
whether a tunnel is available to this machine or to the whole network, and
defaulting to the network is how a personal tunnel becomes an open relay on a
café Wi-Fi. `RemotePath.isLoopbackAddress` matches exactly rather than by
prefix for the same reason: `127.0.0.1.example.com` is not loopback.

The SOCKS implementation is checked against PySocks, an independent client: the
request bytes in the tests were captured from it, and it accepted this
handler's success reply and went on to use the tunnel.

### Reading `~/.ssh/config`

The format looks simpler than it is, and four things trip up every naive
parser. All four appear in real files, and all four are tested:

- `Keyword=Value` is as valid as `Keyword Value`, with optional whitespace
  around the `=`.
- Values can be quoted, and `#` inside quotes is part of the value — which
  matters, because a path can contain one.
- **The first value wins**, not the last. Every other configuration format in
  common use is the other way round, and getting it backwards silently changes
  which user or port a host connects as. `IdentityFile`, `LocalForward`,
  `RemoteForward` and `DynamicForward` are the exceptions: those accumulate.
- `Match host` compares against the **resolved `HostName`**, not the alias;
  `Match originalhost` is the one that matches what the user typed. A file with
  `Host web` / `HostName web.example.com` / `Match host web` has a block that
  looks like it applies and does not.

The parser was checked against OpenSSH 9.6's own `ssh -G` on every case in its
test file, including the ones where `ssh` refuses the input.

sssh diverges from `ssh` in exactly one place, on purpose: **`Match exec` is
never evaluated and `ProxyCommand` is never run.** Both ask a configuration
file to run a shell command, and a config file can arrive by import, by sync,
or from a colleague. Blocks containing one are skipped and the import says so,
by line number. `ProxyJump` covers the common case and is supported.

Nothing is imported until the user has seen what will be. Every setting sssh
cannot honour is listed, because an import that silently drops half a host's
configuration produces a saved connection that behaves differently from the
same alias in `ssh` — and that is discovered at the worst possible moment. The
file is chosen through the system picker rather than read from `~/.ssh/config`
directly, and private keys named by `IdentityFile` are recorded as paths, never
read.

### Snippets

`{{name}}` is a parameter and `{{name=default}}` gives it one. Everything else
is literal — including a lone `{`, an unclosed `{{`, and `${VAR}`. The syntax is
doubled braces precisely because shell scripts are full of single ones, and a
template language that eats `awk '{print $1}'` is worse than no template
language at all.

A default belongs to a *name*, not to an occurrence: `{{a}} … {{a=d}}` is one
parameter with one default, because resolving it per occurrence makes the same
name expand to two different things in one command. A parameter with nothing to
fill it becomes empty rather than staying as `{{name}}`, since sending the
literal placeholder to a shell turns a template into a syntax error at the far
end.

The parameter sheet shows the final text before it goes. A snippet runs on a
machine whose shell the user is not looking at, and that preview is the
difference between a shortcut and a gamble. Snippets are never run on the app's
own initiative and there is no "run on connect": a saved command that fires by
itself on an unfamiliar machine is a way to lose an afternoon.

### Secrets, sync and the app lock

Three separate mechanisms, protecting three different things. Confusing them is
how an app ends up claiming more than it delivers.

**The device key.** A P-256 key generated inside the Secure Enclave, used to
wrap every stored secret before it reaches the Keychain. It can perform key
agreement and can never be read out, so a Keychain database lifted off a backup
is ciphertext without the hardware that made the key. On an Intel Mac with no
Secure Enclave the fallback is a software key stored `ThisDeviceOnly`, which is
meaningfully weaker — and the settings screen says which one is in use rather
than claiming the stronger one everywhere. The scheme is the ordinary one: a
fresh ephemeral key per secret, ECDH against the device key, HKDF to an AES-GCM
key. Nothing novel, which is the point.

**What syncs, and how.** Hosts, groups, snippets, tunnels and host-key
fingerprints go through CloudKit's private database. None of it is secret, and
fingerprints syncing is what makes trust follow the user between devices.
Private keys, passphrases and passwords never go there: CloudKit's private
database is not end-to-end encrypted, and a key in it would be a key in a
database Apple can read.

Secret sync is off by default and opt-in, and when it is on it goes through
iCloud Keychain — which *is* end-to-end encrypted. The trade is stated in the
settings screen rather than buried, because it is real: a synced secret cannot
be wrapped with the device key, since the device key is device-bound and the
other machine would have nothing to open it with. So device-only secrets are
protected by the Enclave *and* the Keychain; synced ones are protected by iCloud
Keychain alone.

Because of that, the store reads from both scopes and only writes to the
current one, and switching writes each secret to the new scope before deleting
the old copy. The other order loses a key if it is interrupted; this order
leaves a duplicate, which reads fine and is cleaned up next time.

**The app lock** protects neither of those. It protects the *session*: an
unlocked laptop on a desk with a terminal already connected to production, which
is the common threat and the one the Keychain does nothing about. It covers the
screen opaquely rather than blurring it — a blur over a terminal still shows the
shape of the last command — and it uses `deviceOwnerAuthentication` rather than
the biometrics-only policy, so a user whose Face ID fails in the dark is not
locked out of their own terminal.

### Generating keys

On device, which is the whole point: a key generated anywhere else has been
somewhere else. Ed25519 by default; RSA because people still have servers that
will not take anything else, and a key you cannot use is not security.

The private half goes straight to the Keychain and is never displayed. The
public half is shown and copyable, and is the only half meant to leave.

`OpenSSHPrivateKeyWriter` is checked against `ssh-keygen` rather than against
this package's own parser: a round trip through our own reader would pass just
as happily with two fields swapped. For an unencrypted key the output is
byte-for-byte what `ssh-keygen` writes. Two details in that format are easy to
get wrong and both are pinned by tests: RSA's fields are `e, n` in the public
blob and `n, e, d, iqmp, p, q` in the private half, and the private section is
padded with 1, 2, 3, … rather than with zeros.
