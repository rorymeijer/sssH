# sssh — Super SSH

A native, universal SSH client for macOS, iPadOS and iOS. SwiftUI,
privacy-first, no AI features.

**Status: Phase 0 complete — SSH backend chosen and the interactive-PTY
transport written. No app UI yet.**

## Where things are

| Path | What |
|---|---|
| `Sources/ssshCore` | Backend-agnostic protocols and value types. Pure Swift. |
| `Sources/ssshTransportNIOSSH` | The swift-nio-ssh backed transport. The only module that knows about SwiftNIO. |
| `Sources/ssshPTYSpike` | `sssh-ptyspike`, the Phase 0 interactive-PTY harness. |
| `Integration/` | A throwaway sshd and a script that runs the harness against it. |
| `docs/PHASE-0-BACKEND-DECISION.md` | Which backend, why, and every library limitation found. **Start here.** |
| `docs/ARCHITECTURE.md` | Layering, and the reasoning behind the awkward parts. |

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

swift-nio-ssh, driven directly rather than through Citadel's `SSHClient`, with
Citadel supplying RSA, `diffie-hellman-group14-*`, AES128-CTR and OpenSSH
private-key parsing. Owning the pipeline is what makes remote port forwarding,
terminal backpressure and macOS 14 support possible at all. The reasoning, the
cost (Citadel's SFTP client becomes unreachable) and the four library gaps
found along the way are in
[docs/PHASE-0-BACKEND-DECISION.md](docs/PHASE-0-BACKEND-DECISION.md).

**The code has not been compiled**: it was written against the libraries'
actual sources, but the environment it was written in has no Swift toolchain.
Expect ordinary compile errors on the first build. See "Verification status" in
the Phase 0 report.

## Phases

- [x] **0** — PTY spike, backend decision, `SSHTransport` protocol
- [ ] **1** — Core terminal app: SwiftTerm host, password + key auth, known-hosts prompt, tabs, host list
- [ ] **2** — Splits, broadcast, session restore, command palette, tmux, reconnect
- [ ] **3** — Command blocks (OSC 133 + heuristics), per-block actions, in-session search
- [ ] **4** — SFTP browser, transfer queue, drag and drop
- [ ] **5** — Port forwarding: local, remote, dynamic
- [ ] **6** — Groups, tags, snippets, `~/.ssh/config` import, themes
- [ ] **7** — CloudKit sync, Keychain/Secure Enclave, app lock
- [ ] **8** — Dutch localisation pass, accessibility, macOS/iPad platform work, hardening

## Licence and conventions

Code, identifiers and comments in English. All user-facing strings are
Dutch-first through a String Catalog, from Phase 1 onwards — nothing in the
current modules produces user-facing prose, by design.
