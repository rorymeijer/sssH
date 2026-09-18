# Integration harness

A throwaway SSH server plus a script that runs the Phase 0 PTY harness against
it. This is where the parts that cannot be unit-tested are actually verified:
real `pty-req`/`window-change` handling, real `vim`/`htop`/`tmux`, real
OpenSSH-generated keys, and real `exit-status` on teardown.

## Running it

```sh
docker compose -f Integration/docker-compose.yml up --build -d
swift build
./Integration/run-spike.sh            # automated checks
./Integration/run-spike.sh interactive  # hand the local terminal to the remote shell
docker compose -f Integration/docker-compose.yml down -v
```

`Integration/.keys/` is a volume the container writes into: the client key
pair, a passphrase-protected key pair, and the host key fingerprint for the
run to pin. It is regenerated on every `up --build`, and git-ignored.

## What it proves that the unit tests cannot

The unit tests build `openssh-key-v1` files from the format's own rules, which
checks the reader but not compatibility with what `ssh-keygen` really emits.
The container generates its keys with the real `ssh-keygen`, so a run here is
the compatibility test.

## Deliberate choices

- **Loopback only.** The container has a fixed password, so port 2222 is bound
  to `127.0.0.1` and nothing else.
- **The host key is pinned, not trusted.** `run-spike.sh` reads the
  fingerprint the container wrote and passes it with `--host-key`, so the run
  goes through the same fail-closed verification the app does. The
  `--trust-any-host-key` flag exists but is not used here.
- **`vim`, `htop` and `tmux` are installed.** A skipped check is not evidence.
