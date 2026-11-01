import Accelerate
import Foundation

/// DSSS-Empfänger (802.11b, 1 und 2 Mbit/s) bei 20 MS/s: Barker-Matched-Filter
/// über ein Symbol (20 Abtastwerte = 1 µs), Symboltakt aus den Korrelations-
/// spitzen der Präambel mit Früh-spät-Nachführung, Frequenzablage aus den
/// Differenzphasen der Präambel, DBPSK/DQPSK, selbstsynchronisierende
/// Entwürfelung (x⁷ + x⁴ + 1), SFD lang (0xF3A0) und kurz (0x05CF), PLCP-Kopf
/// mit CRC-16, dann FCS. CCK (5,5/11 Mbit/s) wird erkannt, aber nicht dekodiert.
final class WLANDSSSDemodulator {
    static let samplesPerSymbol = 20
    static let barker: [Float] = [1, -1, 1, 1, -1, 1, 1, 1, -1, -1, -1]
    /// Symbolwellenform bei 20 MS/s: Chip ⌊n·11/20⌋.
    static let taps: [Float] = (0..<samplesPerSymbol).map { barker[$0 * 11 / samplesPerSymbol] }
    /// Höchstdauer eines Rahmens in µs (Symbolen).
    static let maximumSymbols = 4400
    static let maximumSamples = maximumSymbols * samplesPerSymbol

    /// SFD in Sendereihenfolge (LSB zuerst): lang 0xF3A0, kurz 0x05CF.
    static let longSFD: [UInt8] = (0..<16).map { UInt8(0xF3A0 >> $0 & 1) }
    static let shortSFD: [UInt8] = (0..<16).map { UInt8(0x05CF >> $0 & 1) }

    private(set) var bursts = 0
    /// Arbeitspuffer, über Blöcke wiederverwendet (vorher je Block fünf neue
    /// Felder à ≈ 0,5 MB samt Nullfüllen – 31.10.2026). vDSP überschreibt sie ganz.
    private var mfRe: [Float] = [], mfIm: [Float] = [], energy: [Float] = [], mags: [Float] = [], power: [Float] = []
    private(set) var headerErrors = 0
    private(set) var fcsErrors = 0
    private(set) var unsupported = 0

    /// Sucht Rahmen in `count` Abtastwerten ab `from`; liefert die Pakete und
    /// die Stelle, bis zu der der Puffer abgearbeitet ist (bei einem
    /// angefangenen Rahmen dessen Anfang).
    func detect(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int, from: Int, noise: Float)
        -> (packets: [WLANPacket], consumed: Int) {
        let spb = Self.samplesPerSymbol
        guard count > spb * 400, from < count else { return ([], from) }
        let mfCount = count - spb + 1
        WLANScratch.size(&mfRe, mfCount); WLANScratch.size(&mfIm, mfCount); WLANScratch.size(&energy, mfCount)
        WLANScratch.size(&mags, count); WLANScratch.size(&power, mfCount)
        vDSP_conv(re, 1, Self.taps, 1, &mfRe, 1, vDSP_Length(mfCount), vDSP_Length(spb))
        vDSP_conv(im, 1, Self.taps, 1, &mfIm, 1, vDSP_Length(mfCount), vDSP_Length(spb))
        mfRe.withUnsafeMutableBufferPointer { r in
            mfIm.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_zvmags(&split, 1, &energy, 1, vDSP_Length(mfCount))
            }
        }
        // Leistung je Symbol (gleitende Summe über 20 Werte).
        var input = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: re), imagp: UnsafeMutablePointer(mutating: im))
        vDSP_zvmags(&input, 1, &mags, 1, vDSP_Length(count))
        vDSP_vswsum(mags, 1, &power, 1, vDSP_Length(mfCount), vDSP_Length(spb))

        let gate = noise * Float(spb) * 4
        var packets: [WLANPacket] = []
        var n = max(0, from)
        let limit = mfCount - spb * 200
        while n < limit {
            guard power[n] > gate else { n += 1; continue }
            let start = n
            bursts += 1
            switch decode(mfRe: mfRe, mfIm: mfIm, energy: energy, start: start, count: mfCount, gate: gate, power: power) {
            case let .packet(packet, end):
                packets.append(packet)
                n = end
            case .needMore:
                return (packets, start)
            case .failed:
                // Bis zum Ende des Bursts überspringen.
                var k = start + spb * 8
                while k < mfCount, power[k] > gate, k - start < Self.maximumSamples { k += spb }
                n = k
            }
        }
        return (packets, max(from, n))
    }

    private enum Outcome { case packet(WLANPacket, Int), needMore, failed }

    private func decode(mfRe: [Float], mfIm: [Float], energy: [Float], start: Int, count: Int, gate: Float, power: [Float]) -> Outcome {
        let spb = Self.samplesPerSymbol
        // Symboltakt: Phase mit der größten Korrelationsenergie über 48 Symbole.
        guard start + spb * 64 < count else { return .needMore }
        var bestPhase = 0, bestEnergy: Float = -1
        for phase in 0..<spb {
            var sum: Float = 0
            for m in 0..<48 { sum += energy[start + phase + spb * m] }
            if sum > bestEnergy { bestEnergy = sum; bestPhase = phase }
        }
        var t = start + bestPhase
        // Differenzphasen; Ablage θ = ½·arg Σ d², das löst die 0/π-Mehrdeutigkeit.
        var dRe: Float = 0, dIm: Float = 0
        var previousRe = mfRe[t], previousIm = mfIm[t]
        var t2 = t + spb
        for _ in 1..<56 {
            let a = mfRe[t2], b = mfIm[t2]
            let cr = a * previousRe + b * previousIm, ci = b * previousRe - a * previousIm
            dRe += cr * cr - ci * ci
            dIm += 2 * cr * ci
            previousRe = a; previousIm = b
            t2 += spb
        }
        let theta = atan2(dIm, dRe) / 2
        let cosT = cos(theta), sinT = sin(theta)

        // Symbolweise Dekodierung mit Früh-spät-Nachführung.
        var lastRe = mfRe[t], lastIm = mfIm[t]
        var earlyLate: Float = 0, tracked = 0
        var descrambler: UInt8 = 0      // letzte sieben empfangenen Bits
        var symbolIndex = 0

        /// Liefert die korrigierte Differenzphase des nächsten Symbols oder nil am Pufferende.
        func nextPhase() -> Float? {
            t += spb
            guard t + 1 < count else { return nil }
            let a = mfRe[t], b = mfIm[t]
            var cr = a * lastRe + b * lastIm, ci = b * lastRe - a * lastIm
            (cr, ci) = (cr * cosT + ci * sinT, ci * cosT - cr * sinT)
            lastRe = a; lastIm = b
            earlyLate += energy[t + 1] - energy[t - 1]
            tracked += 1
            if tracked == 16 {
                let reference = energy[t] * 2
                if earlyLate > reference { t += 1 } else if earlyLate < -reference { t -= 1 }
                earlyLate = 0
                tracked = 0
            }
            symbolIndex += 1
            return atan2(ci, cr)
        }
        func descramble(_ bit: UInt8) -> UInt8 {
            let out = bit ^ (descrambler >> 3 & 1) ^ (descrambler >> 6 & 1)
            descrambler = (descrambler << 1 | bit) & 0x7F
            return out
        }
        func dbpskBit() -> UInt8? {
            guard let phase = nextPhase() else { return nil }
            return descramble(abs(phase) > .pi / 2 ? 1 : 0)
        }
        func dqpskBits() -> (UInt8, UInt8)? {
            guard let phase = nextPhase() else { return nil }
            // 0 → 00, π/2 → 01, π → 11, −π/2 → 10 (d0 zuerst).
            let quadrant = Int((phase / (.pi / 2)).rounded()) & 3
            let dibit: (UInt8, UInt8) = [(0, 0), (0, 1), (1, 1), (1, 0)][quadrant]
            return (descramble(dibit.0), descramble(dibit.1))
        }

        // Präambel: Einsen (lang) oder Nullen (kurz), dann SFD.
        var history: [UInt8] = []
        var shortPreamble = false
        var found = false
        while history.count < 220 {
            guard let bit = dbpskBit() else { return .needMore }
            history.append(bit)
            guard history.count >= 32 else { continue }
            let tail = Array(history.suffix(16))
            let lead = history[(history.count - 32)..<(history.count - 16)]
            if tail == Self.longSFD, lead.allSatisfy({ $0 == 1 }) { found = true; break }
            if tail == Self.shortSFD, lead.allSatisfy({ $0 == 0 }) { found = true; shortPreamble = true; break }
        }
        guard found else { return .failed }

        // PLCP-Kopf: SIGNAL, SERVICE, LENGTH (LSB zuerst), CRC-16 (MSB zuerst).
        var header: [UInt8] = []
        while header.count < 48 {
            if shortPreamble {
                guard let pair = dqpskBits() else { return .needMore }
                header.append(pair.0); header.append(pair.1)
            } else {
                guard let bit = dbpskBit() else { return .needMore }
                header.append(bit)
            }
        }
        let signal = (0..<8).reduce(0) { $0 | Int(header[$1]) << $1 }
        let length = (0..<16).reduce(0) { $0 | Int(header[16 + $1]) << $1 }
        let crcOK = Self.headerCRC(Array(header[0..<32])) == Array(header[32..<48])
        if !crcOK { headerErrors += 1 }
        let bitsPerSymbol: Int
        switch signal {
        case 0x0A: bitsPerSymbol = 1
        case 0x14: bitsPerSymbol = 2
        case 0x37, 0x6E: unsupported += 1; return .failed
        default: return .failed
        }
        guard length > 0, length <= Self.maximumSymbols, (length * bitsPerSymbol) % 8 == 0 else { return .failed }
        guard t + spb * (length + 1) < count else { return crcOK || length < 1000 ? .needMore : .failed }

        var bits: [UInt8] = []
        bits.reserveCapacity(length * bitsPerSymbol)
        for _ in 0..<length {
            if bitsPerSymbol == 2 {
                guard let pair = dqpskBits() else { return .needMore }
                bits.append(pair.0); bits.append(pair.1)
            } else {
                guard let bit = dbpskBit() else { return .needMore }
                bits.append(bit)
            }
        }
        var mpdu = [UInt8](repeating: 0, count: bits.count / 8)
        for i in 0..<mpdu.count {
            var byte: UInt8 = 0
            for bit in 0..<8 { byte |= bits[8 * i + bit] << UInt8(bit) }
            mpdu[i] = byte
        }
        guard WLANCRC32.verify(mpdu) else { fcsErrors += 1; return .failed }
        var level: Float = 0
        for m in 0..<48 { level += power[start + spb * m] }
        level /= Float(48 * spb)
        let packet = WLANPacket(modulation: .dsss, rateMbps: Double(bitsPerSymbol), mpdu: Array(mpdu.dropLast(4)),
                                rssiDB: 10 * log10(Double(max(level, 1e-12))),
                                offsetKHz: Double(theta) / (2 * .pi) * 1000, date: Date())
        return .packet(packet, t + spb)
    }

    /// CRC-16 des PLCP-Kopfs (x¹⁶ + x¹² + x⁵ + 1, Start 0xFFFF, Einerkomplement)
    /// über die 32 Bits in Sendereihenfolge; Ergebnis MSB zuerst.
    static func headerCRC(_ bits: [UInt8]) -> [UInt8] {
        var crc: UInt16 = 0xFFFF
        for bit in bits {
            let feedback = (crc >> 15 & 1) ^ UInt16(bit)
            crc <<= 1
            if feedback != 0 { crc ^= 0x1021 }
        }
        crc = ~crc
        return (0..<16).map { UInt8(crc >> (15 - $0) & 1) }
    }
}
