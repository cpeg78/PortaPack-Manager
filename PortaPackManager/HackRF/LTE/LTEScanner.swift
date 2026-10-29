import Foundation

/// Eine gefundene Zelle (Ergebnis einer Auswertung, ohne Gerät).
struct LTECellFinding: Sendable, Equatable {
    var carrierMHz: Double
    var sync: LTESyncHit
    var mib: LTEMIB
    var measurement: LTEMeasurement?
}

/// Ein belegter Frequenzabschnitt im Übersichtsspektrum.
struct LTESegment: Sendable, Equatable {
    var lowMHz: Double
    var highMHz: Double
    var levelDB: Double
    var widthMHz: Double { highMHz - lowMHz }
}

/// Suchlauf ohne Gerät: Fensterplan, Spektrum → Kandidaten, Auswertung einer Aufnahme.
///
/// Ablauf je Band: 19,2-MS/s-Fenster im 12-MHz-Abstand (nutzbar ±6 MHz)
/// aufnehmen, daraus das Übersichtsspektrum (15-kHz-Raster) bilden, belegte
/// Abschnitte finden, Mittenkandidaten im 100-kHz-Raster ableiten (Abschnitts-
/// mitte, Kanten ± halbe belegte Breite der Normbandbreiten) und je Kandidat
/// den 1,92-MS/s-Kanal aus derselben Aufnahme schneiden: PSS/SSS/MIB. Gefundene
/// Zellen werden aus dem Abschnitt herausgenommen, der Rest erneut untersucht.
enum LTEScanner {
    static let windowStepMHz = 12.0
    static let usableHalfMHz = 6.0
    /// Belegte halbe Breite (N_RB · 90 kHz) der Normbandbreiten.
    static let occupiedHalfMHz: [Double] = [0.54, 1.35, 2.25, 4.5, 6.75, 9.0]

    /// Abstimmfrequenzen (MHz) für ein Band, inklusive 1 MHz Rand.
    static func windows(for band: LTEBand) -> [Double] {
        let low = band.lowMHz - 1, high = band.highMHz + 1
        let count = Int(((high - low) / windowStepMHz).rounded(.up))
        let span = Double(count) * windowStepMHz
        let first = low - (span - (high - low)) / 2 + usableHalfMHz
        return (0..<count).map { first + Double($0) * windowStepMHz }
    }

    /// Spektrumspunkte (MHz, dB) des nutzbaren Teils einer Aufnahme.
    static func spectrumPoints(re: [Float], im: [Float], tunedMHz: Double) -> [(mhz: Double, db: Float)] {
        let spectrum = LTEFrontEnd.powerSpectrum(re: re, im: im, size: 1280)
        guard spectrum.count == 1280 else { return [] }
        var out: [(Double, Float)] = []
        for i in 0..<1280 {
            let offset = Double(i - 640) * 0.015
            guard abs(offset) <= usableHalfMHz else { continue }
            out.append((tunedMHz + offset, spectrum[i]))
        }
        return out
    }

    /// Belegte Abschnitte: über Boden + 6 dB, mindestens 1 MHz breit; Pegelstufen
    /// über 4 dB teilen einen Abschnitt.
    static func segments(_ points: [(mhz: Double, db: Float)]) -> [LTESegment] {
        let sorted = points.sorted { $0.mhz < $1.mhz }
        guard sorted.count > 100 else { return [] }
        // Glätten (7 Punkte, linear)
        let linear = sorted.map { pow(10, Double($0.db) / 10) }
        var smooth = [Double](repeating: 0, count: linear.count)
        for i in linear.indices {
            let lo = max(0, i - 3), hi = min(linear.count - 1, i + 3)
            smooth[i] = 10 * log10(linear[lo...hi].reduce(0, +) / Double(hi - lo + 1))
        }
        let floor = smooth.sorted()[smooth.count / 10]
        let threshold = floor + 6
        var raw: [(Int, Int)] = []
        var start: Int?
        var gap = 0
        for i in smooth.indices {
            if smooth[i] > threshold {
                if start == nil { start = i }
                gap = 0
            } else if let s = start {
                gap += 1
                if gap > 4 {
                    raw.append((s, i - gap))
                    start = nil
                    gap = 0
                }
            }
        }
        if let s = start { raw.append((s, smooth.count - 1 - gap)) }
        var out: [LTESegment] = []
        for (a, b) in raw {
            guard sorted[b].mhz - sorted[a].mhz >= 0.9 else { continue }
            // Stufen suchen
            var cuts = [a]
            let w = 20
            if b - a > 4 * w {
                var i = a + 2 * w
                while i < b - 2 * w {
                    let left = smooth[(i - w)..<i].reduce(0, +) / Double(w)
                    let right = smooth[i..<(i + w)].reduce(0, +) / Double(w)
                    if abs(left - right) > 4 {
                        // Größte Stufe in der Umgebung
                        var best = i, bestStep = 0.0
                        for j in i..<min(b - 2 * w, i + w) {
                            let l = smooth[(j - w)..<j].reduce(0, +) / Double(w)
                            let r = smooth[j..<(j + w)].reduce(0, +) / Double(w)
                            if abs(l - r) > bestStep { bestStep = abs(l - r); best = j }
                        }
                        cuts.append(best)
                        i = best + 2 * w
                    } else {
                        i += 1
                    }
                }
            }
            cuts.append(b)
            for c in 0..<(cuts.count - 1) {
                let lo = cuts[c], hi = cuts[c + 1]
                guard sorted[hi].mhz - sorted[lo].mhz >= 0.9 else { continue }
                let level = smooth[lo...hi].reduce(0, +) / Double(hi - lo + 1)
                out.append(LTESegment(lowMHz: sorted[lo].mhz, highMHz: sorted[hi].mhz, levelDB: level - floor))
            }
        }
        return out
    }

    /// Mittenkandidaten (MHz, 100-kHz-Raster) für einen Abschnitt.
    static func candidates(for segment: LTESegment, band: LTEBand?) -> [Double] {
        var centers: [Double] = [(segment.lowMHz + segment.highMHz) / 2]
        for half in occupiedHalfMHz where 2 * half <= segment.widthMHz + 0.4 {
            centers.append(segment.lowMHz + half)
            centers.append(segment.highMHz - half)
        }
        var out: [Double] = []
        for c in centers {
            let raster = (c * 10).rounded() / 10
            for d in [0.0, -0.1, 0.1] {
                let f = ((raster + d) * 10).rounded() / 10
                if let band, f < band.lowMHz + 0.6 || f > band.highMHz - 0.6 { continue }
                if !out.contains(where: { abs($0 - f) < 0.01 }) { out.append(f) }
            }
        }
        return out
    }

    /// Frequenzhypothesen für die PSS-Suche: ohne Vorwissen ±35 kHz, sonst um die erwartete Ablage.
    static func cfoHypotheses(ppm: Double?, carrierMHz: Double) -> [Double] {
        if let ppm {
            let expected = ppm * carrierMHz
            return [expected - 5000, expected, expected + 5000]
        }
        return stride(from: -35_000.0, through: 35_000, by: 10_000).map { $0 }
    }

    /// Wertet eine 19,2-MS/s-Aufnahme (Mitte `tunedMHz`) für die Kandidaten aus.
    static func analyze(re: [Float], im: [Float], tunedMHz: Double, candidates: [Double], ppm: Double?) -> [LTECellFinding] {
        var found: [LTECellFinding] = []
        for carrier in candidates {
            let offset = (carrier - tunedMHz) * 1e6
            guard abs(offset) <= (usableHalfMHz + 0.5) * 1e6 else { continue }
            found += analyzeCarrier(re: re, im: im, offsetHz: offset, carrierMHz: carrier,
                                    hypotheses: cfoHypotheses(ppm: ppm ?? estimatePPM(found), carrierMHz: carrier))
        }
        return found
    }

    static func estimatePPM(_ cells: [LTECellFinding]) -> Double? {
        guard !cells.isEmpty else { return nil }
        return cells.map { $0.sync.cfoHz / $0.carrierMHz }.reduce(0, +) / Double(cells.count)
    }

    /// Ein Träger: Kanal ausschneiden, Zellen suchen, MIB lesen.
    static func analyzeCarrier(re: [Float], im: [Float], offsetHz: Double, carrierMHz: Double, hypotheses: [Double]) -> [LTECellFinding] {
        let narrow = LTEFrontEnd.channel(re: re, im: im, offsetHz: offsetHz)
        return analyzeNarrow(re: narrow.re, im: narrow.im, carrierMHz: carrierMHz, hypotheses: hypotheses)
    }

    /// Wie oben, für ein schon auf 1,92 MS/s gebrachtes Signal.
    static func analyzeNarrow(re: [Float], im: [Float], carrierMHz: Double, hypotheses: [Double], only: Int? = nil) -> [LTECellFinding] {
        let hits = LTECellSearch.search(re: re, im: im, cfoHypotheses: hypotheses, only: only)
        var out: [LTECellFinding] = []
        let frameScale = 1 - (hits.first?.cfoHz ?? 0) / (carrierMHz * 1e6)
        for hit in hits {
            var r = re, q = im
            LTEFrontEnd.shift(&r, &q, hz: hit.cfoHz, rate: LTEFrontEnd.searchRate)
            let numerology = hit.extendedCP ? LTECellSearch.numerologyExtended : LTECellSearch.numerologyNormal
            let layout = LTECellLayout(pci: hit.pci, extendedCP: hit.extendedCP, nRB: 6)
            guard let result = LTEMIBDecoder.decode(re: r, im: q, frameStart: hit.frameStart, layout: layout,
                                                    numerology: numerology, frameScale: frameScale) else { continue }
            out.append(LTECellFinding(carrierMHz: carrierMHz, sync: hit, mib: result.mib, measurement: result.measurement))
        }
        return out
    }

    /// Messwerte einer bekannten Zelle (PCI) ohne MIB – auch dann, wenn das MIB
    /// gerade nicht dekodierbar ist (Beobachten beim Ausrichten der Antenne).
    static func measure(re: [Float], im: [Float], hypotheses: [Double], pci: Int) -> (hit: LTESyncHit, measurement: LTEMeasurement)? {
        guard let hit = LTECellSearch.search(re: re, im: im, cfoHypotheses: hypotheses, only: pci, maxCells: 1)
            .first(where: { $0.pci == pci }) else { return nil }
        var r = re, q = im
        LTEFrontEnd.shift(&r, &q, hz: hit.cfoHz, rate: LTEFrontEnd.searchRate)
        let numerology = hit.extendedCP ? LTECellSearch.numerologyExtended : LTECellSearch.numerologyNormal
        let demod = LTEDemodulator(numerology: numerology, layout: LTECellLayout(pci: pci, extendedCP: hit.extendedCP, nRB: 6))
        var estimates: [LTEChannelEstimate] = []
        var frame = hit.frameStart
        while frame < r.count {
            for subframe in [0, 5] {
                let start = frame + subframe * numerology.subframeLength
                if let grid = demod.subframe(re: r, im: q, start: start, subframe: subframe) {
                    estimates.append(LTEChannelEstimator.estimate(grid, ports: 1))
                }
            }
            frame += numerology.frameLength
        }
        guard let measurement = LTEMeasurement.average(estimates) else { return nil }
        return (hit, measurement)
    }

    /// Nimmt die belegte Breite gefundener Zellen aus einem Abschnitt heraus.
    static func remaining(_ segment: LTESegment, after cells: [LTECellFinding]) -> [LTESegment] {
        var parts = [segment]
        for cell in cells {
            let half = Double(cell.mib.nRB) * 0.09 + 0.1
            let lo = cell.carrierMHz - half, hi = cell.carrierMHz + half
            parts = parts.flatMap { part -> [LTESegment] in
                guard hi > part.lowMHz, lo < part.highMHz else { return [part] }
                var pieces: [LTESegment] = []
                if lo > part.lowMHz { pieces.append(LTESegment(lowMHz: part.lowMHz, highMHz: lo, levelDB: part.levelDB)) }
                if hi < part.highMHz { pieces.append(LTESegment(lowMHz: hi, highMHz: part.highMHz, levelDB: part.levelDB)) }
                return pieces
            }
        }
        return parts.filter { $0.widthMHz >= 0.9 }
    }
}
