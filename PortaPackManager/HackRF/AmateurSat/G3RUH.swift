import Foundation

/// G3RUH-Verwürfler (x¹⁷ + x¹² + 1, selbstsynchronisierend). Senden:
/// y = x ⊕ y[−12] ⊕ y[−17]; Empfangen: x = y ⊕ y[−12] ⊕ y[−17].
/// Eine Pegelumkehr des ganzen Stroms kehrt auch die entwürfelten Bits um –
/// die NRZI-Dekodierung danach ist dagegen unempfindlich.
struct G3RUHScrambler {
    private var register: UInt32 = 0

    mutating func scramble(_ bit: UInt8) -> UInt8 {
        let y = bit ^ UInt8((register >> 11) & 1) ^ UInt8((register >> 16) & 1)
        register = (register << 1) | UInt32(y)
        return y
    }

    mutating func descramble(_ bit: UInt8) -> UInt8 {
        let x = bit ^ UInt8((register >> 11) & 1) ^ UInt8((register >> 16) & 1)
        register = (register << 1) | UInt32(bit)
        return x
    }
}

/// 9600 Bd FSK/GMSK nach G3RUH aus dem FM-Diskriminatorsignal bei 48 kHz
/// (5 Werte je Bit): Gleichanteil weg (Restablage nach der Doppler-
/// Korrektur), Tiefpass, Bittakt wie bei AFSK, Entwürfeln, NRZI, HDLC.
/// Geliefert werden geprüfte Rahmen ohne FCS.
final class G3RUHDemodulator: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let baud = 9600.0

    private let filter = RadioDemodulator.lowpass(taps: 25, cutoff: 6_500, rate: G3RUHDemodulator.sampleRate)
    private var history: [Float] = []
    private var dc: Float = 0
    private var clock = BitClock(bitRate: G3RUHDemodulator.baud, sampleRate: G3RUHDemodulator.sampleRate, inertia: 0.6)
    private var scrambler = G3RUHScrambler()
    private var nrzi = NRZIDecoder()
    private var deframer = HDLCDeframer(minimumBytes: 16, maximumBytes: 400)

    func reset() {
        history = []
        dc = 0
        clock = BitClock(bitRate: Self.baud, sampleRate: Self.sampleRate, inertia: 0.6)
        scrambler = G3RUHScrambler()
        nrzi = NRZIDecoder()
        deframer = HDLCDeframer(minimumBytes: 16, maximumBytes: 400)
    }

    func process(_ samples: [Float]) -> [[UInt8]] {
        let filtered = RadioDemodulator.decimateReal(samples, history: &history, filter: filter, factor: 1)
        var frames: [[UInt8]] = []
        var d = dc
        for x in filtered {
            d += 0.0005 * (x - d)
            guard let value = clock.push(x - d) else { continue }
            let level: UInt8 = value > 0 ? 1 : 0
            let bit = nrzi.decode(scrambler.descramble(level))
            if let frame = deframer.push(bit) { frames.append(frame) }
        }
        dc = d
        return frames
    }
}

/// Schmalband-FM-Vorstufe für Satelliten: wie `FMChannelizer` (HackRF 240 kHz
/// unter der Mitte, ÷10 auf 240 kHz, je Kanal mischen, ÷5 auf 48 kHz,
/// Diskriminator), aber jeder Kanal folgt zusätzlich der Doppler-Verschiebung
/// `factor · f` (factor = −Annäherungsgeschwindigkeit / c), die die Bahnrechnung
/// laufend nachstellt.
final class SatChannelizer: @unchecked Sendable {
    static let inputRate = FMChannelizer.inputRate
    static let offset = FMChannelizer.offset
    static let midRate = FMChannelizer.midRate
    static let outputRate = FMChannelizer.outputRate

    struct Channel: Sendable {
        /// Abstand zur Mittenfrequenz (Hz).
        let offset: Double
        /// Sollfrequenz (Hz) – Grundlage der Doppler-Verschiebung.
        let frequency: Double
        let cutoff: Double
    }

    let channels: [Channel]
    private(set) var channelPowerDB: [Float]

    private let lock = NSLock()
    private var dopplerFactor = 0.0
    private let stage1: [Float]
    private let filters: [[Float]]
    private let oscRe: [Float]
    private let oscIm: [Float]
    private var oscIndex = 0
    private var histRe: [Float] = []
    private var histIm: [Float] = []
    private var states: [State]

    private struct State {
        var phase = 0.0
        var histRe: [Float] = []
        var histIm: [Float] = []
        var lastRe: Float = 1
        var lastIm: Float = 0
    }

    init(channels: [Channel]) {
        self.channels = channels
        channelPowerDB = channels.map { _ in -100 }
        stage1 = RadioDemodulator.lowpass(taps: 63, cutoff: 60_000, rate: Self.inputRate)
        filters = channels.map { RadioDemodulator.lowpass(taps: 63, cutoff: $0.cutoff, rate: Self.midRate) }
        oscRe = (0..<10).map { Float(cos(-2 * Double.pi * Double($0) / 10)) }
        oscIm = (0..<10).map { Float(sin(-2 * Double.pi * Double($0) / 10)) }
        states = channels.map { _ in State() }
    }

    /// Doppler-Faktor setzen (aus jedem Thread).
    func setDoppler(factor: Double) {
        lock.withLock { dopplerFactor = factor }
    }

    var doppler: Double { lock.withLock { dopplerFactor } }

    func reset() {
        histRe = []; histIm = []
        states = channels.map { _ in State() }
    }

    /// IQ-Block (int8, 2,4 MS/s) → Diskriminatorwerte je Kanal (48 kHz, rad/Wert).
    func process(_ iq: Data) -> [[Float]] {
        let count = iq.count / 2
        guard count > 0 else { return channels.map { _ in [] } }
        let factor = doppler
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var k = oscIndex
            for n in 0..<count {
                let i = Float(p[2 * n]) / 128, q = Float(p[2 * n + 1]) / 128
                let c = oscRe[k], s = oscIm[k]
                re[n] = i * c - q * s
                im[n] = i * s + q * c
                k += 1
                if k == 10 { k = 0 }
            }
            oscIndex = k
        }
        let (midRe, midIm) = RadioDemodulator.decimateComplex(re, im, history: &histRe, &histIm, filter: stage1, factor: 10)
        var outputs: [[Float]] = []
        for index in channels.indices {
            var state = states[index]
            var cRe = midRe, cIm = midIm
            let shift = channels[index].offset + factor * channels[index].frequency
            if shift != 0 {
                let increment = -2 * Double.pi * shift / Self.midRate
                for n in cRe.indices {
                    let c = Float(cos(state.phase)), s = Float(sin(state.phase))
                    let r = cRe[n], i = cIm[n]
                    cRe[n] = r * c - i * s
                    cIm[n] = r * s + i * c
                    state.phase += increment
                }
                state.phase = state.phase.truncatingRemainder(dividingBy: 2 * .pi)
            }
            let (bRe, bIm) = RadioDemodulator.decimateComplex(cRe, cIm, history: &state.histRe, &state.histIm,
                                                              filter: filters[index], factor: 5)
            var power: Float = 0
            var out = [Float](repeating: 0, count: bRe.count)
            var pr = state.lastRe, pi = state.lastIm
            for n in bRe.indices {
                let r = bRe[n], i = bIm[n]
                power += r * r + i * i
                out[n] = atan2f(i * pr - r * pi, r * pr + i * pi)
                pr = r; pi = i
            }
            state.lastRe = pr; state.lastIm = pi
            if !bRe.isEmpty { channelPowerDB[index] = 10 * log10(max(power / Float(bRe.count), 1e-12)) }
            states[index] = state
            outputs.append(out)
        }
        return outputs
    }
}
