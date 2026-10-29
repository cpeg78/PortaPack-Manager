import Accelerate
import Foundation
import Testing
@testable import PortaPackManager

/// Wahl des analogen Basisbandfilters für Zigbee (`ZigbeeDemodulator.basebandFilter`).
///
/// Prüfstand: komplexes Basisband mit 48 MS/s um die HackRF-Mitte (Kanal bei
/// +2 MHz), breitbandiges Rauschen (wie hinter dem LNA), Nutzrahmen, Störer;
/// dann das MAX2837-Filter als Butterworth 5. Ordnung (−3 dB bei ±Breite/2,
/// samt Phase), Abtasten mit 8 MS/s **ohne** weiteres Filter (der Wandler
/// faltet alles jenseits ±4 MHz herein), Pegel auf −15 dBFS, Int8 – und der
/// echte Demodulator. Gezählt werden Nutzrahmen mit gültiger FCS.
///
/// Gemessen 29.10.2026 (derselbe Aufbau als `swiftc -O`-Programm mit 2²⁰
/// Werten, 4 Läufe je Wert, ≈ 12 Rahmen je Lauf, Anteil in %, Nutzsignal 6 dB
/// über dem Rauschen in 2 MHz):
///
/// | Störer (relativ zum Kanal)   | 8 MHz | 7 MHz | 6 MHz | 5 MHz |
/// |------------------------------|-------|-------|-------|-------|
/// | nur Rauschen                 |  98   | 100   | 100   |  96   |
/// | Zigbee −10 MHz, +40 dB       |  19   |  85   |  98   |  87   |
/// | WLAN (16,6 MHz) −12 MHz, +30 |   0   |  38   |  94   |  89   |
/// | WLAN −15 MHz, +40 dB         |   0   |   0   |   0   |  60   |
/// | Zigbee/WLAN darüber (+5…+15) |  ≥ 98 | ≥ 98  | ≥ 98  | 89–98 |
///
/// Bei 3. Ordnung bleibt die Reihenfolge (6 MHz ≥ 8 MHz überall), bei 7.
/// ebenso. Empfindlichkeit ohne Störer (16 Läufe, 189 Rahmen, 5. Ordnung):
/// 3 dB 69 → 79, 4 dB 151 → 156, 5 dB 185 → 182 (8 → 6 MHz) – gleich im
/// Rahmen der Streuung; 5,5 MHz verliert schon (52, 138, 181).
@Suite("Zigbee-Basisbandfilter")
struct ZigbeeFilterTests {
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u = max(next(), 1e-12), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() * Double(r.count)) }
    }

    private static let decimation = 6
    private static let rate = 8_000_000.0 * Double(decimation)
    private static let log2n = 19
    private static let count = 1 << log2n

    private final class FFT {
        let setup: FFTSetupD
        init() { setup = vDSP_create_fftsetupD(vDSP_Length(ZigbeeFilterTests.log2n), FFTRadix(kFFTRadix2))! }
        deinit { vDSP_destroy_fftsetupD(setup) }
        func run(_ re: inout [Double], _ im: inout [Double], forward: Bool) {
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zipD(setup, &split, 1, vDSP_Length(ZigbeeFilterTests.log2n),
                                  FFTDirection(forward ? kFFTDirection_Forward : kFFTDirection_Inverse))
                }
            }
        }
    }

    private static func frequency(_ k: Int) -> Double { Double(k < count / 2 ? k : k - count) * rate / Double(count) }

    /// Butterworth-Tiefpass Ordnung `order`, −3 dB bei `cutoff` (komplexer Gang).
    static func butterworth(_ f: Double, cutoff: Double, order: Int) -> (re: Double, im: Double) {
        var hr = 1.0, hi = 0.0
        for k in 1...order {
            let angle = Double.pi * Double(2 * k + order - 1) / Double(2 * order)
            let dr = -cos(angle), di = f / cutoff - sin(angle)
            let m = dr * dr + di * di
            let qr = dr / m, qi = -di / m
            (hr, hi) = (hr * qr - hi * qi, hr * qi + hi * qr)
        }
        return (hr, hi)
    }

    private static func addZigbee(_ re: inout [Double], _ im: inout [Double], at f: Double, amplitude: Double,
                                  rng: inout Random, start: Int, gap: ClosedRange<Int>) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var position = start
        while true {
            let payload = (0..<rng.int(20...40)).map { _ in UInt8(rng.int(0...255)) }
            let (sr, si) = IEEE802154.modulate(symbols: IEEE802154.symbols(psdu: IEEE802154.withFCS(payload)),
                                               samplesPerChip: 4 * decimation)
            guard position + sr.count + 1000 < count else { break }
            let phase0 = rng.next() * 2 * .pi
            for k in 0..<sr.count {
                let n = position + k
                let phase = phase0 + 2 * Double.pi * f * Double(n) / rate
                let c = cos(phase), s = sin(phase)
                re[n] += amplitude * (Double(sr[k]) * c - Double(si[k]) * s)
                im[n] += amplitude * (Double(sr[k]) * s + Double(si[k]) * c)
            }
            frames.append(payload)
            position += sr.count + rng.int(gap)
        }
        return frames
    }

    enum Interferer { case none, zigbee(offset: Double, db: Double), wlan(offset: Double, db: Double) }

    /// Anteil empfangener Nutzrahmen (empfangen, gesendet).
    static func run(snr: Double, filter: Double, order: Int = 5, interferer: Interferer, seed: UInt64) -> (ok: Int, sent: Int) {
        let fft = FFT()
        var rng = Random(state: seed)
        let sigma = (rate / 2e6 / 2).squareRoot()     // Rauschleistung 1 in 2 MHz
        var re = (0..<count).map { _ in sigma * rng.gaussian() }, im = (0..<count).map { _ in sigma * rng.gaussian() }
        let channel = 2e6 + 30_000
        let frames = addZigbee(&re, &im, at: channel, amplitude: pow(10, snr / 20), rng: &rng, start: 3000, gap: 20_000...40_000)
        switch interferer {
        case .none: break
        case .zigbee(let offset, let db):
            _ = addZigbee(&re, &im, at: channel + offset, amplitude: pow(10, db / 20), rng: &rng, start: rng.int(0...3000), gap: 200...800)
        case .wlan(let offset, let db):
            // Flaches Rauschband 16,6 MHz (OFDM-ähnlich), Leistung 10^(db/10).
            var wr = (0..<count).map { _ in rng.gaussian() }, wi = (0..<count).map { _ in rng.gaussian() }
            fft.run(&wr, &wi, forward: true)
            for k in 0..<count where abs(frequency(k) - (channel + offset)) > 8.3e6 { wr[k] = 0; wi[k] = 0 }
            fft.run(&wr, &wi, forward: false)
            let power = zip(wr, wi).reduce(0) { $0 + $1.0 * $1.0 + $1.1 * $1.1 } / Double(count)
            let a = pow(10, db / 20) / power.squareRoot()
            for n in 0..<count { re[n] += a * wr[n]; im[n] += a * wi[n] }
        }
        fft.run(&re, &im, forward: true)
        for k in 0..<count {
            let h = butterworth(frequency(k), cutoff: filter / 2, order: order)
            (re[k], im[k]) = (re[k] * h.re - im[k] * h.im, re[k] * h.im + im[k] * h.re)
        }
        fft.run(&re, &im, forward: false)
        let samples = count / decimation
        var power = 0.0
        for m in 0..<samples { power += re[m * decimation] * re[m * decimation] + im[m * decimation] * im[m * decimation] }
        let scale = pow(10, -15.0 / 20) * 128 / (power / Double(samples)).squareRoot()
        var data = Data(count: 2 * samples)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let q = raw.bindMemory(to: Int8.self)
            for m in 0..<samples {
                q[2 * m] = Int8(max(-127, min(127, (re[m * decimation] * scale).rounded())))
                q[2 * m + 1] = Int8(max(-127, min(127, (im[m * decimation] * scale).rounded())))
            }
        }
        let demod = ZigbeeDemodulator()
        var received = Set<[UInt8]>()
        for offset in stride(from: 0, to: data.count, by: 262_144) {
            for frame in demod.process(data.subdata(in: offset..<min(data.count, offset + 262_144)), channel: 15) {
                received.insert(frame.mpdu)
            }
        }
        return (frames.filter { received.contains($0) }.count, frames.count)
    }

    private static func total(snr: Double, filter: UInt32, interferer: Interferer, seeds: Range<UInt64>) -> (ok: Int, sent: Int) {
        seeds.reduce((0, 0)) { sum, seed in
            let r = run(snr: snr, filter: Double(filter), interferer: interferer, seed: 1000 + seed * 77)
            return (sum.0 + r.ok, sum.1 + r.sent)
        }
    }

    @Test("Prüfstand: Butterworth-Gang −3 dB an der Grenze, Phase stetig")
    func butterworthShape() {
        let h = Self.butterworth(3e6, cutoff: 3e6, order: 5)
        #expect(abs(10 * log10(h.re * h.re + h.im * h.im) + 3.01) < 0.05)
        let dc = Self.butterworth(0, cutoff: 3e6, order: 5)
        #expect(abs(dc.re - 1) < 1e-9 && abs(dc.im) < 1e-9)
        // 5. Ordnung: −100 dB je Dekade.
        let far = Self.butterworth(30e6, cutoff: 3e6, order: 5)
        #expect(abs(10 * log10(far.re * far.re + far.im * far.im) + 100) < 0.5)
    }

    @Test("6 MHz statt 8 MHz: Störer unter dem Kanal falten nicht mehr herein, im Rauschen kein Verlust")
    func sixMegahertz() {
        #expect(ZigbeeDemodulator.basebandFilter == 6_000_000)
        #expect(HackRFDevice.basebandFilters.contains(ZigbeeDemodulator.basebandFilter))
        let old: UInt32 = 8_000_000, new = ZigbeeDemodulator.basebandFilter
        // Breitbandiger Störer 12 MHz unter dem Kanal (WLAN-ähnlich, +30 dB).
        let wlanOld = Self.total(snr: 6, filter: old, interferer: .wlan(offset: -12e6, db: 30), seeds: 0..<2)
        let wlanNew = Self.total(snr: 6, filter: new, interferer: .wlan(offset: -12e6, db: 30), seeds: 0..<2)
        // Zigbee-Netz zwei Kanäle tiefer, +40 dB.
        let zigOld = Self.total(snr: 6, filter: old, interferer: .zigbee(offset: -10e6, db: 40), seeds: 0..<2)
        let zigNew = Self.total(snr: 6, filter: new, interferer: .zigbee(offset: -10e6, db: 40), seeds: 0..<2)
        // Nur Rauschen nahe der Empfindlichkeitsgrenze.
        let noiseOld = Self.total(snr: 4, filter: old, interferer: .none, seeds: 0..<3)
        let noiseNew = Self.total(snr: 4, filter: new, interferer: .none, seeds: 0..<3)
        print("Zigbee-Filter 8 → 6 MHz: WLAN −12 MHz \(wlanOld.ok)/\(wlanOld.sent) → \(wlanNew.ok)/\(wlanNew.sent), "
              + "Zigbee −10 MHz \(zigOld.ok)/\(zigOld.sent) → \(zigNew.ok)/\(zigNew.sent), "
              + "Rauschen 4 dB \(noiseOld.ok)/\(noiseOld.sent) → \(noiseNew.ok)/\(noiseNew.sent)")
        #expect(wlanNew.ok >= wlanOld.ok + wlanNew.sent / 2)
        #expect(zigNew.ok >= zigOld.ok + zigNew.sent / 3)
        #expect(Double(zigNew.ok) >= 0.75 * Double(zigNew.sent))
        // Im Rauschen höchstens so viel schlechter, wie die Streuung erlaubt.
        #expect(Double(noiseNew.ok) >= 0.9 * Double(noiseOld.ok))
    }
}
