import Foundation
import Observation
import os

/// APRS-Empfang im HackRF-Modus: NFM auf 144,800 MHz, AFSK 1200, AX.25 –
/// oder LoRa-APRS auf 433,775 MHz (SF12, 125 kHz, CR 4/5, Sync 0x12; die
/// Nutzlast ist nach drei Vorspann-Bytes eine TNC2-Textzeile).
@MainActor
@Observable
final class APRSModel {
    /// Kennung statt Frequenz als Rohwert: 433,775 MHz gibt es als FM- und als LoRa-APRS
    /// (31.10.2026: ein Testsender schickte dort AFSK über FM, kein LoRa).
    enum Channel: String, CaseIterable, Identifiable {
        case europe = "eu", northAmerica = "na", iss, uhf, lora
        var id: String { rawValue }
        var mhz: Double {
            switch self {
            case .europe: 144.800
            case .northAmerica: 144.390
            case .iss: 145.825
            case .uhf, .lora: 433.775
            }
        }
        /// LoRa statt AFSK: anderer Vordergrund (2 MS/s, LoRa-Demodulator).
        var isLoRa: Bool { self == .lora }
        var title: String {
            switch self {
            case .europe: String(localized: "144,800 MHz (Europa)")
            case .northAmerica: String(localized: "144,390 MHz (Nordamerika)")
            case .iss: String(localized: "145,825 MHz (ISS)")
            case .uhf: String(localized: "433,775 MHz (FM-APRS)")
            case .lora: String(localized: "433,775 MHz (LoRa-APRS)")
            }
        }
    }

    var channel: Channel = Channel(rawValue: UserDefaults.standard.string(forKey: "aprsChannel") ?? "") ?? .europe {
        didSet { UserDefaults.standard.set(channel.rawValue, forKey: "aprsChannel") }
    }
    var lnaGain = GainProfile.preset(.aprs).lna
    var vgaGain = GainProfile.preset(.aprs).vga
    var amplifier = GainProfile.preset(.aprs).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne
    var monitorAudio = false {
        didSet { shared.lock.withLock { shared.monitor = monitorAudio } }
    }

    private(set) var running = false
    private(set) var stations: [APRSStation] = []
    private(set) var log: [APRSPacket] = []
    private(set) var packetCount = 0
    private(set) var signalDB: Float = -100
    private(set) var error: String?

    private let shared = Shared()
    private let audio = AudioOutput()
    private var updateTask: Task<Void, Never>?

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        /// Auf 70 cm etwas breiter: dort liegen Sender samt HackRF-Quarz leicht ±5 kHz daneben
        /// (Aufnahme 31.10.2026: Träger +5 kHz, Hub ±3,5 kHz).
        var front = FMChannelizer(channelOffsets: [0], stage1Cutoff: 50_000, channelCutoff: 8_000)
        let demod = AFSKDemodulator()
        var tracker = APRSStationTracker()
        var recent: [APRSPacket] = []
        var count = 0
        var monitor = false
        var dcState: Float = 0
        var power: Float = -100
        /// LoRa-APRS-Demodulator(en) (nur der Empfangsthread benutzt sie).
        var lora: [LoRaDemodulator] = []
        var loraLogged = Date.distantPast
        var loraCounts: [Int] = []
    }

    nonisolated static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "APRS")

    /// LoRa-APRS: SF12/125 kHz, Sync-Wort 0x12 (SX127x-Standard „privat“).
    nonisolated static let loraParameters = LoRaParameters(spreadingFactor: 12, bandwidth: 125_000, syncWord: 0x12)

    private func centerHz(_ channel: Channel) -> UInt64 {
        UInt64(channel.mhz * 1_000_000 - (channel.isLoRa ? LoRaDemodulator.offset : FMChannelizer.offset))
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            let lora = channel.isLoRa
            try device.setSampleRate(UInt32(lora ? LoRaDemodulator.inputRate : FMChannelizer.inputRate))
            try device.setFrequency(centerHz(channel))
            try applyGains(to: device)
            let shared = shared
            let output = audio.buffer
            shared.front = FMChannelizer(channelOffsets: [0], stage1Cutoff: 50_000, channelCutoff: channel == .uhf ? 12_000 : 8_000)
            shared.demod.reset()
            if lora {
                shared.lora = [LoRaDemodulator(parameters: Self.loraParameters, centerFrequency: channel.mhz * 1_000_000)]
                shared.loraCounts = []
                try device.startReceiving(owner: self) { block in
                    let frames = shared.lora.flatMap { $0.process(block) }
                    // Alle 10 s: erkannte Präambeln und Sync-Fehler je SF, wenn sich etwas tat.
                    let counts = shared.lora.flatMap { [$0.detections, $0.syncFailures] }
                    if counts != shared.loraCounts, Date().timeIntervalSince(shared.loraLogged) >= 10 {
                        shared.loraCounts = counts
                        shared.loraLogged = Date()
                        let text = shared.lora.map { d in
                            "SF\(d.parameters.spreadingFactor) \(d.detections)/\(d.syncFailures)" + (d.lastSyncSeen.isEmpty ? "" : " \(d.lastSyncSeen)")
                        }.joined(separator: ", ")
                        Self.log.notice("LoRa Präambeln/Sync-Fehler (erwartet Sync \(Self.loraParameters.syncSymbols.0)/\(Self.loraParameters.syncSymbols.1)): \(text, privacy: .public)")
                    }
                    // Jeder Rahmen ins Protokoll: zeigt, ob es an Erkennung, Prüfsumme oder APRS-Text scheitert.
                    for f in frames {
                        let text = String(decoding: f.payload.prefix(80).map { $0 < 0x20 || $0 > 0x7E ? 0x2E : $0 }, as: UTF8.self)
                        Self.log.notice("LoRa-Rahmen: CRC \(f.crcValid.map { $0 ? "ok" : "falsch" } ?? "keine", privacy: .public), \(f.payload.count) Byte, CR 4/\(f.codingRate + 4), SNR \(f.snrDB, format: .fixed(precision: 1)) dB, Pegel \(f.levelDB, format: .fixed(precision: 1)) dBFS, Ablage \(Int(f.frequencyOffsetHz)) Hz, korrigiert \(f.correctedCodewords): \(text, privacy: .public)")
                    }
                    // Nur Rahmen mit gültiger Prüfsumme – SF12 findet sonst Rauschen.
                    let packets = frames.filter { $0.crcValid == true }.compactMap { APRSPacket.parse(loRa: $0.payload) }
                    shared.lock.withLock {
                        if let level = frames.last?.levelDB { shared.power = Float(level) }
                        guard !packets.isEmpty else { return }
                        for packet in packets { shared.tracker.ingest(packet) }
                        shared.recent.append(contentsOf: packets)
                        if shared.recent.count > 500 { shared.recent.removeFirst(shared.recent.count - 500) }
                        shared.count += packets.count
                    }
                }
            } else {
                if monitorAudio { try audio.start() }
                try device.startReceiving(owner: self) { block in
                    let disc = shared.front.process(block)[0]
                    let frames = shared.demod.process(disc)
                    let power = shared.front.channelPowerDB.first ?? -100
                    let monitor = shared.lock.withLock { shared.power = power; return shared.monitor }
                    if monitor {
                        // Hub ±3 kHz → ±0,4 rad; Gleichanteil (Frequenzablage) entfernen.
                        var dc = shared.dcState
                        let samples = disc.map { x -> Float in
                            dc += 0.001 * (x - dc)
                            return max(-1, min(1, (x - dc) * 1.5))
                        }
                        shared.dcState = dc
                        output.write(samples)
                    }
                    let packets = frames.compactMap(AX25Frame.parse).map(APRSPacket.parse)
                    guard !packets.isEmpty else { return }
                    shared.lock.withLock {
                        for packet in packets { shared.tracker.ingest(packet) }
                        shared.recent.append(contentsOf: packets)
                        if shared.recent.count > 500 { shared.recent.removeFirst(shared.recent.count - 500) }
                        shared.count += packets.count
                    }
                }
            }
            running = true
            runningChannel = channel
            error = nil
            updateTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self else { return }
                    let (stations, recent, count) = self.shared.lock.withLock {
                        (self.shared.tracker.sorted, self.shared.recent, self.shared.count)
                    }
                    if count != self.packetCount {
                        self.stations = stations
                        self.log = recent.suffix(200).reversed()
                        self.packetCount = count
                    }
                    self.signalDB = self.shared.lock.withLock { self.shared.power }
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
        audio.stop()
        running = false
    }

    /// Kanal, auf dem gerade empfangen wird (AFSK und LoRa brauchen verschiedene Vordergründe).
    private var runningChannel: Channel?

    /// Kanalwechsel bei laufendem Empfang. Zwischen AFSK und LoRa neu starten.
    func retune(on device: HackRFDevice?) {
        guard running, let device, device.isReceiving(for: self) else { return }
        if runningChannel?.isLoRa != channel.isLoRa {
            stop(on: device)
            start(on: device)
            return
        }
        runningChannel = channel
        do {
            try device.setFrequency(centerHz(channel))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setMonitoring(_ on: Bool) {
        monitorAudio = on
        guard running else { return }
        if on {
            do { try audio.start() } catch { self.error = error.localizedDescription }
        } else {
            audio.stop()
        }
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
            shared.tracker = APRSStationTracker()
            shared.recent.removeAll()
        }
        stations = []
        log = []
    }
}
