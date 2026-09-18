# Een macOS-release van sssH publiceren

Deze handleiding publiceert een Developer ID-ondertekende en door Apple
genotariseerde macOS-app via GitHub Releases. Sparkle controleert vervolgens de
EdDSA-handtekening van het update-archief voordat het de update installeert.

De app gebruikt deze vaste feed-URL:

```text
https://github.com/rorymeijer/sssH/releases/latest/download/appcast.xml
```

De nieuwste **gepubliceerde** GitHub Release moet daarom altijd zowel
`appcast.xml` als het bijbehorende zipbestand bevatten.

## Wat wordt er ondertekend?

Er zijn twee aparte beveiligingslagen:

1. **Developer ID + Apple-notarisatie** bewijzen aan Gatekeeper wie de app heeft
   gebouwd en dat Apple de app heeft gecontroleerd.
2. **Sparkle EdDSA** ondertekent het zipbestand. Sparkle vergelijkt die
   handtekening met `SUPublicEDKey` in de app.

Beide zijn nodig. Een Git-tag of GitHub Release ondertekent de app niet.

## Eenmalige voorbereiding

Je hebt nodig:

- een betaald Apple Developer-account;
- een certificaat **Developer ID Application** in je login-sleutelhanger;
- toegang tot team `GPYS6SK835` in Xcode;
- XcodeGen;
- GitHub CLI (`gh`) met schrijftoegang tot `rorymeijer/sssH`;
- Sparkle's tools `generate_keys` en `generate_appcast`;
- een veilige back-up van de Sparkle-private sleutel.

Installeer de lokale hulpmiddelen indien nodig:

```sh
brew install xcodegen gh
gh auth login
```

Sparkle staat al als Swift Package in de macOS-app. De bijpassende tools zijn
te vinden in het SwiftPM-artifact van Sparkle, of in de download van dezelfde
Sparkle-versie op:

<https://github.com/sparkle-project/Sparkle/releases>

### Sparkle-sleutel controleren en back-uppen

`SUPublicEDKey` is al in de app geconfigureerd. Gebruik niet zomaar een nieuw
sleutelpaar: bestaande installaties vertrouwen de huidige publieke sleutel.

Maak een versleutelde export van de bestaande private sleutel en bewaar die in
een wachtwoordmanager of andere offline kluis:

```sh
/path/to/Sparkle/bin/generate_keys -x sparkle_private_key
```

Commit `sparkle_private_key` nooit en upload hem nooit naar GitHub. Verwijder
de lokale export nadat de back-up is gecontroleerd.

### Vereiste Sparkle-entitlements oplossen

De app is gesandboxed en gebruikt `SUEnableInstallerLauncherService = YES`.
Volgens Sparkle moeten daarom ook deze waarden in
`App/Sources/ssshApp/Resources/sssh.macOS.entitlements` staan:

```xml
<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
<array>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
</array>
```

Publiceer geen Sparkle-release voordat dit is toegevoegd en een update van een
oudere testbuild naar een nieuwere testbuild succesvol is uitgevoerd.

## Iedere release

In de voorbeelden is de release `0.2.0`, build `2`. Vervang deze waarden
door de echte versie.

### Geautomatiseerde release

`scripts/release.sh` automatiseert de versie-update, tests, het Xcode-archive,
Developer ID-export, Apple-notarisatie, Sparkle-ZIP en appcast, en maakt ten
slotte een GitHub-draft. Het publiceert de draft nooit automatisch.

Sla eenmalig de Apple-notarisatiegegevens op in de login-sleutelhanger:

```sh
xcrun notarytool store-credentials "sssH-notary" \
    --apple-id "jouw-apple-id@example.com" \
    --team-id "GPYS6SK835" \
    --password "app-specifiek-wachtwoord"
```

Zorg dat de repository schoon en volledig gepusht is. Maak daarna bijvoorbeeld
interactief een release. Het script toont de huidige versie en stelt het volgende
buildnummer voor:

```sh
./scripts/release.sh
```

Of geef versie 0.2.1 en buildnummer 3 direct mee:

```sh
./scripts/release.sh 0.2.1 3
```

Standaard verwacht het script Sparkle's tools in
`~/Documents/Sparkle/bin`. Een afwijkende locatie of Keychain-profiel kan per
aanroep worden ingesteld:

```sh
SSSH_SPARKLE_BIN_DIR="/pad/naar/Sparkle/bin" \
SSSH_NOTARY_PROFILE="sssH-notary" \
./scripts/release.sh 0.2.1 3
```

Releasebestanden komen buiten de repository in
`~/Documents/sssH-Releases/<versie>`. Controleer na afloop de GitHub-draft en
publiceer hem pas als de ZIP en `appcast.xml` beide als assets aanwezig zijn.

### 1. Begin met een schone releasecommit

Controleer dat alle bedoelde wijzigingen zijn gecommit en dat de tests en de
macOS-build slagen. Publiceer nooit een binary uit een andere commit dan de
commit die je tagt.

```sh
git status --short
git pull --ff-only
```

### 2. Verhoog beide versienummers

Werk in `App/project.yml` bij:

```yaml
MARKETING_VERSION: "0.2.0"
CURRENT_PROJECT_VERSION: "2"
```

- `MARKETING_VERSION` is de zichtbare versie.
- `CURRENT_PROJECT_VERSION` is het buildnummer en moet bij iedere release
  hoger zijn. Sparkle gebruikt dit nummer om versies te vergelijken.

Dit project gebruikt ook een geschreven `App/Supporting/Info.plist`. Zorg dat
deze waarden overeenkomen:

```xml
<key>CFBundleShortVersionString</key>
<string>0.2.0</string>
<key>CFBundleVersion</key>
<string>2</string>
```

Genereer daarna het Xcode-project opnieuw:

```sh
cd App
xcodegen generate
open sssh.xcodeproj
```

Commit en push de versieverhoging:

```sh
git add project.yml Supporting/Info.plist
git commit -m "Prepare sssH 0.2.0"
git push
```

### 3. Maak een Release-archive in Xcode

1. Open het gegenereerde `App/sssh.xcodeproj`.
2. Selecteer scheme **sssh_macOS**.
3. Selecteer als bestemming **Any Mac**.
4. Kies **Product → Archive**.
5. Open na de build de Organizer.
6. Kies **Distribute App** en vervolgens distributie buiten de Mac App Store
   met **Developer ID**.
7. Kies uploaden naar Apple's notarisatieservice.
8. Wacht totdat Xcode meldt dat de notarisatie is geslaagd.
9. Exporteer de genotariseerde app naar een nieuwe, lege releasemap.

Gebruik geen gewone Debug-build uit DerivedData. De geëxporteerde app hoort
`sssh.app` te heten.

### 4. Controleer ondertekening en notarisatie

Ga in Terminal naar de releasemap en voer uit:

```sh
codesign --verify --deep --strict --verbose=2 sssh.app
spctl --assess --type execute --verbose=2 sssh.app
xcrun stapler validate sssh.app
```

Verwacht:

- `codesign` geeft geen fout;
- `spctl` meldt `accepted` en noemt Developer ID/notarisatie;
- `stapler` meldt dat validatie is geslaagd.

Controleer ook de identiteit en entitlements:

```sh
codesign -dv --verbose=4 sssh.app 2>&1
codesign -d --entitlements :- sssh.app
```

Controleer in de uitvoer minimaal:

- bundle identifier `nl.rorymeijer.sssh`;
- een **Developer ID Application** authority;
- Hardened Runtime;
- app sandbox;
- netwerk-clienttoegang;
- de Sparkle Mach/XPC-excepties `-spks` en `-spki`.

Stop bij iedere fout. Herstel de signing/notarisatie en archiveer opnieuw; ga
niet verder met een lokaal opnieuw ondertekende app.

### 5. Maak het zipbestand

Gebruik `ditto`, zodat resource forks, permissies en symlinks in Sparkle
correct behouden blijven:

```sh
ditto -c -k --sequesterRsrc --keepParent sssh.app sssH-0.2.0.zip
```

Pak het zipbestand als extra controle in een lege tijdelijke map uit en
controleer de app opnieuw:

```sh
release_check_dir="$(mktemp -d)"
ditto -x -k sssH-0.2.0.zip "$release_check_dir"
codesign --verify --deep --strict --verbose=2 "$release_check_dir/sssh.app"
spctl --assess --type execute --verbose=2 "$release_check_dir/sssh.app"
```

### 6. Genereer de ondertekende appcast

Maak voor een gewone release een schone stagingmap met alleen het nieuwe
zipbestand. Zo krijgen oudere items niet per ongeluk URL's naar de verkeerde
GitHub Release:

```sh
mkdir -p sparkle-staging
cp sssH-0.2.0.zip sparkle-staging/
```

Genereer de appcast met de Sparkle-versie die bij de app hoort:

```sh
/path/to/Sparkle/bin/generate_appcast sparkle-staging/ \
    --download-url-prefix "https://github.com/rorymeijer/sssH/releases/download/v0.2.0/" \
    -o appcast.xml
```

`generate_appcast` vraagt zo nodig toegang tot de private sleutel in de
login-sleutelhanger. Controleer daarna `appcast.xml`:

- de enclosure-URL eindigt op
  `/releases/download/v0.2.0/sssH-0.2.0.zip`;
- de versie en het buildnummer zijn correct;
- `sparkle:edSignature` bestaat en is niet leeg;
- de lengte van het bestand klopt.

Gebruik voor delta-updates een blijvend archief met oude binaries en volg
Sparkle's delta-documentatie; voeg oude binaries niet zonder bijpassende
download-URL's toe aan deze eenvoudige stagingmap.

### 7. Maak eerst een conceptrelease op GitHub

Een draft voorkomt dat de vaste `/releases/latest/`-URL al naar een
onvolledige release wijst.

```sh
gh release create v0.2.0 \
    sssH-0.2.0.zip \
    appcast.xml \
    --repo rorymeijer/sssH \
    --target main \
    --title "sssH 0.2.0" \
    --generate-notes \
    --draft
```

Open het concept en controleer titel, tag, targetcommit, release notes en beide
assets:

```sh
gh release view v0.2.0 --repo rorymeijer/sssH --web
```

Controleer dat de getagde commit exact de commit is waarmee het archive is
gemaakt.

### 8. Publiceer en verifieer

Publiceer de draft via de GitHub-webinterface. Zorg dat het een normale release
is, geen prerelease, en dat GitHub hem als **Latest** markeert.

Controleer daarna:

```sh
curl --fail --location --head \
    "https://github.com/rorymeijer/sssH/releases/latest/download/appcast.xml"

curl --fail --location --head \
    "https://github.com/rorymeijer/sssH/releases/download/v0.2.0/sssH-0.2.0.zip"
```

Beide opdrachten moeten uiteindelijk HTTP 200 opleveren.

### 9. Test de echte Sparkle-update

Dit is de beslissende eindtest:

1. Installeer een eerder, correct ondertekend release-exemplaar in
   `/Applications`.
2. Start dat exemplaar.
3. Kies **sssH → Zoek naar updates…**.
4. Controleer dat versie 0.2.0 wordt gevonden.
5. Installeer de update.
6. Controleer dat de app opnieuw start en de nieuwe versie toont.
7. Voer desgewenst opnieuw `codesign`, `spctl` en `stapler validate` uit op
   `/Applications/sssh.app`.

Test niet alleen vanuit Xcode of vanaf een read-only disk image. Sparkle kan een
update alleen betrouwbaar vervangen wanneer de app op een schrijfbare locatie,
bij voorkeur `/Applications`, staat.

## Als er iets fout gaat

- **De appcast geeft 404:** de release is niet gepubliceerd, niet Latest, of
  `appcast.xml` ontbreekt als asset.
- **Sparkle meldt een ongeldige handtekening:** het zipbestand is na het
  genereren van de appcast gewijzigd, of de verkeerde private sleutel is
  gebruikt. Genereer zip en appcast opnieuw; wijzig nooit alleen de XML.
- **Gatekeeper weigert de app:** controleer Developer ID, Hardened Runtime,
  notarisatie en stapling.
- **Sparkle downloadt maar installeert niet:** controleer de sandbox-entitlements
  en de `-spks`/`-spki` Mach/XPC-excepties.
- **Er verschijnt geen update:** controleer dat het nieuwe
  `CFBundleVersion` strikt hoger is dan het geïnstalleerde buildnummer.
- **GitHub accepteert een asset niet:** een asset met dezelfde naam bestaat al.
  Verwijder/vervang de draft vóór publicatie; wijzig geen gepubliceerde release
  waar gebruikers de appcast al van kunnen hebben opgehaald.

## Officiële documentatie

- [Sparkle: basisinstallatie en publiceren](https://sparkle-project.org/documentation/)
- [Sparkle in een gesandboxte app](https://sparkle-project.org/documentation/sandboxing/)
- [GitHub Releases beheren](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
