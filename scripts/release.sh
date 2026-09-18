#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly APP_DIR="$REPO_ROOT/App"
readonly PROJECT_FILE="$APP_DIR/project.yml"
readonly INFO_PLIST="$APP_DIR/Supporting/Info.plist"
readonly PROJECT_PATH="$APP_DIR/sssh.xcodeproj"
readonly SCHEME="sssh_macOS"
readonly TEAM_ID="GPYS6SK835"
readonly GITHUB_REPOSITORY="rorymeijer/sssH"
readonly EXPECTED_SPARKLE_PUBLIC_KEY="gbxFgROhkDGw8Tmhvotvm4rCnaFjzUgu/2qDEAyYHMQ="
readonly NOTARY_PROFILE="${SSSH_NOTARY_PROFILE:-sssH-notary}"
readonly SPARKLE_BIN_DIR="${SSSH_SPARKLE_BIN_DIR:-$HOME/Documents/Sparkle/bin}"
readonly RELEASES_ROOT="${SSSH_RELEASES_DIR:-$HOME/Documents/sssH-Releases}"
readonly XCODE_DEVELOPER_DIR="${SSSH_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

version_changes_pending=false
check_dir=""

cleanup() {
    exit_code=$?

    if [[ "$exit_code" -ne 0 && "$version_changes_pending" == true ]]; then
        echo "Release mislukt; tijdelijke versiewijzigingen worden teruggezet." >&2
        git -C "$REPO_ROOT" restore --staged -- App/project.yml
        git -C "$REPO_ROOT" restore -- App/project.yml
    fi

    if [[ -n "$check_dir" && -d "$check_dir" ]]; then
        rm -rf "$check_dir"
    fi

    exit "$exit_code"
}

trap cleanup EXIT

usage() {
    cat <<EOF
Gebruik:
  scripts/release.sh
  scripts/release.sh <versie> <buildnummer>

Voorbeeld:
  scripts/release.sh
  scripts/release.sh 0.2.1 3

Optionele omgevingsvariabelen:
  SSSH_NOTARY_PROFILE     notarytool-Keychain-profiel (standaard: sssH-notary)
  SSSH_SPARKLE_BIN_DIR    map met generate_keys en generate_appcast
  SSSH_RELEASES_DIR       uitvoermap (standaard: ~/Documents/sssH-Releases)
  SSSH_XCODE_DEVELOPER_DIR volledige Xcode Developer-map

Het script maakt uitsluitend een GitHub-draft. Publiceer die na controle handmatig.
EOF
}

die() {
    echo "Fout: $*" >&2
    exit 1
}

step() {
    echo
    echo "==> $*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is niet geïnstalleerd of staat niet in PATH."
}

if [[ "$#" -eq 0 ]]; then
    current_version_prompt="$(perl -ne 'print "$1\n" if /MARKETING_VERSION:\s*"([^"]+)"/' "$PROJECT_FILE")"
    current_build_prompt="$(perl -ne 'print "$1\n" if /CURRENT_PROJECT_VERSION:\s*"([^"]+)"/' "$PROJECT_FILE")"

    echo "Huidige versie: $current_version_prompt (build $current_build_prompt)"
    read -r -p "Nieuwe versie [$current_version_prompt]: " requested_version
    requested_version="${requested_version:-$current_version_prompt}"

    if [[ "$requested_version" == "$current_version_prompt" ]]; then
        suggested_build="$current_build_prompt"
    else
        suggested_build="$((current_build_prompt + 1))"
    fi

    read -r -p "Nieuw buildnummer [$suggested_build]: " requested_build
    requested_build="${requested_build:-$suggested_build}"
    set -- "$requested_version" "$requested_build"
elif [[ "$#" -ne 2 ]]; then
    usage
    exit 2
fi

readonly VERSION="$1"
readonly BUILD_NUMBER="$2"
readonly TAG="v$VERSION"
readonly ARCHIVE_NAME="sssH-$VERSION"
readonly ZIP_NAME="$ARCHIVE_NAME.zip"
readonly RELEASE_DIR="$RELEASES_ROOT/$VERSION"
readonly ARCHIVE_PATH="$RELEASE_DIR/$ARCHIVE_NAME.xcarchive"
readonly EXPORT_DIR="$RELEASE_DIR/export"
readonly APP_PATH="$EXPORT_DIR/sssh.app"
readonly ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"
readonly STAGING_DIR="$RELEASE_DIR/sparkle-staging"
readonly APPCAST_PATH="$RELEASE_DIR/appcast.xml"
readonly NOTARY_ZIP="$RELEASE_DIR/notarization-upload.zip"
readonly EXPORT_OPTIONS="$RELEASE_DIR/ExportOptions.plist"
readonly GENERATE_KEYS="$SPARKLE_BIN_DIR/generate_keys"
readonly GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Versie moet de vorm 0.2.1 hebben."
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] ||
    die "Buildnummer moet een positief geheel getal zijn."

for command_name in git gh xcodegen xcodebuild xcrun codesign spctl ditto perl grep curl; do
    require_command "$command_name"
done

[[ -d "$XCODE_DEVELOPER_DIR" ]] ||
    die "Volledige Xcode-installatie ontbreekt in $XCODE_DEVELOPER_DIR."
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"

xcode_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
[[ "$xcode_sdk_path" == "$XCODE_DEVELOPER_DIR"/* ]] ||
    die "xcrun gebruikt niet de volledige Xcode-installatie: $xcode_sdk_path"

[[ -x "$GENERATE_KEYS" ]] ||
    die "Niet uitvoerbaar: $GENERATE_KEYS. Stel SSSH_SPARKLE_BIN_DIR correct in."
[[ -x "$GENERATE_APPCAST" ]] ||
    die "Niet uitvoerbaar: $GENERATE_APPCAST. Stel SSSH_SPARKLE_BIN_DIR correct in."
[[ -f "$PROJECT_FILE" ]] || die "Ontbrekend projectbestand: $PROJECT_FILE"
[[ -f "$INFO_PLIST" ]] || die "Ontbrekende Info.plist: $INFO_PLIST"

cd "$REPO_ROOT"

step "Voorwaarden controleren"
current_branch="$(git branch --show-current)"
[[ -n "$current_branch" ]] || die "Een release kan niet vanaf een detached HEAD worden gemaakt."

dirty_files="$(git status --porcelain --untracked-files=all -- . \
    ':(exclude)Notized/**' \
    ':(exclude)Releases/**')"
[[ -z "$dirty_files" ]] || {
    echo "$dirty_files" >&2
    die "De repository bevat niet-gecommitte wijzigingen. Commit of herstel ze eerst."
}

git fetch --quiet origin
git merge-base --is-ancestor "origin/$current_branch" HEAD ||
    die "De lokale branch loopt achter op origin/$current_branch. Pull eerst."
git merge-base --is-ancestor HEAD "origin/$current_branch" ||
    die "De lokale branch bevat ongepushte commits. Push ze eerst."

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null &&
    die "De lokale tag $TAG bestaat al."
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 &&
    die "De tag $TAG bestaat al op GitHub."
if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    die "GitHub Release $TAG bestaat al."
fi

visibility="$(gh repo view "$GITHUB_REPOSITORY" --json visibility --jq .visibility)"
[[ "$visibility" == "PUBLIC" ]] ||
    die "Repository $GITHUB_REPOSITORY is $visibility. De Sparkle-feed moet publiek bereikbaar zijn."

current_version="$(perl -ne 'print "$1\n" if /MARKETING_VERSION:\s*"([^"]+)"/' "$PROJECT_FILE")"
current_build="$(perl -ne 'print "$1\n" if /CURRENT_PROJECT_VERSION:\s*"([^"]+)"/' "$PROJECT_FILE")"
if [[ "$VERSION" == "$current_version" && "$BUILD_NUMBER" == "$current_build" ]]; then
    echo "Versie $VERSION ($BUILD_NUMBER) staat al ingesteld; versie-update wordt overgeslagen."
else
    (( BUILD_NUMBER > current_build )) ||
        die "Build $BUILD_NUMBER moet hoger zijn dan huidige build $current_build."

    step "Versie instellen op $VERSION ($BUILD_NUMBER)"
    RELEASE_VERSION="$VERSION" perl -0pi -e \
        's/(MARKETING_VERSION:\s*")[^"]+(")/$1$ENV{RELEASE_VERSION}$2/' \
        "$PROJECT_FILE"
    RELEASE_BUILD="$BUILD_NUMBER" perl -0pi -e \
        's/(CURRENT_PROJECT_VERSION:\s*")[^"]+(")/$1$ENV{RELEASE_BUILD}$2/' \
        "$PROJECT_FILE"
    version_changes_pending=true
fi

project_version="$(perl -ne 'print "$1\n" if /MARKETING_VERSION:\s*"([^"]+)"/' "$PROJECT_FILE")"
project_build="$(perl -ne 'print "$1\n" if /CURRENT_PROJECT_VERSION:\s*"([^"]+)"/' "$PROJECT_FILE")"
[[ "$project_version" == "$VERSION" ]] ||
    die "project.yml bevat niet versie $VERSION."
[[ "$project_build" == "$BUILD_NUMBER" ]] ||
    die "project.yml bevat niet build $BUILD_NUMBER."

step "Xcode-project genereren en tests uitvoeren"
(
    cd "$APP_DIR"
    xcodegen generate
)
swift test --package-path "$REPO_ROOT"

if ! git diff --quiet -- "$PROJECT_FILE"; then
    step "Versiecommit maken en pushen"
    git add "$PROJECT_FILE"
    git commit -m "Prepare sssH $VERSION"
    version_changes_pending=false
    git push origin "$current_branch"
fi
readonly RELEASE_COMMIT="$(git rev-parse HEAD)"

[[ ! -e "$RELEASE_DIR" ]] ||
    die "Uitvoermap bestaat al: $RELEASE_DIR. Verplaats hem of kies een nieuwe versie."
mkdir -p "$RELEASE_DIR"

cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
EOF

step "Release-archive bouwen"
xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates

step "Developer ID-app exporteren"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates

[[ -d "$APP_PATH" ]] || die "De export bevat geen $APP_PATH."

app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
[[ "$app_version" == "$VERSION" ]] ||
    die "Geëxporteerde app heeft versie $app_version in plaats van $VERSION."
[[ "$app_build" == "$BUILD_NUMBER" ]] ||
    die "Geëxporteerde app heeft build $app_build in plaats van $BUILD_NUMBER."

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

step "App naar Apple sturen voor notarisatie"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
rm -f "$NOTARY_ZIP"

step "Definitieve Sparkle-ZIP maken"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

check_dir="$(mktemp -d)"
ditto -x -k "$ZIP_PATH" "$check_dir"
codesign --verify --deep --strict --verbose=2 "$check_dir/sssh.app"
spctl --assess --type execute --verbose=2 "$check_dir/sssh.app"

step "Sparkle-sleutel controleren"
key_output="$("$GENERATE_KEYS")"
echo "$key_output"
[[ "$key_output" == *"$EXPECTED_SPARKLE_PUBLIC_KEY"* ]] ||
    die "De Sparkle-private sleutel hoort niet bij SUPublicEDKey."

step "Ondertekende appcast genereren"
mkdir "$STAGING_DIR"
cp "$ZIP_PATH" "$STAGING_DIR/"
"$GENERATE_APPCAST" "$STAGING_DIR" \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/" \
    -o "$APPCAST_PATH"

entry_count="$(grep -c '<sparkle:version>' "$APPCAST_PATH")"
[[ "$entry_count" == "1" ]] ||
    die "Appcast bevat $entry_count updates; verwacht precies 1."
grep -F "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST_PATH" >/dev/null ||
    die "Appcast bevat niet build $BUILD_NUMBER."
grep -F "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_PATH" >/dev/null ||
    die "Appcast bevat niet versie $VERSION."
grep -F "releases/download/$TAG/$ZIP_NAME" "$APPCAST_PATH" >/dev/null ||
    die "Appcast bevat niet de verwachte download-URL."
grep -F 'sparkle:edSignature="' "$APPCAST_PATH" >/dev/null ||
    die "Appcast bevat geen Sparkle-handtekening."

step "GitHub-draft maken"
gh release create "$TAG" \
    "$ZIP_PATH" \
    "$APPCAST_PATH" \
    --repo "$GITHUB_REPOSITORY" \
    --target "$RELEASE_COMMIT" \
    --title "sssH $VERSION" \
    --generate-notes \
    --draft

echo
echo "Draft $TAG is aangemaakt."
echo "Controleer en publiceer hem via:"
echo "  gh release view $TAG --repo $GITHUB_REPOSITORY --web"
echo
echo "Na publicatie controleer je:"
echo "  curl --fail --location --head https://github.com/$GITHUB_REPOSITORY/releases/latest/download/appcast.xml"
echo "  curl --fail --location --head https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/$ZIP_NAME"
