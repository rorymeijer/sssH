# The sssh app

The SwiftUI app for macOS, iPadOS and iOS. The SSH stack it sits on lives in
SwiftPM at the repository root, so it can be built and tested on Linux in CI
independently of anything with a UI.

## Generating the project

The `.xcodeproj` is generated rather than committed. A `.pbxproj` is unreadable
in review and merges badly; `project.yml` is the same information in a form a
person can check.

```sh
brew install xcodegen
cd App && xcodegen generate
open sssh.xcodeproj
```

Re-run `xcodegen generate` after adding files or changing `project.yml`.

## Layout

| Path | What |
|---|---|
| `Model/` | SwiftData entities. Written to CloudKit's rules — every attribute defaulted, no unique constraints — so the store syncs without a migration. |
| `Files/` | The SFTP browser's models: remote and local listings, the transfer queue, drag and drop. |
| `Secrets/` | The Keychain store, the Secure Enclave app key and the app lock. The only place a password or key is written. |
| `Session/` | Connection lifecycle, tabs, host-key and credential prompts, known-hosts storage. |
| `Terminal/` | The SwiftTerm host view and colour schemes. |
| `UI/` | Views. |
| `Resources/Localizable.xcstrings` | Dutch source strings with English translations. |

## The three rules

These are the ones the brief calls non-negotiable, and where they are enforced:

- **The transport is replaceable.** `AppEnvironment` is the only type that
  names `NIOSSHTransportFactory`. Everything else takes `any SSHTransport`.
- **Secrets stay out of the synced store.** `Host` holds a `SecretReference`,
  which is a UUID. `KeychainSecretsStore` is the only thing that serialises a
  secret, and `SecretString` has no `Codable` conformance so nothing else can.
- **The UI is localisable.** Every user-facing string goes through
  `Text(_:comment:)` or `String(localized:comment:)`. The transport layer
  produces structured errors, never prose; `ConnectionFailureText` is the one
  place that turns a failure into a sentence.

## What the app does

Connections in tabs and splits, with broadcast input and session restore.
Password, key and `keyboard-interactive` authentication, and a host-key prompt
that is loud on a mismatch. Command blocks — OSC 133 where the shell cooperates,
an echo-based fallback where it does not — with per-block actions and
in-session search. An SFTP browser with a transfer queue and drag and drop.
Local, remote and dynamic (SOCKS5) port forwarding. Hosts with groups and tags,
snippets with parameters, `~/.ssh/config` import, and a theme editor. CloudKit
sync for configuration, secrets in the Keychain behind a Secure Enclave key,
an app lock, and on-device key generation.

What it deliberately does not do: anything with AI, any telemetry, and any
network call that is not the user's own SSH connection or their own iCloud.
See [../docs/SECURITY.md](../docs/SECURITY.md).
