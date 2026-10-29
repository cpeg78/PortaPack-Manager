# Changelog

All notable changes to PortaPack Manager. Versions follow
[Semantic Versioning](https://semver.org).

## 1.0 – 2026-10-29

First public release.

### Receivers (HackRF mode)

- **Tools:** reception schedule for weather satellites, amateur satellites and
  weather balloons (SGP4 pass prediction, SondeHub launch forecast, priorities,
  automatic return to the previous receiver); spectrum and waterfall with
  markers, max hold and “Listen in Radio”; occupancy monitor over hours or days
  with heat map and CSV/PNG export; LTE cell search (PSS/SSS, MIB, SIB1 with
  operator and cell ID); antenna check across all important bands; IQ
  recording and offline decoding with SigMF export and import.
- **Broadcast:** FM with RDS and stereo, AM, NFM, SSB (USB/LSB) and CW with
  selectable filters; DAB+ with station scan and radio text; DVB-T2 with picture
  and sound; audio recording as AAC or WAV.
- **Aviation:** ADS-B with map, aircraft database, routes, photos and airports;
  ACARS and VDL Mode 2 with plain-language interpretation, ADS-C and CPDLC;
  airband scanner listening to all channels at once, with on-device
  transcription and search; VOR radial, Morse ident and cross bearing; FLARM;
  drone Remote ID via HackRF and the Mac's Bluetooth.
- **Maritime and radio services:** AIS with map and photos, DSC on channel 70,
  APRS, POCSAG (DAPNET only).
- **Weather:** radiosondes (RS41 and DFM, up to four at once, flight
  history, landing estimate, archive); METEOR-M LRPT images.
- **Navigation and time:** GPS L1 position fix with weak-signal search,
  20 ms tracking and hot start; DCF77 radio clock including leap seconds.
- **Smart home and IoT:** wireless sensors (433/868 MHz); Z-Wave, Homematic,
  EnOcean and Wireless M-Bus meters at the same time; Zigbee with decryption,
  ZDO/ZCL and 2D/3D network map; Thread; Bluetooth LE; Wi-Fi occupancy and
  frame capture (PCAP); LoRaWAN; Meshtastic.
- **Amateur radio and space:** ISS SSTV and APRS, amateur satellites with
  AX.25 1200/9600 and Doppler correction; FT8 and WSPR with drift tracking;
  hydrogen line (21 cm) with LSR velocity.

### Ease of use

- Start page with one-click tiles, initial setup with automatic crystal
  calibration, the same layout on every receiver page with a plain-language
  status line, “Optimize Signal” and automatic gain control.
- Switching pages keeps the receiver running; one shared frequency memory with
  CSV import/export (also from SDR++/CHIRP); CSV export of all live lists.
- Runs in the background with a menu bar icon, optional start at login.
- Interface and built-in manual in German and English.

### Remote access and sharing

- Web page for phone and tablet with 14 receivers, audio on the phone, shared
  frequency memory and schedule; access key, home network/VPN only.
- Notifications on the Mac or via ntfy.
- Opt-in data sharing: ADS-B (Beast) to adsb.fi/airplanes.live, AIS as NMEA,
  radiosondes to SondeHub, Home Assistant via MQTT.
- Archive of aircraft, ships, radiosondes and airband in an SQLite database with
  retention period, full-text search and ZIP backup.

### Device management (Mayhem mode)

- Firmware updates (nightly/stable) with checksum verification, apps-only
  update and complete renewal including the SD card via SD over USB.
- Live screen mirroring with touch and key control, SD card browser, console.
