import Foundation
import Observation

/// POCSAG-Empfang im HackRF-Modus: NFM, 2-FSK ±4,5 kHz, 512/1200/2400 Bd.
/// Vorlage ist DAPNET (Funkruf der Funkamateure, zum Mitlesen gesendet).
/// Nachrichten bleiben nur im Speicher – nichts wird auf Platte geschrieben.
@MainActor
@Observable
final class PagerModel {
    static let dapnetMHz = 439.9875

    var lnaGain = GainProfile.preset(.pager).lna
    var vgaGain = GainProfile.preset(.pager).vga
    var amplifier = GainProfile.preset(.pager).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne
    var monitorAudio = false {
        didSet { shared.lock.withLock { shared.monitor = monitorAudio } }
    }

    private(set) var running = false
    private(set) var messages: [PagerMessage] = []
    private(set) var messageCount = 0
    private(set) var signalDB: Float = -100
    private(set) var lockedRates: [Int] = []
    private(set) var error: String?

    private let shared = Shared()
    private let audio = AudioOutput()
    private var updateTask: Task<Void, Never>?

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let front = FMChannelizer(channelOffsets: [0], stage1Cutoff: 50_000, channelCutoff: 9_000)
        let demod = POCSAGDemodulator()
        var recent: [PagerMessage] = []
        var count = 0
        var monitor = false
        var dcState: Float = 0
        var power: Float = -100
        var lockedRates: [Int] = []
    }

    static func tuning(_ mhz: Double) -> UInt64 {
        UInt64((mhz * 1_000_000 - FMChannelizer.offset).rounded())
    }

    func start(on device: HackRFDevice, frequencyMHz: Double) {
        guard !running else { return }
        do {
            try device.setSampleRate(UInt32(FMChannelizer.inputRate))
            try device.setFrequency(Self.tuning(frequencyMHz))
            try applyGains(to: device)
            let shared = shared
            let output = audio.buffer
            shared.front.reset()
            shared.demod.reset()
            if monitorAudio { try audio.start() }
            try device.startReceiving(owner: self) { block in
                let disc = shared.front.process(block)[0]
                let found = shared.demod.process(disc)
                let power = shared.front.channelPowerDB.first ?? -100
                let locked = shared.demod.lockedRates
                let monitor = shared.lock.withLock {
                    shared.power = power
                    shared.lockedRates = locked
                    return shared.monitor
                }
                if monitor {
                    // Hub ±4,5 kHz → ±0,59 rad; Gleichanteil (Frequenzablage) entfernen.
                    var dc = shared.dcState
                    let samples = disc.map { x -> Float in
                        dc += 0.001 * (x - dc)
                        return max(-1, min(1, (x - dc) * 1.2))
                    }
                    shared.dcState = dc
                    output.write(samples)
                }
                guard !found.isEmpty else { return }
                shared.lock.withLock {
                    shared.recent.append(contentsOf: found)
                    if shared.recent.count > 1000 { shared.recent.removeFirst(shared.recent.count - 1000) }
                    shared.count += found.count
                }
            }
            running = true
            error = nil
            updateTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self else { return }
                    let (recent, count, power, locked) = self.shared.lock.withLock {
                        (self.shared.recent, self.shared.count, self.shared.power, self.shared.lockedRates)
                    }
                    if count != self.messageCount {
                        self.messages = recent.reversed()
                        self.messageCount = count
                    }
                    self.signalDB = power
                    self.lockedRates = locked
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
        lockedRates = []
    }

    /// Frequenzwechsel bei laufendem Empfang.
    func retune(on device: HackRFDevice?, frequencyMHz: Double) {
        guard running, let device, device.isReceiving(for: self) else { return }
        do {
            try device.setFrequency(Self.tuning(frequencyMHz))
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
        shared.lock.withLock { shared.recent.removeAll() }
        messages = []
    }
}
