#!/bin/zsh
# Baut eine auslieferbare, mit Developer ID signierte und notarisierte App
# als Disk-Image (.dmg) – für GitHub Releases, nicht für den App Store.
#
#   Scripts/release.sh             Tests, bauen, signieren, notarisieren, DMG
#   Scripts/release.sh --dry-run   alles außer der Notarisierung (nichts geht an Apple)
#   Scripts/release.sh --skip-tests
#
# Ergebnis: ~/Library/Caches/de.christiangolz.portapackmanager/Release/
#           PortaPackManager-<Version>.dmg
# Hochgeladen wird nichts – das Veröffentlichen auf GitHub bleibt Handarbeit.
#
# Voraussetzungen:
# - „Developer ID Application“-Zertifikat im Schlüsselbund
# - Config/Signing.local.xcconfig mit DEVELOPMENT_TEAM
# - notarytool-Profil im Schlüsselbund, Name in NOTARY_PROFILE
#   (Standard: portapack-notarisierung). Anlegen siehe ~/Documents/Codex/CLAUDE.md.
#
# Kein -allowProvisioningUpdates, kein -exportArchive: beides spricht mit Apple
# und hat den Xcode-Account abgemeldet. Gebaut wird außerhalb von ~/Documents
# (iCloud-Falle), xattr -cr direkt vor jedem Signieren.
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_NAME="PortaPackManager"
DISPLAY_NAME="PortaPack Manager"
CACHE="$HOME/Library/Caches/de.christiangolz.portapackmanager"
DERIVED="$CACHE/DerivedData-Release"
OUT="$CACHE/Release"
IDENTITY="${PORTAPACK_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-portapack-notarisierung}"

DRY=0
TESTS=1
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --skip-tests) TESTS=0 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

cd "$PROJECT_DIR"
fail() { echo "✗ $*" >&2; exit 1; }

[[ -f Config/Signing.local.xcconfig ]] || fail "Config/Signing.local.xcconfig fehlt (Vorlage: .example)."
[[ "$(security find-identity -v -p codesigning)" == *"\"$IDENTITY"* ]] || fail "Keine Signieridentität „$IDENTITY“ im Schlüsselbund."
if (( ! DRY )); then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "notarytool-Profil „$NOTARY_PROFILE“ fehlt – anlegen mit: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id … --team-id … --password <app-spezifisch>"
fi
[[ -z "$(git status --porcelain)" ]] || echo "! Arbeitskopie hat ungesicherte Änderungen – die App enthält sie."

xcodegen generate --quiet
mkdir -p "$DERIVED" "$OUT"
LOG="$OUT/build.log"

if (( TESTS )); then
    echo "› Tests"
    if ! xcodebuild test -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -destination 'platform=macOS' \
            -derivedDataPath "$CACHE/DerivedData-ReleaseTests" >"$OUT/test.log" 2>&1; then
        grep -E "✘|error:|failed" "$OUT/test.log" | head -20 >&2
        fail "Tests fehlgeschlagen – Protokoll: $OUT/test.log"
    fi
fi

echo "› Bauen (Release, $IDENTITY)"
if ! xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
        CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" PROVISIONING_PROFILE_SPECIFIER= \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO "OTHER_CODE_SIGN_FLAGS=--timestamp" \
        ONLY_ACTIVE_ARCH=NO clean build >"$LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$LOG" | sort -u | head -20 >&2
    fail "Bauen fehlgeschlagen – Protokoll: $LOG"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DERIVED/Build/Products/Release/$APP_NAME.app/Contents/Info.plist")
BUILD_NO=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$DERIVED/Build/Products/Release/$APP_NAME.app/Contents/Info.plist")
STAGE="$OUT/stage-$VERSION"
APP="$STAGE/$DISPLAY_NAME.app"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$DERIVED/Build/Products/Release/$APP_NAME.app" "$APP"
xattr -cr "$APP"

echo "› Signatur prüfen ($VERSION, Build $BUILD_NO)"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -1
# Erst in Variablen lesen: `codesign … | grep -q` bricht mit pipefail ab,
# sobald grep früh endet (SIGPIPE beim Schreiber).
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
[[ "$SIGNATURE" == *"Authority=Developer ID Application"* ]] || fail "Nicht mit Developer ID signiert."
[[ "$SIGNATURE" == *"(runtime)"* ]] || fail "Hardened Runtime fehlt."
[[ "$SIGNATURE" == *"Timestamp="* ]] || fail "Signatur ohne sicheren Zeitstempel."
if [[ "$ENTITLEMENTS" == *"get-task-allow"* ]]; then
    fail "get-task-allow in den Entitlements – so lehnt Apple die Notarisierung ab."
fi
for f in LICENSE README.md README.de.md; do cp "$f" "$STAGE/"; done
ln -s /Applications "$STAGE/Programme"

if (( ! DRY )); then
    echo "› Notarisieren (App)"
    ZIP="$OUT/$APP_NAME-$VERSION-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$OUT/notary-app.log"
    grep -q "status: Accepted" "$OUT/notary-app.log" || fail "Notarisierung abgelehnt – Bericht: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
    rm -f "$ZIP"
    xcrun stapler staple "$APP"
    xattr -cr "$APP"
fi

echo "› Disk-Image"
hdiutil create -quiet -volname "$DISPLAY_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if (( ! DRY )); then
    echo "› Notarisieren (Disk-Image)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$OUT/notary-dmg.log"
    grep -q "status: Accepted" "$OUT/notary-dmg.log" || fail "Notarisierung des Disk-Images abgelehnt."
    xcrun stapler staple "$DMG"
    echo "› Gatekeeper-Prüfung"
    spctl --assess --type execute --verbose "$APP"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
    echo "› Probelauf: nicht notarisiert – Gatekeeper würde die App auf fremden Macs ablehnen."
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ $DMG"
