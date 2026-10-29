import Foundation
import Observation

/// Ein beim Suchlauf gefundenes Ensemble (gemerkt in den Einstellungen).
struct DABStoredEnsemble: Codable, Hashable, Identifiable, Sendable {
    struct Service: Codable, Hashable, Identifiable, Sendable {
        var id: UInt32
        var label: String
        var kind: DABAudioKind
        var bitrate: Int
        var programmeType: Int
    }

    var channel: String
    var label: String
    var services: [Service]
    /// Störabstand beim Einlesen; entscheidet, wo ein mehrfach gesendeter
    /// Dienst gelistet wird (fehlt in älteren Einträgen).
    var snr: Double?
    var id: String { channel }

    init(channel: String, ensemble: DABEnsemble, snr: Double? = nil) {
        self.channel = channel
        label = ensemble.label
        self.snr = snr
        services = ensemble.audioServices.map { service in
            Service(id: service.id, label: service.label, kind: service.kind,
                    bitrate: ensemble.subchannel(for: service)?.bitrate ?? 0, programmeType: service.programmeType)
        }
    }
}

/// DAB+-Empfang im HackRF-Modus: Kanal abstimmen, Suchlauf, Dienst hören.
@MainActor
@Observable
final class DABModel {
    var lnaGain = GainProfile.preset(.dab).lna
    var vgaGain = GainProfile.preset(.dab).vga
    var amplifier = GainProfile.preset(.dab).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne
    var volume: Double = 0.7 {
        didSet { shared.lock.withLock { shared.volume = Float(volume) } }
    }

    private(set) var channel: DABChannel
    private(set) var running = false
    private(set) var status = DABReceiver.Status()
    private(set) var playingServiceID: UInt32?
    private(set) var ensembles: [DABStoredEnsemble]
    private(set) var scanning = false
    private(set) var scanProgress = 0.0
    private(set) var scanStatus = ""
    private(set) var error: String?
    private(set) var bufferFill: Double = 0

    private let shared = Shared()
    private let audio = AudioOutput()
    private var pollTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let receiver = DABReceiver()
        var volume: Float = 0.7
        /// Fernzugriff: bekommt die Werte vor der Lautstärke (für den AAC-Strom).
        var remoteTap: (@Sendable ([Float], [Float]) -> Void)?
        /// Solange jemand aus der Ferne hört, bleibt der Mac stumm.
        var localMuted = false
        /// Superframes kommen stoßweise (alle 120 ms) – erst abspielen, wenn
        /// genug gepuffert ist, und nach einem Leerlauf neu vorpuffern.
        var prebuffering = true
        var pendingLeft: [Float] = []
        var pendingRight: [Float] = []
        /// Laufende Tonaufnahme (bekommt den Ton vor der Lautstärke).
        var recorder: AudioFileRecorder?
    }

    private static let ensemblesKey = "dabEnsembles"
    private static let channelKey = "dabChannel"
    private static let serviceKey = "dabService"

    init() {
        let defaults = UserDefaults.standard
        channel = defaults.string(forKey: Self.channelKey).flatMap(DABChannel.named) ?? DABChannel.named("5C")!
        if let data = defaults.data(forKey: Self.ensemblesKey),
           let stored = try? JSONDecoder().decode([DABStoredEnsemble].self, from: data) {
            ensembles = stored
        } else {
            ensembles = []
        }
        let lastService = defaults.object(forKey: Self.serviceKey) as? Int
        playingServiceID = lastService.map { UInt32($0) }
        shared.volume = Float(volume)
    }

    // MARK: - Fernzugriff

    /// Abgriff der dekodierten Werte für den Fernzugriff (`nil` = aus).
    func setRemoteTap(_ tap: (@Sendable ([Float], [Float]) -> Void)?) {
        shared.lock.withLock { shared.remoteTap = tap }
    }

    /// Mac-Lautsprecher stumm, solange jemand aus der Ferne hört.
    func setLocalMuted(_ muted: Bool) {
        shared.lock.withLock { shared.localMuted = muted }
        localMuted = muted
    }

    private(set) var localMuted = false

    // MARK: - Start und Stopp

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            try device.setSampleRate(DABFrontEnd.inputRate)
            try applyGains()
            try device.setFrequency(channel.frequency)
            try audio.start()
            let shared = shared
            let output = audio.buffer
            shared.lock.withLock {
                shared.receiver.reset()
                shared.receiver.select(serviceID: playingServiceID)
                shared.prebuffering = true
                shared.receiver.audioHandler = { left, right in
                    // Läuft innerhalb von `process`, also unter `shared.lock`.
                    shared.remoteTap?(left, right)
                    shared.recorder?.append(left: left, right: right)
                    let gain = shared.localMuted ? 0 : shared.volume
                    var l = left, r = right
                    for n in l.indices { l[n] *= gain; r[n] *= gain }
                    if shared.prebuffering {
                        shared.pendingLeft += l
                        shared.pendingRight += r
                        if shared.pendingLeft.count >= 14_400 {        // 0,3 s
                            output.write(left: shared.pendingLeft, right: shared.pendingRight)
                            shared.pendingLeft = []
                            shared.pendingRight = []
                            shared.prebuffering = false
                        }
                    } else {
                        if output.fill == 0 { shared.prebuffering = true }
                        output.write(left: l, right: r)
                    }
                }
            }
            try device.startReceiving(owner: self) { block in
                shared.lock.withLock { shared.receiver.process(block) }
            }
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    self.status = self.shared.lock.withLock { self.shared.receiver.status() }
                    self.bufferFill = Double(self.audio.buffer.fill) / 48_000
                    self.rememberEnsemble()
                    self.updateAudioRecording()
                }
            }
        } catch {
            self.error = error.localizedDescription
            audio.stop()
        }
    }

    func stop() {
        stopAudioRecording()
        scanTask?.cancel()
        scanTask = nil
        scanning = false
        pollTask?.cancel()
        pollTask = nil
        device?.stopReceiving(owner: self)
        audio.stop()
        running = false
    }

    // MARK: - Tonaufnahme

    /// Laufende Tonaufnahme (Anzeige: Dauer, Größe).
    private(set) var audioRecording: AudioRecordingInfo?
    /// Warum die letzte Aufnahme vorzeitig endete.
    private(set) var audioRecordingIssue: String?
    /// Zählt beendete Aufnahmen – die Liste lädt dann neu.
    private(set) var audioRecordingsVersion = 0
    private var recorder: AudioFileRecorder?

    /// Nimmt den dekodierten Ton (Stereo, vor der Lautstärke) auf; Dateiname mit Sendername.
    func startAudioRecording(format: AudioFileFormat) {
        guard running, recorder == nil else { return }
        let detail = playingLabel.map { "\($0) \(channel.name)" } ?? channel.name
        let url = AudioRecordingStore.newURL(source: AudioRecordingStore.dabPrefix, detail: detail, format: format)
        let new = AudioFileRecorder(url: url, format: format, channels: 2)
        shared.lock.withLock { shared.recorder = new }
        recorder = new
        audioRecordingIssue = nil
        audioRecording = AudioRecordingInfo(url: url, started: Date(), seconds: 0, bytes: 0)
    }

    func stopAudioRecording() {
        guard let recorder else { return }
        shared.lock.withLock { shared.recorder = nil }
        self.recorder = nil
        audioRecording = nil
        recorder.finish { [weak self] in
            Task { @MainActor in self?.audioRecordingsVersion += 1 }
        }
    }

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

    // MARK: - Abstimmen

    /// Wechselt den Kanal (der gewählte Dienst bleibt, falls er dort sendet).
    func tune(_ channel: DABChannel, service: UInt32? = nil) {
        self.channel = channel
        UserDefaults.standard.set(channel.name, forKey: Self.channelKey)
        if let service { setPlaying(service) }
        do {
            // Ohne eigenen Empfang nur merken – sonst verstimmte der Kanalwähler
            // den Strom einer anderen Seite (z. B. ADS-B im Fernbetrieb).
            if let device, device.isReceiving(for: self) { try device.setFrequency(channel.frequency) }
        } catch {
            self.error = error.localizedDescription
        }
        audio.buffer.clear()
        let id = playingServiceID
        shared.lock.withLock {
            shared.receiver.reset()
            shared.receiver.select(serviceID: id)
            shared.prebuffering = true
            shared.pendingLeft = []
            shared.pendingRight = []
        }
        status = DABReceiver.Status()
    }

    /// Spielt einen Dienst; liegt er auf einem anderen Kanal, wird umgeschaltet.
    func play(_ service: DABStoredEnsemble.Service, on channelName: String) {
        if channelName != channel.name, let target = DABChannel.named(channelName) {
            tune(target, service: service.id)
            return
        }
        setPlaying(service.id)
        audio.buffer.clear()
        shared.lock.withLock {
            shared.receiver.select(serviceID: service.id)
            shared.prebuffering = true
            shared.pendingLeft = []
            shared.pendingRight = []
        }
    }

    private func setPlaying(_ id: UInt32?) {
        playingServiceID = id
        UserDefaults.standard.set(id.map { Int($0) }, forKey: Self.serviceKey)
    }

    /// Name des laufenden Dienstes (aus dem Live-Ensemble oder dem Speicher).
    var playingLabel: String? {
        guard let id = playingServiceID else { return nil }
        if let label = status.ensemble.services[id]?.label, !label.isEmpty { return label }
        return ensembles.lazy.flatMap(\.services).first { $0.id == id }?.label
    }

    /// Senderliste ohne Doppelte: Dienste mit gleicher Kennung (dasselbe
    /// Programm in mehreren Ensembles, etwa NDR auf 9B/10A/10C) erscheinen nur
    /// im Ensemble mit dem besten Störabstand, bei Gleichstand im ersten.
    var stationList: [(ensemble: DABStoredEnsemble, services: [DABStoredEnsemble.Service])] {
        Self.deduplicated(ensembles)
    }

    static func deduplicated(_ ensembles: [DABStoredEnsemble]) -> [(ensemble: DABStoredEnsemble, services: [DABStoredEnsemble.Service])] {
        var home: [UInt32: Int] = [:]
        for (index, ensemble) in ensembles.enumerated() {
            for service in ensemble.services {
                if let current = home[service.id],
                   (ensemble.snr ?? -.infinity) <= (ensembles[current].snr ?? -.infinity) { continue }
                home[service.id] = index
            }
        }
        return ensembles.enumerated().compactMap { index, ensemble in
            let services = ensemble.services.filter { home[$0.id] == index }
            return services.isEmpty ? nil : (ensemble, services)
        }
    }

    /// Weitere Kanäle, auf denen ein Dienst ebenfalls läuft.
    func otherChannels(of id: UInt32, besides channel: String) -> [String] {
        ensembles.filter { $0.channel != channel && $0.services.contains { $0.id == id } }.map(\.channel)
    }

    /// Hält das gemerkte Ensemble des aktuellen Kanals aktuell.
    private func rememberEnsemble() {
        let live = status.ensemble
        guard status.synchronized, !live.label.isEmpty, !live.audioServices.isEmpty else { return }
        var entry = DABStoredEnsemble(channel: channel.name, ensemble: live, snr: status.snr)
        if let index = ensembles.firstIndex(where: { $0.channel == channel.name }) {
            // Störabstand aus dem Suchlauf behalten, sonst schwankt die Zuordnung.
            entry.snr = ensembles[index].snr ?? entry.snr
            // Nur wachsen lassen: während des Einlesens fehlen anfangs Dienste.
            if ensembles[index] != entry, entry.services.count >= ensembles[index].services.count {
                ensembles[index] = entry
                saveEnsembles()
            }
        } else {
            ensembles.append(entry)
            ensembles.sort { Self.channelOrder($0.channel) < Self.channelOrder($1.channel) }
            saveEnsembles()
        }
    }

    private static func channelOrder(_ name: String) -> Int {
        DABChannel.bandIII.firstIndex { $0.name == name } ?? .max
    }

    private func saveEnsembles() {
        if let data = try? JSONEncoder().encode(ensembles) {
            UserDefaults.standard.set(data, forKey: Self.ensemblesKey)
        }
    }

    func forgetEnsembles() {
        ensembles = []
        UserDefaults.standard.removeObject(forKey: Self.ensemblesKey)
    }

    // MARK: - Suchlauf

    /// Prüft alle Kanäle des Band III: kurz auf Rahmensynchronisation warten,
    /// bei Erfolg das Ensemble vollständig einlesen.
    func scan() {
        guard device != nil, running, !scanning else { return }
        scanTask?.cancel()
        scanning = true
        scanProgress = 0
        let previous = channel
        let previousService = playingServiceID
        setPlaying(nil)
        scanTask = Task { [weak self] in
            guard let self else { return }
            var found: [DABStoredEnsemble] = []
            var lost = false
            let channels = DABChannel.bandIII
            for (index, candidate) in channels.enumerated() {
                if Task.isCancelled { break }
                // Übernommen (Plan, andere Seite)? Sonst liefe die Schleife blind
                // weiter und meldete am Ende „Antenne prüfen“.
                guard self.device?.isReceiving(for: self) == true else { lost = true; break }
                self.scanStatus = String(localized: "Kanal \(candidate.name) (\(candidate.megahertz.formatted(.number.precision(.fractionLength(3)))) MHz) · \(found.count) Ensembles gefunden")
                self.scanProgress = Double(index) / Double(channels.count)
                self.tune(candidate)
                // Bis zu 1,2 s auf Synchronisation warten.
                var locked = false
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(200))
                    let status = self.shared.lock.withLock { self.shared.receiver.status() }
                    if status.synchronized && status.framesDecoded > 1 { locked = true; break }
                }
                guard locked else { continue }
                // Ensemble einlesen, bis sich 1,5 s lang nichts mehr ändert (höchstens 8 s).
                var last = DABEnsemble()
                var stableSince = Date()
                let started = Date()
                while Date().timeIntervalSince(started) < 8, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    let ensemble = self.shared.lock.withLock { self.shared.receiver.ensemble }
                    if ensemble != last { last = ensemble; stableSince = Date() }
                    let complete = !ensemble.label.isEmpty && !ensemble.audioServices.isEmpty
                        && ensemble.services.values.allSatisfy { !$0.label.isEmpty }
                    if complete && Date().timeIntervalSince(stableSince) > 1.5 { break }
                }
                if !last.label.isEmpty, !last.audioServices.isEmpty {
                    let snr = self.shared.lock.withLock { self.shared.receiver.status().snr }
                    let entry = DABStoredEnsemble(channel: candidate.name, ensemble: last, snr: snr)
                    found.append(entry)
                    self.ensembles.removeAll { $0.channel == candidate.name }
                    self.ensembles.append(entry)
                    self.ensembles.sort { Self.channelOrder($0.channel) < Self.channelOrder($1.channel) }
                    self.saveEnsembles()
                }
            }
            let cancelled = Task.isCancelled
            self.scanning = false
            self.scanProgress = 1
            let services = Set(found.flatMap { $0.services.map(\.id) }).count
            if lost {
                self.scanStatus = String(localized: "Suchlauf abgebrochen – ein anderer Empfänger hat den HackRF übernommen.")
                return
            }
            self.scanStatus = cancelled
                ? String(localized: "Suchlauf abgebrochen")
                : (found.isEmpty ? String(localized: "Keine DAB-Sender gefunden – prüfe die Antenne (174–240 MHz).")
                                 : String(localized: "\(services) Sender in \(found.count) Ensembles gefunden"))
            // Zurück zum vorigen Dienst oder zum ersten gefundenen.
            if let previousService, let ensemble = self.ensembles.first(where: { $0.services.contains { $0.id == previousService } }),
               let target = DABChannel.named(ensemble.channel) {
                self.tune(target, service: previousService)
            } else if let first = found.first, let service = first.services.first, let target = DABChannel.named(first.channel) {
                self.tune(target, service: service.id)
            } else {
                self.tune(previous, service: previousService)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }
}
