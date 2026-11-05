# Changelog

All notable changes to PortaPack Manager. Versions follow
[Semantic Versioning](https://semver.org).

## 1.3.0 – 2026-11-05

### Added

- **Radiosonde wind profile:** the sonde drifts with the wind – a new “Wind”
  view shows wind speed and direction over altitude during ascent, taken from
  the sonde's GPS speed and course. Remote Access shows the wind speed profile
  too.
- **Everything else a radiosonde sends:** pressure (RS41-SGP), GPS satellites,
  exact model, mainboard and firmware, configured frequency, shutdown
  countdown and extra instruments such as ozonesondes (XDATA: OIF411, ECC, CFH)
  – shown only when a sonde actually sends them, on the Mac, in Remote Access,
  on SondeHub and via MQTT. Pressure, satellites and ozone cell current are
  archived; the history adds a pressure chart, an ozone profile and the share
  of frames received.

- **Aircraft squawk and emergencies:** the aircraft list shows the transponder
  code; an aircraft reporting an emergency or squawking 7700, 7600 or 7500 is
  shown in red, on the Mac and in Remote Access, and triggers a notification.
- **What the autopilot is flying:** selected altitude and heading, pressure
  setting (QNH), active autopilot modes, ADS-B version and position accuracy
  in the aircraft's info card.

- **AIS rescue aircraft, emergency beacons and safety messages:** SAR aircraft
  appear with altitude and an aircraft symbol, AIS-SART, man-overboard and EPIRB
  beacons with an SOS symbol – an active beacon triggers a notification.
  Plain-text safety messages are listed on the AIS page.

- **Tire pressure:** sensors in the Toyota format now show pressure and
  temperature, also sent to Home Assistant.

- **ACARS/VDL2 archive:** datalink messages are now stored, and the search on
  the ACARS page also finds older messages by text, registration or flight.

- **Wi-Fi frames:** the device list shows which network each device is
  connected to and the maker, model or name that routers and phones reveal via
  WPS; deauth and disassociation frames are listed with their reason, with a
  warning when a deauth attack is likely.

- **Meshtastic:** traceroutes with SNR per hop, neighbor links on the map,
  waypoints, range tests, detection sensors, paxcounters, acknowledgements and
  every kind of telemetry (air quality, power, local statistics, wind and rain
  …) – each kept separately per node.

- **APRS via the ISS:** packets from the ISS and NO-44 digipeaters are decoded
  like on the APRS page, and their positions appear on a new map.

- **DAB+ and FM artist and title:** stations that tag them (DL Plus on DAB+,
  RadioText+ on FM) show “♪ Artist – Title”, also in Remote Access and the
  phone's lock screen.
- **DAB+ slideshow:** pictures the station sends along (logo, cover art,
  news) appear on the DAB+ page.
- **DAB+ alternatives:** the DAB+ page shows where the current programme also
  runs, as reported by the station: other ensembles and FM frequencies.
- **DAB+ programme guide:** if the ensemble sends one (SPI/EPG), the DAB+
  page lists the current show with its description and the next ones.

- **Zigbee meters and newer Aqara devices:** energy, power, voltage and current
  now use each device's own multiplier and divisor, and Aqara's manufacturer
  cluster (0xFCC0) is read like the older Xiaomi attribute.

- **Z-Wave:** door locks, thermostat and fan state, colors, pulse meters,
  configuration parameters, associations, sensor alarms, scenes and the list
  of supported command classes – user codes only as “slot in use”, never the
  code itself.

- **EnOcean:** light, presence, CO₂, room panel, meter, contact and valve
  actuator profiles, window handles (F6-10-00), universal teach-in (UTE) and
  VLD switching/dimming actuators with energy readings (D2-01) and blinds
  (D2-05).

- **Homematic wall thermostat:** HM-TC-IT-WM-W-EU status (actual and set
  temperature, battery, mode), thermostat group updates and battery warnings
  in acknowledgements.

- **Remote ID:** a drone's emergency self-ID is shown in red; the details add
  altitude and speed accuracy and the operating altitude range.

- **ACARS:** more OOOI labels (landing, arrival, diversion …) and the ground
  station squitter's network, location and frequency.

- **Airband noise reduction:** noisy transmissions are cleaned up while you
  listen – the app learns each channel's noise in speech pauses and removes it,
  keeping only the speech band (Medium by default, Strong for very noisy ones).

- **Bluetooth:** AirPods/Beats battery levels, AirTag battery, SwitchBot
  thermometers, and every BTHome v2 object.

- **APRS:** telemetry with channel names, units and conversion, message
  numbers and acknowledgements, raw NMEA positions, rain and solar radiation.

- **Pager (DAPNET):** time signals, Skyper rubric news in plain text,
  transmitter IDs and DX cluster calls are named and decoded.

- **Wireless M-Bus compact frames:** meters that send only values (CI 0x79)
  are decoded once the app has seen one full frame from them; error and alarm
  frames show their code.

- **Aircraft on the ground:** taxiing aircraft at airports appear on the map
  with taxi speed and heading, marked “on the ground”.

- **Mode S Enhanced Surveillance:** radar replies now add callsign (also for
  aircraft without ADS-B), selected altitude, heading, indicated and true
  airspeed, Mach, bank angle – and the wind at the aircraft's altitude.

- **AIS weather stations:** coastal weather and tide stations (IMO 289
  met/hydro) show wind, temperature, pressure, visibility, water level,
  current, waves and water temperature.

- **DFM radiosondes:** temperature and battery voltage for DFM-09 and DFM-17,
  and a more precise model name.

- **DAB+ announcements and station time:** traffic, news, warnings and other
  announcements running in the ensemble are shown with the station carrying
  them, plus the time sent by the station.

- **TV programme guide:** what's on now and next, the station's channel
  number and its time.

- **LoRaWAN:** MAC commands (battery and link margin from device status), ADR
  and acknowledgement flags, and Cayenne LPP payloads in plain text.

- **ACARS weather:** METAR reports in datalink messages are broken down into
  wind, visibility, clouds, temperature and QNH; TAF forecasts show their
  validity.

- **METEOR recording time:** the status shows when the first and last image
  lines were taken, from the satellite's onboard clock.

- **More weather stations:** Fine Offset WH24/WH65B/WS69 (Ecowitt, Froggit,
  Misol and others) with wind, rain, UV and light, the WH25/WH32 indoor and
  outdoor sensors, WH2/WH5/Telldus thermometers and Oregon Scientific
  THGR122N/228N/968, THN132N and THGR810.

### Changed

- **Tables:** right-click a column header to hide or show columns; the layout
  is remembered per table, and spare width is now shared among all columns
  instead of truncating some.
- **Aircraft info card** stays at the left edge of the map instead of
  following the selected aircraft.
- **More accurate radiosonde humidity:** the RS41 humidity now uses the
  manufacturer's method (heated-sensor temperature, pressure correction) once
  the calibration data is complete, instead of an empirical approximation.

- **Short radiosonde flights leave the archive:** flights with fewer than 100
  reports (a random catch at the edge of range) no longer appear in the archive
  and are deleted once they have been silent for six hours.

### Fixed

- **Crash on Z-Wave sensor alarms** with sensor type 0xFF (any R1/R2 frame
  `9C 02 xx FF`), and a crash on DVB-T2 time-offset tables (TOT) shorter than
  14 bytes.
- **APRS raw NMEA** accepted `inf`/`1e5` as coordinates, which emptied the APRS
  tab in Remote Access for an hour; coordinates are now digits only and
  range-checked.
- **AIS weather stations:** wave height, wave period and water temperature were
  read from the wrong bits (they are now at 277/285/327 as in IMO SN.1/Circ.289).
- **Mode-S Comm-B identification (BDS 2,0)** accepted any reply as a callsign;
  invalid characters now reject it. Global CPR positions with latitudes beyond
  ±90° are discarded.
- **Firmware rescue (SPI)** checks the device's board ID against the chosen
  device type – a HackRF One image could be written to a HackRF Pro. The
  `hackrf` command is retried when the Mayhem console comes back, and
  installing is blocked while an SD transfer runs. SD downloads are CRC-checked.
- **English texts:** 17 German keys had conflicting translations; “Fahrt” for
  ships no longer reads “Airspeed”, “Netz” no longer “Mains”.
- **Remote Access:** a timer of an old connection could cut a new one;
  `/api/mode` gets 60 s more; quick taps no longer start several mode switches;
  viewers no longer see plan switches. AIS→UDP forwarding tracks the connection
  state and counts only successful sends. The SondeHub antenna field is empty
  by default (it is published).
- **Archive:** a corrupt full-text index is rebuilt instead of setting the whole
  archive aside; restoring a backup checks the database before copying files;
  recording names from backups are confined to the recordings folder; failed
  writes keep sightings in memory.
- **Reception plan:** a manual start during the sonde listening pause now asks
  and skips the window; device-unresponsive and stream-lost cases are no longer
  reported as “taken over”.
- **Control panel** no longer re-renders the whole page several times a second
  (counters and levels moved into child views on all pages); FT8 clock and
  ACARS sorting likewise.
- **DAB programme guide:** files are no longer re-parsed on every carousel
  round; size limits apply while collecting; `defaultContentId` is honoured.
- **Homematic smoke, water and motion detectors:** every sensor event was
  shown as a window contact – a smoke alarm read “open”. The app now learns
  the model from the device info and shows smoke alarm, dry/damp/wet and
  motion with brightness.
- **LoRaWAN:** the documentation no longer claims that OTAA joins are read
  along – join accepts are downlinks the receiver cannot hear. For OTAA
  devices, enter the session keys from your network server.

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
