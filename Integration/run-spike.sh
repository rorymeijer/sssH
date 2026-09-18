#!/bin/bash
# Runs the Phase 0 PTY harness against the container from docker-compose.yml.
#
# The host key is pinned from the fingerprint the container wrote, so the run
# exercises the same fail-closed path the app uses rather than the
# trust-anything escape hatch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS="${ROOT}/Integration/.keys"

if [[ ! -f "${KEYS}/host_key_fingerprint" ]]; then
    echo "no host key fingerprint in ${KEYS}; is the sshd container up?" >&2
    echo "  docker compose -f Integration/docker-compose.yml up --build -d" >&2
    exit 2
fi

FINGERPRINT="$(cat "${KEYS}/host_key_fingerprint")"
MODE="${1:-verify}"

echo "pinning host key ${FINGERPRINT}"

# The key file must not be group/world readable or nothing will use it.
chmod 600 "${KEYS}/id_ed25519" || true

run() {
    local label="$1"; shift
    echo
    echo "=== ${label} ==="
    "${ROOT}/.build/debug/sssh-ptyspike" "${MODE}" \
        --host 127.0.0.1 --port 2222 --user spike \
        --host-key "${FINGERPRINT}" \
        "$@"
}

if [[ "${MODE}" == "interactive" ]]; then
    # One session, attached to this terminal — the manual half of the proof.
    run "interactive session" --key "${KEYS}/id_ed25519"
    exit 0
fi

# All three authentication paths, because the credential delegate walks them in
# order and a key that silently fell back to the password would otherwise look
# like a pass.
run "public-key authentication" --key "${KEYS}/id_ed25519"
run "password authentication" --password spike-password
run "passphrase-protected key" --key "${KEYS}/id_ed25519_passphrase" --passphrase spike-passphrase
