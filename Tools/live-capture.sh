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
# Schlüssel liegt seit 28.10.2026 im Schlüsselbund (alte Installationen: UserDefaults).
token=$(security find-generic-password -s de.christiangolz.portapackmanager.remote -a remoteToken -w 2>/dev/null \
    || defaults read de.christiangolz.portapackmanager remoteToken 2>/dev/null)
mode=$(curl -s --max-time 5 -H "X-PortaPack: 1" "http://localhost:1478/api/state?k=$token" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("mode") or "")
except Exception: print("")')
osascript -e 'quit app "PortaPack Manager"'
sleep 4
Tools/iq-capture.sh "$dir/${name}_${rate}_${center}.iq" "$center" "$rate" "$seconds" "$lna" "$vga" 0 $filter
result=$?
Scripts/run.sh --start >/dev/null 2>&1
if [[ -n "$mode" ]]; then
    for i in {1..10}; do
        sleep 3
        curl -s --max-time 5 -H "X-PortaPack: 1" -o /dev/null "http://localhost:1478/api/mode?m=$mode&k=$token" && break
    done
    echo "Fernzugriff wieder auf $mode"
fi
exit $result
