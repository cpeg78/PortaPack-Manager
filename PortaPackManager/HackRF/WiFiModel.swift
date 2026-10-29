import Accelerate
import CoreWLAN
import Foundation
import Observation

/// Ein WLAN aus der Suche des Mac (CoreWLAN).
struct WiFiNetwork: Identifiable, Sendable, Equatable {
    var id: String { bssid ?? "\(ssid ?? "?")-\(channel)" }
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var noise: Int
    var channel: Int
    var band: Band
    var widthMHz: Int
    var security: String

    enum Band: String, Sendable {
        case ghz2 = "2,4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz"
        /// Anzeige mit dem Dezimaltrenner des Gebietsschemas (der Rohwert ist fest deutsch).
        var title: String {
            switch self {
            case .ghz2: FrequencyInput.format(2.4, decimals: 1) + " GHz"
            case .ghz5: "5 GHz"
            case .ghz6: "6 GHz"
            }
        }
    }

    /// Mittenfrequenz des Kanals in MHz.
    var centerMHz: Double {
        switch band {
        case .ghz2: channel == 14 ? 2484 : 2407 + 5 * Double(channel)
        case .ghz5: 5000 + 5 * Double(channel)
        case .ghz6: 5950 + 5 * Double(channel)
        }
    }

    static func from(_ n: CWNetwork) -> WiFiNetwork? {
        guard let ch = n.wlanChannel else { return nil }
        let band: Band = switch ch.channelBand {
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        default: .ghz2
        }
        let width = switch ch.channelWidth {
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: 20
        }
        let security: String
        if n.supportsSecurity(.wpa3Personal) || n.supportsSecurity(.wpa3Transition) { security = "WPA3" }
        else if n.supportsSecurity(.wpa2Personal) || n.supportsSecurity(.wpa2Enterprise) { security = "WPA2" }
        else if n.supportsSecurity(.wpaPersonal) || n.supportsSecurity(.wpaEnterprise) { security = "WPA" }
        else if n.supportsSecurity(.WEP) { security = "WEP" }
        else if n.supportsSecurity(.none) { security = String(localized: "offen") }
        else { security = "?" }
        return WiFiNetwork(ssid: n.ssid, bssid: n.bssid, rssi: n.rssiValue, noise: n.noiseMeasurement,
                           channel: ch.channelNumber, band: band, widthMHz: width, security: security)
    }
}

/// Ein Netz, wie es der HackRF aus Beacons und Probe-Antworten liest.
struct WLANStation: Identifiable, Sendable, Equatable {
    var bssid: String
    var ssid: String?
    /// Kanal, auf dem der Rahmen empfangen wurde; `dsChannel` der im Beacon genannte.
    var channel: Int
    var dsChannel: Int?
    var security: String
    var rssiDB: Double
    var beacons = 0
    var rateMbps: Double
    var nan = false
    var lastSeen: Date

    var id: String { bssid }
    var displayName: String { ssid.flatMap { $0.isEmpty ? nil : $0 } ?? (nan ? "NAN-Cluster" : String(localized: "(verborgen)")) }
}

/// Ein Gerät, das per Probe-Anfrage nach Netzen sucht.
struct WLANClient: Identifiable, Sendable, Equatable {
    var mac: String
    var ssids: Set<String> = []
    var probes = 0
    var rssiDB: Double
    var channel: Int
    var lastSeen: Date

    var id: String { mac }
    /// Zufällige (lokal verwaltete) Adresse: zweitunterstes Bit des ersten Bytes.
    var randomized: Bool {
        guard let first = mac.split(separator: ":").first, let byte = UInt8(first, radix: 16) else { return false }
        return byte & 0x02 != 0
    }
}

/// Zähler der Rahmenarten eines Durchlaufs.
struct WLANFrameCounts: Sendable, Equatable {
    var total = 0
    var beacons = 0
    var probeRequests = 0
    var data = 0
    var control = 0
    var nan = 0
    var dsss = 0
    var ofdm = 0
}

/// Belegung eines 1-MHz-Abschnitts: Anteil der Zeit über der Schwelle und Spitzenpegel.
struct OccupancyBin: Identifiable, Sendable, Equatable {
    var mhz: Double
    var busy: Double
    var peakDB: Double
    var id: Double { mhz }
}

/// WLAN-Seite: Netze über das WLAN des Mac, Kanalbelegung über den HackRF.
///
/// Belegung: 20 MS/s in Fenstern zu 12 MHz Abstand (nutzbar ±6 MHz, flach
/// im 20-MHz-Basisbandfilter; DC-Lücke ±0,2 MHz), FFT 1024 ohne Mittelung –
/// jedes FFT-Fenster (51 µs) zählt für sich, so erscheinen auch kurze Pakete
/// (WLAN, Zigbee, Bluetooth) als Belegungsanteil. Je MHz die mittlere
/// Leistung der 51 Bins (der Höchstwert läge schon bei Rauschen ≈ 12 dB über
/// dem Boden – erste Fassung zeigte überall 95 % belegt). Schwelle 6 dB über
/// dem Rauschboden: Median der ruhigsten Zeitanteile aller Abschnitte.
@MainActor
@Observable
final class WiFiModel {
    enum Sweep: String, CaseIterable, Identifiable {
        case ghz2 = "2,4 GHz"
        case ghz5 = "5 GHz"
        var id: Self { self }
        /// Anzeige mit dem Dezimaltrenner des Gebietsschemas (der Rohwert ist fest deutsch).
        var title: String { self == .ghz2 ? FrequencyInput.format(2.4, decimals: 1) + " GHz" : "5 GHz" }
        var rangeMHz: ClosedRange<Double> { self == .ghz2 ? 2400...2484 : 5150...5850 }
        var windowCenters: [Double] {
            Array(stride(from: rangeMHz.lowerBound + 6, through: rangeMHz.upperBound + 5.9, by: 12))
        }
    }

    enum HackRFMode: String, CaseIterable, Identifiable {
        case occupancy = "Belegung"
        case frames = "Rahmen"
        var id: Self { self }
    }

    /// Kanalfolge für den Rahmenempfang.
    enum FrameChannels: String, CaseIterable, Identifiable {
        case ghz2 = "2,4 GHz, Kanäle 1–13"
        case ghz2Main = "2,4 GHz, nur 1/6/11"
        case ghz5 = "5 GHz (36–64, 100–140, 149–165)"
        case single = "Ein Kanal"
        var id: Self { self }
        var title: String {
            switch self {
            case .ghz2: String(localized: "2,4 GHz, Kanäle 1–13")
            case .ghz2Main: String(localized: "2,4 GHz, nur 1/6/11")
            case .ghz5: String(localized: "5 GHz (36–64, 100–140, 149–165)")
            case .single: String(localized: "Ein Kanal")
            }
        }
        var list: [Int] {
            switch self {
            case .ghz2: Array(1...13)
            case .ghz2Main: [1, 6, 11]
            case .ghz5: Array(stride(from: 36, through: 64, by: 4)) + Array(stride(from: 100, through: 140, by: 4)) + Array(stride(from: 149, through: 165, by: 4))
            case .single: []
            }
        }
    }

    var sweep: Sweep = .ghz2
    var hackRFMode: HackRFMode = .occupancy
    var frameChannels: FrameChannels = .ghz2
    var fixedChannel = 6
    /// Verweildauer je Kanal beim Rahmenempfang in Sekunden.
    var frameDwell = 1.0
    private(set) var stations: [WLANStation] = []
    private(set) var clients: [WLANClient] = []
    private(set) var frameCounts = WLANFrameCounts()
    private(set) var frameChannel = 0
    private(set) var frameNoiseDB = -100.0
    private let frames = FrameCollector()

    var lnaGain = GainProfile.preset(.wifi).lna
    var vgaGain = GainProfile.preset(.wifi).vga
    var amplifier = GainProfile.preset(.wifi).amplifier
    var antennaPower = false

    private(set) var networks: [WiFiNetwork] = []
    private(set) var current: WiFiNetwork?
    private(set) var scanningNetworks = false
    private(set) var networkError: String?
    private(set) var bins: [OccupancyBin] = []
    private(set) var running = false
    private(set) var sweeps = 0
    private(set) var error: String?

    private var sweepTask: Task<Void, Never>?
    private let analyzer = OccupancyAnalyzer()

    // MARK: Netze (CoreWLAN)

    /// Sucht Netze über das WLAN des Mac. SSID und BSSID gibt macOS nur mit
    /// Ortungserlaubnis heraus – die wird vorher erfragt.
    func scanNetworks() {
        guard !scanningNetworks else { return }
        scanningNetworks = true
        networkError = nil
        Task {
            _ = try? await LocationProvider.shared.currentLocation()
            let result = await Task.detached { () -> Result<([WiFiNetwork], WiFiNetwork?), Error> in
                guard let interface = CWWiFiClient.shared().interface() else {
                    return .failure(WiFiError.noInterface)
                }
                do {
                    let found = try interface.scanForNetworks(withName: nil, includeHidden: true)
                    let list = found.compactMap(WiFiNetwork.from)
                    var current: WiFiNetwork?
                    if let ch = interface.wlanChannel() {
                        current = WiFiNetwork(ssid: interface.ssid(), bssid: interface.bssid(), rssi: interface.rssiValue(),
                                              noise: interface.noiseMeasurement(), channel: ch.channelNumber,
                                              band: ch.channelBand == .band5GHz ? .ghz5 : ch.channelBand == .band6GHz ? .ghz6 : .ghz2,
                                              widthMHz: 20, security: "")
                    }
                    return .success((list, current))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case let .success((list, current)):
                networks = list.sorted { $0.rssi > $1.rssi }
                self.current = current
                if list.allSatisfy({ $0.ssid == nil }), !list.isEmpty {
                    networkError = String(localized: "Netznamen fehlen – erlaube PortaPack Manager die Ortungsdienste (Systemeinstellungen › Datenschutz & Sicherheit).")
                }
            case let .failure(error):
                networkError = error.localizedDescription
            }
            scanningNetworks = false
        }
    }

    enum WiFiError: LocalizedError {
        case noInterface
        var errorDescription: String? { String(localized: "Kein WLAN gefunden – ist das WLAN des Mac ausgeschaltet?") }
    }

    // MARK: Rahmen (HackRF)

    /// Sammelt 802.11-Rahmen vom Empfangsthread, fasst Netze und Geräte zusammen.
    private final class FrameCollector: @unchecked Sendable {
        let lock = NSLock()
        let receiver = WLANReceiver()
        var stations: [String: WLANStation] = [:]
        var clients: [String: WLANClient] = [:]
        var counts = WLANFrameCounts()
        var channel = 0
        /// Roh­rahmen für den PCAP-Export (mit rekonstruierter FCS und Kanal).
        var captured: [PCAPWriter.Frame] = []
        var capture = false

        func reset() {
            lock.withLock {
                stations = [:]
                clients = [:]
                counts = WLANFrameCounts()
                captured = []
            }
        }

        func process(_ block: Data) {
            let packets = receiver.process(block)
            guard !packets.isEmpty else { return }
            let channel = lock.withLock { self.channel }
            let freq = Int(WLANReceiver.frequencyMHz(channel: channel))
            lock.withLock {
                for packet in packets {
                    counts.total += 1
                    if packet.modulation == .dsss { counts.dsss += 1 } else { counts.ofdm += 1 }
                    if capture, captured.count < 20_000 {
                        // Pegel aus log10 kann −∞ sein – erst klemmen, dann wandeln (sonst Absturz).
                        let rssi = Int8(packet.rssiDB.isFinite ? max(-127, min(-1, packet.rssiDB)) : -127)
                        captured.append(PCAPWriter.Frame(bytes: packet.mpdu + WLANCRC32.fcs(packet.mpdu), date: packet.date,
                                                         radiotap: PCAPWriter.radiotap(frequencyMHz: freq, rssiDBm: rssi, is5GHz: channel >= 32)))
                    }
                    guard let frame = WLANFrame.parse(packet.mpdu) else { continue }
                    switch frame.kind {
                    case .beacon, .probeResponse:
                        counts.beacons += 1
                        let bssid = WLANFrame.mac(frame.address3)
                        var station = stations[bssid] ?? WLANStation(bssid: bssid, channel: channel, security: "", rssiDB: packet.rssiDB,
                                                                     rateMbps: packet.rateMbps, lastSeen: packet.date)
                        station.beacons += 1
                        station.channel = channel
                        station.dsChannel = frame.dsChannel ?? station.dsChannel
                        if let ssid = frame.ssid, !ssid.isEmpty { station.ssid = ssid }
                        if let security = frame.security { station.security = security }
                        station.rssiDB = 0.8 * station.rssiDB + 0.2 * packet.rssiDB
                        station.rateMbps = min(station.rateMbps, packet.rateMbps)
                        station.nan = station.nan || frame.address3 == WLANFrame.nanCluster
                        station.lastSeen = packet.date
                        stations[bssid] = station
                        DevicePruning.prune(&stations, limit: 2000, maxAge: 1800, now: packet.date) { $0.lastSeen }
                    case .probeRequest:
                        counts.probeRequests += 1
                        let mac = WLANFrame.mac(frame.address2)
                        var client = clients[mac] ?? WLANClient(mac: mac, rssiDB: packet.rssiDB, channel: channel, lastSeen: packet.date)
                        client.probes += 1
                        client.channel = channel
                        if let ssid = frame.ssid, client.ssids.count < 64 { client.ssids.insert(ssid.isEmpty ? String(localized: "(alle)") : ssid) }
                        client.rssiDB = 0.8 * client.rssiDB + 0.2 * packet.rssiDB
                        client.lastSeen = packet.date
                        clients[mac] = client
                        // Zufällige (randomisierte) Adressen blähen die Liste sonst unbegrenzt auf.
                        DevicePruning.prune(&clients, limit: 2000, maxAge: 1800, now: packet.date) { $0.lastSeen }
                    case .data: counts.data += 1
                    case .control: counts.control += 1
                    case .action:
                        if frame.nanAttributes != nil { counts.nan += 1 }
                    default: break
                    }
                }
            }
        }
    }

    /// Rahmenempfang: Kanäle der Reihe nach, je `frameDwell` Sekunden.
    private func runFrames(on device: HackRFDevice) async throws {
        try device.setSampleRate(UInt32(WLANReceiver.sampleRate))
        try device.setBasebandFilter(20_000_000)
        try applyGains(to: device)
        let collector = frames
        while !Task.isCancelled {
            let channels = frameChannels == .single ? [fixedChannel] : frameChannels.list
            for channel in channels {
                try Task.checkCancellation()
                try device.setFrequency(UInt64(WLANReceiver.frequencyMHz(channel: channel) * 1_000_000))
                collector.lock.withLock { collector.channel = channel }
                collector.receiver.reset()
                frameChannel = channel
                try device.startReceiving(owner: self) { collector.process($0) }
                try await Task.sleep(for: .seconds(frameDwell))
                guard device.isReceiving(for: self) else { throw HackRFError.takenOver }
                device.stopReceiving(owner: self)
                let (stations, clients, counts) = collector.lock.withLock { (collector.stations, collector.clients, collector.counts) }
                self.stations = stations.values.sorted { $0.beacons > $1.beacons }
                self.clients = clients.values.sorted { $0.lastSeen > $1.lastSeen }
                frameCounts = counts
                frameNoiseDB = collector.receiver.noiseDB
                sweeps += 1
                if frameChannels == .single { try await Task.sleep(for: .milliseconds(10)) }
            }
        }
    }

    func clearFrames() {
        frames.reset()
        stations = []
        clients = []
        frameCounts = WLANFrameCounts()
    }

    /// Rahmenmitschnitt für PCAP ein-/ausschalten.
    var captureFrames = false {
        didSet { frames.lock.withLock { frames.capture = captureFrames } }
    }

    /// Mitgeschnittene 802.11-Rahmen als PCAP (Linktyp 127, mit Radiotap).
    func pcap() -> Data {
        let captured = frames.lock.withLock { frames.captured }
        return PCAPWriter.data(linktype: 127, frames: captured)
    }

    var capturedCount: Int { frames.lock.withLock { frames.captured.count } }

    // MARK: Belegung (HackRF)

    func start(on device: HackRFDevice) {
        guard !running else { return }
        running = true
        error = nil
        if hackRFMode == .frames {
            sweepTask = Task { [weak self] in
                do {
                    guard let self else { return }
                    try await self.runFrames(on: device)
                } catch is CancellationError {
                } catch {
                    self?.error = error.localizedDescription
                    self?.running = false
                }
                if let self { device.stopReceiving(owner: self) } else if device.currentOwner == nil { device.stopReceiving() }
            }
            return
        }
        let analyzer = analyzer
        sweepTask = Task { [weak self] in
            do {
                try device.setSampleRate(20_000_000)
                try device.setBasebandFilter(HackRFDevice.basebandFilter(for: 20_000_000))
                try self?.applyGains(to: device)
                while !Task.isCancelled, let self {
                    let sweep = self.sweep
                    var collected: [OccupancyBin] = []
                    for center in sweep.windowCenters {
                        try Task.checkCancellation()
                        try device.setFrequency(UInt64(center * 1_000_000))
                        analyzer.reset()
                        try device.startReceiving(owner: self) { analyzer.process($0) }
                        try await Task.sleep(for: .milliseconds(250))
                        guard device.isReceiving(for: self) else { throw HackRFError.takenOver }
                        device.stopReceiving(owner: self)
                        collected += analyzer.bins(centerMHz: center).filter { sweep.rangeMHz.contains($0.mhz) }
                    }
                    // Mit dem vorigen Durchlauf glätten.
                    let previous = Dictionary(self.bins.map { ($0.mhz, $0) }, uniquingKeysWith: { _, new in new })
                    self.bins = collected.map { bin in
                        guard let old = previous[bin.mhz] else { return bin }
                        return OccupancyBin(mhz: bin.mhz, busy: 0.5 * old.busy + 0.5 * bin.busy,
                                            peakDB: max(bin.peakDB, old.peakDB - 3))
                    }
                    self.sweeps += 1
                }
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
                self?.running = false
            }
            if let self { device.stopReceiving(owner: self) } else if device.currentOwner == nil { device.stopReceiving() }
        }
    }

    func stop(on device: HackRFDevice?) {
        sweepTask?.cancel()
        sweepTask = nil
        device?.stopReceiving(owner: self)
        running = false
    }

    func changeSweep(_ sweep: Sweep) {
        self.sweep = sweep
        bins = []
    }

    func applyGains(to device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    // MARK: Auswertung

    /// Mittlere Belegung im Bereich `mhz ± halfWidth`.
    func busy(around mhz: Double, halfWidth: Double) -> Double? {
        let inside = bins.filter { abs($0.mhz - mhz) <= halfWidth }
        guard !inside.isEmpty else { return nil }
        return inside.map(\.busy).reduce(0, +) / Double(inside.count)
    }

    /// Zigbee-Kanäle nach Belegung (freieste zuerst) – Empfehlung für das eigene Netz.
    var zigbeeRanking: [(channel: Int, busy: Double)] {
        guard sweep == .ghz2 else { return [] }
        return IEEE802154.channels.compactMap { ch in
            busy(around: IEEE802154.frequencyMHz(channel: ch), halfWidth: 1).map { (ch, $0) }
        }
        .sorted { $0.busy < $1.busy }
    }

    /// WLAN-Kanäle 1–13 nach Belegung (±10 MHz).
    var wifiRanking: [(channel: Int, busy: Double)] {
        guard sweep == .ghz2 else { return [] }
        return (1...13).compactMap { ch in
            busy(around: 2407 + 5 * Double(ch), halfWidth: 10).map { (ch, $0) }
        }
        .sorted { $0.busy < $1.busy }
    }
}

/// Zählt je 1-MHz-Abschnitt, wie oft ein FFT-Fenster über der Schwelle liegt.
final class OccupancyAnalyzer: @unchecked Sendable {
    static let fftSize = 1024
    static let sampleRate = 20_000_000.0
    /// Nutzbar ±6 MHz um die Mitte, ohne DC ±0,2 MHz.
    static let usableMHz = 6.0

    private let lock = NSLock()
    private let setup: FFTSetup
    private let log2n: vDSP_Length
    private let window: [Float]
    /// Leistung je Bin (dB) aller verarbeiteten FFT-Fenster.
    private var frames: [[Float]] = []

    init() {
        log2n = vDSP_Length(log2(Double(Self.fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.window = window
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() { lock.withLock { frames = [] } }

    /// Höchstens 48 FFT-Fenster je Block, gleichmäßig verteilt.
    func process(_ iq: Data) {
        let n = Self.fftSize
        let available = iq.count / (2 * n)
        guard available > 0 else { return }
        let count = min(available, 48)
        let step = available / count
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        var power = [Float](repeating: 0, count: n)
        var results: [[Float]] = []
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: Int8.self)
            for k in 0..<count {
                let base = k * step * 2 * n
                for i in 0..<n {
                    re[i] = Float(b[base + 2 * i]) / 128 * window[i]
                    im[i] = Float(b[base + 2 * i + 1]) / 128 * window[i]
                }
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { m in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n))
                    }
                }
                var db = [Float](repeating: 0, count: n)
                var floor: Float = 1e-12
                vDSP_vthr(power, 1, &floor, &power, 1, vDSP_Length(n))
                var reference: Float = Float(n * n) / 4
                vDSP_vdbcon(power, 1, &reference, &db, 1, vDSP_Length(n), 0)
                // FFT-Shift: Mitte in die Mitte.
                results.append(Array(db[(n / 2)...] + db[..<(n / 2)]))
            }
        }
        lock.withLock { frames += results }
    }

    /// 1-MHz-Abschnitte des Fensters um `centerMHz`.
    func bins(centerMHz: Double) -> [OccupancyBin] {
        let frames = lock.withLock { self.frames }
        guard frames.count >= 4 else { return [] }
        let n = Self.fftSize
        let binMHz = Self.sampleRate / Double(n) / 1e6
        // Mittlere Leistung (dB) je Abschnitt und FFT-Fenster.
        var offsets: [Double] = []
        var series: [[Float]] = []
        for mhzOffset in stride(from: -Self.usableMHz + 0.5, through: Self.usableMHz - 0.5, by: 1) {
            let lo = Int(((mhzOffset - 0.5) / binMHz).rounded()) + n / 2
            let hi = Int(((mhzOffset + 0.5) / binMHz).rounded()) + n / 2
            let indices = (max(0, lo)..<min(n, hi)).filter { abs((Double($0) - Double(n / 2)) * binMHz) > 0.2 }
            guard !indices.isEmpty else { continue }
            offsets.append(mhzOffset)
            series.append(frames.map { frame in
                var sum: Float = 0
                for i in indices { sum += pow(10, frame[i] / 10) }
                return 10 * log10(sum / Float(indices.count))
            })
        }
        // Rauschboden: je Abschnitt das 10-%-Quantil über die Zeit, davon der
        // Median – ein dauerhaft belegter Abschnitt verschiebt ihn nicht.
        let quiet = series.map { values -> Float in
            let sorted = values.sorted()
            return sorted[sorted.count / 10]
        }.sorted()
        let floor = quiet[quiet.count / 2]
        let threshold = floor + 6
        return zip(offsets, series).map { offset, values in
            let busy = values.filter { $0 > threshold }.count
            return OccupancyBin(mhz: centerMHz + offset, busy: Double(busy) / Double(values.count),
                                peakDB: Double((values.max() ?? floor) - floor))
        }
    }
}
