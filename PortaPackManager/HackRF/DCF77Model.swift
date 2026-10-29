import Foundation
import Observation

/// Funkuhr: DCF77 (77,5 kHz) im HackRF-Modus. Zeigt den Sekundentakt, die Bits
/// der laufenden Minute, die dekodierte Zeit und den Gang der Rechneruhr.
/// Der HackRF arbeitet hier unter seinem Datenblatt (1 MHz) – ob der Pegel
/// reicht, zeigt der Rauschabstand des Trägers. Live unerprobt.
@MainActor
@Observable
final class DCF77Model {
    var lnaGain = GainProfile.preset(.dcf77).lna
    var vgaGain = GainProfile.preset(.dcf77).vga
    var amplifier = GainProfile.preset(.dcf77).amplifier
    var antennaPower = false

    struct Status: Sendable {
        var carrierOffsetHz = 0.0
        var snrDB = 0.0
        var levelDBFS = -100.0
        var locked = false
        var contrast: Float = 0
        var bits: [UInt8?] = []
        var seconds: [DCF77Decoder.Second] = []
        var time: DCF77Code.Time?
        var timeDate: Date?
        var clockOffset: TimeInterval?
        var minutesDecoded = 0
        var minutesFailed = 0
        var lastError: String?
        var envelope: [Float] = []
    }

    private(set) var running = false
    private(set) var status = Status()
    private(set) var error: String?

    private let shared = Shared()
    private var pollTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let demod = DCF77Demodulator()
        let decoder = DCF77Decoder()

        /// „Leeren“ bei laufendem Empfang: der Demodulator läuft ohne Lock auf
        /// dem Empfangsthread – zurückgesetzt wird deshalb dort.
        var resetRequested = false

        func handle(_ block: Data) {
            if lock.withLock({ defer { resetRequested = false }; return resetRequested }) { reset() }
            let now = Date()
            let envelope = demod.process(block)
            lock.withLock {
                decoder.feed(envelope, endDate: now, delay: DCF77Demodulator.groupDelay)
            }
        }

        func snapshot() -> Status {
            lock.withLock {
                Status(carrierOffsetHz: demod.carrierOffsetHz, snrDB: demod.snrDB, levelDBFS: demod.levelDBFS,
                       locked: decoder.locked, contrast: decoder.contrast, bits: decoder.bits,
                       seconds: decoder.seconds, time: decoder.time, timeDate: decoder.timeDate,
                       clockOffset: decoder.clockOffset, minutesDecoded: decoder.minutesDecoded,
                       minutesFailed: decoder.minutesFailed, lastError: decoder.lastError,
                       envelope: Array(decoder.display.suffix(DCF77Decoder.displaySeconds * DCF77Decoder.displayRate)))
            }
        }

        func reset() {
            lock.withLock { demod.reset(); decoder.reset() }
        }
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            shared.reset()
            try device.setSampleRate(UInt32(DCF77Demodulator.inputRate))
            try device.setBasebandFilter(1_750_000)
            try device.setFrequency(UInt64(DCF77Code.frequencyHz + DCF77Demodulator.offset))
            try applyGains()
            let shared = shared
            try device.startReceiving(owner: self) { shared.handle($0) }
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    self.status = self.shared.snapshot()
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
        if running { shared.lock.withLock { shared.resetRequested = true } } else { shared.reset() }
        status = Status()
    }

    func applyGains() throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain)); try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier); try device.setAntennaPower(antennaPower)
    }
    func applyGainsQuietly() { do { try applyGains() } catch { self.error = error.localizedDescription } }
}
