#!/bin/zsh
# Übersetzt den DVB-T2-Simulationsprüfstand (Empfänger + Testsender) mit
# Optimierung und startet ihn. Optionen siehe Tools/T2Sweep/main.swift.
# Build-Verzeichnis außerhalb von ~/Documents (iCloud-Falle, siehe ../CLAUDE.md).
set -euo pipefail
cd "${0:A:h}/.."
out="${T2SWEEP_BUILD:-$HOME/Library/Caches/de.christiangolz.portapackmanager/t2sweep}"
mkdir -p "$out"
# T2SWEEP_DVB: anderer Empfängerstand (z. B. ein älterer Checkout) zum Vergleich.
dvb=${T2SWEEP_DVB:-PortaPackManager/HackRF/DVBT2}
sources=(
    $dvb/T2Parameters.swift $dvb/T2Layout.swift $dvb/T2Tables.swift $dvb/T2Sync.swift $dvb/T2L1.swift
    $dvb/T2LDPC.swift $dvb/T2BCH.swift $dvb/T2BICM.swift $dvb/T2PLPDecoder.swift $dvb/T2BaseBand.swift $dvb/T2FrontEnd.swift
    $dvb/T2Receiver.swift
    PortaPackManagerTests/DVBT2Simulation.swift Tools/T2Sweep/LDPCExperiment.swift Tools/T2Sweep/main.swift
)
# T2SWEEP_DEBUG=1: ohne Optimierung (Absturzmeldungen mit Zeilenangabe).
optimize=(-O -wmo)
binary="$out/t2sweep${T2SWEEP_SUFFIX:-}"
if [[ -n "${T2SWEEP_DEBUG:-}" ]]; then optimize=(-Onone -g); binary="$out/t2sweep-debug${T2SWEEP_SUFFIX:-}"; fi
if [[ ! -x "$binary" ]] || [[ -n "$(find $sources $dvb/T2LDPCKernel.c $dvb/T2LDPCKernel.h -newer "$binary" 2>/dev/null)" ]]; then
    clang -O3 -c $dvb/T2LDPCKernel.c -o "$binary-kernel.o"
    swiftc $optimize -swift-version 6 -import-objc-header $dvb/T2LDPCKernel.h \
        -module-name T2Sweep -o "$binary" $sources "$binary-kernel.o"
fi
exec "$binary" "$@"
