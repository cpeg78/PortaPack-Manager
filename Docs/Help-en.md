# PortaPack Manager – Help

PortaPack Manager turns a **HackRF One with PortaPack** into a radio lab on
your Mac: aircraft and ships on the map, radio and TV, weather balloons and
satellite images, wireless sensors around the house – and on the side, it keeps
the device's Mayhem firmware up to date. The app decodes everything itself, no
extra software needed.

This help is also built into the app: menu **Help ▸ PortaPack Manager Help**
(⌘?) or the **?** button at the top right of every page.

<a id="start"></a>
## Getting Started

1. **Connect the PortaPack via USB and switch it on.** The app detects it
   automatically – the bottom left of the sidebar then shows “Mayhem mode”.
2. **Go through the initial setup** (appears on first launch, otherwise via
   Overview ▸ Device Controls ▸ “Initial Setup …”): choose your antenna, take
   over your location, calibrate the crystal. Takes about a minute.
3. **Click a tile on the start page**, for example “Aircraft”. The app switches
   to HackRF mode by itself and starts receiving.

The app sets gain, frequencies and channels for you – but you can still adjust
everything by hand.

### The Device's Two Modes

| Mode | What for | How to get there |
|---|---|---|
| **Mayhem mode** | The PortaPack runs on its own with its display. The app updates the firmware, manages the SD card and mirrors the screen. | Switch the device on normally, or “Back to Mayhem (Restart)” |
| **HackRF mode** | The Mac receives itself – for all receiver pages. | Automatically when you open a receiver page |

Switching takes a few seconds. If you don't want it to switch automatically,
turn off **Settings ▸ Antenna & Device ▸ “Switch to HackRF mode
automatically”**.

<a id="overview"></a>
## Start Page (Overview)

Start anything with one click here, and see how your device is doing.

- **What would you like to see?** – tiles for the most popular receivers. A
  click opens the page, switches to HackRF mode and starts. Green badges show
  what's going on right now (“8 now”, “2 in range”, “from 19:37”). Tiles carry
  the same name and icon as the page in the sidebar.
- **Connection** – which mode the device is in; **Technical Details**
  (collapsed) list firmware, serial number and radio chip.
- **Location** – your saved location; change it via “Settings …”.
- **Device Controls** – “Refresh Status” (⌘R), “Set Clock”, “Back to Mayhem
  (Restart)”, “SD Card as Drive” and “Initial Setup …”.
- **Troubleshooting** (collapsed) – “Reconnect USB” (helps when the connection
  hangs) and “DFU Mode …” (emergencies only, when the device no longer starts at
  all; switching it off and on returns to normal).

If a receiver, a Reception Schedule entry or Remote Access is running, restart,
mode switch, SD drive and “Reconnect USB” ask first (“Currently running: … –
anyway?”). DFU mode always asks.

If a scheduled recording is running, the tile asks before it takes over the
device.

<a id="empfang"></a>
## Receiving – How Every Receiver Page Works

All receiver pages share the same layout: a map, list or image on the left, the
**Controls** panel on the right (show or hide it with “Controls” at the top
right). The panel always lists its sections in the same order:

1. **Start/Stop** (for Radio and DAB+: “Play”), next to it **Clear** and, where
   available, **Archive …**.
2. **Channel** – frequency, band or channel, if the page offers a choice.
3. **Reception** – status line, “Optimize Signal”, gain (see below).
4. **Status** – counters and readings.
5. Page-specific options, then **Display** (sorting, tracks, filters).
6. **Data & Export** – databases, “Show in Finder”, save CSV/PCAP.
   Almost every page with a live list (aircraft, ships, ACARS/VDL2, APRS, DSC,
   radio sensors, pager, Meshtastic, LoRaWAN, Bluetooth, Wi-Fi, smart home,
   Zigbee, FT8/WSPR, FLARM) has **Save list as CSV …** there: a table with
   semicolons as separators, UTF-8, which Excel, Numbers and LibreOffice open
   directly. Times are in UTC, numbers use a decimal point. Keys (Zigbee,
   LoRaWAN, meters) never end up in the file.
7. **Note** – short tips on antenna and reception; on pages that receive other
   people's communication, also the legal note (see “Legal and Privacy”).

If you have hidden the Controls panel and an error occurs, it appears as a
narrow banner above the content – “Show Controls” opens the panel again.

### Keyboard and Input

- **Space** starts and stops reception on every receiver page (Radio and DAB+:
  Play/Stop). In Radio, **← →** change the frequency by one step, **↑ ↓** by ten.
- While the cursor is in a text field, Space and the arrow keys belong to the
  text field – so you can type safely.
- **Frequencies** are entered in MHz everywhere, with a comma or a point
  (“433.92” or “433,92”); “kHz” or “GHz” after the number works too. Invalid or
  out-of-range input is outlined in red, with the reason below.
- **Delete** removes the selected entry in lists that allow deleting
  (recordings, airband history, sonde archive, frequency memory, SD card) –
  after asking.

Deleting asks everywhere and says what will be lost: saved keys, recordings,
images, measurements. “Clear” only clears the list on screen; the saved station
list of DAB+ and TV is deleted with “Delete Station List …”.

General settings (location, notifications, online services …) live only on the
**Settings** page. A receiver page shows at most one line with a
**“Settings …”** button that takes you straight there.

### The “Reception” Section

- **Status line in plain language**, e.g. “Receiving – about 12 messages per
  minute” or “Nothing received for 5 min” – then with a hint at what might be
  wrong.
- **Optimize Signal** tries out gain settings and keeps the best one (a few
  seconds up to half a minute). The result is shown below it.
- **Adjust gain automatically** (on by default): if the receiver is overloaded,
  the app lowers the gain; if the signal is far too weak, it turns it up. This
  switch applies to all pages.
- **Manual settings** (collapsed) – the sliders:

| Slider | What it does | Rule of thumb |
|---|---|---|
| **LNA** (0–40 dB) | Input gain | Has the biggest effect on how weak stations come in – adjust this first |
| **VGA** (0–62 dB) | Post-amplification | Adjust next |
| **Built-in amplifier (+14 dB)** | Extra stage right at the antenna | Only for very weak signals; next to strong transmitters it overloads |
| **Antenna power (bias tee)** | 3.3 V on the antenna jack | **Only** for active antennas or preamps powered through it – otherwise something can break |

### Level

At the bottom left of the sidebar, a **level bar** shows how hard the receiver
is driven and which page the HackRF is currently receiving for. Green is fine.
Orange (“very loud”) is only a hint – as long as messages come in, all is well.
Red means **overloaded**: interference appears, and you receive less instead of
more. Then turn off the built-in amplifier first, then lower LNA, then VGA – or
use “Optimize Signal”.

### External LNA

If a wideband preamp sits in front of the HackRF, turn on **Settings ▸ Antenna
& Device ▸ “External LNA”**. All pages then start with less gain and without
the built-in amplifier; the bottom of the sidebar shows “External LNA on”.

### One Device, One Receiver

The HackRF can only receive for one page at a time.

- **Switching pages does not stop reception.** You can look around other pages
  while the receiver keeps running and collecting data. A **green dot** in the
  sidebar shows which one is receiving; the bottom says “Level for …”.
- If you start reception on another page, the app asks briefly: “… is running.
  Stop it and start …?” – **Switch** stops the previous receiver, **Cancel**
  leaves everything as it is.
- If the Reception Schedule is recording, “Switch” skips that entry – and your
  choice sticks: the receiver from before the entry does not come back. If the
  phone is using the HackRF (Remote Access), remote operation ends.
- Remote Access and Reception Schedule entries don’t ask – they take over the
  device themselves. The status line then says “The HackRF is currently
  receiving for …” – press **Start** to get it back.
- After a Reception Schedule entry, the receiver that was running before starts
  again by itself – including TV, Bluetooth, GPS or the hydrogen line. If you
  have started something else in the meantime, that stays.

<a id="antennaCheck"></a>
## Antenna Check

Tells you in about two minutes what your antenna is good for: “Good for FM,
aircraft, digital radio – marginal for ships”, plus specific tips (such as
“build a V-dipole for satellites”).

- **Start** measures all important bands one after another, **Stop** cancels.
- Only turn on **Antenna power (bias tee)** for active antennas.
- A receiver that was running before restarts by itself afterwards; during a
  scheduled recording, the check waits.
- **“No verdict”** only means that nobody was transmitting on that band at the
  moment (ships, weather balloons and satellites aren't on the air all the
  time) – not a bad sign.

<a id="spectrum"></a>
## Spectrum – “What's Transmitting Here?”

Shows everything transmitting in the chosen range (2–20 MHz wide) as a curve
and waterfall.

- Choose frequency and **bandwidth** at the top of the Controls panel, then
  **Start**.
- Click in the spectrum or the waterfall to tune there; **Presets** jump to
  well-known bands (FM, airband, ADS-B, Wi-Fi …).
- **Right-click** a signal: **Listen in Radio** opens Radio on exactly that
  frequency with a suitable mode (airband AM, FM broadcast WFM, 2 m/70 cm and
  everything else NFM). If the spectrum is still running, the app asks before
  switching. **Save** puts the frequency into the frequency memory.
- **Markers:** ⌥-click sets a marker (up to four); it snaps to the nearby peak.
  Under “Markers & max hold” in the Controls panel you see frequency and level,
  and from the second marker on the offset from marker 1 (kHz and dB). **Marker
  to peak** puts marker 1 on the strongest signal.
- **Max hold** keeps the highest level per frequency as a yellow line – so you
  also see short transmissions. **Reset** starts over, as does changing the
  frequency or bandwidth.
- “Auto scale” follows the noise floor.

Round frequencies such as 100.000 MHz often show a spur from the HackRF itself –
that's normal.

<a id="radio"></a>
## Radio

FM with **station names, radio text (RDS)** and stereo, plus AM, narrowband
FM (e.g. airband 118–137 MHz in AM) and, for amateur radio, **SSB (USB/LSB)** and
**Morse (CW)**.

- **Play/Stop** at the top of the Controls panel (space bar).
- Change the frequency in the large display on the left: digits with the scroll
  wheel or a click, ← → one step, ↑ ↓ ten steps. Choose mode and step in the
  Controls panel.
- **Quick tune with scan** finds all stations in a band (FM, airband,
  PMR446 …) and reads their names. They appear in the station list on the left –
  sorted by strength, name or frequency, saved frequencies on top.
- The **star** saves the current frequency with its mode and step to the
  **frequency memory** (top of the list on the left, switchable between “Radio”
  and “All”). Right-click an entry to edit or delete it.
- **Squelch** (AM/NFM) mutes the audio between transmissions.
- **Filter** sets the width of the receive filter: AM 6/9/10 kHz, SSB
  1.8–3 kHz, CW 250/500/1000 Hz; for NFM the channel spacing (6.25/12.5/25 kHz).
  Narrower rejects neighbours and noise, wider sounds fuller. FM is fixed.
- **SSB and CW:** USB for amateur radio above 10 MHz, LSB below. The volume
  adjusts itself (AGC). Tune in steps of 10 Hz to 1 kHz; for fine tuning use the
  scroll wheel over the smallest digits. In CW a precisely tuned station sounds
  at the chosen **pitch** (default 700 Hz).
- **Amateur radio presets** tune to the usual frequencies, e.g. 2 m SSB
  144.300 MHz, 70 cm 432.200 MHz or 10 m 28.500 MHz.
- **Shortwave** (below 30 MHz): the HackRF receives only from 1 MHz and is weak
  there. An upconverter or a long wire antenna works much better.
- **Record audio** (Data & Export) writes what you hear to a file – AAC (m4a,
  small) or WAV (lossless); FM in stereo, otherwise mono. The recording ends with
  “Stop recording” or Stop. Below are the latest recordings to play, show in
  Finder and delete.

Tip: while a strong FM station is playing, you can use it to measure the crystal
correction (Settings ▸ Antenna & Device, see the “Settings” chapter).

<a id="dab"></a>
## Digital Radio (DAB+)

Digital radio in top quality, with radio text (title, artist).

- The first time you open it, the app **finds all stations by itself** (1–2
  minutes). After that, just click a station in the list.
- **Scan** looks for new stations later, **Clear** forgets all found ones.
- Above the list, choose **By Ensemble** or **By Name**.
- The status line tells you how good reception is; individual values are under
  “Status”.
- **Record audio** (Data & Export) records the current station in stereo; the
  file name contains station and time.

Antenna: DAB+ is in Band III (174–240 MHz). A whip antenna of about 40 cm works
much better than the telescopic antenna.

<a id="tv"></a>
## Television (DVB-T2)

Free-to-air terrestrial TV (DVB-T2 HD) with picture and sound.

- The first time you open it, the app scans for all channels (about 1–2
  minutes). Later, start a scan with **Rescan Channels**; **Clear** forgets all
  found stations.
- DVB-T2 needs a **strong signal**. The status line shows how many data blocks
  arrive error-free. Below about 80 % the picture stutters – then only a better
  antenna helps (roof, window facing the transmitter); more gain usually
  doesn't.
- Private channels (freenet TV) are encrypted and stay dark.

<a id="adsb"></a>
## Aircraft (ADS-B)

Aircraft within radio range on the map – with registration, type, airline,
route and photo.

- **Start**, then click an aircraft to open its info card.
- **Aircraft database** (load it under “Data & Export” with **Refresh**,
  ≈ 95 MB): registration and type even without internet. If you like, the app
  looks up unknown aircraft, routes and photos online – turn this on under
  **Settings ▸ Online Services**.
- Under **Display**: metric units, flight tracks and **Show airports**.
- **Airports** on the map: large airports as filled circles, small airfields
  as rings, heliports (“H”) only when zoomed in closely. Click one for its
  name, town and elevation. Load the list (OurAirports, 12 MB) once under
  “Data & Export” with **Load Airports** – your location is not sent. In
  Remote Access, the circle button on the left of the map turns them on and
  off.
- **Archive …** – all sightings per day or across all days, with track and
  photo, exportable as CSV. Click a column header to sort.
- For distance and bearing, the app needs your location (Settings ▸ Location).

Range: indoors often just a few kilometers, with an outdoor antenna 100 km and
more.

<a id="acars"></a>
## Aircraft Datalink (ACARS & VDL2)

Text messages between cockpit and ground – position reports, weather, departure
times, controller clearances (CPDLC).

- Under **Channel**, choose the mode: **VDL2** (common in Europe, the default)
  or ACARS with its channels. Then **Start**.
- The **Meaning** column translates the abbreviations into plain language. A
  click opens the detail card, including “Show on ADS-B Map”.
- Under **Display ▸ Sorting**, **Important First** moves controller messages
  and positions to the top, **By Aircraft** groups the messages of one
  aircraft. Filters hide empty acknowledgements and ATN traffic.

<a id="ais"></a>
## Ships (AIS)

Ships on the map with name, type, destination, arrival time and photo.

- **Start** – only receivable with a **line of sight to a coast, river or
  harbor**; inland you'll usually get nothing.
- Turn tracks on under “Display”, photos from the web (Wikimedia Commons) under
  **Settings ▸ Online Services**.
- **Archive …** works like for aircraft.

<a id="aprs"></a>
## Radio Amateurs (APRS)

Position and weather reports from radio amateurs on 144.800 MHz, on the map.
Depending on your area, only a few packets arrive per hour. With **Listen to
Channel** you hear the packets as chirps; turn tracks on under “Display”.

<a id="pager"></a>
## Paging (POCSAG)

Pager messages from the amateur radio network **DAPNET** (439.9875 MHz).

> **Important:** In Germany, listening to or passing on alerts from fire
> brigades, ambulance services and police is prohibited (§ 5 TDDDG). That's why
> the app deliberately offers only DAPNET and stores nothing.

<a id="planner"></a>
## Reception Schedule

Receives **weather satellites, amateur satellites and weather balloons
automatically** – even at night, and even while another receiver or Remote
Access is running (which then carries on by itself afterwards). You'll find the
schedule in the sidebar under “Tools”; the METEOR, Amateur Satellites and
Weather Balloons pages lead here with “Reception Schedule …”.

### How It Works

1. Enter your **location** – without it there's no prediction (“Settings …”
   takes you there).
2. For each area, turn on the **“Receive passes automatically”** or
   **“Receive launches automatically”** switch; for amateur satellites, also
   choose which ones.
3. Keep the Mac awake and the app open – while a schedule is on, the app
   prevents sleep.

### Good to Know

- **Satellites:** The list shows passes for the next 48 hours with their
  elevation; recording happens above the minimum elevation you set, from one
  minute before rise until after set.
- **Weather balloons** launch at fixed times (usually 0 and 12 UTC, some
  stations also 6 and 18). The schedule only switches over when SondeHub
  actually reports a balloon in range, and shows beforehand where it's likely to
  drift.
- **A sonde window follows reception:** If a balloon can still be heard at the
  planned end, the window keeps running until nothing has come in for
  5 minutes. If a balloon has landed or left the range (10 minutes of silence),
  or none shows up at all for 30 minutes, the window ends early – and whatever
  was running before starts again.
- **Priority** when entries overlap: METEOR, then amateur satellites, then
  radiosondes.
- **Skip** ends a running recording – in the red banner at the bottom, on this
  page or in Remote Access. The entry won't start again, and the previous
  reception carries on.
- **After every entry**, whatever was running before starts again – whether
  aircraft from the phone or TV on the Mac. If you tap Stop on the phone or
  start something yourself in the meantime, nothing comes back by itself.
- Results appear in the **History**. If you like, the app notifies you
  (Settings ▸ Notifications).

<a id="sonde"></a>
## Weather Balloons (Radiosondes)

Weather balloons transmit position, altitude (up to more than 30 km),
temperature and humidity between 400 and 406 MHz. The app scans the band by
itself and listens to up to four sondes at once.

- **Start** at launch time – or more conveniently, let the **Reception
  Schedule** catch the balloons automatically.
- **History** below the map and list: altitude, climb rate, temperature and
  humidity of the selected sonde over time, plus the **Profile** (temperature
  and humidity over altitude, ascent only).
- **Landing estimate** roughly shows where the balloon will come down during
  descent. For recovery, the predictions on SondeHub are more accurate.
- **Archive …**: all flights received so far with peak altitude, duration and
  distance. A click shows track and history; “Save CSV …” saves a flight, “On
  SondeHub” opens it there. **Delete** (button, right-click or the Delete key)
  removes a flight after asking; a flight that is still being received can only
  be deleted afterwards. Every report recorded by the Reception Schedule goes
  into the archive.
- If you know the frequency of a sonde the scan doesn't find, you can **pin**
  it under “Channels”.
- If a constant interferer at your location keeps taking a scan slot, add it in
  Settings under “Antenna & Device ▸ Weather balloons: constant interferers”.
  (a frequency or a range in MHz). The list is empty by default; “Factory
  Defaults” empties it again.

Range: high-flying balloons can often still be heard at 200 km, low-flying ones
up to about 100 km. Put the antenna as high as possible and outdoors, with a
short cable.

<a id="meteor"></a>
## Weather Satellite (METEOR)

Weather images straight from the Russian satellite METEOR-M (137.9 MHz) as it
passes over you.

- **Passes** shows the next times. Set up automatic recording in the
  **Reception Schedule** (“Reception Schedule …” button).
- The app saves finished images as PNG; **Show in Finder** under “Data &
  Export” opens the folder.

You need a **satellite antenna** with a clear view of the sky: a V-dipole (two
53 cm rods at a 120° angle, horizontal) or a QFH. Telescopic and scanner
antennas barely hear the satellite. Below about 20° elevation, a simple antenna
rarely gets an image.

<a id="flarm"></a>
## FLARM/OGN (Gliding)

Collision warning devices of gliders on 868.2 MHz. The app recognizes the
frames but can't read the (obfuscated) position. Only near airfields and in
flying weather, mostly on weekends.

<a id="sensors"></a>
## Wireless Sensors

Weather stations, wireless thermometers, tire pressure sensors and other
devices on 433 and 868 MHz. Most of them transmit every 30–60 seconds.

- Choose the **band** at the top of the Controls panel (433.92 or 868.30 MHz),
  then **Start**.
- Under **Display** you can search by model, ID or value, sort, and hide
  **Tire pressure (TPMS)** – the sensors of passing cars (hidden at first).

<a id="ble"></a>
## Bluetooth Devices

All Bluetooth LE devices nearby with manufacturer and kind (trackers, watches,
sensors, headphones …). At the top, choose the **advertising channel** (37, 38,
39 or alternating). Many devices change their address about every 15 minutes
and then show up as new.

<a id="zigbee"></a>
## Zigbee (Smart Home)

The radio traffic of your Zigbee network (e.g. Zigbee2MQTT, Hue, IKEA):
devices, network map and readings.

### How It Works

1. **Channel Search** finds your network's channel (or choose the channel by
   hand), then **Start**.
2. To read the contents, enter the **network key** – easiest with “Import
   Configuration …” from Zigbee2MQTT. Then you'll see switches, temperatures,
   motion sensors. Keys are stored only in your Mac's keychain.

### Network Map

The coordinator sits in the center, well-connected devices are close together,
devices without a known link sit on the outer ring. The two best links per
device are shown; “All Links” shows all of them.

- **3D:** drag to rotate, scroll to zoom, click to select a device and show its
  links.
- **2D:** scroll to zoom, drag to pan, double-click to reset.
- If the app hears several networks, choose one at the top under “Network”.

### Tips

- **Thread/Matter** is recognized. You'll find the Thread key in Home Assistant
  in `/config/.storage/thread.datasets`. Thread often uses a different channel
  than Zigbee.
- **Save PCAP …** under “Data & Export” writes the capture for Wireshark.
- The **Wi-Fi** page shows which channel is free (“Show Zigbee Channels”).

<a id="wifi"></a>
## Wi-Fi

Shows the Wi-Fi networks around you and how busy each channel is – with a
recommendation for the freest channel, for Zigbee too – and, if you like, the
management frames for Wireshark.

- Choose the **mode** at the top: measure occupancy or capture frames, then
  **Start**.
- Save captured frames under “Data & Export” with **Save PCAP …**.
- **Search Networks** (section “Networks (Mac Wi-Fi)”) queries the Mac's Wi-Fi
  and works even without a PortaPack.

<a id="drones"></a>
## Drones (Remote ID)

Newer drones broadcast an **electronic ID** with position, altitude and the
pilot's location – via Bluetooth and Wi-Fi. The app listens on all paths at
once, through the HackRF and the Mac; choose which ones at the top under
“Sources”. Turn flight tracks and pilot position on under “Display”. You'll
only get hits when a drone is flying nearby.

<a id="meshtastic"></a>
## Meshtastic (LoRa)

Messages and positions from the Meshtastic network (869.525 MHz, LongFast). The
public default channel is decrypted, your own channels with their key; direct
messages stay private. Set region, preset, key and frequency at the top under
**Channel**.

<a id="lorawan"></a>
## LoRaWAN Network

Sensors on LoRaWAN (e.g. The Things Network) on 868 MHz. The app listens to all
spreading factors at once. Only **your own** devices are readable, whose
session keys (ABP) you store under “Data & Export”.

<a id="smartHome868"></a>
## Smart Home 868 MHz

Radio traffic from smart home devices and wireless meters around 868 MHz – all
at once:

| Protocol | Typical devices |
|---|---|
| Z-Wave | Switches, thermostats, sensors, smart plugs |
| Homematic | Radiator thermostats, window contacts, weather sensors |
| EnOcean | Battery-free switches, room sensors, window contacts |
| Wireless M-Bus | Water, heat, electricity and gas meters, heat cost allocators |

> Only analyze **your own** devices. Reading, storing or passing on the radio
> traffic of other people's devices – such as your neighbors' meters – is not
> allowed.

### How It Works

- **Start** – the **devices** appear at the top with their last value and
  level, below them the individual **frames** (a click shows all fields). If
  you select a device, you only see its frames; “All Frames” clears that.
- Under **Protocols**, turn off what doesn't interest you.
- Many devices only transmit on changes or every few minutes; meters every
  15 seconds to 15 minutes.
- A lock indicates **encrypted** contents (Z-Wave S0/S2, Homematic IP, meters
  without a key).

### Keys for Wireless Meters

You get your meter's key from your utility, landlord or manufacturer. Enter it
under “Data & Export” in **Meter Keys**: meter number (8 digits, printed on the
meter) and key (32 characters 0–9/A–F). It's stored only in your Mac's
keychain.

### EnOcean Sensors

Temperature and humidity sensors don't say over the air how to read their
values. If you teach in a sensor while the page is running, the app detects its
profile by itself. Otherwise select the device and set the profile from the
manual under **EnOcean Profile** (e.g. A5-04-01).

<a id="airband"></a>
## Airband

A scanner for aviation voice radio (118–137 MHz, AM). The app listens to **all
channels in your list at once**: as soon as someone talks on one, you hear
them – if several talk at once, the loudest.

### How It Works

1. Under **Add Channel**, enter the channel as shown on charts (e.g. “118.005”
   or “121.5”), plus a name (“Tower”). The emergency frequency 121.5 MHz is
   already in the list.
2. **Start**.

### In the Channel List

- **Star = priority:** interrupts any other channel.
- **Lock = lock out:** never audible – good for continuous transmitters such as
  ATIS.
- **Hold** (pause button in the row or next to Start): listen to this channel
  only, until “Resume”.
- **Squelch:** the app learns each channel's noise by itself; the slider sets
  how far above it a signal must be. Lower = more sensitive, but more false
  alarms.
- **Span:** the app listens to 8 MHz at once. If your channels are spread
  further apart, turn on “Wide span (16 MHz)” before starting (needs more
  processing power). The Controls panel lists channels outside the span.

### Finding Active Channels

The search sweeps the whole band and remembers where people talked. “Listen per
window” sets how long it stays at each spot – longer also finds rare channels.
Finds appear on the left with their number of transmissions; right-click ▸ “Add
Channel to List” to take one over. A channel that's busy almost all the time is
usually ATIS/VOLMET or interference.

### History and Recordings

- The **History** shows every transmission with time, channel, duration and
  strength. **Count voice only** (on by default) hides clicks and carriers
  without audio.
- **Record transmissions** (off by default) saves every transmission as an
  audio file to play back (▶ in the history). The files stay on your Mac (“Show
  in Finder”); **Clear …** removes history and recordings.
- The page shows the last 1000 transmissions; recordings are kept only for
  these. Older entries (without audio) stay in the archive until the retention
  period removes them.

### Transmissions as Text

Turn on “Convert transmissions to text” under **Detection**, and the app
writes every transmission as text into the **Text** column of the history.
Recognition runs on your Mac only – nothing leaves the computer. You don't
need to record anything: the audio stays in memory only briefly.

- **Language:** English for regular radiotelephony, German for VFR traffic at
  small airfields and rescue helicopters. “Automatic” tries both and keeps the
  more confident result.
- The first time you turn it on, macOS downloads the speech model once (the
  progress shows in the control panel). On macOS 15 the system also asks for
  permission to use speech recognition.
- **Faded text** means the recognizer was unsure. Hover over the text to see
  the raw text exactly as the recognizer delivered it. The column already shows
  number words as digits (“flight level eight zero” → “flight level 80”, “one
  two three decimal eight seven five” → “123.875”).
- A **blue callsign** in front (e.g. DLH4AB) means the transmission mentioned
  an aircraft the app knows from ADS-B – from the running ADS-B page or the
  sightings of the last three hours. Right-click ▸ “Show aircraft …” jumps to
  the map.
- **Search:** the field above the history searches the text of all stored
  transmissions, including older ones. Several words must all appear; a
  callsign such as “DLH4AB” also finds the transmissions in which it was
  recognized.
- Right-click to copy the text or the raw text.
- If more transmissions arrive than the Mac can handle, the oldest waiting ones
  are dropped (“Dropped” in the control panel). Transmissions shorter than 0.8
  seconds aren't recognized.

Don't expect a perfect transcript: airband radio is fast, noisy and full of
jargon. Numbers, runways and flight levels work well; airline names and
spelled letters often go wrong with a weak signal.

Range: aircraft in the air often 100 km and more, the ground (tower, apron)
usually only near the airport.

> **Legal:** Airband radio isn't intended for the general public. Whether merely
> listening is allowed is viewed differently in Germany; what's clearly
> prohibited is passing on contents or even the fact of reception (§ 5 TDDDG).
> That's why the app shares nothing, and recordings stay on your Mac. Listen
> for yourself only.

<a id="vor"></a>
## Radio Beacons (VOR)

VOR beacons (108–118 MHz) tell any receiver in which direction from the beacon
it is – the **radial**. The app measures the radial, reads the Morse
identifier and works out your location from two beacons.

### How It Works

1. The first time, click **“Load Database”** (button in the empty list): all
   beacons from OurAirports, ≈ 3 MB. Later, update it under “Data & Export”
   with **Refresh**. Your location isn't sent.
2. The beacons nearest to your location are listed at the bottom. A click (list
   or map) tunes to it. Without the database, enter the frequency by hand.
3. **Start** – the large number is the radial in degrees, relative to magnetic
   north as usual in aviation; below it the true bearing.

### What You See

- **Quality:** “good” when the signal is clean and the radial barely wavers.
  With “unusable”, the beacon is too far away or disturbed.
- **Identifier:** the three Morse letters; “matches” if they belong to the
  selected beacon. “Play Tone” plays them.
- **Cross bearing:** once the quality is steady, the app remembers the radial.
  Choose a second beacon – both lines and their intersection appear on the map.
  Most accurate at roughly a right angle; below 30° the app warns you.

Range: on the ground often only 30–80 km, more with an antenna outdoors and up
high.

> Just for experimenting – don't use it for navigation.

<a id="dsc"></a>
## Maritime Distress (DSC)

Ships and coast stations call each other digitally on **VHF channel 70
(156.525 MHz)**. This is also where **distress calls** go: the red button on a
radio sends the ID (MMSI), the nature of the distress and the position. The page
listens to channel 70 and shows every call.

- **List:** distress calls are shown in **red**, urgency in orange, safety in
  yellow. “Rep.” counts repeats – a distress call repeats every few minutes.
- A click shows all details (sender and recipient with country, nature of
  distress, position, follow-up channel). Calls with a position appear on the
  map.
- **Ship names** come from AIS: if the AIS page or its archive of the past week
  knows the ship, its name is shown instead of the number.
- **Notification** on a distress call: Settings ▸ Notifications.

Most calls are tests and routine calls. Only receivable with a line of sight to
a coast, river or harbor, ideally with an antenna for the marine band. DSC and
AIS don't run at the same time.

> **Important:** **Never answer a distress call yourself** – that's the job of
> the rescue coordination center (Bremen Rescue) and ships nearby. The app
> doesn't transmit anything anyway. Don't pass on contents. If you witness an
> emergency yourself, dial **112**, or **124 124** from sea.

<a id="amateurSat"></a>
## Amateur Satellites & ISS

Images and radio packets from space: on certain days the ISS sends **SSTV
images**, its APRS digipeater almost always relays packets from radio amateurs,
and small satellites send **telemetry**.

### How It Works

1. Choose the **satellite** at the top. **Passes** shows when it's above the
   horizon.
2. Press **Start** when it rises – or turn on “Receive passes automatically” in
   the **Reception Schedule** (“Reception Schedule …” button).

| Satellite | Frequency | What you get |
|---|---|---|
| ISS | 145.800 MHz | SSTV images (only during ARISS events) |
| ISS | 145.825 MHz | APRS packets |
| PCSAT (NO-44) | 145.827 MHz | APRS packets, only at times |
| GRBBeta | 436.785 MHz | Telemetry |

For the ISS, the app listens to SSTV and APRS at once. Under **Custom
Satellite** you can add more (catalog number, frequency, mode).

### ISS SSTV Images

- SSTV runs **only on announced dates** – ARISS announces them on its website.
  Otherwise 145.800 MHz is silent.
- The app detects the start of an image by itself and shows it line by line. So
  start in good time before the pass – no image start, no image.
- Finished images go to the **Gallery** at the bottom (double-click to open) and
  as PNG to the “SSTV” folder (“Show in Finder”). Incomplete images are named
  “_partial”.

### Packets

Each packet appears under “Frames” with sender, recipient and contents
(right-click to copy). **Clear** empties the list; the gallery stays.

### Antenna

For the ISS, a **2 m antenna** with a clear view of the sky is enough (ground
plane, dipole or small Yagi). The higher the pass (from about 30°), the better.
For GRBBeta you need a 70 cm antenna. **Doppler correction** compensates for
the frequency shift as the satellite passes; this requires your location to be
set.

<a id="ft8"></a>
## Amateur Radio FT8/WSPR

Radio amateurs exchange short messages with **FT8** (call sign, locator,
report) and send beacons with **WSPR**. Both still get through far below the
noise – that's why you'll often see stations hundreds of kilometers away. The
app only receives and doesn't report anything.

### How It Works

1. Choose the **band** (2 m, 6 m or 70 cm).
2. Choose the **mode**: FT8, WSPR or both. **Deep decoding (OSD)** finds even
   weaker FT8 signals.
3. **Start**. After each cycle the stations heard appear: every 15 seconds for
   FT8, every two minutes for WSPR.

### What You See

- **List** with time (UTC), SNR (around −20 dB is normal for FT8), message and –
  if the locator is known – distance and bearing. CQ calls are green; “Show CQ
  calls only” hides the rest.
- **Map** with all stations; a click draws a line from you.
- **Waterfall** of the last minute (FT8) or two minutes (WSPR); green frames
  mark decoded signals.

### Tips

- **Antenna** for the chosen band, outdoors and up high – otherwise FT8 on 2 m
  often stays quiet. 6 m is busiest in summer.
- **Clock:** FT8 only tolerates about ±2 seconds of error. If your Mac's clock
  is off, the app shows a hint. To fix it: System Settings ▸ General ▸ Date &
  Time ▸ “Set time and date automatically”.
- **Crystal:** for WSPR, crystal calibration is worth it (Settings ▸ Antenna &
  Device). Without it, the app searches more widely, and the hertz values shown
  won't be exact.
- **Warm-up:** a HackRF without a TCXO drifts during the first 15–20 minutes
  after power-up – on 2 m easily a few tens of hertz per minute. Let it warm up
  first, or use a TCXO or an external 10 MHz clock on CLKIN (the app shows under
  “Note” whether one is detected).
- **Track crystal drift** (on by default): once the app hears at least three
  stations more than once, it estimates from their frequencies how far the
  HackRF has drifted since the start and shifts the audio band back. “Status”
  then shows “Drift: … Hz/min” and “offset since start”. This doesn't replace
  crystal calibration – it only measures the change since the start.

<a id="hydrogen"></a>
## Hydrogen Line

Radio astronomy with the HackRF: hydrogen gas in the Milky Way radiates at
1420.4 MHz. From the shift of the line, you can read how fast spiral arms are
moving toward or away from us.

### What You Need

- A **dish** (about 1 m or more) or a **horn antenna** for 1420 MHz – a whip
  antenna isn't enough.
- Right at the antenna, a **low-noise preamp with band filter** (“H-line LNA”),
  powered via **Antenna power (bias tee)**. Without it you won't see anything.

### How It Works

1. Enter your **location** (Settings ▸ Location).
2. Enter the antenna's **azimuth and elevation** (0° north, 90° east). The link
   “Milky Way at its highest” takes over the direction in which the line is
   usually strongest.
3. **Start** and wait – ten minutes is a good start; longer means less noise.
   The measurement is saved automatically at the end.

### What You See

- The curve over **velocity** (km/s, positive = receding) or **frequency**.
  Earth's and the Sun's motion are already taken out.
- **SNR** at the top: from about 5, the line is definitely there.
- **Smoothing** and **Baseline** make the curve calmer.
- Under “Data & Export” you save **measurement series**, overlay several of them
  and export them as CSV – even with no device connected.
- **Start Over** starts from scratch. If you leave the page, the measurement
  keeps running; if another page takes the HackRF, it pauses until **Resume**.

Gain is deliberately not adjusted automatically here – it has to stay the same
during the measurement. A level around −30 dBFS is ideal.

### Technical Details

There are two **methods**: frequency switching (the HackRF alternately listens
next to the line, nothing else to do) and reference measurement (first point at
“empty” sky or a 50 Ω termination and **Record Reference**, then aim at the
source). The velocity refers to the local standard of rest (LSR).

<a id="cells"></a>
## Cell Towers (LTE)

Searches for the LTE base stations (4G) around you and shows what they broadcast
for every phone: cell number, bandwidth, level and – if it works – network
operator and cell ID.

> Only the base station's public broadcasts are read. The app doesn't receive
> calls, data or signals from phones.

### How It Works

1. **Connect an antenna.** The telescopic antenna works for 800/900 MHz; for
   1800–2600 MHz a short cellular antenna is better. By a window you'll find
   much more.
2. Choose the **bands** at the top and press **Start** (“Start Scan”). Each band
   takes a few seconds; progress and spectrum are shown at the top.
3. If **“Read network operator (SIB1)”** is on, the app checks every cell found
   individually and reads operator and ID.

If the scan misses something, enter the frequency (e.g. 806) or channel number
(EARFCN, e.g. 6300) under **Single Frequency**. The scan sets the gain per band
by itself.

### What the Columns Mean

| Column | Meaning |
|---|---|
| Band, EARFCN, MHz | Frequency band, channel number and frequency |
| PCI | Cell number (0–503), distinguishes neighboring cells |
| Width, Ant. | Bandwidth and number of transmit antennas |
| RSRP | Level in dBFS – relative, not a calibrated value |
| Quality | SNR; green from 13 dB, orange from 3 dB |
| Operator, TAC, Cell ID | Network operator, area and site/sector (from SIB1) |

A dash under Operator means: not read without errors; the reason is in the
tooltip.

### Watching a Cell

Select a cell and press **“Watch Cell”**: the app continuously records level
and quality – that's how you align an antenna or find the best spot by the
window. The “Crystal residual error” under “Status” also shows how accurate your
crystal calibration is.

<a id="occupancy"></a>
## Occupancy Monitor

Who's transmitting when, and on which frequency? The Occupancy Monitor watches
a band for **hours or days** and shows how often each channel is busy.

### How It Works

1. Under **Band**, choose a preset (433 MHz, 868 MHz, 2 m, 70 cm, PMR446,
   airband, marine, Freenet, CB radio) or enter From/To yourself. The **Grid**
   sets how finely the frequencies are divided.
2. **Start** – and let it run.

### What You See

- **Heat map:** newest time at the top, bright = busy. Drag to pan, scroll to
  move through time, ⌘ + scroll zooms the frequency, ⌥ + scroll the time.
- **Occupancy per Frequency** and **Most Active Frequencies** with their latest
  transmission times.
- A click selects a frequency; **Listen in Radio** (or double-click in the list)
  opens it in Radio – the monitor then pauses.

**Threshold** (default 10 dB above noise) sets when a channel counts as busy;
**Time slice** (e.g. 1 minute) sets how finely time is stored; **Heat map
shows** chooses occupancy, peak or average.

### Recording and Export

- Every measurement is saved continuously and survives a restart:
  **Resume** appends, **Start Over** starts a new one.
- Under “Data & Export” you open **saved recordings** (even without a device),
  limit the **Maximum file size** and export CSV and PNG.
- The monitor keeps running when you leave the page. If you start another
  receiver page, it pauses until **Resume**.
- Gain stays fixed during a recording so the values remain comparable over
  hours.

<a id="dcf77"></a>
## Radio Clock (DCF77)

The time signal from Mainflingen, Germany (77.5 kHz) – compared against your
Mac's clock. Needs a long wire antenna or an active loop antenna; ordinary
antennas and the ferrite antenna of a radio clock barely pick up the signal.

- **Seconds of the current minute:** one box per second – gray = 0,
  blue = 1, green = minute marker, red = unreadable. After a complete minute,
  date and time appear at the top, along with how far the Mac's clock is off.
- **Envelope (last 20 s):** the signal strength with one tick per second.
  Every second the carrier dips briefly – 100 ms for a 0, 200 ms for a 1; in
  the last second of the minute the dip is missing (minute marker).
- Under “Carrier 77.5 kHz” and “Second pulse” you find the SNR, “Marker depth”
  and how many minutes were valid. If the second pulse stays “searching”, the
  signal is too weak or disturbed – often by power supplies, chargers or
  monitors nearby.

Minutes with a leap second (61 seconds long, announced beforehand) are read
correctly too.

<a id="gps"></a>
## GPS Positioning

Determines your position straight from the GPS satellites. Best with an
**active GPS antenna with a clear view of the sky** – turn on “Antenna power
(bias tee)” for it. The first fix takes about a minute. **Use as My Location**
takes it over for all maps.

### Weak Signals (Window, Balcony, Trees)

- The **weak-signal search** (under “Manual settings”, on by default) looks for
  satellites the fast search misses, using long integration. It finds
  satellites about ten times weaker than the fast search; this costs some
  computing time, and the first fix then rather takes two minutes.
- A satellite marked **“weak”** is tracked with long integration – it still
  counts for the position, just slightly less accurately.
- The app remembers orbit data, almanac and the last position. On the next
  start it uses them to predict which satellites are in the sky and searches
  specifically (“Search: targeted …”). Without a stored position it uses your
  location from Settings. If the orbit data is less than two hours old, the
  first fix arrives after a little more than ten seconds (**hot start**).

> Deep inside a building it usually still isn't enough. The closer to the
> window and the more open sky, the better – and an active antenna always helps.

<a id="recorder"></a>
## Recording

Record raw data (IQ) and analyze it later – to examine something at your
leisure or to pass a recording on.

- Choose a **preset** (ADS-B, GPS, DVB-T2 channel, DAB block, Zigbee channel) –
  it sets frequency and sample rate to match. “Status” shows the data rate and
  maximum duration.
- **Start Recording**; later **Play & Analyze** (Spectrum, ADS-B, GPS, DVB-T2,
  DAB+, Zigbee) – this works even with no device connected.

### SigMF – exchanging recordings with other programs

SigMF is the common format for IQ recordings: the samples in `.sigmf-data`,
next to it a small description `.sigmf-meta` (sample rate, frequency, time,
device). GNU Radio, inspectrum, SigDigger and many other programs read it.

- **Record as SigMF** (under “Data & Export”) writes new recordings in this
  format right away.
- **Export as SigMF …** (context menu of the recording or button under
  “Data & Export”) saves an existing recording as the two files.
- **Open SigMF …** adds a recording from elsewhere to your list – choose the
  `.sigmf-meta` file; the `.sigmf-data` must be next to it. Supported are
  `ci8` (HackRF), `cu8` (rtl_sdr), `ci16` and `cf32` (e.g. GNU Radio); wider
  formats are converted to 8 bits so that the loudest part at the beginning
  fits the range well. Unpack a `.sigmf` archive in the Finder first.
- The decoders need the sample rate and centre of their preset. If a recording
  from elsewhere fits none of them, the app tells you after opening – the
  spectrum always works.

> The description contains device and software, but **never your location**.
> If a file from elsewhere brings a location along, the app does not import it.

<a id="remote"></a>
## Remote Access (Phone, On the Go)

A web page for phone and tablet with almost all of the app's receivers – map of
aircraft and ships, radio with sound, weather, smart home and more. Turn it on
under **Settings ▸ Remote Access**.

### How It Works

1. **“Turn On Remote Access”**.
2. Open one of the **addresses** on your phone – easiest via **QR code**. The
   address contains the access key; without it the page shows nothing.
3. On iPhone, add it as an app via “Share ▸ Add to Home Screen”.

**On the go, via VPN only:** install Tailscale on your Mac and phone and use
the Tailscale address (100.x.y.z) – or dial into your home network via VPN (e.g.
the FRITZ!Box's WireGuard). **“Home network and VPN only”** is on by default:
the Mac only accepts devices from your own network (IPv6 included) and from the
VPN and rejects everything from the internet right away. Port forwarding on your router
therefore won't work – and wouldn't be a good idea anyway, as the page and sound
would travel unencrypted. If macOS asks about incoming connections the first
time, confirm with “Allow”.

### Using It on Your Phone

- At the top left, the button with the receiver's name opens the menu with all
  tabs: Aircraft, Aircraft Datalink, Airband, Ships, Maritime Distress, Weather
  & Satellites, Digital Radio, Radio, Spectrum, Occupancy Monitor, Wireless
  Sensors, Smart Home 868, Zigbee and FT8/WSPR.
- **Start** switches the HackRF to this receiver, **Stop** ends it. The square
  at the top right ends any reception – including one started on the Mac, and
  nothing starts again by itself afterwards. The antenna next to it is
  “Optimize Signal”.
- For Radio, Digital Radio and Airband, **Listen Here** plays the sound on your
  phone; **Mute** only turns off the sound, reception continues.
- Tap a box's heading to expand or collapse it.
- The frequency memory, the airband channel list and the Reception Schedule are
  shared between Mac and phone. The Radio tab lists the frequency memory to tap
  and tune; editing and deleting happen on the Mac. Under **Weather & Satellites** you turn the Reception
  Schedule on and off and skip entries.

### Good to Know

- While Remote Access is on, the Mac stays awake.
- **Regenerate** creates a new key and locks out all pages opened so far. The
  browser remembers the key and removes it from the address bar – so a
  screenshot won't give it away.
- Keys (Zigbee, meters) are never transferred via the web page; you enter them
  on the Mac.
- **Last rejected** shows when someone from outside tried to connect. If your
  VPN uses unusual addresses, you can turn off “Home network and VPN only”.
- If the keychain can't be read at some point, Remote Access pauses and says so
  under Settings ▸ Remote Access. As soon as the key can be read again, it
  resumes by itself – with the same key, your phones stay signed in.

<a id="sharing"></a>
## Share Data

Pass received data on to community networks or your Home Assistant. You'll
find it under **Settings ▸ Share Data**; everything is **off** until you turn it
on. Data is only sent while the respective page (or Remote Access or the
Reception Schedule) is receiving.

- **Aircraft (ADS-B)** to adsb.fi, airplanes.live or your own targets – without
  your location. Optionally with a random station ID by which the services
  recognize you (airplanes.live requires it).
- **Ships (AIS)** as NMEA to AISHub, MarineTraffic, VesselFinder or similar –
  the service gives you address and port when you sign up.
- **Weather balloons** to SondeHub (needs a call sign; location only if you
  choose, rounded to about 1 km).
- **Home Assistant (MQTT):** wireless sensors, Smart Home 868 MHz, Zigbee
  devices, radiosondes and the number of aircraft to your own MQTT broker; Home
  Assistant creates the devices by itself. With “Only devices with …” you pass
  on selected devices only – please leave out other people's devices (your
  neighbor's weather station). Without this list, at most 20 new devices per
  hour go to Home Assistant (a few more at the start) – so nobody can create
  hundreds of made-up devices over the air. The form counts devices held back;
  add them to the list and they come through right away. Devices pushed out
  (more than 1000) are also removed from Home Assistant. Without TLS, user name
  and password travel in plain text – the form points this out.

What the app *fetches* from the internet (aircraft data, photos) is set under
Online Services.

<a id="firmware"></a>
## Firmware

Keeps the PortaPack's Mayhem firmware up to date – Nightly (new every day) or
Stable.

### How It Works

1. Choose the **channel** at the top (Nightly or Stable), a release on the
   left, then **Install**.
2. The app downloads the package, verifies it, copies it to the SD card and has
   Mayhem flash it. **Don't unplug the device meanwhile.** While it is only
   downloading, “Cancel Download” stops it – nothing on the device has changed
   yet.
3. The device restarts, and the app checks the new version.

If the device is in HackRF mode, the page offers “Back to Mayhem Mode”.

### Other Options

- **Update Apps Only** – refreshes the apps on the SD card.
- **Fully Refresh Device** – firmware **and** all files on the SD card
  (≈ 25 minutes via “SD over USB”). If ejecting hangs along the way: switch the
  device off and on and choose “Finish Refresh”.
- **Local File …** installs a downloaded package.
- **Device type:** if the device doesn't report a type (older firmware), the
  page asks for it – please choose correctly (HackRF One / Pro / PortaRF).
- **Erase and Rewrite Flash** (under “Method”, in HackRF mode): only as a
  rescue when nothing else works.

<a id="screen"></a>
## Screen & Control

Mirrors the PortaPack display live on your Mac. Clicks act as touches, arrow
keys and Enter work like the buttons on the device, and you type text directly.
Screenshots at the push of a button. Mayhem mode only – if the device is in
HackRF mode, the page switches back by itself as long as nothing is receiving;
otherwise it offers “Back to Mayhem Mode Anyway”.

<a id="files"></a>
## SD Card

View files on the PortaPack's SD card, download and upload them (with
checksum), create folders, delete. Transfers can be stopped with “Cancel”; a
half-uploaded file is removed again. Faster for large amounts: Overview ▸ “SD
Card as Drive”. In HackRF mode the page switches back to Mayhem mode like
“Screen & Control”.

<a id="console"></a>
## Console

Free-form commands to the Mayhem shell and a log of all the app's commands – for
advanced users and troubleshooting.

<a id="settings"></a>
## Settings

Everything that applies to the whole app is on the **Settings** page – in the
sidebar under “Device” or with **⌘,**. Choose the section at the top. Other
pages only show a short line with a **“Settings …”** button that jumps straight
to the matching section.

| Section | What you set there |
|---|---|
| **General** | The app's language, opening at login, background mode, menu bar icon (see below). |
| **Location** | Your location – by hand or via “Use My Current Location”. For maps, distances and the Reception Schedule; it stays on this Mac. |
| **Antenna & Device** | “External LNA”, “Adjust gain automatically”, “Switch to HackRF mode automatically”, “Device display” and the crystal correction. |
| **Frequencies** | The frequency memory: search, edit and delete all saved frequencies, import and export them as CSV (see below). |
| **Remote Access** | The web page for your phone (chapter “Remote Access”). |
| **Share Data** | Sharing with ADS-B/AIS networks, SondeHub and Home Assistant (chapter “Share Data”). |
| **Notifications** | Notifications on your Mac and phone – and for what (see below). |
| **Online Services** | Look up aircraft data, routes and photos online (ADS-B), ship photos (AIS). |
| **Archive** | What the archive contains, how long it is kept, backup and restore; buttons open the archives. |

### Frequency Memory

Every page with a frequency field (Radio, Spectrum, Pagers, Wireless Sensors,
Weather Balloons, Recording, Meshtastic, VOR, Occupancy) has a **Frequency
memory** section in the Controls panel:

- **Save …** stores the current frequency – with a name and folder if you like.
  The page is saved too; the list shows “This page” or “All”.
- **Click** an entry to tune to it. Entries outside the page's range (e.g.
  433 MHz on the VOR page) are greyed out. On the Occupancy page a click opens
  Radio.
- **Settings ▸ Frequencies** lists all entries in a table: search, double-click
  to edit (name, frequency, mode, bandwidth, page, folder, note), press Delete to
  remove (the app asks first).
- **Export …/Import …** as CSV with the columns
  `Name;Frequenz (MHz);Modus;Bandbreite (kHz);Notiz;Gruppe;Seite`. Importing also
  accepts lists from SDR++ or CHIRP with these columns (English names work too),
  a comma or a point as decimal separator and frequencies in Hz. Entries that
  already exist are skipped.

Your earlier Radio favorites were moved into the frequency memory automatically
on first launch.

### Keep Running in the Background

If you close the window, the app keeps running – and so do reception,
recordings, the Reception Schedule and remote access. Without an open window the
Dock icon disappears (can be switched off: “Dock icon only while a window is
open”). Get back via the **menu bar icon** ▸ “Open PortaPack Manager” or by
opening the app again.

The menu bar icon shows the state: antenna = ready, filled = receiving, red dot
= recording (including a scheduled recording), orange warning triangle = device
problem. The menu lists the running receiver with frequency and level, the next
scheduled slot, remote access with the number of listeners and the device state;
plus “Stop reception”, “Pause reception schedule” (no new slots until you
resume – after a restart the app schedules again), “Settings …” and “Quit”.

**Quit (⌘Q):** If something is running (receiver, scheduled slot, recording,
occupancy recording, remote access with listeners), the app asks: “Keep running
in the background” (Return), “Quit” or “Cancel”. If nothing is running, ⌘Q quits
right away. During a firmware installation the app cannot be quit. When you log
out or shut down, it does not ask.

### Open at Login

**Open at login** adds the app as a login item (see System Settings ▸ General ▸
Login Items; if macOS asks for approval there, a button takes you to it). **When
opened at login** decides what happens then:

| Choice | What starts |
|---|---|
| **Resume recording** (default) | The receiver that ran last – also if you quit the app while it was receiving. If you stopped it yourself, nothing starts. |
| **Reception schedule only** | Only the scheduled slots. |
| **Start a specific page …** | The chosen page (e.g. Aircraft). |
| **Start nothing** | Just the app. |

The Reception Schedule runs in any case. The app waits up to 3 minutes for the
HackRF and switches to HackRF mode by itself; meanwhile the menu bar menu shows
“Waiting for the HackRF …”. If a scheduled slot is running, the receiver starts
afterwards. Opening at login never turns on remote access (it only runs if you
switched it on), and a choice made on the phone is not restored. **Start in the
background** (on by default) opens no window. If you open the app yourself,
nothing starts by itself.

### Crystal Correction

The crystal in the HackRF is slightly off – like a clock that runs fast. This
mainly affects narrow signals (FT8/WSPR, satellites). **Calibrate
Automatically** finds the strongest FM station and measures against it (about
a minute); whatever was running before starts again afterwards. If Radio is
playing a strong FM station, the app measures against exactly that one. The
correction applies to all receivers.

### Notifications

Notifications on your Mac and/or your phone via the free **ntfy** app: there,
choose “Subscribe to topic” and enter the topic shown, or scan the QR code. You
can choose weather balloons in range, satellite passes, results of scheduled
recordings, “Device unreachable” and maritime distress calls. Only short
message texts go to your phone, without distances or positions from which your
location could be worked out. **Send Test Message** checks the connection.

### Archive and Storage

- Aircraft, ships, radiosondes and the airband history are kept in a database
  (`Archiv.sqlite`); images, recordings and measurement series sit next to it as
  files – all under *Library ▸ Application Support ▸
  de.christiangolz.portapackmanager*, so they end up in your Time Machine backup.
- **Switch-over:** On the first launch with the database, the app imports the
  previous daily files in the background (progress under Settings ▸ Archive). It
  checks every entry and only then moves the old files into the folder
  “Archiv-vor-Datenbank” – nothing is deleted. If you like, remove them there
  with **Delete Old Files …**. If the import fails, the files stay where they are
  and the app tries again at the next launch.
- **Retention:** unlimited (default), 2 years, 1 year, 90 or 30 days. If you
  choose a shorter period, the app asks first and tells you how many entries
  will be removed.
- **Backup:** a ZIP file with a copy of the database and the other files.
  Restoring only adds what is missing – also from older backups with daily
  files. Nothing existing is ever overwritten.
- Anything that can be reloaded at any time (aircraft database, radio beacons,
  orbital data) lives in the cache, not in the backup.

<a id="fehler"></a>
## Troubleshooting

| Problem | What helps |
|---|---|
| Device isn't detected | Another USB cable (a data cable!), switch the device off/on, Overview ▸ “Reconnect USB” |
| Page shows “HackRF mode required” | “Switch to HackRF Mode” – or the device isn't plugged in or is off |
| Nothing is received | Read the status line; “Optimize Signal”; Antenna Check; move the antenna outdoors and higher |
| “Overloaded” | Leave the automatic adjustment on, turn off the built-in amplifier; with an external preamp, turn on “External LNA” |
| “The HackRF is currently receiving for …” | Another page, Remote Access or the Reception Schedule is using the device – “Start” gets it back |
| Remote Access doesn't work | Mac and phone on the same network, or both on Tailscale; use the full address from Settings ▸ Remote Access |
| Firmware update aborts | Don't unplug, try again. If nothing helps: “Fully Refresh Device” |

**Rule of thumb:** it's almost always the antenna, not the app. An antenna
outdoors and as high as possible does more than any setting.

<a id="recht"></a>
## Legal and Privacy

- The app **only receives**; it never transmits over the air.
- In Germany, receiving is largely permitted. Messages not intended for you
  (e.g. pages from public authorities) may neither be analyzed nor passed on
  (§ 5 TDDDG). Encrypted content stays encrypted – except in your own networks
  with your own keys.
- **Ban on interception and disclosure:** anything not meant for you – such as
  airband, ACARS/CPDLC, pages, maritime radio or other people's smart home and
  LoRa networks – may neither be recorded nor passed on, not even the fact that
  you received it. This also applies to Remote Access, “Share Data” and the
  archive. The affected pages briefly remind you of this in their “Note”
  section.
- **What the app sends to the internet** – only for the respective feature and
  without your location, unless you explicitly allow it:
  - firmware downloads from GitHub,
  - the aircraft database (OpenSky Network) – only when you load it,
  - aircraft data and photos (hexdb.io, adsbdb.com, planespotters.net – only
    the aircraft address or call sign),
  - ship photos (Wikimedia Commons, only the IMO number),
  - the airport and radio beacon lists (OurAirports),
  - satellite orbits (CelesTrak) and weather balloon data (SondeHub),
  - whatever you turn on yourself under “Share Data” and “Notifications”.
- Map tiles come from OpenStreetMap.
- For “Convert transmissions to text” (Airband), macOS downloads a speech model from
  Apple once; the recognition itself runs on your Mac.
