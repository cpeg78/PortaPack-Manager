import Foundation
import Observation

/// Ein Sensor, zusammengefasst über alle seine Pakete.
struct SensorDevice: Identifiable, Sendable, Equatable {
    var latest: SensorReading
    var firstSeen: Date
    var lastSeen: Date
    var count: Int
    var rssiDB: Double
    var snrDB: Double
    var offsetKHz: Double
    var frequencyMHz: Double

    var id: String { latest.key }
}

/// Ein empfangenes Paket mit Pulsanalyse und – falls erkannt – Werten.
struct SensorPacket: Identifiable, Sendable, Equatable {
    let id: Int
    let train: SensorPulseTrain
    let analysis: SensorPulseAnalysis
    let readings: [SensorReading]
    let frequencyMHz: Double
}

/// Funksensoren auf 433/868 MHz im HackRF-Modus (wie rtl_433).
@MainActor
@Observable
final class SensorModel {
    enum Band: String, CaseIterable, Identifiable {
        case ism433 = "433,92 MHz"
        case srd868 = "868,30 MHz"
        var id: String { rawValue }
        var frequencyMHz: Double { self == .ism433 ? 433.92 : 868.3 }
        /// Anzeige mit dem Dezimaltrenner des Gebietsschemas (der Rohwert ist fest deutsch).
        var title: String { FrequencyInput.format(frequencyMHz, decimals: 2) + " MHz" }
    }

    var frequencyMHz: Double = 433.92
    var lnaGain = GainProfile.preset(.sensors).lna
    var vgaGain = GainProfile.preset(.sensors).vga
    var amplifier = GainProfile.preset(.sensors).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne
    /// Pakete ohne erkannten Sensor in der Liste zeigen.
    var showUnknown = true

    private(set) var running = false
    private(set) var sensors: [SensorDevice] = []
    private(set) var packets: [SensorPacket] = []
    private(set) var packetCount = 0
    private(set) var decodedCount = 0
    private(set) var noiseDB = -100.0
    private(set) var error: String?

    private let shared = Shared()
    private var pollTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let demod = SensorDemodulator()
        var frequencyMHz = 433.92
        var sensors: [String: SensorDevice] = [:]
        var packets: [SensorPacket] = []
        var nextID = 0
        var decoded = 0
        var noiseDB = -100.0

        /// Läuft auf dem Empfangsthread.
        func handle(_ block: Data) {
            let trains = demod.process(block)
            let noise = demod.noiseDB
            guard !trains.isEmpty else {
                lock.withLock { noiseDB = noise }
                return
            }
            // Analyse und Dekoder brauchen keinen Lock – nur das Ablegen.
            let results = trains.map { ($0, SensorAnalyzer.analyze($0), SensorDecoders.decode($0)) }
            lock.withLock {
                noiseDB = noise
                for (train, analysis, readings) in results {
                    packets.append(SensorPacket(id: nextID, train: train, analysis: analysis,
                                                readings: readings, frequencyMHz: frequencyMHz))
                    nextID += 1
                    if !readings.isEmpty { decoded += 1 }
                    for reading in readings {
                        let key = reading.key
                        if var sensor = sensors[key] {
                            sensor.latest = reading
                            sensor.lastSeen = train.date
                            sensor.count += 1
                            sensor.rssiDB = train.rssiDB
                            sensor.snrDB = train.snrDB
                            sensor.offsetKHz = train.offsetKHz
                            sensors[key] = sensor
                        } else {
                            sensors[key] = SensorDevice(latest: reading, firstSeen: train.date, lastSeen: train.date,
                                                        count: 1, rssiDB: train.rssiDB, snrDB: train.snrDB,
                                                        offsetKHz: train.offsetKHz, frequencyMHz: frequencyMHz)
                            // Kennungen aus der Luft (Reifendrucksensoren vorbeifahrender Autos …) – begrenzen.
                            DevicePruning.prune(&sensors, limit: 2000, maxAge: 3600, now: train.date) { $0.lastSeen }
                        }
                    }
                }
                if packets.count > 400 { packets.removeFirst(packets.count - 400) }
            }
        }
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            shared.demod.reset()
            try device.setSampleRate(UInt32(SensorDemodulator.inputRate))
            try retune()
            try applyGains()
            let shared = shared
            try device.startReceiving(owner: self) { block in shared.handle(block) }
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let (sensors, packets, nextID, decoded, noise) = self.shared.lock.withLock {
                        (Array(self.shared.sensors.values), self.shared.packets, self.shared.nextID,
                         self.shared.decoded, self.shared.noiseDB)
                    }
                    let sorted = sensors.sorted { $0.lastSeen > $1.lastSeen }
                    if sorted != self.sensors {
                        Self.reportToMQTT(sorted, previous: self.sensors)
                        self.sensors = sorted
                    }
                    if nextID != self.packetCount {
                        self.packets = packets.reversed()
                        self.packetCount = nextID
                        self.decodedCount = decoded
                    }
                    if self.noiseDB != noise { self.noiseDB = noise }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Neue oder geänderte Sensoren an Home Assistant (nur wenn dort eingeschaltet).
    private static func reportToMQTT(_ sensors: [SensorDevice], previous: [SensorDevice]) {
        let bridge = MQTTBridge.shared
        guard bridge.isEnabled(.sensors) || bridge.isEnabled(.tpms) else { return }
        let before = Dictionary(previous.map { ($0.id, $0.lastSeen) }, uniquingKeysWith: { a, _ in a })
        for sensor in sensors where before[sensor.id] != sensor.lastSeen {
            bridge.report(source: MQTTFeeds.isTPMS(sensor) ? .tpms : .sensors, deviceID: sensor.id,
                          name: MQTTFeeds.name(of: sensor), model: sensor.latest.model,
                          values: MQTTFeeds.values(of: sensor), seen: sensor.lastSeen)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        device?.stopReceiving(owner: self)
        running = false
    }

    func tune(to mhz: Double) {
        frequencyMHz = max(1, min(6000, mhz))
        do { try retune() } catch { self.error = error.localizedDescription }
    }

    private func retune() throws {
        shared.lock.withLock { shared.frequencyMHz = frequencyMHz }
        guard let device else { return }
        try device.setFrequency(UInt64(frequencyMHz * 1_000_000 - SensorDemodulator.offset))
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
            shared.sensors = [:]
            shared.packets = []
            shared.decoded = 0
        }
        sensors = []
        packets = []
        decodedCount = 0
    }
}
