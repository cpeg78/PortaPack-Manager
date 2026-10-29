import Foundation
import Observation

/// AIS-Empfang im HackRF-Modus: beide Kanäle (161,975 und 162,025 MHz)
/// gleichzeitig, GMSK 9600, HDLC, Auswertung der Schiffsmeldungen.
@MainActor
@Observable
final class AISModel {
    nonisolated static let centerMHz = 162.000
    /// Kanal 87B (A) und 88B (B) relativ zur Mitte.
    nonisolated static let channels: [(name: String, offset: Double)] = [("A", -25_000), ("B", 25_000)]

    var lnaGain = GainProfile.preset(.ais).lna
    var vgaGain = GainProfile.preset(.ais).vga
    var amplifier = GainProfile.preset(.ais).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne

    private(set) var running = false
    private(set) var vessels: [AISVessel] = []
    /// Anzahl der Schiffe für die Startseite (eigene Größe, siehe `ADSBModel.aircraftCount`).
    private(set) var vesselCount = 0
    private(set) var log: [LogLine] = []
    private(set) var messageCount = 0
    private(set) var channelDB: [Float] = [-100, -100]
    private(set) var error: String?

    struct LogLine: Identifiable, Sendable {
        let id: Int
        let date: Date
        let mmsi: Int
        let type: Int
        let nmea: [String]
    }

    private let shared = Shared()
    private var updateTask: Task<Void, Never>?

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let front = FMChannelizer(channelOffsets: AISModel.channels.map(\.offset), stage1Cutoff: 60_000, channelCutoff: 9_000)
        let demods = AISModel.channels.map { _ in GMSKDemodulator() }
        var tracker = AISTracker()
        var recent: [LogLine] = []
        var count = 0
        var power: [Float] = [-100, -100]
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            try device.setSampleRate(UInt32(FMChannelizer.inputRate))
            try device.setFrequency(UInt64(Self.centerMHz * 1_000_000 - FMChannelizer.offset))
            try applyGains(to: device)
            let shared = shared
            shared.front.reset()
            try device.startReceiving(owner: self) { block in
                let outputs = shared.front.process(block)
                let power = shared.front.channelPowerDB
                shared.lock.withLock { shared.power = power }
                var decoded: [(AISBits, String)] = []
                for (index, samples) in outputs.enumerated() {
                    for frame in shared.demods[index].process(samples) {
                        decoded.append((AISBits(frameBytes: frame), AISModel.channels[index].name))
                    }
                }
                guard !decoded.isEmpty else { return }
                var outgoing: [String] = []
                shared.lock.withLock {
                    for (bits, channel) in decoded {
                        guard let message = AISMessage.decode(bits) else { continue }
                        shared.tracker.ingest(message, channel: channel)
                        shared.count += 1
                        let nmea = AISNMEA.sentences(for: bits, channel: channel, sequence: shared.count)
                        outgoing += nmea
                        shared.recent.append(LogLine(id: shared.count, date: Date(), mmsi: message.mmsi, type: message.type, nmea: nmea))
                    }
                    if shared.recent.count > 500 { shared.recent.removeFirst(shared.recent.count - 500) }
                }
                NMEAFeeder.shared.send(outgoing)
            }
            running = true
            error = nil
            updateTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let (vessels, recent, count) = self.shared.lock.withLock {
                        (self.shared.tracker.sorted, self.shared.recent, self.shared.count)
                    }
                    if count != self.messageCount {
                        self.vessels = vessels
                        if self.vesselCount != vessels.count { self.vesselCount = vessels.count }
                        self.log = recent.suffix(200).reversed()
                        self.messageCount = count
                        self.archive(vessels)
                    }
                    // Nur bei Änderung zuweisen – jede Zuweisung zeichnet neu (Review L2).
                    let power = self.shared.lock.withLock { self.shared.power }
                    if power != self.channelDB { self.channelDB = power }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop(on device: HackRFDevice?) {
        updateTask?.cancel()
        updateTask = nil
        device?.stopReceiving(owner: self)
        running = false
        TrafficArchive.ais.save()
    }

    /// Schiffe mit neuer Meldung ins Tagesarchiv (das Archiv merkt sich, was neu ist).
    private func archive(_ vessels: [AISVessel]) {
        let updates = vessels.map { vessel in
            let kind = vessel.isBaseStation ? String(localized: "Basisstation") : vessel.isAidToNavigation ? String(localized: "Seezeichen")
                : AISMessage.shipTypeText(vessel.shipType)
            return SightingUpdate(
                key: String(vessel.mmsi), name: vessel.name, registration: vessel.callsign, type: kind,
                route: vessel.destination, lastSeen: vessel.lastSeen, messages: vessel.messages,
                latitude: vessel.latitude, longitude: vessel.longitude, speed: vessel.speedKnots)
        }
        TrafficArchive.ais.record(updates, home: TrafficArchive.home)
    }

    func applyGains(to device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    func clear() {
        shared.lock.withLock {
            shared.tracker = AISTracker()
            shared.recent.removeAll()
        }
        vessels = []
        log = []
    }
}
