import Foundation
import Observation

/// APRS-Empfang im HackRF-Modus: NFM auf 144,800 MHz, AFSK 1200, AX.25.
@MainActor
@Observable
final class APRSModel {
    enum Channel: Double, CaseIterable, Identifiable {
        case europe = 144.800
        case northAmerica = 144.390
        case iss = 145.825
        var id: Double { rawValue }
        var title: String {
            switch self {
            case .europe: String(localized: "144,800 MHz (Europa)")
            case .northAmerica: String(localized: "144,390 MHz (Nordamerika)")
            case .iss: String(localized: "145,825 MHz (ISS)")
            }
        }
    }

    var channel: Channel = .europe
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
        let front = FMChannelizer(channelOffsets: [0], stage1Cutoff: 50_000, channelCutoff: 8_000)
        let demod = AFSKDemodulator()
        var tracker = APRSStationTracker()
        var recent: [APRSPacket] = []
        var count = 0
        var monitor = false
        var dcState: Float = 0
        var power: Float = -100
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            try device.setSampleRate(UInt32(FMChannelizer.inputRate))
            try device.setFrequency(UInt64(channel.rawValue * 1_000_000 - FMChannelizer.offset))
            try applyGains(to: device)
            let shared = shared
            let output = audio.buffer
            shared.front.reset()
            shared.demod.reset()
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
            running = true
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

    /// Kanalwechsel bei laufendem Empfang.
    func retune(on device: HackRFDevice?) {
        guard running, let device, device.isReceiving(for: self) else { return }
        do {
            try device.setFrequency(UInt64(channel.rawValue * 1_000_000 - FMChannelizer.offset))
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
