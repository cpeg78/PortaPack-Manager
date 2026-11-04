# Changelog

All notable changes to PortaPack Manager. Versions follow
[Semantic Versioning](https://semver.org).

## 1.2.0 – 2026-11-04

### Added

- **Aircraft without ADS-B:** helicopters, police, military and older aircraft
  that only have a Mode S transponder (no position) now appear in the aircraft
  list and the archive with registration, type and altitude – not on the map,
  since they don't send a position. ADS-B reception is unchanged.
- **Aircraft symbols by kind and size:** helicopters, light aircraft and
  gliders get their own map symbol, wide-body aircraft a larger one – on the
  Mac and on the phone. The kind comes from the category the aircraft sends,
  otherwise from the aircraft database.
- **Homematic radiator thermostats:** the status message of the HM-CC-RT-DN
  (“Information 0x0A”) now shows measured and target temperature, valve
  position, battery voltage, mode (automatic/manual/party/boost) and errors.
- **Wireless M-Bus security mode 7:** meters using OMS security profile B
  (authentication layer with message counter and MAC, per-message derived key –
  e.g. Diehl water meters, Engelmann Sensostar) are decrypted with the meter
  key like mode 5; the MAC is verified. Without a key, the message counter and
  MAC are shown.
- **Techem heat cost allocators (Wireless M-Bus):** their manufacturer-specific
  frames now show the consumption units of the current and the previous billing
  period with dates, plus room and radiator temperature – instead of raw bytes.
- **Aircraft list time limit:** choose under Display how long aircraft without
  messages stay in the table (15 min, 30 min – the default –, 1 h or 3 h).
  Selecting an older aircraft in the table shows it greyed out at its last
  position on the map, so the map can jump to it.
- **Longer aircraft tracks:** ADS-B tracks now keep 1000 points (about three
  minutes at cruise) instead of 200; the map only receives the new points.
- **ISS and amateur satellites in remote access:** the phone lists the next
  passes and can skip them, like METEOR passes and sondes.
- **SD card transfers keep running** when you switch pages; progress and
  “Cancel” come back when you return.

### Fixed

- **Airports “not loaded”:** the data section showed this while “Show
  airports” was off, although the list was already on the Mac.
- **Crash without login:** a malformed login form sent to remote access could
  quit the app.
- **Crash via radio:** an APRS packet with “inf” or “nan” as course, speed or
  altitude crashed the app while the APRS tab was open on a phone.
- **Radio and spectrum no longer retune another receiver:** tuning, crystal
  correction and gain presets only change the device while that page owns it;
  otherwise the value is remembered for the next start.
- **Skipped satellite passes stay skipped** after the passes are recalculated.
- **Restoring a damaged backup** no longer sets your intact archive aside; you
  get a clear message instead.
- **Manually started sonde, METEOR or amateur satellite pages** pause during
  another schedule job and resume afterwards instead of showing “running”
  without data.
- **No data loss on quit:** aircraft and ship sightings and pending database
  writes are saved before the app ends.
- **Schedule doesn't wait for the network:** orbital data and SondeHub are
  fetched in the background, so passes start on time.
- **Aircraft list limited** to 2000 entries – forged signals can no longer
  fill memory.
- **Flashing:** the app no longer freezes while the HackRF chip is erased.
- **App files (.ppma)** are checked after upload, like the firmware.
- **Typing on the device** sends long text in pieces instead of cutting it off.
- **Audio** comes back after switching the output device (e.g. Bluetooth).
- **LoRaWAN** shows payloads only when the message check (MIC) is valid.
- **GPS, occupancy monitor, archive retention** and several remote-access
  details (login throttling, image sizes, header handling) hardened.
- **METEOR passes and sonde windows in remote access** are only listed while
  the matching automatic reception is on, like ISS and amateur satellites.
- **Sondes in remote access** move from the live list to the archive once
  they haven't been heard for 5 minutes (also on the map).
- **ntfy over http** shows a warning, since the topic is sent unencrypted.
- **Smart home device list:** a device with readable values no longer shows a
  lock just because an AES signature frame followed (Homematic actuators).
- **Sonde forecast in remote access:** the forecast of a window that is already
  over is labelled with its date and “over” instead of looking like the next one.

- **Aircraft and ship maps (Mac):** closing the info card keeps the aircraft or
  ship selected – its track stays highlighted and the map keeps following it.
  Clicking it again reopens the card; clicking an empty spot deselects.
  The map now keeps the selected aircraft or ship in the centre as it moves,
  until you drag the map (zooming doesn't stop it); clicking it again resumes.

- **Map buttons easier to see:** “Show all …” on every map is now a capsule
  with a background and shadow instead of plain text on the tiles.

- **“Satellite coming” notification:** only for passes the schedule will
  actually record – not when automatic METEOR reception is off or the pass was
  skipped. Planned amateur satellites are announced as well.

## 1.1.1 – 2026-11-01

### Added

- **APRS in remote access:** new tab with a map of the stations (same symbols
  as on the Mac), a station list with distance and comment, the latest
  packets and the channel choice. Tap a station to see its details and track.

- **LoRa APRS:** the APRS receiver also listens on 433.775 MHz (LoRa, SF12,
  125 kHz) – the usual 70 cm APRS in Europe. Stations show up in the same list
  and map, on the Mac and in remote access. A second 433.775 MHz channel
  (“FM APRS”) decodes classic AFSK 1200 there. The chosen channel is remembered.

### Changed

- **WLAN uses half the CPU:** the OFDM preamble check no longer recomputes the
  same sine/cosine values thousands of times per second (measured on a real
  recording: 48 → 21 % of a core, identical frames).

- **Airband uses less CPU:** “Wide span (16 MHz)” is now only used when the
  channel list doesn’t fit into 8 MHz; otherwise the narrow span runs with half
  the load.

- **FT8/WSPR map:** stations can be clicked on the Mac map to select their
  latest decode, and they are drawn larger; on the phone they show the antenna
  symbol with call sign instead of small dots.

- **Remote access info sheet:** on the phone the sheet of an aircraft or ship
  can be dragged at its handle to small, half or large size (tapping the handle
  steps through them); closing it keeps the target selected and centred on the
  map.

- **Remote access weather tab:** a skipped sonde window no longer shows up as
  “Sonde window until …” in the status line, and skipped entries are greyed out.
  An open window that waits because no sonde is in range says “waiting” instead
  of the blue dot; its details give the reason.

- **Overview:** the “Location” section is gone – the location is set in the
  settings.

### Fixed

- **Sidebar:** a selected entry further down the list scrolls into view instead
  of staying hidden below the visible area.

- **Ship photos:** the photo credit shows only the photographer and licence
  (at most 80 characters) instead of a whole licence text some authors put
  into the Wikimedia Commons author field; on the phone it takes at most two
  lines.

## 1.1.0 – 2026-10-31

### Changed

- **Maps on OpenStreetMap (Leaflet) instead of Apple Maps:** every map in the
  app (aircraft, ships, APRS, radiosondes and their archive, drones, DSC,
  Meshtastic, FT8/WSPR, VOR, GPS, traffic archive) now uses the same Leaflet
  map as the remote access page – one look on Mac, phone and future Linux/Windows
  versions. Only changed targets are sent to the map; direction arrows on tracks
  keep a fixed on-screen spacing and thin out when zooming out. GPS gets a
  “Show position” button; drones, Meshtastic and VOR get “Show all …”.
  Zooming with mouse wheel and trackpad is smooth instead of stepwise.

- **Map symbols easier to see:** ships get their own hull symbol; aircraft,
  ships, APRS stations, repeaters, beacons and radiosondes have a dark outline
  and stand out on water, forest and fields – on the Mac and on the remote
  access page alike. The phone map shows base stations and aids to navigation
  with their own symbols and radiosondes as balloons. Map labels can be clicked
  to select the target.

- **Remote access archive:** step through the days with ‹ › or pick a day from
  the calendar instead of an ever-growing list.

- **Remote access schedule:** tap a satellite pass or sonde window to see day,
  time (also UTC), duration and – for sonde windows – the SondeHub forecast,
  and skip it or schedule it again, like the switch on the Mac. The weather
  tab is grouped: schedule first (automatic reception, passes, sonde windows,
  sonde gain), then what was received (balloons, images, history).

- **Remote access with accounts:** sign in with user name and password instead
  of an access key in the address. Several accounts with the roles “Control” and
  “View only”; passwords stored as PBKDF2 hashes in the keychain; devices stay
  signed in and can be signed out per account; failed sign-ins are throttled.
  Old links with `?k=` no longer work – create an account under
  Settings ▸ Remote Access.

### Added

- **Airband: Whisper as an alternative speech recognizer** (whisper.cpp,
  runs on the Mac with Metal). Choose the model (Base, Small, Large v3 Turbo);
  the app downloads it once and verifies its checksum. In tests with noisy
  synthetic transmissions: 3–11 % word errors instead of 29–63 % with Apple's
  recognizer, call signs 16–17 of 17 instead of 4–10.

- **Radiosondes: alternate until the first sonde.** Until a sonde is decoded,
  the previous receiver (e.g. ADS-B) keeps running and the HackRF listens for
  sondes for 1½ minutes every 5 minutes (adjustable, or off).

### Fixed

- Drones, Bluetooth LE, Meshtastic and radio sensors: the app no longer crashes
  when opening these pages.
- Airports on the aircraft map: if macOS cleared the app's cache folder (e.g.
  when disk space runs low), the list is downloaded again automatically; the
  remote access page no longer asks to load it on the Mac right after start.
- Menu bar: “Settings …” opens the settings even when the main window is
  being created anew.
- Radiosonde charts: the hover box no longer appears twice (temperature and
  humidity chart drew it on top of each other).

- A sonde window no longer ends after 30 minutes without reception while
  SondeHub still reports a sonde in range.

- Remote access: the weather balloon box only counts sondes heard in the last
  5 minutes as “live”.
- Switching to HackRF mode retries when the PortaPack first returns in Mayhem
  mode (it was still closing an app).
- Running the tests no longer starts a second remote access server.

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
