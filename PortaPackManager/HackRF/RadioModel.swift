import Accelerate
import Foundation
import Observation

/// Radioempfang im HackRF-Modus: Abstimmen, Demodulieren, Abspielen, Suchlauf.
@MainActor
@Observable
final class RadioModel {
    var frequencyMHz: Double = 98.0
    /// Betriebsart. Ein Wechsel setzt die Filterbandbreite auf die Vorgabe der
    /// neuen Betriebsart (andere Bandbreite: `select(mode:bandwidthHz:)`) und
    /// stimmt bei SSB/CW ins 10-kHz-Raster um (`RadioTuning`).
    var mode: RadioMode = .wfm {
        didSet {
            if mode != oldValue { bandwidthHz = mode.defaultBandwidthHz ?? 0 }
            shared.demod.lock.withLock { shared.demod.radio.mode = mode; shared.demod.radio.reset() }
            if mode != oldValue, ownsDevice { retuneQuietly() }
        }
    }
    /// Filterbandbreite in Hz (siehe `RadioMode.bandwidthOptionsHz`; UKW: 0 = fest).
    /// Werte, die nicht zur Betriebsart passen, werden zur Vorgabe.
    var bandwidthHz: Double = 0 {
        didSet {
            // Zuweisen im eigenen didSet ruft didSet nicht erneut auf – daher danach übergeben.
            let valid = mode.validBandwidth(bandwidthHz) ?? 0
            if valid != bandwidthHz { bandwidthHz = valid }
            shared.demod.lock.withLock { shared.demod.radio.bandwidthHz = valid }
        }
    }
    /// CW: Tonhöhe des Überlagerungstons (BFO) in Hz.
    var cwPitchHz: Double = UserDefaults.standard.object(forKey: "radioCWPitch") as? Double ?? 700 {
        didSet {
            UserDefaults.standard.set(cwPitchHz, forKey: "radioCWPitch")
            shared.demod.lock.withLock { shared.demod.radio.cwPitchHz = cwPitchHz }
        }
    }
    static let cwPitchRange: ClosedRange<Double> = 400...1_000

    /// Betriebsart und Bandbreite in einem Zug (für Favoriten, Vorlagen und
    /// Sprünge aus anderen Seiten). `nil` = Vorgabe der Betriebsart; der Schritt
    /// folgt der Betriebsart, wenn sie wechselt.
    func select(mode newMode: RadioMode, bandwidthHz newBandwidth: Double? = nil) {
        if newMode != mode {
            mode = newMode
            stepKHz = newMode.defaultStepKHz
        }
        bandwidthHz = newMode.validBandwidth(newBandwidth) ?? 0
    }
    var volume: Double = 0.5 {
        didSet { shared.demod.lock.withLock { shared.demod.volume = Float(volume) } }
    }
    var lnaGain = GainProfile.preset(.radio).lna
    var vgaGain = GainProfile.preset(.radio).vga
    var amplifier = GainProfile.preset(.radio).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne
    var stepKHz: Double = 100
    /// Rauschsperre AM/NFM in dB über dem Rauschboden (0 = aus).
    var squelchDB: Double = UserDefaults.standard.object(forKey: "radioSquelchDB") as? Double ?? 8 {
        didSet {
            UserDefaults.standard.set(squelchDB, forKey: "radioSquelchDB")
            shared.demod.lock.withLock { shared.demod.radio.squelchDB = Float(squelchDB) }
        }
    }
    private(set) var squelchOpen = true
    private(set) var channelAboveFloorDB: Float = 0
    var stereo = true {
        didSet { shared.demod.lock.withLock { shared.demod.radio.stereoEnabled = stereo } }
    }

    private(set) var running = false
    private(set) var signalDB: Float = -100
    private(set) var bufferFill: Double = 0
    private(set) var error: String?
    private(set) var scanning = false
    private(set) var scanProgress = 0.0
    /// Ergebnis des letzten Suchlaufs – gemerkt, damit die Senderliste wie bei
    /// DAB+ nach dem Seitenwechsel oder Neustart noch da ist.
    private(set) var stations: [FoundStation] = LastScan.load()?.stations ?? []
    private(set) var scannedBand: ScanBand? = LastScan.load()?.band
    private(set) var scanStatus = ""
    private(set) var rds = RDSInfo()
    private(set) var rdsSynced = false
    /// RDS-Sendernamen je Frequenz (kHz), aus Suchlauf und Hören gelernt.
    private(set) var stationNames = StationNames.load()
    private(set) var pilotLocked = false
    /// Ergebnis der letzten Ablagemessung (noch nicht übernommen).
    private(set) var measurement: OffsetMeasurement?
    private(set) var measuring = false
    private(set) var correctionPPM = HackRFDevice.frequencyCorrectionPPM

    struct OffsetMeasurement: Equatable {
        var frequencyMHz: Double
        var offsetHz: Double
        /// Neue Gesamtkorrektur in ppm.
        var ppm: Double
    }

    private let shared = Shared()
    private let audio = AudioOutput()
    private var meterTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    private final class Shared: @unchecked Sendable {
        final class Demod: @unchecked Sendable {
            let lock = NSLock()
            let radio = RadioDemodulator()
            /// Lautstärke am Mac (der Demodulator selbst läuft fest auf `remoteLevel`).
            var volume: Float = 0.5
            /// Fernzugriff: bekommt die Werte vor dem Mac-Regler (für den AAC-Strom).
            var remoteTap: (@Sendable ([Float], [Float]) -> Void)?
            /// Solange jemand aus der Ferne hört, bleibt der Mac stumm.
            var localMuted = false
            /// Laufende Tonaufnahme (bekommt den Ton vor dem Mac-Regler).
            var recorder: AudioFileRecorder?
        }
        let demod = Demod()
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            try device.setSampleRate(UInt32(RadioDemodulator.inputRate))
            try applyGains()
            try retune()
            try audio.start()
            try startStream()
            running = true
            error = nil
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self else { return }
                    let radio = self.shared.demod.radio
                    let (db, info, synced, pilot, squelch) = self.shared.demod.lock.withLock {
                        (radio.signalDB, radio.rds.info, radio.rds.decoder.synced, radio.pilotLocked,
                         (radio.squelchOpen, radio.channelDB - radio.channelFloorDB))
                    }
                    self.signalDB = db
                    self.squelchOpen = squelch.0
                    self.channelAboveFloorDB = squelch.1.isNaN ? 0 : squelch.1
                    if info != self.rds { self.rds = info }
                    self.rdsSynced = synced
                    if !self.scanning, self.mode == .wfm, synced, let name = StationNames.complete(info) {
                        self.remember(name, at: self.frequencyMHz)
                    }
                    self.pilotLocked = pilot
                    self.bufferFill = Double(self.audio.buffer.fill) / 48_000
                    self.updateAudioRecording()
                }
            }
        } catch {
            self.error = error.localizedDescription
            audio.stop()
        }
    }

    /// Startet den Empfang für das Abspielen (2,4 MS/s, Demodulator).
    private func startStream() throws {
        guard let device else { return }
        let demod = shared.demod
        let output = audio.buffer
        demod.lock.withLock {
            demod.radio.mode = mode
            demod.radio.volume = Self.remoteLevel
            demod.volume = Float(volume)
            demod.radio.stereoEnabled = stereo
            demod.radio.squelchDB = Float(squelchDB)
            demod.radio.bandwidthHz = bandwidthHz
            demod.radio.cwPitchHz = cwPitchHz
            demod.radio.reset()
        }
        try device.startReceiving(owner: self) { block in
            let (audio, tap, gain, recorder) = demod.lock.withLock {
                (demod.radio.process(block), demod.remoteTap, demod.localMuted ? 0 : demod.volume / Self.remoteLevel, demod.recorder)
            }
            tap?(audio.left, audio.right)
            recorder?.append(left: audio.left, right: audio.right)
            output.write(left: Self.scaled(audio.left, gain), right: Self.scaled(audio.right, gain))
        }
    }

    /// Der Demodulator liefert fest auf diesem Pegel (= Vorgabe des Mac-Reglers):
    /// UKW mit ±2 rad Hub erreicht gerade Vollaussteuerung. Der Fernzugriff hört
    /// so unabhängig vom Mac-Regler, der Mac skaliert danach mit `volume / remoteLevel`.
    nonisolated static let remoteLevel: Float = 0.5

    nonisolated private static func scaled(_ values: [Float], _ gain: Float) -> [Float] {
        if gain == 1 { return values }
        var out = vDSP.multiply(gain, values)
        vDSP.clip(out, to: -1...1, result: &out)
        return out
    }

    // MARK: - Fernzugriff

    /// Ton für den Fernzugriff (48 kHz Stereo, vor dem Mac-Regler). Gilt auch für spätere Starts.
    func setRemoteTap(_ tap: (@Sendable ([Float], [Float]) -> Void)?) {
        shared.demod.lock.withLock { shared.demod.remoteTap = tap }
    }

    /// Mac stumm schalten, solange aus der Ferne gehört wird.
    func setLocalMuted(_ muted: Bool) {
        shared.demod.lock.withLock { shared.demod.localMuted = muted }
        localMuted = muted
    }

    private(set) var localMuted = false

    /// Gehört der HackRF gerade diesem Radio? Nur dann darf aus der Ferne
    /// abgestimmt werden – `tune` stellt sonst den Strom eines anderen Empfängers um.
    var ownsDevice: Bool {
        running && device?.isReceiving(for: self) == true
    }

    func stop() {
        stopAudioRecording()
        scanTask?.cancel()
        scanTask = nil
        scanning = false
        meterTask?.cancel()
        meterTask = nil
        device?.stopReceiving(owner: self)
        audio.stop()
        running = false
    }

    func tune(to mhz: Double) {
        frequencyMHz = max(1.24, min(6000, mhz))   // HackRF läuft 240 kHz darunter, ab 1 MHz
        do {
            try retune()
            audio.buffer.clear()
            shared.demod.lock.withLock {
                shared.demod.radio.rds.retuned()
                shared.demod.radio.resetCarrierOffset()
            }
            rds = RDSInfo()
            measurement = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func step(_ direction: Double) {
        tune(to: ((frequencyMHz * 1000 + direction * stepKHz) / stepKHz).rounded() * stepKHz / 1000)
    }

    func applyGains() throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    func applyGainsQuietly() {
        do { try applyGains() } catch { self.error = error.localizedDescription }
    }

    private func retune() throws {
        guard let device else { return }
        let plan = RadioTuning.plan(frequencyMHz: frequencyMHz, mode: mode)
        shared.demod.lock.withLock { shared.demod.radio.fineOffsetHz = plan.fineOffsetHz }
        try device.setFrequency(plan.hardwareHz)
    }

    private func retuneQuietly() {
        do { try retune() } catch { self.error = error.localizedDescription }
    }

    // MARK: - Tonaufnahme

    /// Laufende Tonaufnahme (Anzeige: Dauer, Größe).
    private(set) var audioRecording: AudioRecordingInfo?
    /// Warum die letzte Aufnahme vorzeitig endete.
    private(set) var audioRecordingIssue: String?
    /// Zählt beendete Aufnahmen – die Liste lädt dann neu.
    private(set) var audioRecordingsVersion = 0
    private var recorder: AudioFileRecorder?

    /// Beginnt eine Aufnahme des hörbaren Tons (vor dem Mac-Regler, also auch
    /// bei stummem Mac). UKW in Stereo, die übrigen Betriebsarten mono.
    func startAudioRecording(format: AudioFileFormat) {
        guard running, recorder == nil else { return }
        let detail = "\(RadioTuning.fileFrequency(frequencyMHz, mode: mode)) MHz \(mode.shortTitle)"
            + (mode == .wfm ? stationName(at: frequencyMHz).map { " \($0)" } ?? "" : "")
        let url = AudioRecordingStore.newURL(source: AudioRecordingStore.radioPrefix, detail: detail, format: format)
        let new = AudioFileRecorder(url: url, format: format, channels: mode == .wfm ? 2 : 1)
        shared.demod.lock.withLock { shared.demod.recorder = new }
        recorder = new
        audioRecordingIssue = nil
        audioRecording = AudioRecordingInfo(url: url, started: Date(), seconds: 0, bytes: 0)
    }

    func stopAudioRecording() {
        guard let recorder else { return }
        shared.demod.lock.withLock { shared.demod.recorder = nil }
        self.recorder = nil
        audioRecording = nil
        recorder.finish { [weak self] in
            Task { @MainActor in self?.audioRecordingsVersion += 1 }
        }
    }

    /// Dauer/Größe nachführen; ein Schreibfehler beendet die Aufnahme.
    private func updateAudioRecording() {
        guard let recorder, var info = audioRecording else { return }
        if let failure = recorder.failure {
            stopAudioRecording()
            audioRecordingIssue = failure
            return
        }
        info.seconds = recorder.seconds.rounded(.down)
        info.bytes = recorder.bytesWritten
        if info != audioRecording { audioRecording = info }
    }

    // MARK: - Frequenzablage

    /// Misst die Trägerablage des eingestellten UKW-Senders und leitet daraus
    /// die Quarzablage des HackRF ab. Übernommen wird sie erst mit
    /// `applyMeasurement()`.
    func measureOffset(seconds: Double = 4) {
        guard running, mode == .wfm, !measuring else { return }
        measuring = true
        measurement = nil
        shared.demod.lock.withLock { shared.demod.radio.resetCarrierOffset() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            let offset = self.shared.demod.lock.withLock { self.shared.demod.radio.carrierOffsetHz }
            // Restablage −f·Δε (siehe HackRFDevice.corrected) → Δε = −Ablage/f.
            let ppm = HackRFDevice.frequencyCorrectionPPM - offset / (self.frequencyMHz * 1_000_000) * 1e6
            self.measurement = OffsetMeasurement(frequencyMHz: self.frequencyMHz, offsetHz: offset, ppm: ppm)
            self.measuring = false
        }
    }

    /// Ob `calibrateAutomatically` das Gerät an jemand anderen verloren hat.
    private(set) var lostDevice = false

    /// Ersteinrichtung: UKW-Suchlauf, am stärksten Sender die Quarzablage messen
    /// und übernehmen – ohne dass jemand wissen muss, was ein ppm ist.
    /// Liefert einen Satz für die Anzeige.
    func calibrateAutomatically(on device: HackRFDevice) async -> String {
        lostDevice = false
        if !running { start(on: device) }
        guard running else { return error ?? String(localized: "Der Empfang ließ sich nicht starten.") }
        defer { stop() }
        // Abbrechbar (Ersteinrichtung, „Abbrechen“): Suchlauf beenden, nichts übernehmen.
        let cancelled = String(localized: "Abgleich abgebrochen – nichts geändert.")
        scan(ScanBands.fm)
        while scanning {
            if Task.isCancelled { cancelScan() }
            try? await Task.sleep(for: .milliseconds(300))
        }
        if Task.isCancelled { return cancelled }
        // Übernommen (Plan, Fernzugriff)? Dann nicht „Antenne prüfen“ melden.
        guard device.isReceiving(for: self) || error != HackRFError.takenOver.localizedDescription else {
            lostDevice = true
            return String(localized: "Abgebrochen – ein anderer Empfänger hat den HackRF übernommen.")
        }
        guard let best = stations.max(by: { $0.levelDB < $1.levelDB }) else {
            return String(localized: "Kein UKW-Sender gefunden – prüfe die Antenne. Den Abgleich kannst du später unter Einstellungen › Antenne & Gerät nachholen.")
        }
        // Der Suchlauf stimmt am Ende auf den stärksten Sender ab; kurz einschwingen lassen.
        try? await Task.sleep(for: .seconds(1.5))
        guard signalDB >= -45 else {
            return String(localized: "Der stärkste Sender (\(best.mhz.formatted(.number.precision(.fractionLength(1)))) MHz) ist zu schwach für einen genauen Abgleich.")
        }
        measureOffset()
        while measuring { try? await Task.sleep(for: .milliseconds(200)) }
        if Task.isCancelled {
            measurement = nil
            return cancelled
        }
        guard let measurement else { return String(localized: "Die Messung ist fehlgeschlagen.") }
        applyMeasurement()
        return String(localized: "Abgeglichen an \(measurement.frequencyMHz.formatted(.number.precision(.fractionLength(1)))) MHz: Korrektur \(measurement.ppm.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) ppm.")
    }

    func applyMeasurement() {
        guard let measurement else { return }
        setCorrection(measurement.ppm)
    }

    func setCorrection(_ ppm: Double) {
        HackRFDevice.frequencyCorrectionPPM = ppm
        correctionPPM = ppm
        measurement = nil
        guard let device else { return }
        do {
            try device.setSampleRate(UInt32(RadioDemodulator.inputRate))
            try retune()
            shared.demod.lock.withLock { shared.demod.radio.resetCarrierOffset() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Spektraler Suchlauf über ein Band (siehe `BandScanner`). Unterbricht
    /// das Abspielen, misst das Band in 20-MHz-Fenstern und stimmt danach auf
    /// den stärksten Kanal ab.
    func scan(_ band: ScanBand) {
        guard let device, !scanning else { return }
        scanTask?.cancel()
        scanning = true
        scanProgress = 0
        scannedBand = band
        stations = []
        mode = band.mode
        stepKHz = band.rasterKHz
        scanTask = Task { [weak self] in
            guard let self else { return }
            let accumulator = ScanAccumulator()
            var levels: [Double: Float] = [:]
            var readingNames = false
            let centers = BandScanner.windowCenters(for: band)
            do {
                device.stopReceiving(owner: self)
                audio.buffer.clear()
                try device.setSampleRate(BandScanner.sampleRate)
                for (index, center) in centers.enumerated() {
                    try Task.checkCancellation()
                    self.scanStatus = String(localized: "Suche \(index + 1) von \(centers.count) bei \(center.formatted(.number.precision(.fractionLength(1)))) MHz")
                    try device.setFrequency(UInt64(center * 1_000_000))
                    accumulator.reset()
                    try device.startReceiving(owner: self) { block in accumulator.process(block) }
                    // Kurz einschwingen lassen, dann messen.
                    try await Task.sleep(for: .milliseconds(80))
                    accumulator.reset()
                    let steps = max(1, Int(band.dwellSeconds / 0.1))
                    for step in 0..<steps {
                        try await Task.sleep(for: .milliseconds(100))
                        self.scanProgress = (Double(index) + Double(step + 1) / Double(steps)) / Double(centers.count)
                    }
                    guard device.isReceiving(for: self) else { throw HackRFError.takenOver }
                    device.stopReceiving(owner: self)
                    let window = BandScanner.channelLevels(spectrum: accumulator.shiftedMaxHold(), centerMHz: center, band: band)
                    for (channel, level) in window { levels[channel] = max(levels[channel] ?? -999, level) }
                }
                self.stations = BandScanner.pickStations(levels, band: band)
                LastScan.save(band: band, stations: self.stations)
                if band.mode == .wfm {
                    readingNames = true
                    try await self.readStationNames(on: device)
                    readingNames = false
                }
                self.scanStatus = self.stations.isEmpty
                    ? String(localized: "Nichts gefunden – versuch es noch einmal oder verbessere die Antenne.")
                    : String(localized: "\(self.stations.count) Sender gefunden")
            } catch HackRFError.takenOver {
                // Nicht zurückstellen: Abtastrate und Frequenz gehören jetzt einem anderen.
                self.scanning = false
                self.stop()
                self.error = HackRFError.takenOver.localizedDescription
                self.scanStatus = ""
                return
            } catch is CancellationError {
                self.scanStatus = readingNames
                    ? String(localized: "\(self.stations.count) Sender gefunden – Lesen der Namen abgebrochen")
                    : String(localized: "Suchlauf abgebrochen")
            } catch {
                self.error = error.localizedDescription
                self.scanStatus = ""
            }
            // Abspielen wiederherstellen.
            do {
                try device.setSampleRate(UInt32(RadioDemodulator.inputRate))
                if let best = self.stations.max(by: { $0.levelDB < $1.levelDB }) {
                    self.frequencyMHz = best.mhz
                } else {
                    self.frequencyMHz = band.channels.first ?? self.frequencyMHz
                }
                try self.retune()
                if self.running { try self.startStream() }
            } catch {
                self.error = error.localizedDescription
            }
            self.scanning = false
            self.scanProgress = 1
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: - Sendernamen

    func stationName(at mhz: Double) -> String? {
        stationNames[StationNames.key(mhz)]
    }

    private func remember(_ name: String, at mhz: Double) {
        let key = StationNames.key(mhz)
        guard stationNames[key] != name else { return }
        stationNames[key] = name
        StationNames.save(stationNames)
    }

    /// Nach dem UKW-Suchlauf: jeden Sender kurz anstimmen, bis der
    /// RDS-Sendername vollständig ist. Ohne Synchronisation nach 1,5 s
    /// (kein RDS oder zu schwach) weiter, sonst höchstens 3,5 s je Sender.
    private func readStationNames(on device: HackRFDevice) async throws {
        let order = stations.filter { !$0.possiblySpur }.sorted { $0.levelDB > $1.levelDB }
        guard !order.isEmpty else { return }
        let demod = shared.demod
        try device.setSampleRate(UInt32(RadioDemodulator.inputRate))
        demod.lock.withLock {
            demod.radio.mode = .wfm
            demod.radio.reset()
        }
        // Nur dekodieren, nicht abspielen.
        try device.startReceiving(owner: self) { block in _ = demod.lock.withLock { demod.radio.process(block) } }
        defer { device.stopReceiving(owner: self) }
        for (index, station) in order.enumerated() {
            try Task.checkCancellation()
            guard device.isReceiving(for: self) else { throw HackRFError.takenOver }
            scanStatus = String(localized: "Lese Sendernamen \(index + 1) von \(order.count): \(station.mhz.formatted(.number.precision(.fractionLength(1)))) MHz")
            scanProgress = Double(index) / Double(order.count)
            frequencyMHz = station.mhz
            try retune()
            demod.lock.withLock {
                demod.radio.rds.retuned()
                demod.radio.resetCarrierOffset()
            }
            let start = ContinuousClock.now
            while ContinuousClock.now - start < .milliseconds(3500) {
                try await Task.sleep(for: .milliseconds(150))
                let (info, synced) = demod.lock.withLock { (demod.radio.rds.info, demod.radio.rds.decoder.synced) }
                if let name = StationNames.complete(info), synced {
                    remember(name, at: station.mhz)
                    break
                }
                if !synced, ContinuousClock.now - start > .milliseconds(1500) { break }
            }
        }
        scanProgress = 1
    }
}

/// Abstimmung des HackRF für eine Wunschfrequenz. Der HackRF liegt 240 kHz
/// darunter (DC-Spitze außerhalb des Kanals). SSB/CW stimmen ihn nur im
/// 10-kHz-Raster um; die Restablage (±5 kHz) mischt der Demodulator digital
/// heraus. So bleibt die Feinabstimmung in 10-Hz-Schritten exakt und der
/// Synthesizer springt nicht bei jedem Schritt.
enum RadioTuning {
    static let fineGridHz = 10_000.0

    static func plan(frequencyMHz: Double, mode: RadioMode) -> (hardwareHz: UInt64, fineOffsetHz: Double) {
        let wanted = frequencyMHz * 1_000_000 - RadioDemodulator.offset
        guard mode.isSingleSideband else { return (UInt64(max(1_000_000, wanted)), 0) }
        let hardware = max(1_000_000, (wanted / fineGridHz).rounded() * fineGridHz)
        return (UInt64(hardware), (wanted - hardware).rounded())
    }

    /// Frequenz für Dateinamen (Punkt, ohne Gebietsschema): UKW 2, sonst bis 5 Stellen.
    static func fileFrequency(_ mhz: Double, mode: RadioMode) -> String {
        String(format: mode == .wfm ? "%.2f" : mode.isSingleSideband ? "%.5f" : "%.4f", mhz)
    }
}

/// Gelernte RDS-Sendernamen, dauerhaft in den Einstellungen.
enum StationNames {
    static let defaultsKey = "rdsStationNames"

    /// Frequenz auf 10 kHz gerundet (UKW-Raster 100 kHz, gelegentlich 50 kHz).
    static func key(_ mhz: Double) -> Int { Int((mhz * 100).rounded()) }

    /// Sendername, wenn alle acht Zeichen angekommen sind.
    static func complete(_ info: RDSInfo) -> String? {
        guard info.programService.allSatisfy({ $0 != nil }) else { return nil }
        let text = info.programServiceText
        return text.isEmpty ? nil : text
    }

    static func load() -> [Int: String] {
        let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    static func save(_ names: [Int: String]) {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) }), forKey: defaultsKey)
    }
}

/// Letzter Suchlauf der Radio-Seite (Band und gefundene Kanäle) in den Einstellungen.
enum LastScan {
    static let key = "radioLastScan"

    private struct Stored: Codable {
        var band: String
        var stations: [[Double]]   // [MHz, Pegel dB]
    }

    static func save(band: ScanBand, stations: [FoundStation]) {
        let stored = Stored(band: band.name, stations: stations.map { [$0.mhz, Double($0.levelDB)] })
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func load() -> (band: ScanBand, stations: [FoundStation])? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let band = ScanBands.all.first(where: { $0.name == stored.band }) else { return nil }
        return (band, stored.stations.compactMap { $0.count == 2 ? FoundStation(mhz: $0[0], levelDB: Float($0[1])) : nil })
    }
}

/// Radio-Favorit mit Betriebsart und Funkart (Band der Schnellwahl, z. B.
/// „Flugfunk“) – vorher nur die Frequenz, und ein Flugfunk-Favorit spielte in
/// der gerade eingestellten Betriebsart (27.10.2026).
struct RadioFavorite: Codable, Hashable, Identifiable {
    var mhz: Double
    var mode: RadioMode
    var stepKHz: Double
    /// Name des Schnellwahl-Bandes, zu dem die Frequenz gehört.
    var kind: String?
    var id: Double { mhz }

    /// Funkart zur Frequenz: das kleinste Schnellwahl-Band, das sie enthält.
    static func kind(at mhz: Double) -> String? {
        ScanBands.all.filter { $0.startMHz - 0.0005 <= mhz && mhz <= $0.endMHz + 0.0005 }
            .min { $0.endMHz - $0.startMHz < $1.endMHz - $1.startMHz }?.name
    }

    static func rounded(_ mhz: Double) -> Double { (mhz * 100_000).rounded() / 100_000 }   // 10 Hz (SSB/CW)

    /// Liest die gespeicherte Liste; alte Einträge (nur Frequenzen, kommagetrennt)
    /// bekommen Betriebsart und Funkart aus dem passenden Band, sonst UKW.
    static func decode(_ raw: String) -> [RadioFavorite] {
        if let data = raw.data(using: .utf8), let list = try? JSONDecoder().decode([RadioFavorite].self, from: data) {
            return list.sorted { $0.mhz < $1.mhz }
        }
        return raw.split(separator: ",").compactMap { Double($0) }.map { mhz in
            let band = ScanBands.all.first { $0.name == kind(at: mhz) }
            let mode = band?.mode ?? .wfm
            return RadioFavorite(mhz: mhz, mode: mode, stepKHz: mode.defaultStepKHz, kind: band?.name)
        }.sorted { $0.mhz < $1.mhz }
    }

    static func encode(_ list: [RadioFavorite]) -> String {
        (try? JSONEncoder().encode(list.sorted { $0.mhz < $1.mhz })).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
