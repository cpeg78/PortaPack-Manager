import Foundation
import Observation

/// Flugfunk-Scanner (118–137 MHz AM) im HackRF-Modus: ein breiter Ausschnitt,
/// alle Kanäle gleichzeitig über die Filterbank, Rauschsperre je Kanal, der
/// lauteste aktive Listenkanal wird hörbar.
@MainActor
@Observable
final class AirbandModel {
    // Eigene Vorgabe (breiter Ausschnitt); danach gilt, was die Automatik oder
    // der Nutzer zuletzt eingestellt hat – getrennt nach „Externer Vorverstärker“.
    // Vorher begann jede Sitzung wieder bei der Vorgabe und übersteuerte, obwohl
    // die Automatik schon zurückgenommen hatte (28.10.2026).
    var lnaGain = AirbandModel.storedGain.lna { didSet { storeGain() } }
    var vgaGain = AirbandModel.storedGain.vga { didSet { storeGain() } }
    var amplifier = AirbandModel.storedGain.amplifier { didSet { storeGain() } }

    private static var gainKey: String { GainProfile.externalAmplifier ? "airbandGainExternal" : "airbandGain" }

    private static var storedGain: GainProfile.Preset {
        let preset = GainProfile.preset(.airband)
        guard let values = UserDefaults.standard.array(forKey: gainKey) as? [Double], values.count == 3 else { return preset }
        return GainProfile.Preset(lna: values[0], vga: values[1], amplifier: values[2] != 0)
    }

    /// Nach Umschalten von „Externer Vorverstärker“: die dazu gemerkten Werte laden.
    func reloadStoredGains() {
        let stored = Self.storedGain
        lnaGain = stored.lna; vgaGain = stored.vga; amplifier = stored.amplifier
        if running, let device, device.isReceiving(for: self) { try? applyGains() }
    }

    private func storeGain() {
        UserDefaults.standard.set([lnaGain, vgaGain, amplifier ? 1 : 0], forKey: Self.gainKey)
    }
    var antennaPower = false

    private(set) var running = false
    private(set) var error: String?

    /// Kanalliste des Nutzers (gespeichert).
    private(set) var channels = AirbandChannel.load()
    /// 16 MHz statt 8 MHz Ausschnitt erlauben (doppelte Rechenlast). Genutzt wird er
    /// nur, wenn er mehr Listenkanäle abdeckt als der schmale (`activeWide`).
    var wide = UserDefaults.standard.bool(forKey: "airbandWide") {
        didSet {
            UserDefaults.standard.set(wide, forKey: "airbandWide")
            if !running { activeWide = Self.needsWide(channels, allowed: wide); window = AirbandWindow.best(for: channels, bins: bins) }
        }
    }
    /// Ausschnitt, mit dem gerade empfangen wird (bzw. beim nächsten Start).
    private(set) var activeWide: Bool
    private(set) var window: AirbandWindow
    var squelchDB: Double = UserDefaults.standard.object(forKey: "airbandSquelchDB") as? Double ?? 8 {
        didSet {
            UserDefaults.standard.set(squelchDB, forKey: "airbandSquelchDB")
            receiver?.lock.withLock { receiver?.thresholdDB = Float(squelchDB) }
        }
    }
    var volume: Double = UserDefaults.standard.object(forKey: "airbandVolume") as? Double ?? 0.6 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "airbandVolume")
            receiver?.lock.withLock { receiver?.volume = Float(volume) }
        }
    }
    /// Mitschnitte aufzeichnen (Vorgabe aus).
    var recordAudio = UserDefaults.standard.bool(forKey: "airbandRecord") {
        didSet {
            UserDefaults.standard.set(recordAudio, forKey: "airbandRecord")
            receiver?.lock.withLock { receiver?.recordAudio = recordAudio }
        }
    }
    /// Nur Sprache zählt als Spruch (Vorgabe an) – Knackser, Trägertasten und
    /// Rauschspitzen fallen dann aus Verlauf und Suchlauf.
    var speechOnly = UserDefaults.standard.object(forKey: "airbandSpeechOnly") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(speechOnly, forKey: "airbandSpeechOnly")
            receiver?.lock.withLock { receiver?.speechOnly = speechOnly }
        }
    }
    /// Festgehaltener Kanal (Rasterindex).
    private(set) var hold: Int?

    private(set) var audible: Int?
    private(set) var channelExcess: [Int: Float] = [:]
    private(set) var channelOpen: Set<Int> = []
    private(set) var history: [AirbandTransmission]
    /// Übertragungen seit dem Start (für die Statuszeile).
    private(set) var transmissionCount = 0

    // Suchlauf „aktive Kanäle finden“
    private(set) var finding = false
    private(set) var findProgress = 0.0
    private(set) var findStatus = ""
    private(set) var findings: [AirbandFinding] = []

    private let log = AirbandLog.standard
    /// Spracherkennung der Sprüche (nur auf dem Mac).
    let transcription: AirbandTranscription
    /// Rufzeichen der gerade bekannten ADS-B-Flugzeuge (setzt `RemoteHub`).
    @ObservationIgnored var liveCallsigns: () -> [AirbandCallsign] = { [] }
    /// Rufzeichen aus dem ADS-B-Archiv der letzten Stunden – der HackRF kann nicht
    /// gleichzeitig ADS-B und Flugfunk empfangen, also zählen auch frühere Sichtungen.
    @ObservationIgnored private var archiveCallsigns: [AirbandCallsign] = []
    @ObservationIgnored private var archiveCallsignsDate = Date.distantPast
    private let audio = AudioOutput()
    private var receiver: AirbandReceiver?
    private var pollTask: Task<Void, Never>?
    private var findTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    var sampleRate: Double { activeWide ? 16_000_000 : 8_000_000 }
    var bins: Int { activeWide ? 1920 : 960 }

    /// Breit lohnt sich nur, wenn das beste 16-MHz-Fenster mehr (bzw. wichtigere)
    /// Listenkanäle abdeckt als das beste 8-MHz-Fenster – sonst halbe Rechenlast
    /// (Nutzer 31.10.2026: Flugfunk braucht in der Aktivitätsanzeige viel).
    nonisolated static func needsWide(_ channels: [AirbandChannel], allowed: Bool) -> Bool {
        guard allowed else { return false }
        func score(_ bins: Int) -> Int {
            let window = AirbandWindow.best(for: channels, bins: bins)
            return channels.filter { !$0.locked && window.covers($0.index) }.reduce(0) { $0 + ($1.priority ? 1000 : 1) }
        }
        return score(1920) > score(960)
    }

    init() {
        let channels = AirbandChannel.load()
        let wide = Self.needsWide(channels, allowed: UserDefaults.standard.bool(forKey: "airbandWide"))
        activeWide = wide
        window = AirbandWindow.best(for: channels, bins: wide ? 1920 : 960)
        history = []
        transcription = AirbandTranscription(log: AirbandLog.standard)
        transcription.onResult = { [weak self] result in self?.apply(result) }
        transcription.onWantsAudioChange = { [weak self] wants in
            guard let receiver = self?.receiver else { return }
            receiver.lock.withLock { receiver.transcribeAudio = wants }
        }
        // Verlauf abseits des Main Actors laden; was bis dahin schon empfangen
        // wurde, bleibt vorne.
        let log = log
        Task { [weak self] in
            let loaded = await log.loadRecent()
            guard let self else { return }
            let known = Set(self.history.map(\.id))
            self.history = Array((self.history + loaded.filter { !known.contains($0.id) })
                .sorted { $0.start > $1.start }.prefix(AirbandLog.limit))
        }
    }

    // MARK: - Empfang

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            activeWide = Self.needsWide(channels, allowed: wide)
            window = AirbandWindow.best(for: channels, bins: bins)
            let receiver = AirbandReceiver(sampleRate: sampleRate, bins: bins, output: audio.buffer)
            receiver.lock.withLock {
                receiver.setWindow(window)
                receiver.channels = channels
                receiver.thresholdDB = Float(squelchDB)
                receiver.volume = Float(volume)
                receiver.recordAudio = recordAudio
                receiver.transcribeAudio = transcription.wantsAudio
                receiver.speechOnly = speechOnly
                receiver.remoteTap = remoteTap
                receiver.localMuted = localMuted
                receiver.hold = hold
            }
            self.receiver = receiver
            try device.setSampleRate(UInt32(sampleRate))
            try device.setFrequency(UInt64(window.centerHz.rounded()))
            try applyGains()
            try audio.start()
            try device.startReceiving(owner: self) { receiver.process($0) }
            running = true
            error = nil
            transmissionCount = 0
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    self?.poll()
                }
            }
        } catch {
            self.error = error.localizedDescription
            audio.stop()
        }
    }

    func stop() {
        findTask?.cancel()
        findTask = nil
        finding = false
        pollTask?.cancel()
        pollTask = nil
        device?.stopReceiving(owner: self)
        audio.stop()
        // Laufende Sprüche in den Verlauf.
        if let receiver {
            receiver.lock.withLock { receiver.resetState() }
            collect(receiver.lock.withLock { receiver.takeFinished() })
        }
        receiver = nil
        running = false
        audible = nil
        channelOpen = []
    }

    private func poll() {
        guard let receiver else { return }
        let (audible, excess, open, done, activity) = receiver.lock.withLock {
            (receiver.audible, receiver.channelExcess, receiver.channelOpen, receiver.takeFinished(),
             receiver.finderActive ? receiver.activity : nil)
        }
        self.audible = audible
        channelExcess = excess
        channelOpen = open
        if let activity { updateFindings(activity) }
        collect(done)
    }

    private func collect(_ done: [(AirbandTransmission, [Int16]?)]) {
        guard !done.isEmpty else { return }
        transmissionCount += done.count
        let log = log
        // Der Ton kommt auch nur für die Erkennung mit; gespeichert wird er nur mit
        // „Sprüche aufzeichnen“.
        let record = recordAudio
        let transcribe = transcription.wantsAudio
        if transcribe { refreshArchiveCallsigns() }
        Task { [weak self] in
            // Mitschnitt schreiben abseits des Main Actors.
            let entries = await Task.detached {
                done.map { transmission, samples -> AirbandTransmission in
                    var item = transmission
                    if record, let samples { item.recording = log.writeRecording(samples, for: transmission) }
                    return item
                }
            }.value
            guard let self else { return }
            log.insert(entries)
            self.history = log.merge(entries, into: self.history)
            // Erst nach dem Eintrag in die Datenbank – die Abschrift ändert die Zeile.
            if transcribe {
                let callsigns = self.currentCallsigns()
                for (transmission, samples) in done {
                    if let samples { self.transcription.enqueue(transmission, samples: samples, callsigns: callsigns) }
                }
            }
        }
    }

    // MARK: - Spracherkennung

    /// Rufzeichen in Reichweite: live aus ADS-B, dazu das Archiv der letzten Stunden.
    func currentCallsigns() -> [AirbandCallsign] {
        var seen = Set<String>()
        return (liveCallsigns() + archiveCallsigns).filter { seen.insert($0.callsign.uppercased()).inserted }
    }

    private func refreshArchiveCallsigns() {
        guard Date().timeIntervalSince(archiveCallsignsDate) > 300 else { return }
        archiveCallsignsDate = Date()
        let log = log
        Task { [weak self] in
            let signs = await log.recentCallsigns()
            self?.archiveCallsigns = signs
        }
    }

    /// Ergebnis der Erkennung in den angezeigten Verlauf übernehmen (die Datenbank
    /// schreibt `AirbandTranscription` selbst).
    private func apply(_ result: AirbandTranscriptResult) {
        guard let k = history.firstIndex(where: { $0.id == result.id }) else { return }
        history[k].transcript = result.text
        history[k].transcriptLanguage = result.language
        history[k].transcriptConfidence = result.confidence
        history[k].callsign = result.callsign?.callsign
        history[k].aircraftICAO = result.callsign?.icao
    }

    /// Volltextsuche in allen Abschriften der Datenbank (nicht nur den angezeigten 1000).
    func search(_ text: String) async -> [AirbandTransmission] {
        await log.search(userInput: text)
    }

    // MARK: - Kanalliste

    func addChannel(index: Int, name: String) {
        guard AirbandGrid.range.contains(index) else { return }
        if let k = channels.firstIndex(where: { $0.index == index }) {
            if !name.isEmpty { channels[k].name = name }
        } else {
            channels.append(AirbandChannel(index: index, name: name))
            channels.sort { $0.index < $1.index }
        }
        channelsChanged()
    }

    func removeChannel(_ index: Int) {
        channels.removeAll { $0.index == index }
        if hold == index { setHold(nil) }
        channelsChanged()
    }

    func rename(_ index: Int, to name: String) {
        guard let k = channels.firstIndex(where: { $0.index == index }) else { return }
        channels[k].name = name
        channelsChanged(reposition: false)
    }

    func togglePriority(_ index: Int) {
        guard let k = channels.firstIndex(where: { $0.index == index }) else { return }
        channels[k].priority.toggle()
        channelsChanged()
    }

    func toggleLocked(_ index: Int) {
        guard let k = channels.firstIndex(where: { $0.index == index }) else { return }
        channels[k].locked.toggle()
        if channels[k].locked, hold == index { setHold(nil) }
        channelsChanged()
    }

    func setHold(_ index: Int?) {
        hold = index
        receiver?.lock.withLock { receiver?.hold = index }
    }

    /// Hält den gerade hörbaren Kanal fest bzw. löst das Halten.
    func toggleHold() {
        setHold(hold == nil ? audible : nil)
    }

    private func channelsChanged(reposition: Bool = true) {
        AirbandChannel.save(channels)
        receiver?.lock.withLock { receiver?.channels = channels }
        // Passt die Liste jetzt (nicht mehr) in 8 MHz: mit der anderen Breite neu starten.
        if reposition, !finding, running, Self.needsWide(channels, allowed: wide) != activeWide,
           let device, device.isReceiving(for: self) {
            stop()
            start(on: device)
            return
        }
        if reposition, !finding { moveWindow(to: AirbandWindow.best(for: channels, bins: bins)) }
    }

    /// Listenkanäle außerhalb des Ausschnitts (nicht gleichzeitig hörbar).
    var uncovered: [AirbandChannel] { channels.filter { !$0.locked && !window.covers($0.index) } }

    private func moveWindow(to new: AirbandWindow) {
        guard new != window else { return }
        window = new
        guard running, let device, device.isReceiving(for: self) else { return }
        do {
            try device.setFrequency(UInt64(new.centerHz.rounded()))
            receiver?.lock.withLock { receiver?.setWindow(new) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Aktive Kanäle finden

    /// Wandert in Fenstern über das ganze Band (je `dwell` Sekunden) und
    /// merkt sich, auf welchen Kanälen die Rauschsperre aufging.
    func findActiveChannels(minutes: Double, dwell: Double = 10) {
        guard running, let device, !finding else { return }
        finding = true
        findProgress = 0
        findings = []
        receiver?.lock.withLock {
            receiver?.resetActivity()
            receiver?.finderActive = true
        }
        let total = minutes * 60
        findTask = Task { [weak self] in
            guard let self else { return }
            let start = ContinuousClock.now
            var round = 0
            do {
                outer: while true {
                    let windows = AirbandWindow.sweep(bins: self.bins, shift: round % 2)
                    for (k, w) in windows.enumerated() {
                        let elapsed = Double((ContinuousClock.now - start).components.seconds)
                        if elapsed >= total { break outer }
                        guard device.isReceiving(for: self) else { throw HackRFError.takenOver }
                        self.findStatus = String(format: String(localized: "Runde %d, Abschnitt %d/%d um %.1f MHz"), round + 1, k + 1, windows.count, w.centerHz / 1e6)
                        self.moveWindow(to: w)
                        let steps = Int(dwell / 0.5)
                        for _ in 0..<steps {
                            try await Task.sleep(for: .milliseconds(500))
                            let now = Double((ContinuousClock.now - start).components.seconds)
                            self.findProgress = min(1, now / total)
                        }
                    }
                    round += 1
                }
                self.findStatus = self.findings.isEmpty ? String(localized: "Kein Funkverkehr gefunden – such länger oder verbessere die Antenne.") : String(localized: "\(self.findings.count) Kanäle mit Funkverkehr")
            } catch HackRFError.takenOver {
                self.findStatus = ""
                self.error = HackRFError.takenOver.localizedDescription
            } catch {
                self.findStatus = String(localized: "Suche abgebrochen")
            }
            if let receiver = self.receiver {
                let activity = receiver.lock.withLock { () -> [Int: AirbandActivity] in
                    receiver.finderActive = false
                    return receiver.activity
                }
                self.updateFindings(activity)
            }
            self.finding = false
            self.findProgress = 1
            if device.isReceiving(for: self) { self.moveWindow(to: AirbandWindow.best(for: self.channels, bins: self.bins)) }
        }
    }

    func cancelFind() { findTask?.cancel() }

    // MARK: - Fernzugriff

    @ObservationIgnored private var remoteTap: (@Sendable ([Float]) -> Void)?
    @ObservationIgnored private var localMuted = false

    /// Ton für den Fernzugriff (48 kHz mono). Gilt auch für spätere Starts.
    func setRemoteTap(_ tap: (@Sendable ([Float]) -> Void)?) {
        remoteTap = tap
        receiver?.lock.withLock { receiver?.remoteTap = tap }
    }

    /// Mac stumm schalten, solange aus der Ferne gehört wird.
    func setLocalMuted(_ muted: Bool) {
        localMuted = muted
        receiver?.lock.withLock { receiver?.localMuted = muted }
    }

    private func updateFindings(_ activity: [Int: AirbandActivity]) {
        // Nur bei Änderung setzen: Die Abfrage läuft fünfmal pro Sekunde.
        let next = activity.filter { $0.value.transmissions > 0 }
            .map { AirbandFinding(index: $0.key, activity: $0.value) }
            .sorted { ($0.activity.openSeconds, $0.index) > ($1.activity.openSeconds, $1.index) }
        if next != findings { findings = next }
    }

    // MARK: - Verlauf

    func recordingURL(_ item: AirbandTransmission) -> URL? {
        item.recording.map { log.recordingURL($0) }
    }

    func deleteHistory() {
        transcription.cancelAll()
        log.deleteAll(history)
        history = []
    }

    func delete(_ item: AirbandTransmission) {
        transcription.cancel(item.id)
        log.delete(item)
        history.removeAll { $0.id == item.id }
    }

    var recordingsFolder: URL { log.recordingsFolder }

    // MARK: - Verstärkung

    func applyGains() throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }
}

extension AirbandModel: GainTunable {
    /// Funksprüche sind zu selten für den Optimierer – nur Pegel, Zähler für die Statuszeile.
    var quality: GainQuality? { nil }
    var activity: Int? { transmissionCount }
    var idleHint: String { String(localized: "Flugfunk hört man nur, wenn gerade jemand spricht – nahe am Flughafen oft, sonst selten. „Aktive Kanäle finden“ zeigt, wo hier etwas los ist.") }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}
