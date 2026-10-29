import Foundation
import Observation

struct FLARMDetection: Identifiable, Sendable, Equatable {
    let id: Int
    let date: Date
    let hex: String
    let crcValid: Bool
    let rssiDB: Double
}

/// FLARM/OGN-Erkennung (868,2 MHz) im HackRF-Modus. Zeigt CRC-geprüfte Pakete
/// mit Rohbytes und Pegel; Positionen werden nicht entschlüsselt. Live unerprobt.
@MainActor
@Observable
final class FLARMModel {
    var lnaGain = GainProfile.preset(.meshtastic).lna
    var vgaGain = GainProfile.preset(.meshtastic).vga
    var amplifier = GainProfile.preset(.meshtastic).amplifier
    var antennaPower = false

    private(set) var running = false
    private(set) var detections: [FLARMDetection] = []
    private(set) var total = 0
    private(set) var crcValidCount = 0
    private(set) var noiseDB = -100.0
    private(set) var error: String?

    private let shared = Shared()
    private var pollTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let demod = FLARMDemodulator()
        var detections: [FLARMDetection] = []
        var total = 0
        var valid = 0
        var noiseDB = -100.0

        func handle(_ block: Data) {
            let packets = demod.process(block)
            let noise = demod.noiseDB
            lock.withLock {
                noiseDB = noise
                for packet in packets {
                    total += 1
                    if packet.crcValid { valid += 1 }
                    detections.append(FLARMDetection(id: total, date: packet.date, hex: packet.hex,
                                                      crcValid: packet.crcValid, rssiDB: packet.rssiDB))
                    if detections.count > 500 { detections.removeFirst(detections.count - 500) }
                }
            }
        }
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            shared.demod.reset()
            try device.setSampleRate(UInt32(FLARMDemodulator.inputRate))
            try device.setBasebandFilter(HackRFDevice.basebandFilter(for: UInt32(FLARMDemodulator.inputRate)))
            try device.setFrequency(UInt64(FLARMLink.frequencyMHz * 1_000_000 - FLARMDemodulator.offset))
            try applyGains()
            let shared = shared
            try device.startReceiving(owner: self) { shared.handle($0) }
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let (d, t, v, n) = self.shared.lock.withLock { (self.shared.detections, self.shared.total, self.shared.valid, self.shared.noiseDB) }
                    self.detections = d.reversed()
                    self.total = t; self.crcValidCount = v; self.noiseDB = n
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        device?.stopReceiving(owner: self)
        running = false
    }

    func clear() {
        shared.lock.withLock { shared.detections = []; shared.total = 0; shared.valid = 0 }
        detections = []; total = 0; crcValidCount = 0
    }

    func applyGains() throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain)); try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier); try device.setAntennaPower(antennaPower)
    }
    func applyGainsQuietly() { do { try applyGains() } catch { self.error = error.localizedDescription } }
}
