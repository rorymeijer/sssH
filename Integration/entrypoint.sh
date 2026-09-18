#!/bin/bash
# Prepares the throwaway sshd the Phase 0 harness runs against.
set -euo pipefail

SPIKE_USER="${SPIKE_USER:-spike}"
SPIKE_PASSWORD="${SPIKE_PASSWORD:-spike-password}"

# Host keys. Regenerated on every container start, which is why the harness is
# run with a pinned fingerprint read from this output rather than a fingerprint
# baked into the repository.
ssh-keygen -A >/dev/null

if ! id "$SPIKE_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$SPIKE_USER"
    echo "${SPIKE_USER}:${SPIKE_PASSWORD}" | chpasswd
fi

# A client key in the shared volume, so the test runner can authenticate with a
# public key as well as a password.
if [[ ! -f /keys/id_ed25519 ]]; then
    ssh-keygen -t ed25519 -N "" -C "sssh-spike-plain" -f /keys/id_ed25519 -q
fi
if [[ ! -f /keys/id_ed25519_passphrase ]]; then
    ssh-keygen -t ed25519 -N "spike-passphrase" -C "sssh-spike-encrypted" -f /keys/id_ed25519_passphrase -q
fi

install -d -m 700 -o "$SPIKE_USER" -g "$SPIKE_USER" "/home/${SPIKE_USER}/.ssh"
cat /keys/id_ed25519.pub /keys/id_ed25519_passphrase.pub > "/home/${SPIKE_USER}/.ssh/authorized_keys"
chown "$SPIKE_USER:$SPIKE_USER" "/home/${SPIKE_USER}/.ssh/authorized_keys"
chmod 600 "/home/${SPIKE_USER}/.ssh/authorized_keys"
chmod -R a+rX /keys

# Written where the test runner can read it, so the harness can pin the host
# key instead of trusting anything. Fails closed by construction: if this file
# is missing, the run has nothing to pin and refuses to connect.
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}' > /keys/host_key_fingerprint
echo "host key: $(cat /keys/host_key_fingerprint)"
echo "ready: ${SPIKE_USER} / ${SPIKE_PASSWORD} / /keys/id_ed25519"

exec /usr/sbin/sshd -D -e
