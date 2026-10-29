#!/bin/zsh
# Baut den PortaPack Manager, installiert ihn nach ~/Applications und startet ihn.
#
#   Scripts/run.sh            bauen (Release), installieren, starten
#   Scripts/run.sh --debug    Debug-Build statt Release
#   Scripts/run.sh --start    nur starten (ohne Bauen)
#
# Liegt ein „Developer ID Application“-Zertifikat im Schlüsselbund, signiert
# das Skript damit – dieselbe Identität wie die ausgelieferte App
# (Scripts/release.sh). Die Anforderung hängt dann nur an der Team-Kennung,
# nicht am Namen eines einzelnen Zertifikats; Standort- und Bluetooth-Freigabe
# überstehen so auch eine Zertifikatserneuerung. PORTAPACK_IDENTITY=… wählt eine
# andere Identität, PORTAPACK_IDENTITY=development das Development-Zertifikat.
#
# Gebaut wird unter ~/Library/Caches, nicht im Projektordner: ~/Documents
# liegt in iCloud, und das korrumpiert Build-Datenbanken und Signaturen
# (siehe ~/Documents/Codex/CLAUDE.md, „Die iCloud-Falle“).
# Kein -allowProvisioningUpdates – das meldet den Xcode-Account ab.
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_NAME="PortaPackManager"
DISPLAY_NAME="PortaPack Manager"
DERIVED="$HOME/Library/Caches/de.christiangolz.portapackmanager/DerivedData"
INSTALL_DIR="$HOME/Applications"
TARGET="$INSTALL_DIR/$DISPLAY_NAME.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

CONFIG=Release
BUILD=1
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=Debug ;;
        --start) BUILD=0 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

if (( BUILD )); then
    cd "$PROJECT_DIR"
    if [[ ! -d "$APP_NAME.xcodeproj" || project.yml -nt "$APP_NAME.xcodeproj/project.pbxproj" ]]; then
        echo "› Xcode-Projekt erzeugen"
        xcodegen generate --quiet
    fi

    SIGN_ARGS=()
    IDENTITY="${PORTAPACK_IDENTITY:-}"
    if [[ -z "$IDENTITY" && -f Config/Signing.local.xcconfig ]] \
            && [[ "$(security find-identity -v -p codesigning)" == *'"Developer ID Application:'* ]]; then
        IDENTITY="Developer ID Application"
    fi
    if [[ -n "$IDENTITY" && "$IDENTITY" != development ]]; then
        SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" PROVISIONING_PROFILE_SPECIFIER=)
    fi

    echo "› Bauen ($CONFIG${IDENTITY:+, $IDENTITY})"
    LOG="$DERIVED/../build.log"
    mkdir -p "$DERIVED"
    if ! xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration "$CONFIG" \
            -destination 'platform=macOS' -derivedDataPath "$DERIVED" "${SIGN_ARGS[@]}" build >"$LOG" 2>&1; then
        grep -E "error:|BUILD FAILED" "$LOG" | sort -u | head -20 >&2
        echo "Bauen fehlgeschlagen – vollständiges Protokoll: $LOG" >&2
        exit 1
    fi
    BUILT="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"

    # Laufende Instanz beenden, sonst lässt sich das Bundle nicht ersetzen.
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "› Laufende App beenden"
        pkill -x "$APP_NAME" || true
        for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.25; done
        # Hängt sie (z. B. in einem USB-Aufruf), hart beenden – und wenn auch
        # das nicht greift, abbrechen statt das Bundle unter der laufenden
        # App zu löschen (Review 28.10.2026).
        if pgrep -x "$APP_NAME" >/dev/null; then
            echo "› App reagiert nicht – beende sie hart"
            pkill -9 -x "$APP_NAME" || true
            for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.25; done
        fi
        if pgrep -x "$APP_NAME" >/dev/null; then
            echo "Die App läuft noch – Installation abgebrochen, nichts ersetzt. Bitte von Hand beenden." >&2
            exit 1
        fi
    fi

    echo "› Installieren nach $TARGET"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$TARGET"
    ditto "$BUILT" "$TARGET"
    xattr -cr "$TARGET"
    codesign --verify --deep --strict "$TARGET"

    # Bei macOS neu anmelden, damit Finder und Dock das Symbol übernehmen.
    # Ältere Bundles aus Xcodes DerivedData abmelden – sie trugen beim ersten
    # Start noch kein Symbol, und macOS hält sonst an diesem Eintrag fest.
    for old in "$HOME"/Library/Developer/Xcode/DerivedData/PortaPackManager-*/Build/Products/*/"$APP_NAME.app"(N); do
        "$LSREGISTER" -u "$old" 2>/dev/null || true
    done
    "$LSREGISTER" -f "$TARGET"
    touch "$TARGET"
fi

if [[ ! -d "$TARGET" ]]; then
    echo "Nicht installiert – zuerst ohne --start aufrufen." >&2
    exit 1
fi

echo "› Starten"
open "$TARGET"
