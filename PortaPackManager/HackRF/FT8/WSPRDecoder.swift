import Accelerate
import Foundation

/// Eine WSPR-Dekodierung.
struct WSPRDecode: Sendable, Identifiable {
    let id = UUID()
    /// Audiofrequenz (Mitte zwischen Ton 1 und 2) in Hz über der Skalenfrequenz.
    var frequency: Double
    /// Zeitversatz zum Sollbeginn (1 s nach der geraden Minute).
    var dt: Double
    /// Rauschabstand in 2500 Hz (dB).
    var snr: Double
    /// Frequenzdrift in Hz über die Aussendung.
    var drift: Double
    var message: WSPRMessage
    var symbols: [Int]
}

/// WSPR-Dekoder nach `wsprd` (K1JT/K9AN, hier nach der Fassung in
/// rtlsdr-wsprd): Spektrum über zwei Symbole im Halbsymbolraster, Kandidaten
/// aus dem geglätteten Mittelspektrum, Grobsuche Frequenz/Zeit/Drift über den
/// Sync-Vektor, Verfeinerung, weiche Symbole, Fano-Dekoder, Abziehen
/// erfolgreicher Signale und zweiter Durchgang.
///
/// Arbeitet auf 375 S/s komplex; der Eingang (12 kHz, Index 0 = gerade
/// Minute) wird je Teilband von ±150 Hz um `centers` heruntergemischt.
final class WSPRDecoder: @unchecked Sendable {
    static let rate = 375.0
    static let nsps = 256
    static let nsym = 162
    static let nbits = 81
    static let df = 375.0 / 256.0
    private let fftSize = 512
    private let fft: FT8DFT
    private let decimation = 32
    private let lowpass: [Float]
    /// Tontabellen je (Frequenz, Drift) – die Verfeinerung fragt dieselben bis zu
    /// 17-mal ab. Je Kandidat geleert (eine Tabelle sind ≈ 1,3 MB).
    private var toneCache: [ToneKey: [[[(Float, Float)]]]] = [:]
    /// Ab hier keine neuen Kandidaten mehr (siehe `decode`).
    private var deadline: Date = .distantFuture

    private struct ToneKey: Hashable {
        var f0: Float
        var drift: Float
    }

    /// Zeit, die ein Zyklus höchstens rechnen darf. Der nächste beginnt 120 s später;
    /// dauerte einer länger, fiel der folgende still aus (Review 28.10.2026, Y15).
    static let cycleBudget: TimeInterval = 100

    init() {
        fft = FT8DFT(length: fftSize)
        lowpass = RadioDemodulator.lowpass(taps: 481, cutoff: 165, rate: 12_000)
    }

    /// Dekodiert einen 2-min-Zyklus. `centers`: Mitten der Teilbänder in Hz.
    /// Nach `deadline` werden keine weiteren Kandidaten mehr geprüft; was bis dahin
    /// dekodiert ist, kommt zurück.
    func decode(_ signal: FT8Signal, centers: [Double], hashes: WSPRCallHashes,
                deadline: Date = Date().addingTimeInterval(WSPRDecoder.cycleBudget)) -> [WSPRDecode] {
        self.deadline = deadline
        var all: [WSPRDecode] = []
        for center in centers {
            guard Date() < deadline else { break }
            let base = downconvert(signal, center: center)
            for var d in decodeBaseband(base, hashes: hashes) {
                d.frequency += center
                if all.contains(where: { $0.message.callsign == d.message.callsign && abs($0.frequency - d.frequency) < 3 }) { continue }
                all.append(d)
            }
        }
        return all.sorted { $0.snr > $1.snr }
    }

    /// 12 kHz → 375 S/s um `center`.
    func downconvert(_ x: FT8Signal, center: Double) -> FT8Signal {
        let mixed = x.shifted(by: center, sampleRate: 12_000)
        let taps = lowpass.count
        // Filter mittig ausrichten: Ausgang n gehört zu Eingang n·32.
        let pad = taps / 2
        var re = [Float](repeating: 0, count: mixed.count + taps), im = re
        for i in 0..<mixed.count { re[pad + i] = mixed.re[i]; im[pad + i] = mixed.im[i] }
        let outCount = mixed.count / decimation
        var oRe = [Float](repeating: 0, count: outCount), oIm = oRe
        vDSP_desamp(re, vDSP_Stride(decimation), lowpass, &oRe, vDSP_Length(outCount), vDSP_Length(taps))
        vDSP_desamp(im, vDSP_Stride(decimation), lowpass, &oIm, vDSP_Length(outCount), vDSP_Length(taps))
        return FT8Signal(re: oRe, im: oIm)
    }

    private struct Candidate {
        var freq: Float = 0
        var snr: Float = 0
        var drift: Float = 0
        var shift: Int = 0
        var sync: Float = 0
    }

    // MARK: - Dekodierung auf 375 S/s

    func decodeBaseband(_ input: FT8Signal, hashes: WSPRCallHashes) -> [WSPRDecode] {
        var idat = input.re, qdat = input.im
        let np = idat.count
        let sync = WSPRCodec.sync.map { Int($0) }
        let minsync1: Float = 0.10
        let symfac: Float = 50
        let minrms: Float = 52.0 * (symfac / 64.0)
        let iifac = 8
        var results: [WSPRDecode] = []
        let hann = (0..<fftSize).map { Float(sin(0.006147931 * Double($0))) }

        for pass in 0..<2 {
            if pass == 1 && results.isEmpty { break }
            let maxdrift = 4
            let minsync2: Float = 0.12
            let blocks = 4 * (np / fftSize) - 1
            guard blocks > 10 else { return results }
            // Spektrum über 2 Symbole im Halbsymbolraster.
            var ps = [[Float]](repeating: [Float](repeating: 0, count: blocks), count: fftSize)
            var inRe = [Float](repeating: 0, count: fftSize), inIm = inRe
            var outRe = [Float](), outIm = [Float]()
            for i in 0..<blocks {
                for j in 0..<fftSize {
                    let k = i * 128 + j
                    inRe[j] = k < np ? idat[k] * hann[j] : 0
                    inIm[j] = k < np ? qdat[k] * hann[j] : 0
                }
                fft.run(inRe, inIm, &outRe, &outIm)
                for j in 0..<fftSize {
                    var k = j + fftSize / 2
                    if k > fftSize - 1 { k -= fftSize }
                    ps[j][i] = outRe[k] * outRe[k] + outIm[k] * outIm[k]
                }
            }
            var psavg = [Float](repeating: 0, count: fftSize)
            for j in 0..<fftSize { psavg[j] = ps[j].reduce(0, +) }
            // Glätten (7 Punkte), ±150 Hz.
            var smspec = [Float](repeating: 0, count: 411)
            for i in 0..<411 {
                for j in -3...3 { smspec[i] += psavg[256 - 205 + i + j] }
            }
            let sortedSpec = smspec.sorted()
            let noise = max(sortedSpec[122], 1e-30)
            let minSNR = Float(pow(10.0, -8.0 / 10.0))
            for j in 0..<411 {
                smspec[j] = smspec[j] / noise - 1
                if smspec[j] < minSNR { smspec[j] = 0.1 * minSNR }
            }
            var cands: [Candidate] = []
            for j in 1..<410 where smspec[j] > smspec[j - 1] && smspec[j] > smspec[j + 1] && cands.count < 200 {
                let f = Float(j - 205) * Float(Self.df / 2)
                guard abs(f) <= 150 else { continue }
                cands.append(Candidate(freq: f, snr: 10 * log10(smspec[j]) - 26.3))
            }
            cands.sort { $0.snr > $1.snr }

            // Grobsuche Frequenz/Zeit/Drift.
            for c in cands.indices {
                guard Date() < deadline else { return results }
                var syncMax: Float = -1e30
                let if0 = Int(cands[c].freq / Float(Self.df / 2)) + Self.nsps
                for ifr in (if0 - 1)...(if0 + 1) {
                    for k0 in -10..<22 {
                        for idrift in -maxdrift...maxdrift {
                            var ss: Float = 0, pow: Float = 0
                            for k in 0..<Self.nsym {
                                let ifd = ifr + Int(Float(k - Self.nbits) / Float(Self.nbits) * Float(idrift) / Float(Self.df))
                                let kindex = k0 + 2 * k
                                guard kindex >= 0, kindex < blocks, ifd - 3 >= 0, ifd + 3 < fftSize else { continue }
                                let p0 = ps[ifd - 3][kindex].squareRoot()
                                let p1 = ps[ifd - 1][kindex].squareRoot()
                                let p2 = ps[ifd + 1][kindex].squareRoot()
                                let p3 = ps[ifd + 3][kindex].squareRoot()
                                ss += Float(2 * sync[k] - 1) * ((p1 + p3) - (p0 + p2))
                                pow += p0 + p1 + p2 + p3
                            }
                            let s = pow > 0 ? ss / pow : 0
                            if s > syncMax {
                                syncMax = s
                                cands[c].shift = 128 * (k0 + 1)
                                cands[c].drift = Float(idrift)
                                cands[c].freq = Float(ifr - Self.nsps) * Float(Self.df / 2)
                                cands[c].sync = s
                            }
                        }
                    }
                }
            }

            for c in cands {
                guard Date() < deadline else { return results }
                toneCache.removeAll(keepingCapacity: true)
                var freq = c.freq, shift = c.shift
                let drift = c.drift
                var syncValue: Float = 0
                // Zeit (Modus 0), dann Frequenz (Modus 1).
                (shift, _, syncValue) = syncAndDemodulate(idat, qdat, freq: freq, freqRange: 0...0, fstep: 0,
                                                          lags: stride(from: shift - 128, through: shift + 128, by: 8), drift: drift)
                (shift, freq, syncValue) = syncAndDemodulate(idat, qdat, freq: freq, freqRange: -2...2, fstep: 0.1,
                                                             lags: stride(from: shift, through: shift, by: 1), drift: drift)
                guard syncValue > minsync1 else { continue }
                var decoded: (data: [UInt8], jitter: Int)?
                var idt = 0
                while decoded == nil && idt <= 128 / iifac {
                    var ii = (idt + 1) / 2
                    if idt % 2 == 1 { ii = -ii }
                    ii *= iifac
                    let (symbols, s2) = softSymbols(idat, qdat, freq: freq, shift: shift + ii, drift: drift, symfac: symfac)
                    var sq: Float = 0
                    for v in symbols { let y = Float(v) - 128; sq += y * y }
                    let rms = (sq / Float(Self.nsym)).squareRoot()
                    if s2 > minsync2, rms > minrms, let data = WSPRCodec.fano(WSPRCodec.deinterleave(symbols)) {
                        decoded = (data, ii)
                    }
                    idt += 1
                }
                guard let (data, jitter) = decoded, let message = WSPRCodec.unpack(data, hashes: hashes) else { continue }
                if results.contains(where: { $0.message.callsign == message.callsign && abs($0.frequency - Double(freq)) < 3 }) { continue }
                let channel = WSPRCodec.channelSymbols(data)
                if pass == 0 {
                    subtract(&idat, &qdat, f0: freq, shift: shift + jitter, drift: drift, symbols: channel)
                }
                results.append(WSPRDecode(frequency: Double(freq), dt: Double(shift + jitter) / Self.rate - 1.0,
                                          snr: Double(c.snr), drift: Double(drift), message: message, symbols: channel))
            }
        }
        return results
    }

    /// Korrelation mit dem Sync-Vektor über Frequenz und Zeitversatz.
    private func syncAndDemodulate(_ id: [Float], _ qd: [Float], freq: Float, freqRange: ClosedRange<Int>, fstep: Float,
                                   lags: StrideThrough<Int>, drift: Float) -> (shift: Int, freq: Float, sync: Float) {
        var best: (Int, Float, Float) = (0, freq, -1e30)
        for ifreq in freqRange {
            let f0 = freq + Float(ifreq) * fstep
            let tones = toneTables(f0: f0, drift: drift)
            for lag in lags {
                var ss: Float = 0, totp: Float = 0
                for i in 0..<Self.nsym {
                    let p = symbolPowers(id, qd, start: lag + i * Self.nsps, tables: tones[i])
                    totp += p.0 + p.1 + p.2 + p.3
                    let cmet = (p.1 + p.3) - (p.0 + p.2)
                    ss += WSPRCodec.sync[i] == 1 ? cmet : -cmet
                }
                let s = totp > 0 ? ss / totp : 0
                if s > best.2 { best = (lag, f0, s) }
            }
        }
        return best
    }

    /// Weiche Symbole (0…255) und Sync-Wert für feste Frequenz/Zeit.
    private func softSymbols(_ id: [Float], _ qd: [Float], freq: Float, shift: Int, drift: Float, symfac: Float) -> ([UInt8], Float) {
        let tones = toneTables(f0: freq, drift: drift)
        var fsymb = [Float](repeating: 0, count: Self.nsym)
        var ss: Float = 0, totp: Float = 0
        for i in 0..<Self.nsym {
            let p = symbolPowers(id, qd, start: shift + i * Self.nsps, tables: tones[i])
            totp += p.0 + p.1 + p.2 + p.3
            let cmet = (p.1 + p.3) - (p.0 + p.2)
            ss += WSPRCodec.sync[i] == 1 ? cmet : -cmet
            fsymb[i] = WSPRCodec.sync[i] == 1 ? p.3 - p.1 : p.2 - p.0
        }
        let sync = totp > 0 ? ss / totp : 0
        var fsum: Float = 0, f2sum: Float = 0
        for v in fsymb { fsum += v / Float(Self.nsym); f2sum += v * v / Float(Self.nsym) }
        let fac = max((f2sum - fsum * fsum).squareRoot(), 1e-20)
        let symbols = fsymb.map { v -> UInt8 in
            let x = max(-128, min(127, symfac * v / fac))
            return UInt8(Int(x + 128))
        }
        return (symbols, sync)
    }

    /// Je Symbol die vier Ton-Oszillatoren (cos, sin) über 256 Abtastwerte.
    private func toneTables(f0: Float, drift: Float) -> [[[(Float, Float)]]] {
        let key = ToneKey(f0: f0, drift: drift)
        if let cached = toneCache[key] { return cached }
        var cache: [Float: [[(Float, Float)]]] = [:]
        let tables: [[[(Float, Float)]]] = (0..<Self.nsym).map { i in
            let fp = f0 + (drift / 2) * Float(i - Self.nbits) / Float(Self.nbits)
            if let t = cache[fp] { return t }
            let t = (0..<4).map { tone -> [(Float, Float)] in
                let f = Double(fp) + (Double(tone) - 1.5) * Self.df
                let dphi = 2 * Double.pi * f / Self.rate
                return (0..<Self.nsps).map { j in (Float(cos(dphi * Double(j))), Float(sin(dphi * Double(j)))) }
            }
            cache[fp] = t
            return t
        }
        toneCache[key] = tables
        return tables
    }

    @inline(__always)
    private func symbolPowers(_ id: [Float], _ qd: [Float], start: Int, tables: [[(Float, Float)]]) -> (Float, Float, Float, Float) {
        var acc: [Float] = [0, 0, 0, 0, 0, 0, 0, 0]
        let lo = max(1, start), hi = min(id.count, start + Self.nsps)
        guard lo < hi else { return (0, 0, 0, 0) }
        for t in 0..<4 {
            let tab = tables[t]
            var i0: Float = 0, q0: Float = 0
            for k in lo..<hi {
                let (c, s) = tab[k - start]
                i0 += id[k] * c + qd[k] * s
                q0 += -id[k] * s + qd[k] * c
            }
            acc[2 * t] = i0; acc[2 * t + 1] = q0
        }
        func mag(_ t: Int) -> Float { (acc[2 * t] * acc[2 * t] + acc[2 * t + 1] * acc[2 * t + 1]).squareRoot() }
        return (mag(0), mag(1), mag(2), mag(3))
    }

    /// Kohärentes Abziehen (wsprd `subtract_signal2`).
    private func subtract(_ id: inout [Float], _ qd: inout [Float], f0: Float, shift: Int, drift: Float, symbols: [Int]) {
        let np = id.count
        let total = Self.nsym * Self.nsps
        let nfilt = 360
        var refi = [Float](repeating: 0, count: total), refq = refi
        var phi = 0.0
        for i in 0..<Self.nsym {
            let dphi = 2 * Double.pi / Self.rate * (Double(f0) + Double(drift / 2) * (Double(i) - Double(Self.nsym) / 2) / (Double(Self.nsym) / 2)
                                                    + (Double(symbols[i]) - 1.5) * Self.df)
            for j in 0..<Self.nsps {
                refi[i * Self.nsps + j] = Float(cos(phi))
                refq[i * Self.nsps + j] = Float(sin(phi))
                phi += dphi
            }
        }
        var w = (0..<nfilt).map { Float(sin(Double.pi * Double($0) / Double(nfilt - 1))) }
        let norm = w.reduce(0, +)
        w = w.map { $0 / norm }
        var partial = [Float](repeating: 0, count: nfilt)
        for i in 1..<nfilt { partial[i] = partial[i - 1] + w[i] }
        let padded = total + 2 * nfilt
        var ci = [Float](repeating: 0, count: padded), cq = ci
        for i in 0..<total {
            let k = shift + i
            if k > 0 && k < np {
                ci[i + nfilt] = id[k] * refi[i] + qd[k] * refq[i]
                cq[i + nfilt] = qd[k] * refi[i] - id[k] * refq[i]
            }
        }
        var cfi = [Float](repeating: 0, count: padded), cfq = cfi
        cfi.withUnsafeMutableBufferPointer { out in
            vDSP_conv(ci, 1, w, 1, out.baseAddress! + nfilt / 2, 1, vDSP_Length(padded - nfilt), vDSP_Length(nfilt))
        }
        cfq.withUnsafeMutableBufferPointer { out in
            vDSP_conv(cq, 1, w, 1, out.baseAddress! + nfilt / 2, 1, vDSP_Length(padded - nfilt), vDSP_Length(nfilt))
        }
        for i in 0..<total {
            var nrm: Float = 1
            if i < nfilt / 2 { nrm = partial[nfilt / 2 + i] }
            else if i > total - 1 - nfilt / 2 { nrm = partial[nfilt / 2 + total - 1 - i] }
            let k = shift + i, j = i + nfilt
            if k > 0 && k < np && nrm > 0 {
                id[k] -= (cfi[j] * refi[i] - cfq[j] * refq[i]) / nrm
                qd[k] -= (cfi[j] * refq[i] + cfq[j] * refi[i]) / nrm
            }
        }
    }
}
