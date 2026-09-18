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
