import Foundation
import Observation

/// Ein Meshtastic-Knoten, zusammengefasst über seine Pakete.
struct MeshtasticNode: Identifiable, Sendable {
    let number: UInt32
    var longName: String?
    var shortName: String?
    var hardware: String?
    var role: String?
    var latitude: Double?
    var longitude: Double?
    var altitude: Int?
    var positionDate: Date?
    var telemetry: [String] = []
    var snrDB: Double
    var levelDB: Double
    var hops: Int?
    var packets: Int
    var firstSeen: Date
    var lastSeen: Date

    var id: UInt32 { number }
    var idString: String { Meshtastic.nodeName(number) }
    var displayName: String { longName ?? shortName ?? idString }
    var hasPosition: Bool { latitude != nil && longitude != nil }
}

/// Eine Zeile im Paketprotokoll.
struct MeshtasticLogLine: Identifiable, Sendable {
    let id: Int
    let frame: LoRaFrame
    let packet: MeshtasticPacket?
    /// Dasselbe Paket (Absender + ID) kam schon einmal – Weiterleitung.
    let duplicate: Bool

    var isText: Bool {
        if case .text? = packet?.data?.content { return true }
        return false
    }

    var kind: String {
        guard let packet else { return String(localized: "Kein Meshtastic") }
        guard let data = packet.data else { return String(localized: "Verschlüsselt") }
        return Meshtastic.portName(data.portnum)
    }

    var summary: String {
        guard let packet else { return String(localized: "\(frame.payload.count) Byte") }
        guard let data = packet.data else {
            return String(format: String(localized: "Kanal-Hash 0x%02X · %d Byte"), packet.header.channelHash, packet.encrypted.count)
        }
        return data.content.summary
    }

    var hex: String { frame.payload.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// Meshtastic-Empfang im HackRF-Modus (LoRa, Standardkanal entschlüsselt).
@MainActor
@Observable
final class MeshtasticModel {
    var region = MeshtasticRegion.eu868
    var preset = MeshtasticPreset.longFast
    /// Leer = Standardkanal (Name der Voreinstellung, z. B. „LongFast“).
    var channelName = ""
    /// Kanalschlüssel in Base64 wie in der App („AQ==“ = Standardschlüssel).
    var pskBase64 = "AQ=="
    var manualFrequency = false
    var frequencyMHz = 869.525
    var lnaGain = GainProfile.preset(.meshtastic).lna
    var vgaGain = GainProfile.preset(.meshtastic).vga
    var amplifier = GainProfile.preset(.meshtastic).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne

    private(set) var running = false
    private(set) var tunedMHz = 0.0
    private(set) var nodes: [MeshtasticNode] = []
    private(set) var log: [MeshtasticLogLine] = []
    private(set) var frameCount = 0
    private(set) var crcErrors = 0
    private(set) var headerErrors = 0
    private(set) var undecrypted = 0
    private(set) var noiseDB = -100.0
    private(set) var error: String?

    private let shared = Shared()
    private var pollTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    var effectiveChannelName: String { channelName.isEmpty ? preset.displayName : channelName }
    var pskValid: Bool { MeshtasticChannel(name: "", pskBase64: pskBase64) != nil }

    /// Frequenz aus Region, Voreinstellung und Kanalname (wie die Firmware).
    var automaticFrequencyMHz: Double {
        region.frequencyMHz(preset: preset, channelName: effectiveChannelName)
    }

    var channelHash: UInt8? { MeshtasticChannel(name: effectiveChannelName, pskBase64: pskBase64)?.hash }

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var demod: LoRaDemodulator?
        var channels: [MeshtasticChannel] = []
        var nodes: [UInt32: MeshtasticNode] = [:]
        var log: [MeshtasticLogLine] = []
        var seen: [UInt64: Date] = [:]
        var count = 0
        var undecrypted = 0
        var crcErrors = 0
        var headerErrors = 0
        var noiseDB = -100.0

        /// Läuft auf dem Empfangsthread.
        func handle(_ block: Data) {
            guard let demod = lock.withLock({ self.demod }) else { return }
            let frames = demod.process(block)
            let (crc, header, noise) = (demod.crcErrors, demod.headerErrors, demod.noiseDB)
            let channels: [MeshtasticChannel] = lock.withLock {
                // Nur Werte des aktuellen Demodulators übernehmen (Umschalten mitten im Block).
                if self.demod === demod { crcErrors = crc; headerErrors = header; noiseDB = noise }
                return self.channels
            }
            guard !frames.isEmpty else { return }
            let decoded = frames.map { frame -> (LoRaFrame, MeshtasticPacket?) in
                guard frame.crcValid != false else { return (frame, nil) }
                return (frame, Meshtastic.decode(frame.payload, channels: channels))
            }
            lock.withLock {
                for (frame, packet) in decoded where frame.crcValid != false {
                    ingest(frame, packet)
                }
                if log.count > 1000 { log.removeFirst(log.count - 1000) }
            }
        }

        private func ingest(_ frame: LoRaFrame, _ packet: MeshtasticPacket?) {
            count += 1
            var duplicate = false
            if let packet {
                let key = UInt64(packet.header.from) << 32 | UInt64(packet.header.id)
                duplicate = seen[key] != nil
                seen[key] = frame.date
                if seen.count > 2000 {
                    let limit = frame.date.addingTimeInterval(-600)
                    seen = seen.filter { $0.value > limit }
                }
                if packet.data == nil, !duplicate { undecrypted += 1 }
                if !duplicate { update(packet, frame) }
            }
            log.append(MeshtasticLogLine(id: count, frame: frame, packet: packet, duplicate: duplicate))
        }

        private func update(_ packet: MeshtasticPacket, _ frame: LoRaFrame) {
            let number = packet.header.from
            var node = nodes[number] ?? MeshtasticNode(number: number, snrDB: frame.snrDB, levelDB: frame.levelDB,
                                                      packets: 0, firstSeen: frame.date, lastSeen: frame.date)
            node.packets += 1
            node.snrDB = frame.snrDB
            node.levelDB = frame.levelDB
            node.lastSeen = frame.date
            node.hops = packet.header.hopsTaken
            switch packet.data?.content {
            case .nodeInfo(let user)?:
                node.longName = user.longName ?? node.longName
                node.shortName = user.shortName ?? node.shortName
                node.hardware = user.hardwareName ?? node.hardware
                node.role = user.roleName ?? node.role
            case .position(let position)? where position.hasFix:
                node.latitude = position.latitude
                node.longitude = position.longitude
                node.altitude = position.altitude ?? node.altitude
                node.positionDate = frame.date
            case .telemetry(let telemetry)?:
                if !telemetry.readings.isEmpty { node.telemetry = telemetry.readings }
            default:
                break
            }
            nodes[number] = node
            // Knotennummern sind frei wählbar (LongFast mit Standardschlüssel kann jeder senden).
            DevicePruning.prune(&nodes, limit: 2000, maxAge: 3600, now: frame.date) { $0.lastSeen }
        }
    }

    // MARK: - Steuerung

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            try device.setSampleRate(UInt32(LoRaDemodulator.inputRate))
            try tune()
            try applyGains()
            let shared = shared
            try device.startReceiving(owner: self) { block in shared.handle(block) }
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    self.poll()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        device?.stopReceiving(owner: self)
        running = false
    }

    private func poll() {
        let (nodes, log, count, undecrypted, stats) = shared.lock.withLock {
            (Array(shared.nodes.values), shared.log, shared.count, shared.undecrypted,
             (shared.crcErrors, shared.headerErrors, shared.noiseDB))
        }
        if count != frameCount {
            self.nodes = nodes.sorted { $0.lastSeen > $1.lastSeen }
            self.log = log.reversed()
            frameCount = count
            self.undecrypted = undecrypted
        }
        (crcErrors, headerErrors, noiseDB) = stats
    }

    /// Region, Voreinstellung, Kanalname oder Frequenz geändert.
    func configurationChanged() {
        if !region.presets.contains(preset) { preset = .longFast }
        if !manualFrequency { frequencyMHz = automaticFrequencyMHz }
        keysChanged()
        guard running else { return }
        do { try tune() } catch { self.error = error.localizedDescription }
    }

    /// Kanalschlüssel neu setzen; der Standardkanal der Voreinstellung wird
    /// immer mitversucht.
    func keysChanged() {
        var channels: [MeshtasticChannel] = []
        if let own = MeshtasticChannel(name: effectiveChannelName, pskBase64: pskBase64) { channels.append(own) }
        let standard = MeshtasticChannel(name: preset.displayName, psk: [1])
        if !channels.contains(standard) { channels.append(standard) }
        shared.lock.withLock { shared.channels = channels }
    }

    private func tune() throws {
        if !manualFrequency { frequencyMHz = automaticFrequencyMHz }
        keysChanged()
        let center = frequencyMHz * 1_000_000
        let demod = LoRaDemodulator(parameters: preset.parameters, centerFrequency: center)
        shared.lock.withLock { shared.demod = demod }
        tunedMHz = frequencyMHz
        guard let device else { return }
        try device.setFrequency(UInt64(center - LoRaDemodulator.offset))
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

    func clear() {
        shared.lock.withLock {
            shared.nodes = [:]
            shared.log = []
            shared.seen = [:]
            shared.undecrypted = 0
        }
        nodes = []
        log = []
        undecrypted = 0
    }
}
