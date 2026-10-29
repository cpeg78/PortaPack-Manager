import Accelerate
import Foundation
@testable import PortaPackManager

/// Baut Navigationsnachrichten (Subframes 1–5) mit korrekter Parität –
/// die Umkehrung von `GPSEphemeris(sf1:sf2:sf3:)` und `GPSNavDecoder`.
enum GPSNavBuilder {
    /// 240 Datenbits eines Subframes.
    struct Bits {
        var b = [UInt8](repeating: 0, count: 240)
        mutating func set(_ pos: Int, _ len: Int, _ value: Int64) {
            let u = UInt64(bitPattern: value) & (len == 64 ? ~0 : (1 << UInt64(len)) - 1)
            for i in 0..<len { b[pos + i] = UInt8((u >> UInt64(len - 1 - i)) & 1) }
        }
        mutating func set(_ pos: Int, _ len: Int, _ value: Double, scale: Double) {
            set(pos, len, Int64((value / scale).rounded()))
        }
        mutating func fillPseudoRandom(from pos: Int, seed: Int) {
            var x = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 | 1
            for i in pos..<240 {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17
                b[i] = UInt8(x & 1)
            }
        }
        var words: [UInt32] {
            (0..<10).map { w in (0..<24).reduce(UInt32(0)) { $0 << 1 | UInt32(b[w * 24 + $1]) } }
        }
    }

    static func p2(_ n: Int) -> Double { pow(2.0, Double(n)) }

    /// Datenwörter eines Subframes. `towCount` = Beginn des nächsten Subframes / 6 s.
    static func subframe(id: Int, towCount: Int, eph: GPSEphemeris, iono: GPSIonoUTC? = nil) -> [UInt32] {
        var s = Bits()
        let sc = GPSConst.pi
        s.set(0, 8, Int64(GPSNavDecoder.preamble))
        s.set(24, 17, Int64(towCount))
        s.set(43, 3, Int64(id))
        switch id {
        case 1:
            s.set(48, 10, Int64(eph.weekNumber % 1024))
            s.set(60, 4, Int64(eph.uraIndex))
            s.set(64, 6, Int64(eph.health))
            s.set(70, 2, Int64(eph.iodc >> 8))
            s.set(160, 8, eph.tgd, scale: p2(-31))
            s.set(168, 8, Int64(eph.iodc & 0xFF))
            s.set(176, 16, eph.toc, scale: 16)
            s.set(192, 8, eph.af2, scale: p2(-55))
            s.set(200, 16, eph.af1, scale: p2(-43))
            s.set(216, 22, eph.af0, scale: p2(-31))
        case 2:
            s.set(48, 8, Int64(eph.iode))
            s.set(56, 16, eph.crs, scale: p2(-5))
            s.set(72, 16, eph.deltaN, scale: p2(-43) * sc)
            s.set(88, 32, eph.m0, scale: p2(-31) * sc)
            s.set(120, 16, eph.cuc, scale: p2(-29))
            s.set(136, 32, eph.e, scale: p2(-33))
            s.set(168, 16, eph.cus, scale: p2(-29))
            s.set(184, 32, eph.sqrtA, scale: p2(-19))
            s.set(216, 16, eph.toe, scale: 16)
        case 3:
            s.set(48, 16, eph.cic, scale: p2(-29))
            s.set(64, 32, eph.omega0, scale: p2(-31) * sc)
            s.set(96, 16, eph.cis, scale: p2(-29))
            s.set(112, 32, eph.i0, scale: p2(-31) * sc)
            s.set(144, 16, eph.crc, scale: p2(-5))
            s.set(160, 32, eph.omega, scale: p2(-31) * sc)
            s.set(192, 24, eph.omegaDot, scale: p2(-43) * sc)
            s.set(216, 8, Int64(eph.iode))
            s.set(224, 14, eph.idot, scale: p2(-43) * sc)
        case 4:
            s.set(48, 2, 1)
            if let iono {
                s.set(50, 6, 56)
                s.set(56, 8, iono.alpha[0], scale: p2(-30)); s.set(64, 8, iono.alpha[1], scale: p2(-27))
                s.set(72, 8, iono.alpha[2], scale: p2(-24)); s.set(80, 8, iono.alpha[3], scale: p2(-24))
                s.set(88, 8, iono.beta[0], scale: p2(11)); s.set(96, 8, iono.beta[1], scale: p2(14))
                s.set(104, 8, iono.beta[2], scale: p2(16)); s.set(112, 8, iono.beta[3], scale: p2(16))
                s.set(192, 8, Int64(iono.leapSeconds))
            } else {
                s.set(50, 6, 57)
                s.fillPseudoRandom(from: 56, seed: towCount &* 31 &+ eph.prn)
            }
        default:
            // Almanach-ähnlicher Inhalt: zufällige Bits wie im echten Signal
            // (lauter Nullen gäben kaum Bitwechsel für die Bitsynchronisation).
            s.set(48, 2, 1)
            s.set(50, 6, 51)
            s.fillPseudoRandom(from: 56, seed: towCount &* 31 &+ eph.prn)
        }
        return s.words
    }

    /// Almanachseite (Subframe 5, Seiten 1–24) aus einer Ephemeride: Bezugszeit
    /// toa = toe, Störterme entfallen (IS-GPS-200 Tabelle 20-VI).
    static func almanacPage(eph: GPSEphemeris, towCount: Int) -> [UInt32] {
        var s = Bits()
        let sc = GPSConst.pi
        s.set(0, 8, Int64(GPSNavDecoder.preamble))
        s.set(24, 17, Int64(towCount))
        s.set(43, 3, 5)
        s.set(48, 2, 1)
        s.set(50, 6, Int64(eph.prn))
        // toa liegt im 4096-s-Raster: Winkel auf toa fortschreiben.
        let toaUnits = Int64((eph.toe / 4096).rounded())
        let dt = Double(toaUnits) * 4096 - eph.toe
        let a = eph.sqrtA * eph.sqrtA
        let n = (GPSConst.mu / (a * a * a)).squareRoot() + eph.deltaN
        func wrap(_ x: Double) -> Double { x - 2 * .pi * (x / (2 * .pi)).rounded() }
        s.set(56, 16, eph.e, scale: p2(-21))
        s.set(72, 8, toaUnits)
        s.set(80, 16, eph.i0 / sc - 0.3, scale: p2(-19))
        s.set(96, 16, eph.omegaDot / sc, scale: p2(-38))
        s.set(112, 8, 0)
        s.set(120, 24, eph.sqrtA, scale: p2(-11))
        s.set(144, 24, wrap(eph.omega0 + eph.omegaDot * dt) / sc, scale: p2(-23))
        s.set(168, 24, eph.omega / sc, scale: p2(-23))
        s.set(192, 24, wrap(eph.m0 + n * dt) / sc, scale: p2(-23))
        let af0 = Int64((eph.af0 / p2(-20)).rounded())
        s.set(216, 8, af0 >> 3)
        s.set(224, 11, eph.af1, scale: p2(-38))
        s.set(235, 3, af0 & 7)
        return s.words
    }

    /// Sendebits (0/1) zu aufeinanderfolgenden Subframes, Paritätskette über alles.
    static func encode(_ subframes: [[UInt32]]) -> [UInt8] {
        var out: [UInt8] = []
        var d29: UInt32 = 0, d30: UInt32 = 0
        for sf in subframes {
            for (i, data) in sf.enumerated() {
                let w = (i == 1 || i == 9)
                    ? GPSParity.encodeZeroTail(data: data, prevD29: d29, prevD30: d30)
                    : GPSParity.encode(data: data, prevD29: d29, prevD30: d30)
                for k in (0..<30).reversed() { out.append(UInt8((w >> UInt32(k)) & 1)) }
                d29 = (w >> 1) & 1; d30 = w & 1
            }
        }
        return out
    }

    /// Ephemeride so quantisieren, wie sie gesendet wird (kodieren → dekodieren).
    static func quantized(_ eph: GPSEphemeris, towCount: Int = 1) -> GPSEphemeris {
        let s = (1...3).map { GPSSubframe(words: subframe(id: $0, towCount: towCount, eph: eph)) }
        return GPSEphemeris(prn: eph.prn, sf1: s[0], sf2: s[1], sf3: s[2])!
    }
}

/// Synthetische Konstellation: Bahnen ähnlich dem echten GPS (6 Ebenen à 4 Satelliten).
enum GPSTestConstellation {
    static func ephemeris(prn: Int, toe: Double, week: Int) -> GPSEphemeris {
        let plane = (prn - 1) / 4, slot = (prn - 1) % 4
        let deg = Double.pi / 180
        let raw = GPSEphemeris(
            prn: prn, weekNumber: week % 1024, iodc: 40 + prn, iode: 40 + prn,
            tgd: -4.6e-9 + Double(prn) * 1e-10, toc: toe,
            af0: Double((prn * 37) % 21 - 10) * 2.1e-5, af1: Double(prn % 5 - 2) * 1.1e-12, af2: 0,
            crs: 20 + Double(prn), deltaN: 4.5e-9, m0: (Double(slot) * 90 + Double(plane) * 15 - 180) * deg,
            cuc: 1.5e-6, e: 0.004 + 0.0005 * Double(prn % 7), cus: 7e-6, sqrtA: 5153.6 + Double(prn % 3),
            toe: toe, cic: 4e-8, omega0: (Double(plane) * 60 - 170) * deg, cis: -6e-8, i0: 55.5 * deg,
            crc: 230, omega: (10 + Double(prn) * 7) * deg, omegaDot: -8.1e-9, idot: 2e-10)
        return GPSNavBuilder.quantized(raw)
    }

    /// Satelliten über `minElevation` (Grad) vom Ort `rx` zur Zeit `t`, höchste zuerst.
    static func visible(rx: SIMD3<Double>, t: Double, week: Int, minElevation: Double, count: Int) -> [GPSEphemeris] {
        let toe = (t / 16).rounded(.down) * 16
        let all = (1...24).map { ephemeris(prn: $0, toe: toe, week: week) }
        let withEl = all.map { eph -> (GPSEphemeris, Double) in
            (eph, GPSGeo.azimuthElevation(rx: rx, sat: eph.position(at: t)).el * 180 / .pi)
        }
        return withEl.filter { $0.1 >= minElevation }.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
    }
}

/// Erzeugt das Empfangssignal mehrerer Satelliten wie ein Empfänger am Ort
/// `rx` es sähe: Laufzeit mit Erddrehung, Satellitenuhr (inkl. Relativistik
/// und TGD), Troposphäre, Doppler aus der Bahn, Navigationsbits, Rauschen.
final class GPSSignalSimulator {
    struct Satellite {
        let eph: GPSEphemeris
        let cn0: Double
        let code: [Int8]
        let bits: [Int8]
    }

    let rx: SIMD3<Double>
    let sampleRate: Double
    /// Wahre GPS-Zeit (Sekunde der Woche) bei Abtastwert 0.
    let startTime: Double
    /// Satellitenzeit des ersten Navigationsbits (Beginn eines Subframes).
    let bitsStart: Double
    let satellites: [Satellite]
    let noiseSigma: Float
    let troposphere: Bool
    let iono: GPSIonoUTC?
    private(set) var sampleIndex = 0
    private var rng: UInt64

    /// - Parameter firstSubframeStart: Satellitenzeit, zu der Subframe 1 beginnt
    ///   (Vielfaches von 30 s); die Bitfolge beginnt einen Rahmen früher.
    /// - Parameter cn0s: C/N0 je Satellit (gleiche Reihenfolge wie `ephemerides`), sonst überall `cn0`.
    init(rx: SIMD3<Double>, startTime: Double, ephemerides: [GPSEphemeris], cn0: Double = 45, cn0s: [Double]? = nil,
         sampleRate: Double = 4_096_000, firstSubframeStart: Double, duration: Double,
         noiseSigma: Float = 20, troposphere: Bool = true, iono: GPSIonoUTC? = nil, seed: UInt64 = 0x1234_5678,
         almanac: Bool = false) {
        self.rx = rx
        self.sampleRate = sampleRate
        self.startTime = startTime
        self.noiseSigma = noiseSigma
        self.troposphere = troposphere
        self.iono = iono
        rng = seed
        let start = firstSubframeStart - 30
        bitsStart = start
        let frames = Int(((startTime + duration - start) / 30).rounded(.up)) + 1
        satellites = ephemerides.enumerated().map { index, eph in
            var subframes: [[UInt32]] = []
            for k in 0..<(frames * 5) {
                let t = start + Double(k) * 6
                let id = k % 5 + 1
                let towCount = Int((t + 6) / 6) % 100_800
                // Almanach: Subframe 5 Seite p (Rahmen p) trägt PRN p (1–24) – hier
                // reihum die simulierten Satelliten.
                if almanac && id == 5 {
                    let page = ephemerides[(k / 5) % ephemerides.count]
                    subframes.append(GPSNavBuilder.almanacPage(eph: page, towCount: towCount))
                    continue
                }
                subframes.append(GPSNavBuilder.subframe(id: id, towCount: towCount,
                                                        eph: eph, iono: id == 4 ? iono : nil))
            }
            let bits = GPSNavBuilder.encode(subframes).map { Int8($0 == 1 ? 1 : -1) }
            let code = GPSCACode.code(prn: eph.prn).map { Int8($0 == 0 ? 1 : -1) }
            return Satellite(eph: eph, cn0: cn0s?[index] ?? cn0, code: code, bits: bits)
        }
    }

    /// Satellitenzeit minus Empfangszeit (−Laufzeit + Satellitenuhr) zur wahren Empfangszeit `tr`.
    func delta(_ sat: GPSEphemeris, at tr: Double) -> Double {
        var tau = 0.075
        let g = GPSGeo.geodetic(rx)
        for _ in 0..<4 {
            let p = GPSGeo.rotateEarth(sat.position(at: tr - tau), travelTime: tau)
            let d = p - rx
            var range = (d * d).sum().squareRoot()
            if troposphere || iono != nil {
                let ae = GPSGeo.azimuthElevation(rx: rx, sat: p)
                if troposphere { range += GPSGeo.troposphere(lat: g.lat, height: g.height, elevation: ae.el) }
                if let iono { range += GPSGeo.klobuchar(iono, lat: g.lat, lon: g.lon, az: ae.az, el: ae.el, tow: tr) }
            }
            tau = range / GPSConst.c
        }
        return -tau + sat.clockBias(at: tr - tau)
    }

    /// Wahre Codephase (Chips) und Doppler (Hz) beim Abtastwert `n`.
    func truth(prn: Int, sample n: Int) -> (codePhase: Double, dopplerHz: Double, transmitTime: Double) {
        let sat = satellites.first { $0.eph.prn == prn }!.eph
        let tr = startTime + Double(n) / sampleRate
        let d = delta(sat, at: tr)
        let rate = (delta(sat, at: tr + 0.01) - delta(sat, at: tr - 0.01)) / 0.02
        let chips = (Double(n) / sampleRate + (startTime - bitsStart) + d) * GPSConst.chipRate
        return (chips.truncatingRemainder(dividingBy: 1023), rate * GPSConst.l1, tr + d)
    }

    /// Nächste `count` Abtastwerte als 8-Bit-IQ.
    func next(_ count: Int) -> Data {
        var buf = [Float](repeating: 0, count: 2 * count)
        let segment = Int(sampleRate / 100)        // 10-ms-Stützstellen, linear dazwischen
        for sat in satellites {
            let amplitude = noiseSigma * Float((2 * pow(10, sat.cn0 / 10) / sampleRate).squareRoot())
            var done = 0
            while done < count {
                let n0 = sampleIndex + done
                let n = min(segment - n0 % segment, count - done)
                let ta = Double(n0) / sampleRate, tb = Double(n0 + n) / sampleRate
                let da = delta(sat.eph, at: startTime + ta), db = delta(sat.eph, at: startTime + tb)
                let chipA = (ta + (startTime - bitsStart) + da) * GPSConst.chipRate
                let chipB = (tb + (startTime - bitsStart) + db) * GPSConst.chipRate
                let phA = GPSConst.l1 * da
                let phB = GPSConst.l1 * db
                buf.withUnsafeMutableBufferPointer { b in
                    sat.code.withUnsafeBufferPointer { c in
                        sat.bits.withUnsafeBufferPointer { bits in
                            gps_synth_add(b.baseAddress! + 2 * done, Int32(n), c.baseAddress!, bits.baseAddress!,
                                          Int32(bits.count), chipA, (chipB - chipA) / Double(n),
                                          phA - phA.rounded(.down), (phB - phA) / Double(n), amplitude)
                        }
                    }
                }
                done += n
            }
        }
        buf.withUnsafeMutableBufferPointer { b in gps_synth_noise(b.baseAddress!, Int32(count), noiseSigma, &rng) }
        sampleIndex += count
        var out = Data(count: 2 * count)
        var lo: Float = -127, hi: Float = 127
        vDSP_vclip(buf, 1, &lo, &hi, &buf, 1, vDSP_Length(2 * count))
        out.withUnsafeMutableBytes { raw in
            vDSP_vfixr8(buf, 1, raw.bindMemory(to: Int8.self).baseAddress!, 1, vDSP_Length(2 * count))
        }
        return out
    }
}
