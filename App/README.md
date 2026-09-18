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
| `Model/` | SwiftData entities. Written to CloudKit's rules already — every attribute defaulted, no unique constraints — so Phase 7 needs no migration. |
| `Secrets/` | The Keychain store. The only place a password or key is written. |
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

## What Phase 1 does and does not do

Does: one connection per tab, password and key authentication, the host-key
prompt (loud on a mismatch), a searchable host list, the Keychain, Dutch-first
strings.

Does not: splits, broadcast input, session restore, the command palette,
command blocks, SFTP, port forwarding, groups and tags as editable structure,
the theme editor, or CloudKit. Those are Phases 2 to 7, in that order.
