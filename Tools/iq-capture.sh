#!/bin/zsh
# IQ-Rohaufnahme ohne App (Tools/IQCapture/main.swift), siehe LiveCaptureTests.
# Die App darf den HackRF dabei nicht halten (beenden oder andere Seite).
# Build-Verzeichnis außerhalb von ~/Documents (iCloud-Falle, siehe ../CLAUDE.md).
set -euo pipefail
cd "${0:A:h}/.."
out="$HOME/Library/Caches/de.christiangolz.portapackmanager/iqcapture"
mkdir -p "$out"
src=PortaPackManager/HackRF
sources=(
    $src/HackRFDevice.swift PortaPackManager/Firmware/FirmwareImage.swift PortaPackManager/Serial/SerialDeviceFinder.swift Tools/IQCapture/main.swift
)
binary="$out/iqcapture"
if [[ ! -x "$binary" ]] || [[ -n "$(find $sources $src/HackRFUSB.c $src/HackRFUSB.h -newer "$binary" 2>/dev/null)" ]]; then
    clang -O2 -c $src/HackRFUSB.c -o "$out/usb.o"
    swiftc -O -swift-version 6 -import-objc-header $src/HackRFUSB.h -framework IOKit -framework CoreFoundation \
        -module-name IQCapture -o "$binary" $sources "$out/usb.o"
fi
exec "$binary" "$@"
