# Releasing sssH (macOS, via Sparkle + GitHub Releases)

Updates are served entirely from GitHub. `SUFeedURL` in the app points at

    https://github.com/rorymeijer/sssH/releases/latest/download/appcast.xml

which is GitHub's never-changing redirect to the `appcast.xml` asset of the
newest release. There is no other server.

## One-time setup (already done)

- EdDSA keypair generated with Sparkle's `generate_keys`; the private key is
  in the login Keychain of the machine that cuts releases (item name
  "Private key for signing Sparkle updates"), the public key is
  `SUPublicEDKey` in the Info.plist. **Back the private key up**
  (`generate_keys -x sparkle_private_key` → password manager); losing it means
  shipping a new app that existing installs will refuse as an update.
- Sandbox: `SUEnableInstallerLauncherService = YES` is set; the app already
  has the outgoing-network entitlement Sparkle's downloader needs.

## Cutting a release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `App/project.yml`
   (and regenerate with `xcodegen generate`, or bump
   `CFBundleShortVersionString`/`CFBundleVersion` in `App/Supporting/Info.plist`
   to match). Sparkle compares `CFBundleVersion`, so it must grow.
2. Archive in Xcode (scheme `sssh_macOS`, Product → Archive), then
   Organizer → Distribute App → Direct Distribution. That signs with
   Developer ID and notarizes — Sparkle will not install an unnotarized build,
   and Gatekeeper would not launch it.
3. Zip the exported app (ditto, not Finder, so signatures survive):

       ditto -c -k --sequesterRsrc --keepParent sssh.app sssH-1.2.0.zip

4. Keep a local `updates/` directory containing the zips of **all** releases
   (so the appcast carries the full history and delta updates can be
   generated), drop the new zip in, and generate the appcast. The
   `generate_appcast` tool ships in `Sparkle-<version>.tar.xz` on
   https://github.com/sparkle-project/Sparkle/releases — the same version the
   app links.

       ./bin/generate_appcast updates/ \
           --download-url-prefix "https://github.com/rorymeijer/sssH/releases/download/v1.2.0/" \
           -o appcast.xml

   The download-url-prefix makes every enclosure URL point at this release's
   assets; signing happens automatically with the key from the Keychain.
5. Publish, with the zip **and** the appcast as assets:

       gh release create v1.2.0 sssH-1.2.0.zip appcast.xml \
           --title "sssH 1.2.0" --notes "…"

6. Done. Running apps find the update at their next scheduled check, or via
   sssH → "Zoek naar updates…".

## Notes

- iOS is untouched by all of this: Sparkle links only into the macOS target,
  and iOS updates go through the App Store.
- The appcast on the *latest* release describes every version (step 4 feeds it
  the whole `updates/` directory), so users several versions behind still get
  a single correct update.
- First-run behaviour: Sparkle asks the user's permission for automatic checks
  on the second launch; "Zoek naar updates…" always works regardless.
