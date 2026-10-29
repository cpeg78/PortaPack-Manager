#!/bin/zsh
# Live-Probe des 802.11-Empfängers ohne App (Tools/WLANProbe/main.swift).
# Die App darf den HackRF dabei nicht halten (beenden oder andere Seite).
# Build-Verzeichnis außerhalb von ~/Documents (iCloud-Falle, siehe ../CLAUDE.md).
set -euo pipefail
cd "${0:A:h}/.."
out="$HOME/Library/Caches/de.christiangolz.portapackmanager/wlanprobe"
mkdir -p "$out"
src=PortaPackManager/HackRF
sources=(
    $src/HackRFDevice.swift PortaPackManager/Firmware/FirmwareImage.swift $src/WiFi/WLANFrame.swift $src/WiFi/WLANOFDM.swift $src/WiFi/WLANDSSS.swift
    PortaPackManager/Serial/SerialDeviceFinder.swift $src/WiFi/WLANReceiver.swift $src/RemoteID.swift $src/BLEAdvertising.swift $src/Meteor/MeteorCoding.swift
    Tools/WLANProbe/main.swift
)
binary="$out/wlanprobe"
if [[ ! -x "$binary" ]] || [[ -n "$(find $sources $src/HackRFUSB.c $src/HackRFUSB.h -newer "$binary" 2>/dev/null)" ]]; then
    clang -O2 -c $src/HackRFUSB.c -o "$out/usb.o"
    swiftc -O -swift-version 6 -import-objc-header $src/HackRFUSB.h -framework IOKit -framework CoreFoundation \
        -module-name WLANProbe -o "$binary" $sources "$out/usb.o"
fi
exec "$binary" "$@"
