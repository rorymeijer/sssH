# sssh — Super SSH

A native, universal SSH client for macOS, iPadOS and iOS. SwiftUI,
privacy-first, no AI features.

**Status: all eight phases done — the feature set in the brief is written.
Phase 8 closed it out with a Dutch localisation pass over every user-facing
string, an accessibility and Dynamic Type pass, macOS and iPad platform work,
and [docs/SECURITY.md](docs/SECURITY.md).**

## Where things are

| Path | What |
|---|---|
| `App/` | The SwiftUI app for macOS, iPadOS and iOS. See [App/README.md](App/README.md). |
| `Sources/ssshCore` | Backend-agnostic protocols and value types. Pure Swift. |
| `Sources/ssshCrypto` | `openssh-key-v1` parsing, and the primitives swift-crypto does not expose (Blowfish, bcrypt_pbkdf, AES-CTR, DER). |
| `Vendor/swift-nio-ssh` | A fork, carrying keyboard-interactive auth and the RFC 8332 RSA fix. See [Vendor/README.md](Vendor/README.md). |
| `Sources/ssshTransportNIOSSH` | The swift-nio-ssh backed transport, and sssh's own SFTP v3 and SOCKS5 implementations. The only module that knows about SwiftNIO. |
| `Sources/ssshPTYSpike` | `sssh-ptyspike`, the Phase 0 interactive-PTY harness. |
| `Integration/` | A throwaway sshd and a script that runs the harness against it. |
| `docs/PHASE-0-BACKEND-DECISION.md` | Which backend, why, and every library limitation found. **Start here.** |
| `docs/ARCHITECTURE.md` | Layering, and the reasoning behind the awkward parts. |
| `docs/SECURITY.md` | What is protected, what is not, and where each claim is enforced. |
| `docs/KEYBOARD-INTERACTIVE-PLAN.md` | The design for two-factor sign-in support, and why it is not written yet. |

## Building the app

```sh
brew install xcodegen
cd App && xcodegen generate && open sssh.xcodeproj
```

## Running the Phase 0 harness

```sh
docker compose -f Integration/docker-compose.yml up --build -d
swift build
./Integration/run-spike.sh              # automated PTY conformance checks
./Integration/run-spike.sh interactive  # attach your terminal to the remote shell
docker compose -f Integration/docker-compose.yml down -v
```

Against your own host:

```sh
swift run sssh-ptyspike verify --host example.test --user you \
    --key ~/.ssh/id_ed25519 --host-key "SHA256:..."
```

Pass credentials through `SSSH_SPIKE_PASSWORD` / `SSSH_SPIKE_PASSPHRASE` rather
than on the command line where anything might read them. The host key must be
pinned with `--host-key`, or `--trust-any-host-key` given explicitly — there is
no default that trusts a stranger.

## Backend, in one paragraph

A vendored fork of swift-nio-ssh, driven directly. sssh owns the channel
pipeline, which is what makes remote port forwarding, terminal backpressure and
macOS 14 support possible at all; the fork adds keyboard-interactive
authentication and RFC 8332's RSA names. Key parsing, RSA signing and the
`bcrypt_pbkdf`/AES-CTR a key file needs are all in `ssshCrypto`. **sssh requires
a server with `curve25519-sha256` and AES-GCM — OpenSSH 6.5 (2014) or newer.**
The reasoning is in
[docs/PHASE-0-BACKEND-DECISION.md](docs/PHASE-0-BACKEND-DECISION.md).

**The code has not been compiled.** It was written against the libraries' actual
sources — every API it calls was checked to exist — but the environment it was
written in has no Swift toolchain and no route to one. Expect ordinary compile
errors on the first build.

The protocol and cryptography work is the exception, and is worth trusting.
Every algorithm that has to agree with something outside this repository was
transcribed to Python line for line and run against an external oracle — never
against itself — and the test vectors in the suite are those same external
values:

| What | Checked against |
|---|---|
| `bcrypt_pbkdf` | OpenBSD's own `bcrypt_pbkdf.c`, compiled and run |
| AES-CTR | FIPS-197 vectors and `openssl enc` |
| `openssh-key-v1` parsing | Ten containers built around real openssl-generated key pairs |
| `openssh-key-v1` writing | `ssh-keygen` — byte-identical output, and `ssh-keygen -y` reads our files |
| DER | `openssl`, plus the identities n = p·q, e·d ≡ 1, iqmp·q ≡ 1 (mod p) |
| SFTP v3 wire format | Paramiko |
| SOCKS5 | PySocks, which accepted our replies and used the tunnel |
| `~/.ssh/config` parsing | OpenSSH 9.6 `ssh -G`, case by case |

All of it matched. `ssh -G` and `ssh-keygen` each found a real bug this way —
a `Match host` that compared the alias instead of the resolved `HostName`, and
a padding scheme that was zeros rather than 1, 2, 3… See "Verification status"
in the Phase 0 report.

## Phases

- [x] **0** — PTY spike, backend decision, `SSHTransport` protocol
- [x] **1** — Core terminal app: SwiftTerm host, password + key auth, `keyboard-interactive`, known-hosts prompt, tabs, host list
- [x] **2** — Splits, broadcast, session restore, command palette, tmux, reconnect
- [x] **3** — Command blocks (OSC 133 + fallback), per-block actions, in-session search
- [x] **4** — SFTP browser, transfer queue, drag and drop
- [x] **5** — Port forwarding: local, remote, dynamic
- [x] **6** — Groups, tags, snippets, `~/.ssh/config` import, themes
- [x] **7** — CloudKit sync, Keychain/Secure Enclave, app lock
- [x] **8** — Dutch localisation pass, accessibility, macOS/iPad platform work, hardening

## Licence and conventions

Code, identifiers and comments in English. All user-facing strings are
Dutch-first through the String Catalog at
`App/Sources/ssshApp/Resources/Localizable.xcstrings`; English is a
translation, and every key carries a comment for whoever translates the next
language. The library modules under `Sources/` produce no user-facing prose at
all, by design — a transport that formats its own error messages cannot be
localised by the app that embeds it.
