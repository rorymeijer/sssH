# Security

What sssh protects, what it does not, and where each claim is enforced in the
code. Written so the claims are checkable rather than reassuring.

## Secrets

**Private keys, passphrases and passwords are only ever in the Keychain.** The
synced model holds an opaque `SecretReference` — a UUID — and nothing else.
There is no code path that writes key material into SwiftData, and
`SecretString` is built to make one hard to write by accident: it has no
`Codable` conformance, its `description` is `<redacted>`, and getting at the
value requires calling `reveal()`, which is conspicuous in review.

| | |
|---|---|
| where | `Sources/ssshCore/Transport/SSHCredential.swift`, `App/Sources/ssshApp/Secrets/KeychainSecretsStore.swift` |

**Stored secrets are wrapped before they reach the Keychain**, with a P-256 key
generated inside the Secure Enclave. That key can perform key agreement and can
never be read out, so a Keychain database lifted off a backup is ciphertext
without the hardware that made it.

On hardware with no Secure Enclave — an Intel Mac without a T2 — the fallback is
a software key stored `ThisDeviceOnly`, which is weaker: that key *can* be read
by anything that can read the Keychain. The settings screen reports which of the
two is actually in use. It does not say "Secure Enclave" on a machine that has
none.

| | |
|---|---|
| where | `App/Sources/ssshApp/Secrets/AppSecurityKey.swift` |

**Accessibility is `WhenUnlocked`, not `AfterFirstUnlock`.** A background
reconnect cannot read a password while the device is locked. That is
deliberate: an SSH session should not be establishable with the phone in
someone else's pocket.

## Sync

**Configuration syncs; secrets do not.** Hosts, groups, snippets, tunnels,
terminal profiles and host-key fingerprints go through CloudKit's private
database. Fingerprints syncing is what makes trust follow the user between
devices.

Nothing secret goes there. CloudKit's private database is not end-to-end
encrypted, and a private key in it would be a private key in a database Apple
can read.

**Secret sync is opt-in, off by default, and confirmed before it happens.**
When it is on, secrets move to iCloud Keychain, which *is* end-to-end
encrypted — never to the app's CloudKit database.

The trade is stated in the settings screen rather than buried, because it is
real: a synced secret cannot be wrapped with the device key, since that key is
device-bound and the other machine would have nothing to open it with. So:

| | device-only | synced |
|---|---|---|
| protected by | Secure Enclave key **and** Keychain | iCloud Keychain's end-to-end encryption |
| leaves the device | no | to the user's own Apple devices |
| in the app's CloudKit database | never | never |

## Host keys

**Fail closed on mismatch.** A changed host key stops the connection. The
prompt distinguishes a first-time key from a changed one, and accepting a
changed one requires a second, separate acknowledgement — Return is not bound to
the accept button.

`ConnectionSupervisor` never retries a rejected host key. Retrying would
re-prompt the user about a possible man-in-the-middle until they clicked
through it, which is the opposite of failing closed.

| | |
|---|---|
| where | `Sources/ssshCore/Transport/SSHHostKey.swift`, `App/Sources/ssshApp/UI/HostKeyPromptView.swift`, `Sources/ssshCore/Session/ConnectionSupervisor.swift` |

## Keys

**Generated on device.** A key generated anywhere else has been somewhere else.
The private half goes straight to the Keychain and is never displayed; the
public line is shown, copyable, and is the only half meant to leave.

Ed25519 by default. RSA is supported because people still have servers that will
not take anything else, and a key you cannot use is not security.

## Things sssh will not do

**It does not run `ProxyCommand`.** That is an arbitrary shell command taken
from a configuration file, and a configuration file can arrive by import, by
sync, or from a colleague. `ProxyJump` covers the common case and is supported.
The import lists every `ProxyCommand` it skipped, by line number.

**It does not evaluate `Match exec`.** Same reason. `ssh -G` applies such a
block; sssh does not, and says so.

**It does not read `~/.ssh` uninvited.** Config import goes through the system
file picker. Keys named by `IdentityFile` are recorded as paths, not read.

**It does not grant OSC 52 clipboard *reads*.** A remote host being able to read
what the user last copied is an exfiltration channel that could hand over a
password out of a manager. Writes are allowed; reads return nothing.

**It has no AI features.** No suggestions, no explanations, no cloud call to
explain a command. In-session search runs entirely on device, over data the app
already has.

**It sends no telemetry.** There is no analytics SDK, no crash reporter, and no
network code outside the SSH transport itself.

## The app lock

Protects the *session*, not the stored secrets: an unlocked laptop on a desk
with a terminal already connected to production. It covers the screen opaquely
rather than blurring it — a blur over a terminal still shows the shape of the
last command — and it uses `deviceOwnerAuthentication` rather than the
biometrics-only policy, so a Face ID failure in the dark is not a lockout.

It does not close connections. Locking the app and losing a long-running job
would make people turn the lock off.

## Entitlements

The macOS build is sandboxed and asks for three things: outgoing network
connections, user-selected files (for config import), CloudKit, and a Keychain
group. Deliberately absent, and checkable in
`App/Sources/ssshApp/Resources/sssh.macOS.entitlements`: incoming network
server, camera, microphone, address book, automation, and — on iOS — any
background mode at all.

## What is not claimed

- sssh does not defend against a compromised device. Nothing in an app can.
- The Secure Enclave wrapping does not protect against someone using the app on
  an unlocked device. That is what the app lock is for, and it is a different
  problem.
- Synced secrets are protected by iCloud Keychain, which is Apple's
  cryptography rather than this app's. That is a deliberate, stated trade for
  the convenience of having them on more than one machine, and it is off by
  default.
