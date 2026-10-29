import CoreGraphics
import Foundation
import Observation
import os

/// Eine Zeile der Dekodierliste (FT8 oder WSPR).
struct FT8Spot: Identifiable, Sendable {
    let id = UUID()
    enum Mode: String, Sendable { case ft8 = "FT8", wspr = "WSPR" }
    var cycle: Date
    var mode: Mode
    var band: FT8Model.Band
    var snr: Double
    var dt: Double
    /// Audiofrequenz über der Skalenfrequenz (Hz).
    var frequency: Double
    var drift: Double?
    var message: String
    /// Sendende Station.
    var call: String?
    /// Locator (aus der Nachricht oder zuletzt von dieser Station gesehen).
    var grid: String?
    var gridFromMessage: Bool
    var isCQ: Bool
    var viaOSD: Bool
    var powerDBm: Int?
}

/// Station mit bekanntem Locator für die Karte.
struct FT8Station: Identifiable, Sendable {
    var id: String { call }
    var call: String
    var grid: String
    var latitude: Double
    var longitude: Double
    var lastHeard: Date
    var lastMode: FT8Spot.Mode
    var bestSNR: Double
    var spots: Int
}

/// Markierung im Wasserfall: Signal einer Dekodierung.
struct FT8WaterfallMark: Identifiable, Sendable {
    let id = UUID()
    var start: Date
    var duration: Double
    var frequency: Double
    var bandwidth: Double
    var label: String
}

/// FT8/WSPR-Empfang im HackRF-Modus: ein oder zwei SSB-Kanäle (FT8 und WSPR
/// liegen höchstens ≈ 320 kHz auseinander und passen gemeinsam in 2,4 MS/s),
/// Zyklen an der UTC-Minute, Dekodierung auf eigenen Warteschlangen.
@MainActor
@Observable
final class FT8Model {
    enum Band: String, CaseIterable, Identifiable, Sendable {
        case m2 = "2 m", m6 = "6 m", cm70 = "70 cm"
        var id: String { rawValue }
        /// Skalenfrequenzen (USB) nach der Frequenzliste von WSJT-X.
        var ft8Dial: Int {
            switch self {
            case .m2: 144_174_000
            case .m6: 50_313_000
            case .cm70: 432_174_000
            }
        }
        var wsprDial: Int {
            switch self {
            case .m2: 144_489_000
            case .m6: 50_293_000
            case .cm70: 432_300_000
            }
        }
    }

    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case ft8 = "FT8", wspr = "WSPR", both = "FT8 + WSPR"
        var id: String { rawValue }
        var hasFT8: Bool { self != .wspr }
        var hasWSPR: Bool { self != .ft8 }
    }

    var band: Band = Band(rawValue: UserDefaults.standard.string(forKey: "ft8Band") ?? "") ?? .m2 {
        didSet { UserDefaults.standard.set(band.rawValue, forKey: "ft8Band") }
    }
    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "ft8Mode") ?? "") ?? .both {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "ft8Mode") }
    }
    var lnaGain = GainProfile.preset(.aprs).lna
    var vgaGain = GainProfile.preset(.aprs).vga
    var amplifier = GainProfile.preset(.aprs).amplifier
    var antennaPower = false
    /// OSD als zweite Stufe nach Belief Propagation.
    var deepDecoding = UserDefaults.standard.object(forKey: "ft8DeepDecoding") as? Bool ?? true {
        didSet { UserDefaults.standard.set(deepDecoding, forKey: "ft8DeepDecoding") }
    }
    /// Quarzdrift aus wiederholt gehörten Stationen schätzen und das Audioband nachführen.
    var driftTracking = UserDefaults.standard.object(forKey: "ft8DriftTracking") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(driftTracking, forKey: "ft8DriftTracking")
            publishCorrection()
        }
    }

    private(set) var running = false
    private(set) var error: String?
    private(set) var spots: [FT8Spot] = []
    private(set) var stations: [FT8Station] = []
    private(set) var decodeCount = 0
    private(set) var lastCycleCount: [FT8Spot.Mode: Int] = [:]
    private(set) var lastDecodeDuration: [FT8Spot.Mode: Double] = [:]
    private(set) var decoding: Set<FT8Spot.Mode> = []
    private(set) var ft8Waterfall: CGImage?
    private(set) var wsprWaterfall: CGImage?
    private(set) var ft8WaterfallRange: ClosedRange<Double> = 0...3200
    private(set) var wsprWaterfallRange: ClosedRange<Double> = 1200...1800
    private(set) var ft8WaterfallTimes: ClosedRange<Double>?
    private(set) var wsprWaterfallTimes: ClosedRange<Double>?
    private(set) var marks: [FT8WaterfallMark] = []
    private(set) var signalDB: Float = -100
    /// Geschätzte Drift des HackRF in Hz/s (`nil`: noch keine Schätzung).
    private(set) var driftRate: Double?
    /// Geschätzte Verstimmung seit dem Start in Hz (`nil`: noch keine Schätzung).
    private(set) var driftOffset: Double?
    /// Stationen der letzten Driftschätzung.
    private(set) var driftStations = 0
    /// Externer Takt an CLKIN (`nil`: Firmware kann es nicht melden).
    private(set) var clockInputDetected: Bool?
    /// Zeitversätze der letzten 10 min (für den Uhrenhinweis).
    private var dtHistory: [(date: Date, dt: Double, mode: FT8Spot.Mode)] = []
    /// Gemerkte Locatoren je Rufzeichen.
    private var knownGrids: [String: String] = [:]

    @ObservationIgnored private let shared = Shared()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lastFT8Slot = 0.0
    @ObservationIgnored private var lastWSPRSlot = 0.0
    /// Zuletzt gerenderte Zeilenstände (FT8, WSPR) – ohne neue Zeile kein neues Bild.
    @ObservationIgnored private var renderedRevisions: (ft8: Int, wspr: Int) = (-1, -1)
    @ObservationIgnored private(set) var startedAt = 0.0
    @ObservationIgnored private var tuned: (band: Band, mode: Mode)?
    @ObservationIgnored private var tracker = FT8DriftTracker()
    /// Angewandte Nachführungen (ab Uhrzeit) – daraus die Rohfrequenz einer Dekodierung.
    @ObservationIgnored private var appliedCorrections: [(from: Double, correction: FT8FrequencyCorrection)] = []
    /// Zählt Starts – Dekodierungen eines alten Laufs speisen die Driftschätzung nicht.
    @ObservationIgnored private var session = 0
    @ObservationIgnored let ft8Hashes = FT8CallHashes()
    @ObservationIgnored let wsprHashes = WSPRCallHashes()
    @ObservationIgnored private let ft8Queue = DispatchQueue(label: "FT8-Dekoder", qos: .utility)
    @ObservationIgnored private let wsprQueue = DispatchQueue(label: "WSPR-Dekoder", qos: .utility)
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "FT8")

    /// Quarzkorrektur gesetzt? Ohne sie liegen die Signale bei 144 MHz um bis
    /// zu einige kHz daneben – die Suchbereiche werden dann breiter.
    var crystalCalibrated: Bool { HackRFDevice.frequencyCorrectionPPM != 0 }
    var crystalPPM: Double { HackRFDevice.frequencyCorrectionPPM }
    var ft8SearchRange: ClosedRange<Double> { crystalCalibrated ? 100...3100 : -1200...4200 }
    var wsprCenters: [Double] { crystalCalibrated ? [1200, 1500, 1800] : stride(from: 300.0, through: 2700, by: 300).map { $0 } }

    /// Empfangsweg je Kanal (Empfangsthread), gelesen unter `lock`.
    private final class Channel: @unchecked Sendable {
        let mode: FT8Spot.Mode
        let channelizer: FT8Channelizer
        var buffer: FT8SampleBuffer
        let fftSize: Int
        let fft: FT8DFT
        let bins: [Int]
        var pendingRe: [Float] = []
        var pendingIm: [Float] = []
        var rows: [(time: Double, values: [Float])] = []
        /// Zählt jede neue Wasserfallzeile – der Main Actor rendert nur bei Änderung.
        var rowRevision = 0
        let averaging: Int
        var accumulated: [Float]
        var accumulatedCount = 0
        var power: Float = -100
        /// Nachführung der Quarzdrift (nur auf dem Empfangsthread).
        var shifter = FT8FrequencyShifter()

        init(mode: FT8Spot.Mode, offset: Int, range: ClosedRange<Double>) {
            self.mode = mode
            channelizer = FT8Channelizer(offset: offset)
            buffer = FT8SampleBuffer(maxSeconds: mode == .ft8 ? 35 : 125)
            let size = mode == .ft8 ? 2048 : 8192
            fftSize = size
            averaging = mode == .ft8 ? 2 : 1
            fft = FT8DFT(length: size)
            let binHz = 12_000.0 / Double(size)
            let lo = Int((range.lowerBound / binHz).rounded(.down)), hi = Int((range.upperBound / binHz).rounded(.up))
            bins = Array(lo...hi).map { ($0 % size + size) % size }
            accumulated = [Float](repeating: 0, count: bins.count)
        }

        /// Neue Abtastwerte: Ringpuffer und Wasserfallzeilen.
        func ingest(_ x: FT8Signal, arrival: Double) {
            buffer.append(x, arrival: arrival)
            pendingRe.append(contentsOf: x.re)
            pendingIm.append(contentsOf: x.im)
            var outRe = [Float](), outIm = [Float]()
            while pendingRe.count >= fftSize {
                let inRe = Array(pendingRe.prefix(fftSize)), inIm = Array(pendingIm.prefix(fftSize))
                pendingRe.removeFirst(fftSize)
                pendingIm.removeFirst(fftSize)
                var winRe = inRe, winIm = inIm
                for i in 0..<fftSize {
                    let w = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(fftSize)))
                    winRe[i] *= w; winIm[i] *= w
                }
                fft.run(winRe, winIm, &outRe, &outIm)
                var total: Float = 0
                for (j, k) in bins.enumerated() {
                    let p = outRe[k] * outRe[k] + outIm[k] * outIm[k]
                    accumulated[j] += p
                    total += p
                }
                power = 10 * log10(max(total / Float(fftSize * fftSize), 1e-20))
                accumulatedCount += 1
                if accumulatedCount >= averaging {
                    let row = accumulated.map { 10 * log10(max($0 / Float(accumulatedCount), 1e-20)) }
                    let time = (buffer.anchor ?? arrival) + Double(buffer.produced - pendingRe.count) / 12_000
                    // Sinkt der Anker (Mac-Uhr springt zurück, z. B. per NTP), passen die
                    // alten Zeilen nicht mehr zur Zeitachse: verwerfen (Review Y5).
                    if let previous = rows.last?.time, time < previous - 1 { rows.removeAll() }
                    rows.append((time, row))
                    if rows.count > 200 { rows.removeFirst(rows.count - 200) }
                    rowRevision &+= 1
                    accumulated = [Float](repeating: 0, count: bins.count)
                    accumulatedCount = 0
                }
            }
        }
    }

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var channels: [Channel] = []
        var correction = FT8FrequencyCorrection.none
    }

    // MARK: - Start/Stopp

    func start(on device: HackRFDevice) {
        guard !running else { return }
        let band = band, mode = mode
        let ft8Dial = band.ft8Dial, wsprDial = band.wsprDial
        let dials = (mode.hasFT8 ? [ft8Dial] : []) + (mode.hasWSPR ? [wsprDial] : [])
        // Die Gleichspannungsspitze 240 kHz unter den untersten Kanal legen.
        let center = dials.min()! - 240_000
        var channels: [Channel] = []
        if mode.hasFT8 {
            channels.append(Channel(mode: .ft8, offset: ft8Dial - center,
                                    range: (ft8SearchRange.lowerBound - 100)...(ft8SearchRange.upperBound + 150)))
        }
        if mode.hasWSPR {
            let centers = wsprCenters
            channels.append(Channel(mode: .wspr, offset: wsprDial - center,
                                    range: (centers.first! - 160)...(centers.last! + 160)))
        }
        ft8WaterfallRange = (ft8SearchRange.lowerBound - 100)...(ft8SearchRange.upperBound + 150)
        wsprWaterfallRange = (wsprCenters.first! - 160)...(wsprCenters.last! + 160)
        // Neue Kanäle beginnen leer: altes Bild weg, nächste Zeile sicher rendern.
        ft8Waterfall = nil; wsprWaterfall = nil
        ft8WaterfallTimes = nil; wsprWaterfallTimes = nil
        renderedRevisions = (-1, -1)
        session += 1
        tracker = mode.hasFT8 ? FT8DriftTracker() : .forWSPR()
        appliedCorrections = []
        driftRate = nil; driftOffset = nil; driftStations = 0
        shared.lock.withLock { shared.correction = .none }
        clockInputDetected = try? device.clockInputDetected()
        do {
            try device.setSampleRate(UInt32(FT8Channelizer.inputRate))
            try device.setFrequency(UInt64(center))
            try applyGains(to: device)
            let shared = shared
            shared.lock.withLock { shared.channels = channels }
            try device.startReceiving(owner: self) { block in
                let arrival = Date().timeIntervalSince1970
                let (re, im) = FT8Channelizer.convert(block)
                let (channels, correction) = shared.lock.withLock { (shared.channels, shared.correction) }
                let shift = correction.value(at: arrival)
                for channel in channels {
                    var out = channel.channelizer.process(re: re, im: im)
                    channel.shifter.apply(&out, hz: shift)
                    shared.lock.withLock { channel.ingest(out, arrival: arrival) }
                }
            }
            running = true
            error = nil
            tuned = (band, mode)
            startedAt = Date().timeIntervalSince1970
            // Zyklen, die vor dem Start begonnen haben, nicht mehr dekodieren.
            lastFT8Slot = ((startedAt - 0.4) / 15).rounded(.down) * 15
            lastWSPRSlot = ((startedAt - 1) / 120).rounded(.down) * 120
            Self.log.notice("FT8/WSPR gestartet: \(band.rawValue, privacy: .public) \(mode.rawValue, privacy: .public), Mitte \(center) Hz")
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.tick()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop(on device: HackRFDevice?) {
        tickTask?.cancel()
        tickTask = nil
        device?.stopReceiving(owner: self)
        shared.lock.withLock { shared.channels = [] }
        running = false
        tuned = nil
    }

    /// Band oder Betriebsart gewechselt: Empfang neu aufsetzen.
    func retune(on device: HackRFDevice?) {
        guard running, let device, device.isReceiving(for: self) else { return }
        if let tuned, tuned.band == band, tuned.mode == mode { return }
        stop(on: device)
        start(on: device)
    }

    func applyGains(to device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    func clear() {
        spots = []
        stations = []
        marks = []
        dtHistory = []
        lastCycleCount = [:]
    }

    // MARK: - Zyklen

    private func tick() {
        guard running else { return }
        let now = Date().timeIntervalSince1970
        // FT8: Zyklus S dekodieren, sobald S + 14,7 s erreicht ist; WSPR bei S + 114 s.
        if mode.hasFT8 {
            let slot = ((now - 14.7) / 15).rounded(.down) * 15
            if slot > lastFT8Slot {
                lastFT8Slot = slot
                if !decoding.contains(.ft8) { decodeFT8(slot: slot) }
            }
        }
        if mode.hasWSPR {
            let slot = ((now - 114) / 120).rounded(.down) * 120
            if slot > lastWSPRSlot {
                lastWSPRSlot = slot
                if !decoding.contains(.wspr) { decodeWSPR(slot: slot) }
            }
        }
        refreshWaterfalls()
        signalDB = shared.lock.withLock { shared.channels.first?.power ?? -100 }
    }

    private func decodeFT8(slot: Double) {
        guard let extracted = shared.lock.withLock({
            shared.channels.first { $0.mode == .ft8 }?.buffer.extract(from: slot, count: FT8Decoder.slotSamples)
        }) else { return }
        // Ohne Daten ab spätestens 0,4 s nach Zyklusbeginn fehlt das erste Costas-Feld zu weit.
        guard extracted.dataStart <= slot + 0.4, extracted.dataEnd >= slot + 13.5 else { return }
        var options = FT8Decoder.Options()
        options.minFrequency = ft8SearchRange.lowerBound
        options.maxFrequency = ft8SearchRange.upperBound
        options.osd = deepDecoding
        let decoderOptions = options
        let hashes = ft8Hashes
        let signal = extracted.signal
        let band = band
        let session = session
        decoding.insert(.ft8)
        ft8Queue.async { [weak self] in
            let start = Date()
            let results = FT8Decoder(options: decoderOptions).decode(signal, hashes: hashes)
            let duration = Date().timeIntervalSince(start)
            Task { @MainActor [weak self] in
                self?.decoding.remove(.ft8)
                self?.ingestFT8(results, slot: slot, band: band, duration: duration)
                self?.trackDrift(results.map { (call: $0.message.from, dt: $0.dt, frequency: $0.frequency) },
                                 transmissionMiddle: slot + FT8Decoder.nominalStart + 6.32, session: session)
            }
        }
    }

    private func decodeWSPR(slot: Double) {
        let count = 114 * 12_000
        guard let extracted = shared.lock.withLock({
            shared.channels.first { $0.mode == .wspr }?.buffer.extract(from: slot, count: count)
        }) else { return }
        guard extracted.dataStart <= slot + 3, extracted.dataEnd >= slot + 110 else { return }
        let centers = wsprCenters
        let hashes = wsprHashes
        let signal = extracted.signal
        let band = band
        let session = session
        // Nur ohne FT8 schätzt WSPR die Drift (FT8 liefert viermal je Minute).
        let tracksDrift = !mode.hasFT8
        decoding.insert(.wspr)
        wsprQueue.async { [weak self] in
            let start = Date()
            let results = WSPRDecoder().decode(signal, centers: centers, hashes: hashes)
            let duration = Date().timeIntervalSince(start)
            Task { @MainActor [weak self] in
                self?.decoding.remove(.wspr)
                self?.ingestWSPR(results, slot: slot, band: band, duration: duration)
                if tracksDrift {
                    self?.trackDrift(results.map { (call: Optional($0.message.callsign), dt: $0.dt, frequency: $0.frequency) },
                                     transmissionMiddle: slot + 1 + 55.3, session: session)
                }
            }
        }
    }

    func ingestFT8(_ results: [FT8Decode], slot: Double, band: Band, duration: Double) {
        let cycle = Date(timeIntervalSince1970: slot)
        lastCycleCount[.ft8] = results.count
        lastDecodeDuration[.ft8] = duration
        var new: [FT8Spot] = []
        for d in results.sorted(by: { $0.frequency < $1.frequency }) {
            let m = d.message
            // Unbekannte Hashes („<...>“) sind kein Rufzeichen.
            let call = m.from.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }.flatMap { $0 == "..." ? nil : $0 }
            if let call, let grid = m.grid { knownGrids[call] = grid }
            let grid = m.grid ?? call.flatMap { knownGrids[$0] }
            new.append(FT8Spot(cycle: cycle, mode: .ft8, band: band, snr: d.snr, dt: d.dt, frequency: d.frequency,
                               message: m.text, call: call, grid: grid, gridFromMessage: m.grid != nil,
                               isCQ: m.isCQ, viaOSD: d.viaOSD))
            marks.append(FT8WaterfallMark(start: cycle.addingTimeInterval(FT8Decoder.nominalStart + d.dt), duration: 12.64,
                                          frequency: d.frequency, bandwidth: 50, label: call ?? m.text))
            dtHistory.append((Date(), d.dt, .ft8))
        }
        Self.log.info("FT8 \(cycle.formatted(date: .omitted, time: .standard), privacy: .public): \(results.count) Dekodierungen in \(String(format: "%.2f", duration)) s")
        add(new)
    }

    func ingestWSPR(_ results: [WSPRDecode], slot: Double, band: Band, duration: Double) {
        let cycle = Date(timeIntervalSince1970: slot)
        lastCycleCount[.wspr] = results.count
        lastDecodeDuration[.wspr] = duration
        var new: [FT8Spot] = []
        for d in results {
            let m = d.message
            let trimmed = m.callsign.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let call: String? = trimmed == "..." ? nil : trimmed
            if let call, let grid = m.grid { knownGrids[call] = grid }
            let grid = m.grid ?? call.flatMap { knownGrids[$0] }
            new.append(FT8Spot(cycle: cycle, mode: .wspr, band: band, snr: d.snr, dt: d.dt, frequency: d.frequency, drift: d.drift,
                               message: m.text, call: call, grid: grid, gridFromMessage: m.grid != nil,
                               isCQ: false, viaOSD: false, powerDBm: m.powerDBm))
            marks.append(FT8WaterfallMark(start: cycle.addingTimeInterval(1 + d.dt), duration: 110.6,
                                          frequency: d.frequency - 3, bandwidth: 6, label: call ?? m.text))
            dtHistory.append((Date(), d.dt, .wspr))
        }
        Self.log.info("WSPR \(cycle.formatted(date: .omitted, time: .standard), privacy: .public): \(results.count) Dekodierungen in \(String(format: "%.2f", duration)) s")
        add(new)
    }

    // MARK: - Quarzdrift

    /// Dekodierungen eines Zyklus → Driftschätzung → neue Nachführung.
    /// `transmissionMiddle`: Mitte der Aussendung bei Δt = 0.
    private func trackDrift(_ decodes: [(call: String?, dt: Double, frequency: Double)], transmissionMiddle: Double, session: Int) {
        guard session == self.session, running else { return }
        var observations: [FT8DriftTracker.Observation] = []
        for d in decodes {
            guard let call = d.call?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), !call.isEmpty, call != "..." else { continue }
            let time = transmissionMiddle + d.dt
            // Rohfrequenz: die dekodierte Frequenz plus die damals angewandte Verschiebung.
            observations.append(.init(key: call, time: time, frequency: d.frequency + appliedCorrection(at: time)))
        }
        guard tracker.add(observations, at: transmissionMiddle) else { return }
        driftRate = tracker.rate
        driftOffset = tracker.correction.value(at: Date().timeIntervalSince1970)
        driftStations = tracker.lastStations
        Self.log.info("Quarzdrift \(String(format: "%+.2f", (self.driftRate ?? 0) * 60), privacy: .public) Hz/min, seit Start \(String(format: "%+.1f", self.driftOffset ?? 0), privacy: .public) Hz (\(self.driftStations) Stationen)")
        publishCorrection()
    }

    /// Verschiebung, die der Empfangsweg zur Uhrzeit `t` angewandt hat.
    func appliedCorrection(at t: Double) -> Double {
        appliedCorrections.last { $0.from <= t }?.correction.value(at: t) ?? 0
    }

    /// Aktuelle Nachführung an den Empfangsweg geben (aus: keine Verschiebung).
    private func publishCorrection() {
        let correction = driftTracking ? tracker.correction : .none
        let now = Date().timeIntervalSince1970
        appliedCorrections.append((now, correction))
        // Eine Stunde reicht weit über jede Aussendung hinaus; der letzte ältere Eintrag bleibt.
        if let keep = appliedCorrections.lastIndex(where: { $0.from < now - 3600 }), keep > 0 {
            appliedCorrections.removeFirst(keep)
        }
        let shared = shared
        shared.lock.withLock { shared.correction = correction }
    }

    private func add(_ new: [FT8Spot]) {
        decodeCount += new.count
        spots.insert(contentsOf: new, at: 0)
        if spots.count > 2000 { spots.removeLast(spots.count - 2000) }
        let cutoff = Date().addingTimeInterval(-600)
        dtHistory.removeAll { $0.date < cutoff }
        marks.removeAll { $0.start.timeIntervalSinceNow < -300 }
        var byCall = Dictionary(uniqueKeysWithValues: stations.map { ($0.call, $0) })
        for s in new {
            guard let call = s.call, let grid = s.grid, let pos = FT8Locator.coordinate(grid) else { continue }
            if var st = byCall[call] {
                st.grid = grid
                st.latitude = pos.lat
                st.longitude = pos.lon
                st.lastHeard = Date()
                st.lastMode = s.mode
                st.bestSNR = max(st.bestSNR, s.snr)
                st.spots += 1
                byCall[call] = st
            } else {
                byCall[call] = FT8Station(call: call, grid: grid, latitude: pos.lat, longitude: pos.lon, lastHeard: Date(),
                                          lastMode: s.mode, bestSNR: s.snr, spots: 1)
            }
        }
        // Begrenzen: Rufzeichen und Locatoren kommen frei wählbar aus der Luft.
        stations = Array(byCall.values.sorted { $0.lastHeard > $1.lastHeard }.prefix(Self.maxStations))
        if knownGrids.count > Self.maxKnownGrids {
            knownGrids = Dictionary(stations.map { ($0.call, $0.grid) }, uniquingKeysWith: { first, _ in first })
        }
    }

    static let maxStations = 2000
    static let maxKnownGrids = 5000

    // MARK: - Uhrzeit

    /// Median der Zeitversätze der letzten 10 min (mind. 5 Dekodierungen).
    var clockOffset: (median: Double, count: Int)? {
        let values = dtHistory.map(\.dt).sorted()
        guard values.count >= 5 else { return nil }
        return (values[values.count / 2], values.count)
    }

    /// Hinweistext zur Mac-Uhr aus der Δt-Statistik.
    nonisolated static func clockVerdict(median: Double, count: Int) -> (ok: Bool, text: String) {
        let text = String(format: "%+.1f s", median)
        if abs(median) <= 0.5 {
            return (true, String(localized: "Uhr passt (Δt-Mittel \(text) aus \(count) Dekodierungen)."))
        }
        let seconds = String(format: "%.1f", abs(median))
        let advice = String(localized: "FT8 verträgt nur etwa ±2 s – schalte in den Systemeinstellungen ▸ Allgemein ▸ Datum & Uhrzeit „Automatisch einstellen“ ein.")
        return (false, median > 0
                ? String(localized: "Die Mac-Uhr geht vermutlich \(seconds) s vor (Δt-Mittel \(text)). \(advice)")
                : String(localized: "Die Mac-Uhr geht vermutlich \(seconds) s nach (Δt-Mittel \(text)). \(advice)"))
    }

    // MARK: - Wasserfall

    /// Rendert nur, wenn seit dem letzten Takt eine Zeile dazukam – sonst lösten die
    /// beiden Bilder zweimal pro Sekunde eine neue Auswertung der Seite aus (Review Y14).
    private func refreshWaterfalls() {
        let revisions = renderedRevisions
        let (ft8, wspr) = shared.lock.withLock { () -> ((Int, [(time: Double, values: [Float])])?, (Int, [(time: Double, values: [Float])])?) in
            let f = shared.channels.first { $0.mode == .ft8 }
            let w = shared.channels.first { $0.mode == .wspr }
            return (f.flatMap { $0.rowRevision != revisions.ft8 ? ($0.rowRevision, $0.rows) : nil },
                    w.flatMap { $0.rowRevision != revisions.wspr ? ($0.rowRevision, $0.rows) : nil })
        }
        if let (revision, rows) = ft8 {
            renderedRevisions.ft8 = revision
            ft8Waterfall = Self.render(rows.map(\.values))
            ft8WaterfallTimes = Self.timeSpan(rows.map(\.time))
        }
        if let (revision, rows) = wspr {
            renderedRevisions.wspr = revision
            wsprWaterfall = Self.render(rows.map(\.values))
            wsprWaterfallTimes = Self.timeSpan(rows.map(\.time))
        }
    }

    /// Zeitbereich der Zeilen als `min...max`. `first...last` brach ab, sobald die
    /// Mac-Uhr zurücksprang und eine neuere Zeile eine kleinere Zeit trug (Review Y5).
    nonisolated static func timeSpan(_ times: [Double]) -> ClosedRange<Double>? {
        guard let low = times.min(), let high = times.max() else { return nil }
        return low...high
    }

    /// Zeilen (älteste zuerst) → Bild, neueste Zeile oben.
    static func render(_ rows: [[Float]]) -> CGImage? {
        guard let width = rows.first?.count, width > 0 else { return nil }
        let height = rows.count
        // Rauschboden aus einer Stichprobe (jeder 7. Wert) – spart das Sortieren aller Pixel.
        var all: [Float] = []
        for row in rows { for x in stride(from: 0, to: row.count, by: 7) { all.append(row[x]) } }
        all.sort()
        let floor = all[all.count / 5]
        let low = floor - 3, span: Float = 28
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (r, row) in rows.reversed().enumerated() {
            for x in 0..<min(width, row.count) {
                let t = max(0, min(1, (row[x] - low) / span))
                let c = palette[Int(t * 255)]
                let o = (r * width + x) * 4
                pixels[o] = c.0; pixels[o + 1] = c.1; pixels[o + 2] = c.2; pixels[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static let palette: [(UInt8, UInt8, UInt8)] = (0..<256).map { i in
        let t = Float(i) / 255
        let stops: [(Float, Float, Float)] = [(0, 0, 0.05), (0, 0.1, 0.5), (0, 0.6, 0.85), (0.95, 0.9, 0.15), (1, 0.3, 0.1), (1, 1, 1)]
        let scaled = t * Float(stops.count - 1)
        let k = min(Int(scaled), stops.count - 2)
        let f = scaled - Float(k)
        let a = stops[k], b = stops[k + 1]
        return (UInt8((a.0 + (b.0 - a.0) * f) * 255), UInt8((a.1 + (b.1 - a.1) * f) * 255), UInt8((a.2 + (b.2 - a.2) * f) * 255))
    }
}

extension FT8Model: GainTunable {
    var quality: GainQuality? { .count(decodeCount) }
    var idleHint: String {
        String(localized: "Auf 2 m und 70 cm ist FT8 oft nur bei Überreichweiten oder Contesten belebt; auf 6 m vor allem von Mai bis August.")
    }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}
