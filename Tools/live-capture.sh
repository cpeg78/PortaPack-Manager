#!/bin/zsh
# Live-Probe am laufenden System: App beenden, IQ aufnehmen (iq-capture.sh),
# App wieder starten und den vorher aus der Ferne gewählten Empfänger
# wieder einschalten. Für geplante Aufnahmen (Sonden, Satelliten).
# Aufruf: Tools/live-capture.sh <name> <mitte Hz> <rate Hz> <sekunden> [LNA] [VGA] [filter Hz]
# Datei: ~/Library/Caches/de.christiangolz.portapackmanager/live/<name>_<rate>_<mitte>.iq
set -uo pipefail
cd "${0:A:h}/.."
name=$1 center=$2 rate=$3 seconds=$4 lna=${5:-24} vga=${6:-30} filter=${7:-}
dir="$HOME/Library/Caches/de.christiangolz.portapackmanager/live"
mkdir -p "$dir"
# Fernzugriff seit 30.10.2026 mit Konto: Name und Passwort eines Kontos mit
# „Bedienen“ aus PORTAPACK_USER/PORTAPACK_PASSWORD (ohne sie wird der Empfänger
# nicht wieder eingeschaltet). Sitzung im Cookie-Glas im Zwischenordner.
jar="$dir/.remote-cookies"
login() {
    [[ -n "${PORTAPACK_USER:-}" && -n "${PORTAPACK_PASSWORD:-}" ]] || return 1
    curl -s --max-time 10 -c "$jar" -o /dev/null -w '%{http_code}' \
        --data-urlencode "name=$PORTAPACK_USER" --data-urlencode "password=$PORTAPACK_PASSWORD" \
        "http://localhost:1478/login" | grep -q 303
}
mode=""
if login; then
    mode=$(curl -s --max-time 5 -b "$jar" -H "X-PortaPack: 1" "http://localhost:1478/api/state" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("mode") or "")
except Exception: print("")')
else
    echo "Hinweis: ohne PORTAPACK_USER/PORTAPACK_PASSWORD wird der Fernzugriff-Empfänger nicht wieder eingeschaltet."
fi
osascript -e 'quit app "PortaPack Manager"'
sleep 4
Tools/iq-capture.sh "$dir/${name}_${rate}_${center}.iq" "$center" "$rate" "$seconds" "$lna" "$vga" 0 $filter
result=$?
Scripts/run.sh --start >/dev/null 2>&1
if [[ -n "$mode" ]]; then
    for i in {1..10}; do
        sleep 3
        login && curl -sf --max-time 5 -b "$jar" -H "X-PortaPack: 1" -o /dev/null "http://localhost:1478/api/mode?m=$mode" && break
    done
    echo "Fernzugriff wieder auf $mode"
fi
exit $result
