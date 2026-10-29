# PortaPack Manager

**Deutsch** · [English](README.md)

**Ein Empfangslabor für den HackRF One mit PortaPack – als macOS-App.**

Flugzeuge und Schiffe auf der Karte, UKW, Digitalradio und Fernsehen,
Wetterballons und Satellitenbilder, Funksensoren und Smart-Home-Funk – der
PortaPack Manager dekodiert alles selbst, ohne Zusatzprogramme. Nebenbei hält
er die Mayhem-Firmware des PortaPack aktuell.

Gedacht für Einsteiger: anschließen, auf der Startseite eine Kachel anklicken,
fertig. Verstärkung, Frequenzen und Kanäle stellt die App selbst ein – von Hand
geht es trotzdem überall.

➜ **[Handbuch](Docs/Hilfe.md)** (dasselbe wie in der App unter *Hilfe*)

![Startseite: ein Klick pro Empfänger](Docs/Bilder/startseite.jpg)

## Was die App kann

**Empfangen** (HackRF-Modus – die App wechselt selbst hinein)

| Bereich | Empfänger |
|---|---|
| Werkzeuge | Empfangsplan (Satelliten und Wetterballons automatisch) · Spektrum und Wasserfall mit Markern und Max-Hold · Belegungsmonitor über Stunden/Tage · LTE-Zellsuche · Antennen-Check · IQ-Aufnahme und Auswertung, SigMF-Export/-Import |
| Rundfunk | UKW mit RDS und Stereo, AM/NFM, SSB/CW mit wählbaren Filtern · DAB+ · DVB-T2 (Antennenfernsehen) · Tonaufnahme |
| Luftfahrt | ADS-B mit Karte, Typ, Strecke, Foto und Flugplätzen · ACARS/VDL2 mit Klartext-Deutung und CPDLC · Flugfunk-Scanner mit Abschrift in Text (auf dem Mac) und Suche · VOR-Funkfeuer mit Kreuzpeilung · FLARM · Drohnen-Kennung (Remote ID) |
| Schifffahrt & Funkdienste | AIS mit Karte und Foto · Seefunk-Notruf (DSC) · APRS · Funkruf (DAPNET) |
| Wetter | Radiosonden (Wetterballons) · Wettersatellit METEOR-M |
| Navigation & Zeit | GPS-Ortung · Funkuhr DCF77 |
| Smart Home & IoT | Funksensoren (433/868 MHz) · Z-Wave, Homematic, EnOcean, Funkzähler (868 MHz) · Zigbee mit Entschlüsselung · Thread · Bluetooth LE · WLAN · LoRaWAN · Meshtastic |
| Amateurfunk & Weltraum | ISS (SSTV, APRS) und Amateurfunk-Satelliten · FT8/WSPR · Wasserstofflinie (Radioastronomie) |

**Für Einsteiger gemacht**

- Startseite mit Kacheln: ein Klick öffnet, schaltet um und startet.
- Jede Empfängerseite gleich aufgebaut, mit Statuszeile in Alltagssprache
  („Empfang läuft – 12 Meldungen pro Minute“).
- *Signal optimieren* und eine Verstärkungsautomatik gegen Übersteuerung.
- Antennen-Check: misst alle Bänder und sagt, wofür die Antenne taugt.
- Ersteinrichtung mit automatischem Quarzabgleich; alle Einstellungen an einem
  Ort.
- Frequenzspeicher für alle Seiten, CSV-Ein- und -Ausgabe (auch Listen aus
  SDR++/CHIRP); Live-Listen als CSV sichern.
- Läuft im Hintergrund weiter, mit Symbol in der Menüleiste und auf Wunsch
  Start beim Anmelden.
- Oberfläche und Handbuch auf Deutsch und Englisch; eingebautes Handbuch mit
  einem Kapitel je Seite.

**Unterwegs und vernetzt**

- Fernzugriff vom Handy – siehe unten.
- Benachrichtigungen am Mac oder per [ntfy](https://ntfy.sh) aufs Handy.
- Archiv aller Sichtungen (Flugzeuge, Schiffe, Wetterballons, Flugfunk) in einer
  Datenbank, mit Aufbewahrungsfrist und Sicherung als ZIP.
- Daten teilen (alles opt-in): ADS-B an adsb.fi/airplanes.live, AIS als NMEA,
  Radiosonden an SondeHub, Messwerte an Home Assistant (MQTT).

**Gerät verwalten** (Mayhem-Modus)

- Firmware-Update (Nightly/Stabil) mit Prüfung von Paket und Prüfsumme,
  „Gerät komplett erneuern“ samt SD-Karteninhalt.
- **PortaPack fernbedienen:** Sein Display erscheint live am Mac; Klicks
  wirken als Touch, Pfeiltasten und Enter wie die Tasten am Gerät, Text tippst
  du direkt ein. Bildschirmfotos per Knopf.
- SD-Karte bearbeiten (mit Prüfsumme, für große Mengen als Laufwerk), Konsole.

## Fernzugriff vom Handy

Der Mac wird zum Empfänger, den du vom Sofa oder unterwegs bedienst: eine
Webseite für Handy und Tablet – nichts zu installieren, auf dem iPhone einfach
„Zum Home-Bildschirm“.

- **14 Empfänger** in einem Menü: Flugzeuge und Schiffe auf der Karte,
  Flugfunk, Flugzeug-Datenfunk, Seefunk-Notruf, Wetter & Satelliten
  (Wetterballons mit Landeschätzung und Flugprofil), DAB+ und Radio, Spektrum,
  Belegungsmonitor, Funksensoren, Smart Home 868, Zigbee mit Netzkarte,
  FT8/WSPR.
- **Ton aufs Handy** bei Radio, DAB+ und Flugfunk; Abstimmen und Suchlauf vom
  Handy aus.
- **Start, Stopp, Signal optimieren** – das Handy schaltet den HackRF selbst
  um. Frequenzspeicher, Flugfunk-Kanalliste und Empfangsplan teilen sich Mac
  und Handy; Plan-Termine lassen sich vom Handy überspringen.
- **Sicher ab Werk:** Zugangsschlüssel in der Adresse (Einrichtung per
  QR-Code), nur Geräte aus Heimnetz oder VPN (z. B. Tailscale), Schlüssel für
  Zigbee oder Zähler verlassen den Mac nie.
- Deutsch und Englisch, hell und dunkel.

![Flugzeuge: Karte mit Flugplätzen, Typ, Betreiber und Strecke](Docs/Bilder/flugzeuge.jpg)

![Schiffe (AIS) auf der Elbe](Docs/Bilder/schiffe.jpg)

![Digitalradio (DAB+): Senderliste und Empfangsgüte](Docs/Bilder/digitalradio.jpg)

![Spektrum und Wasserfall im UKW-Band](Docs/Bilder/spektrum.jpg)

![Firmware: Nightly oder Stabil, mit Prüfung und Komplett-Erneuerung](Docs/Bilder/firmware.jpg)

## Voraussetzungen

- macOS 15 oder neuer (Apple Silicon oder Intel)
- HackRF One mit PortaPack und [Mayhem-Firmware](https://github.com/portapack-mayhem/mayhem-firmware)
  (ab etwa v2.0 bzw. Nightly 2024)
- Eine Antenne – je besser und je höher, desto mehr kommt an. Für
  Wettersatelliten eine eigene Satellitenantenne (V-Dipol/QFH), für GPS eine
  aktive GPS-Antenne.

## Installieren

**Fertige App:** unter *Releases* das Disk-Image `PortaPackManager-<Version>.dmg`
laden, öffnen und die App in *Programme* ziehen. Sie ist mit Developer ID
signiert und von Apple notarisiert – macOS startet sie ohne Warnung.

**Aus dem Quelltext** (Xcode 26 und [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```bash
brew install xcodegen
Scripts/run.sh            # bauen, nach ~/Applications installieren, starten
```

Für eine signierte App `Config/Signing.local.xcconfig` aus der Vorlage anlegen;
ohne sie baut das Projekt unsigniert. Liegt ein Developer-ID-Zertifikat im
Schlüsselbund, signiert `run.sh` damit.

## Datenschutz und Recht

- Die App **empfängt nur**, sie sendet nicht über Funk.
- Der eigene Standort bleibt auf dem Mac, außer du teilst ihn ausdrücklich.
  Was die App ins Internet schickt (Firmware, Flugzeug- und Schiffsfotos,
  Satellitenbahnen …), steht im [Handbuch](Docs/Hilfe.md#recht).
- Nachrichten, die nicht für dich bestimmt sind – etwa Alarmierungen von
  Feuerwehr, Rettungsdienst und Polizei –, darfst du weder auswerten noch
  weitergeben (§ 5 TDDDG). Die App bietet beim Funkruf deshalb nur DAPNET an.

## Entwicklung

```bash
xcodegen generate
xcodebuild -project PortaPackManager.xcodeproj -scheme PortaPackManager -destination 'platform=macOS' build
xcodebuild test -project PortaPackManager.xcodeproj -scheme PortaPackManager -destination 'platform=macOS'
```

- SwiftUI, Swift 6, keine Fremdbibliotheken. USB über IOKit
  (`PortaPackManager/HackRF/HackRFUSB.c`), seriell über POSIX.
- Über 900 Tests (Swift Testing): Dekoder mit Normvektoren und Testsignalen,
  ein Fuzz-Test für alle Funk-Parser, Simulationsprüfstand für DVB-T2.
- Neue Empfängerseiten bekommen ein Kapitel in [`Docs/Hilfe.md`](Docs/Hilfe.md)
  (ein Test prüft das).

### Auslieferung

```bash
Scripts/release.sh --dry-run   # Tests, bauen, Developer-ID-Signatur, DMG – ohne Apple
Scripts/release.sh             # dazu Notarisierung und stapler; lädt nichts hoch
```

Voraussetzung: Zertifikat „Developer ID Application“ und ein notarytool-Profil
im Schlüsselbund (Name in `NOTARY_PROFILE`, Standard `portapack-notarisierung`).

## Lizenz

[GNU General Public License v3.0](LICENSE) oder neuer. Was sich je Version
geändert hat, steht in [CHANGELOG.md](CHANGELOG.md) (englisch).

Der PortaPack Manager ist ein unabhängiges Projekt und steht in keiner
Verbindung zu ShareBrained Technology (PortaPack), Great Scott Gadgets (HackRF)
oder dem Mayhem-Firmware-Team. Die Namen dienen nur dazu, die Kompatibilität zu
beschreiben.

Mehrere Dekoder sind nach freien Projekten unter GPL entstanden oder übernehmen
deren Tabellen – unter anderem gr-dtv (DVB-T2-LDPC), dumpvdl2/libacars
(VDL2, CPDLC-Schemas), rtl_433 (Funksensoren), readsb/dump1090 (ADS-B), SatDump
(METEOR), gr-lora (LoRa) sowie WSJT-X über ft8_lib (MIT) und wsprd
(FT8/WSPR: LDPC-Tabellen, Fano-Metrik). Mitgeliefert wird [Leaflet](https://leafletjs.com)
1.9.4 (BSD-2-Clause, © Vladimir Agafonkin, CloudMade) für die Karten im
Fernzugriff.

