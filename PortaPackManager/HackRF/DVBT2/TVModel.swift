import Foundation
import Observation
import os

/// UHF-Fernsehkanal (8 MHz Raster, Deutschland: K21–K48 nach der zweiten Digitalen Dividende).
struct TVChannel: Hashable, Codable, Identifiable, Sendable {
    let number: Int
    var id: Int { number }
    var name: String { "K\(number)" }
    var frequency: UInt64 { UInt64(306 + 8 * number) * 1_000_000 }
    var megahertz: Int { 306 + 8 * number }

    static let uhf = (21...48).map(TVChannel.init)
}

/// Beim Suchlauf gefundener Multiplex (gemerkt in den Einstellungen).
struct TVStoredMux: Codable, Hashable, Identifiable, Sendable {
    struct Service: Codable, Hashable, Identifiable, Sendable {
        var id: Int
        var name: String
        var provider: String
        var radio: Bool
        var scrambled: Bool
    }

    var channel: Int
    var mode: String
    var snr: Double
    var requiredSNR: Double?
    var services: [Service]
    var id: Int { channel }
    /// Genau 0 heißt „nicht gemessen“ (Synchronisation zu kurz) – ein echter
    /// Messwert trifft 0,0 praktisch nie.
    var snrKnown: Bool { snr != 0 && !mode.isEmpty }
}

/// Grobe Schwelle (Gaußkanal, 64K-LDPC, Richtwerte der Norm-Simulationen) plus
/// Reserve – Richtwert für die Anzeige, bezogen auf `T2Receiver.Status.snr`.
enum T2Threshold {
    static func requiredSNR(modulation: Int, codeRate: Int) -> Double? {
        let table: [[Double]] = [
            [1.0, 2.2, 3.1, 4.1, 4.7, 5.2],          // QPSK
            [6.2, 7.6, 8.9, 10.0, 10.8, 11.3],       // 16-QAM
            [9.9, 11.9, 13.2, 14.6, 15.5, 16.0],     // 64-QAM
            [13.2, 15.6, 17.3, 19.0, 20.2, 20.9],    // 256-QAM
        ]
        guard modulation < table.count, codeRate < 6 else { return nil }
        // Eigener Empfänger im Simulationsprüfstand (K23, 64-QAM 1/2, angezeigter Störabstand an der
        // Schwelle): 10,3 dB im Gaußkanal (Tabelle + 0,4), 12,35 dB mit gleich starkem Echo (+ 2,05).
        // Früher (Min-Sum, vereinfachte LLR): 10,4 bzw. 12,9 dB angezeigt, Reserve damals + 3.
        return table[modulation][codeRate] + 2.5
    }
}

/// DVB-T2-Fernsehen im HackRF-Modus.
@MainActor
@Observable
final class TVModel {
    var lnaGain = GainProfile.preset(.tv).lna
    var vgaGain = GainProfile.preset(.tv).vga
    var amplifier = GainProfile.preset(.tv).amplifier
    var antennaPower = false
    var volume: Double = 0.8 { didSet { player.volume = Float(volume) } }

    private(set) var channel: TVChannel
    private(set) var running = false
    private(set) var status = T2Receiver.Status()
    private(set) var services: [TSService] = []
    private(set) var statistics = TVPlayer.Statistics()
    private(set) var playingServiceID: Int?
    private(set) var muxes: [TVStoredMux]
    private(set) var scanning = false
    private(set) var scanProgress = 0.0
    private(set) var scanStatus = ""
    private(set) var error: String?
    private(set) var droppedBlocks = 0

    let player = TVPlayer()
    private let shared: Shared
    private var pollTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    /// Empfangsseite: läuft auf der seriellen Warteschlange des HackRF.
    private final class Shared: @unchecked Sendable {
        let receiver = T2Receiver()
        let demux = TSDemuxer()
        let player: TVPlayer
        let lock = NSLock()
        // unter `lock`:
        var status = T2Receiver.Status()
        var services: [TSService] = []
        var pendingReset = false
        var pendingService: Int??          // .some(nil) = keinen Dienst
        var selectedService: Int?

        init(player: TVPlayer) {
            self.player = player
            receiver.packetHandler = { [demux] packet in demux.process(packet) }
            demux.servicesChanged = { [weak self] list in
                guard let self else { return }
                lock.withLock { services = list }
                if let id = selectedService, let service = list.first(where: { $0.id == id }) { apply(service) }
            }
            demux.pesHandler = { [weak self] pes in
                guard let self else { return }
                if pes.pid == currentVideo { player.handleVideo(pes) } else if pes.pid == currentAudio { player.handleAudio(pes) }
            }
        }

        private var currentVideo: Int?
        private var currentAudio: Int?
        private var appliedStreams: [TSStream] = []

        /// Ströme eines Dienstes übernehmen (auch wenn die PMT erst später kommt).
        private func apply(_ service: TSService) {
            guard service.streams != appliedStreams, !service.streams.isEmpty else { return }
            appliedStreams = service.streams
            let video = service.video
            let audio = service.audio.first { $0.language == "deu" || $0.language == "ger" } ?? service.audio.first
            currentVideo = video?.pid
            currentAudio = audio?.pid
            demux.pesPIDs = Set([video?.pid, audio?.pid].compactMap { $0 })
            player.select(video: video, audio: audio)
        }

        /// Läuft auf dem Empfangsthread.
        func handle(_ block: Data) {
            let (reset, service) = lock.withLock { () -> (Bool, Int??) in
                defer { pendingReset = false; pendingService = nil }
                return (pendingReset, pendingService)
            }
            if reset {
                receiver.reset()
                demux.reset()
                lock.withLock { services = [] }
                appliedStreams = []
                currentVideo = nil
                currentAudio = nil
                demux.pesPIDs = []
                player.stop()
            }
            if let service {
                selectedService = service
                appliedStreams = []
                currentVideo = nil
                currentAudio = nil
                demux.pesPIDs = []
                player.stop()
                if let id = service, let found = demux.services[id] { apply(found) }
            }
            receiver.process(block)
            let snapshot = receiver.currentStatus()
            lock.withLock { status = snapshot }
        }
    }

    private static let muxesKey = "tvMuxes"
    private static let channelKey = "tvChannel"
    private static let serviceKey = "tvService"

    init() {
        shared = Shared(player: player)
        let defaults = UserDefaults.standard
        let number = defaults.object(forKey: Self.channelKey) as? Int ?? 23
        channel = TVChannel.uhf.first { $0.number == number } ?? TVChannel(number: 23)
        if let data = defaults.data(forKey: Self.muxesKey), let stored = try? JSONDecoder().decode([TVStoredMux].self, from: data) {
            muxes = stored
        } else {
            muxes = []
        }
        playingServiceID = defaults.object(forKey: Self.serviceKey) as? Int
        player.volume = Float(volume)
    }

    // MARK: - Start und Stopp

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            try device.setSampleRate(UInt32(T2FrontEnd.inputRate.rounded()))
            try device.setBasebandFilter(20_000_000)      // Kanal liegt bei −fs/4: ±8,5 MHz nötig
            try applyGains()
            try device.setFrequency(channel.frequency + UInt64(T2FrontEnd.tuningOffset))
            let shared = shared
            shared.lock.withLock {
                shared.pendingReset = true
                shared.pendingService = .some(playingServiceID)
            }
            try device.startReceiving(owner: self) { block in shared.handle(block) }
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let (status, services) = self.shared.lock.withLock { (self.shared.status, self.shared.services) }
                    self.status = status
                    self.services = services
                    self.statistics = self.player.statistics
                    self.logStatus(status)
                    if let device = self.device, device.droppedBlocks != self.droppedBlocks {
                        // Lücke im Abtaststrom: die Rahmenlage stimmt nicht mehr – neu synchronisieren.
                        self.droppedBlocks = device.droppedBlocks
                        self.shared.lock.withLock { self.shared.pendingReset = true; self.shared.pendingService = .some(self.playingServiceID) }
                    }
                    self.rememberMux()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "DVB-T2")
    private var lastLog = Date.distantPast

    /// Alle 5 s eine Zeile ins Systemprotokoll (`log stream … category == "DVB-T2"`),
    /// damit sich ein Empfangsversuch auch ohne Blick auf die Seite nachlesen lässt.
    private func logStatus(_ status: T2Receiver.Status) {
        guard running, Date().timeIntervalSince(lastLog) >= 5 else { return }
        lastLog = Date()
        let total = status.blocksGood + status.blocksBad
        Self.log.notice("K\(self.channel.number, privacy: .public) \(status.stage, privacy: .public) \(self.modeDescription(status), privacy: .public) SNR \(status.snr, format: .fixed(precision: 1)) dB (nötig \(self.requiredSNR(status) ?? 0, format: .fixed(precision: 1))) Blöcke \(status.blocksGood)/\(total) BCH \(status.bchCorrectedBits) Bits/\(status.bchRescuedBlocks) gerettet Ablage \(status.frequencyOffsetHz, format: .fixed(precision: 0)) Hz \(status.sampleRateOffsetPPM, format: .fixed(precision: 2)) ppm Pakete \(status.packets)")
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
        pollTask?.cancel()
        pollTask = nil
        device?.stopReceiving(owner: self)
        player.stop()
        running = false
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

    func tune(_ channel: TVChannel, service: Int? = nil) {
        self.channel = channel
        UserDefaults.standard.set(channel.number, forKey: Self.channelKey)
        if let service { setPlaying(service) }
        // Ohne eigenen Empfang nur merken (sonst verstimmt es den Strom einer anderen Seite).
        do { if let device, device.isReceiving(for: self) { try device.setFrequency(channel.frequency + UInt64(T2FrontEnd.tuningOffset)) } } catch { self.error = error.localizedDescription }
        let id = playingServiceID
        shared.lock.withLock {
            shared.pendingReset = true
            shared.pendingService = .some(id)
            shared.status = T2Receiver.Status()
            shared.services = []
        }
        status = T2Receiver.Status()
        services = []
    }

    func play(serviceID: Int, on channelNumber: Int) {
        if channelNumber != channel.number, let target = TVChannel.uhf.first(where: { $0.number == channelNumber }) {
            tune(target, service: serviceID)
            return
        }
        setPlaying(serviceID)
        shared.lock.withLock { shared.pendingService = .some(serviceID) }
    }

    private func setPlaying(_ id: Int?) {
        playingServiceID = id
        UserDefaults.standard.set(id, forKey: Self.serviceKey)
    }

    var playingName: String? {
        guard let id = playingServiceID else { return nil }
        if let live = services.first(where: { $0.id == id }), !live.name.isEmpty { return live.name }
        return muxes.lazy.flatMap(\.services).first { $0.id == id }?.name
    }

    // MARK: - Gemerkte Multiplexe

    private func modeDescription(_ status: T2Receiver.Status) -> String {
        var parts: [String] = []
        if let fft = status.fft { parts.append(fft.name + (status.extended ? " erw." : "")) }
        if let gi = status.guardInterval { parts.append(gi.name) }
        if let pp = status.pattern { parts.append(pp.name) }
        if let plp = status.post?.plps.first(where: { $0.id == status.plpID }) {
            parts.append("\(plp.constellation?.name ?? "?") \(T2CodeRate(rawValue: plp.codeRate)?.name ?? "?")")
        }
        return parts.joined(separator: " · ")
    }

    private func requiredSNR(_ status: T2Receiver.Status) -> Double? {
        guard let plp = status.post?.plps.first(where: { $0.id == status.plpID }) else { return nil }
        return T2Threshold.requiredSNR(modulation: plp.modulation, codeRate: plp.codeRate)
    }

    private func rememberMux() {
        guard status.locked, !scanning else { return }
        let entry = makeEntry(channel: channel.number, status: status, services: services)
        if let index = muxes.firstIndex(where: { $0.channel == channel.number }) {
            // Dienste nur wachsen lassen; Pegel aktualisieren.
            var merged = entry
            if entry.services.count < muxes[index].services.count { merged.services = muxes[index].services }
            if muxes[index] != merged { muxes[index] = merged; save() }
        } else {
            muxes.append(entry)
            muxes.sort { $0.channel < $1.channel }
            save()
        }
    }

    private func makeEntry(channel: Int, status: T2Receiver.Status, services: [TSService]) -> TVStoredMux {
        TVStoredMux(channel: channel, mode: modeDescription(status), snr: status.snr, requiredSNR: requiredSNR(status),
                    services: services.filter { !$0.name.isEmpty && ($0.video != nil || $0.isRadio || $0.serviceType != 0) }
                        .map { TVStoredMux.Service(id: $0.id, name: $0.name, provider: $0.provider, radio: $0.isRadio, scrambled: $0.scrambled) })
    }

    private func save() {
        if let data = try? JSONEncoder().encode(muxes) { UserDefaults.standard.set(data, forKey: Self.muxesKey) }
    }

    func forgetMuxes() {
        muxes = []
        UserDefaults.standard.removeObject(forKey: Self.muxesKey)
    }

    // MARK: - Suchlauf

    /// Prüft K21–K48: kurz auf T2-Synchronisation warten, bei Erfolg die Dienste lesen.
    func scan() {
        guard running, !scanning else { return }
        scanning = true
        scanProgress = 0
        let previous = channel
        let previousService = playingServiceID
        scanTask = Task { [weak self] in
            guard let self else { return }
            var found = 0
            for (index, candidate) in TVChannel.uhf.enumerated() {
                if Task.isCancelled { break }
                self.scanStatus = String(localized: "Kanal \(candidate.name) (\(candidate.megahertz) MHz) · \(found) gefunden")
                self.scanProgress = Double(index) / Double(TVChannel.uhf.count)
                self.tune(candidate)
                // Erfassung braucht gut 0,3 s Signal plus Rechenzeit.
                var locked = false
                var lockStatus = T2Receiver.Status()
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(250))
                    let s = self.shared.lock.withLock { self.shared.status }
                    if s.locked { locked = true; lockStatus = s; break }
                }
                guard locked, !Task.isCancelled else { continue }
                // Dienste (SDT) – nur bei ausreichendem Störabstand.
                var status = T2Receiver.Status()
                var services: [TSService] = []
                let started = Date()
                while Date().timeIntervalSince(started) < 4, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    (status, services) = self.shared.lock.withLock { (self.shared.status, self.shared.services) }
                    if services.contains(where: { !$0.name.isEmpty }), Date().timeIntervalSince(started) > 2 { break }
                    if status.blocksGood == 0, status.blocksBad > 300 { break }   // zu schwach – nicht weiter warten
                }
                found += 1
                // Riss die Synchronisation danach wieder ab, fehlten Betriebsart und
                // Störabstand („0.0 dB“ grün ohne Angaben, live 27.10.2026) – dann
                // gilt der Stand vom Erfassen.
                if !status.locked || status.fft == nil { status = lockStatus }
                let entry = self.makeEntry(channel: candidate.number, status: status, services: services)
                self.muxes.removeAll { $0.channel == candidate.number }
                self.muxes.append(entry)
                self.muxes.sort { $0.channel < $1.channel }
                self.save()
            }
            let cancelled = Task.isCancelled
            self.scanning = false
            self.scanProgress = 1
            let withServices = self.muxes.filter { !$0.services.isEmpty }.count
            self.scanStatus = cancelled ? String(localized: "Suchlauf abgebrochen")
                : (found == 0 ? String(localized: "Kein Fernsehsignal gefunden – prüfe die Antenne (470–694 MHz).")
                              : String(localized: "\(found) Kanäle gefunden, \(withServices) davon mit lesbaren Sendern"))
            if let previousService, let mux = self.muxes.first(where: { $0.services.contains { $0.id == previousService } }),
               let target = TVChannel.uhf.first(where: { $0.number == mux.channel }) {
                self.tune(target, service: previousService)
            } else {
                self.tune(previous, service: previousService)
            }
        }
    }

    func cancelScan() { scanTask?.cancel() }
}
