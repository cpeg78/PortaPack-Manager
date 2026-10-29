import Accelerate
import Foundation

/// SSTV-Dekoder für das FM-demodulierte Tonsignal (48 kHz).
///
/// Ablauf:
/// 1. Gleichanteil weg, komplex mit 1700 Hz mischen, Tiefpass ±1,9 kHz,
///    ÷2 auf 24 kHz. Gespeichert wird je Abtastwert das Produkt
///    d = z[n]·z*[n−1]; die Tonfrequenz eines Abschnitts ist arg(Σd). Das
///    gewichtet nach Amplitude – FM-Knackser (|z| klein) fallen kaum ins
///    Gewicht, anders als beim Mitteln einzelner Frequenzwerte.
/// 2. VIS-Kopf in 2,5-ms-Schritten suchen (Vorton 1900 Hz, Startbit 1200,
///    7 Datenbits + Parität mit 1100/1300 Hz, Stoppbit 1200). Der gemessene
///    Vorton liefert zugleich den Tonversatz des Senders.
/// 3. Je übertragener Zeile den Synchronimpuls in einem Fenster um die
///    erwartete Lage suchen; über alle gefundenen Impulse eine Gerade legen
///    (Lage = a + b·Zeile). Die Steigung b ist die tatsächliche Zeilendauer –
///    das korrigiert den Schräglauf (Takt von Sender/Empfänger weicht ab).
/// 4. Bildpunkte aus arg(Σd) über ihre Dauer; alle 16 Zeilen
///    und am Ende wird das ganze Bild mit der neuesten Geraden neu gerechnet.
///
/// Nicht threadsicher – der Aufrufer serialisiert (Empfangswarteschlange).
final class SSTVDecoder: @unchecked Sendable {
    static let inputRate = 48_000.0
    static let rate = 24_000.0
    private static let mixFrequency = 1700.0
    private static let hop = 60                 // 2,5 ms
    private static let cell = 12                // Hops je VIS-Bit (30 ms)
    private static let visCells = 14            // 4 Vorton, Start, 7 Daten, Parität, Stopp

    struct Status: Sendable {
        var mode: SSTVMode?
        var rows = 0
        var syncsFound = 0
        var toneOffset = 0.0
    }

    // Vorstufe
    private let filter = RadioDemodulator.lowpass(taps: 383, cutoff: 1900, rate: SSTVDecoder.inputRate)
    private var histRe: [Float] = []
    private var histIm: [Float] = []
    private var dc: Float = 0
    private var mixPhase = 0.0
    private var lastRe: Float = 1
    private var lastIm: Float = 0

    // VIS-Suche
    private var hopSum = SIMD2<Float>(0, 0)
    private var hopFill = 0
    private var hops: [Float] = []
    private var sampleIndex = 0                 // Zähler der 24-kHz-Werte
    private var lastVIS = Int.min / 2
    /// Die letzten 0,5 s – Vorlauf für den Bildpuffer.
    private var recent: [SIMD2<Float>] = []

    // Laufender Empfang
    private var reception: Reception?
    /// Fertige (auch abgebrochene) Bilder, abzuholen mit `takeFinished`.
    private var finished: [SSTVImage] = []

    private struct Reception {
        let mode: SSTVMode
        let offset: Double             // Tonversatz (Hz)
        let base: Int                  // globaler Index von buf[0]
        var buf: [SIMD2<Float>] = []
        let nominalB: Double           // Zeilendauer in Abtastwerten
        var fitA: Double               // Lage des Synchronimpulses von Zeile 0 (im Puffer)
        var fitB: Double
        var syncs: [(line: Int, pos: Double)] = []
        var nextLine = 0
        var missed = 0
        var image: SSTVImage
        /// Chroma je übertragener Zeile (nur Robot 36): Kanal und Werte.
        var robotChroma: [Int: (isCb: Bool, values: [Double])] = [:]
        var robotLuma: [Int: [Double]] = [:]
        /// Lage (Beginn, Dauer) je Zeile beim letzten Zeichnen – neu gezeichnet
        /// wird nur, was sich seitdem um mehr als einen Abtastwert verschoben hat.
        var drawn: [Int: (start: Double, length: Double)] = [:]
        var lastSyncLine = -1
    }

    init() {}

    func reset() {
        histRe = []; histIm = []
        dc = 0; mixPhase = 0; lastRe = 1; lastIm = 0
        hopSum = .zero; hopFill = 0; hops = []; recent = []
        sampleIndex = 0; lastVIS = Int.min / 2
        reception = nil
        finished = []
    }

    var status: Status {
        guard let r = reception else { return Status() }
        return Status(mode: r.mode, rows: r.image.rows, syncsFound: r.syncs.count, toneOffset: r.offset)
    }

    /// Kopie des Bildes im Empfang (oder `nil`).
    var currentImage: SSTVImage? { reception?.image }

    func takeFinished() -> [SSTVImage] {
        defer { finished = [] }
        return finished
    }

    /// Bricht den laufenden Empfang ab und liefert das bisherige Bild als fertig.
    func flush() {
        finishReception()
    }

    // MARK: Eingang

    /// FM-Diskriminatorwerte bei 48 kHz (beliebige Skalierung).
    func process(_ input: [Float]) {
        guard !input.isEmpty else { return }
        // Ein einziger NaN/∞-Wert vergiftete sonst Gleichanteil und Filterverlauf
        // dauerhaft – der Empfänger bliebe bis zum Neustart taub.
        let audio = input.allSatisfy(\.isFinite) ? input : input.map { $0.isFinite ? $0 : 0 }
        var re = [Float](repeating: 0, count: audio.count)
        var im = [Float](repeating: 0, count: audio.count)
        let step = 2 * Double.pi * Self.mixFrequency / Self.inputRate
        var phase = mixPhase
        var d = dc
        for n in audio.indices {
            d += 0.0005 * (audio[n] - d)
            let x = audio[n] - d
            re[n] = x * Float(cos(phase))
            im[n] = -x * Float(sin(phase))
            phase += step
            if phase > 2 * .pi { phase -= 2 * .pi }
        }
        mixPhase = phase
        dc = d
        let (bRe, bIm) = RadioDemodulator.decimateComplex(re, im, history: &histRe, &histIm, filter: filter, factor: 2)
        var products = [SIMD2<Float>](repeating: .zero, count: bRe.count)
        var pr = lastRe, pi = lastIm
        for n in bRe.indices {
            let r = bRe[n], i = bIm[n]
            products[n] = SIMD2(r * pr + i * pi, i * pr - r * pi)
            pr = r; pi = i
        }
        lastRe = pr; lastIm = pi
        push(products)
    }

    /// Tonfrequenz (Hz) zu einer Summe von Produkten d.
    private static func frequency(_ sum: SIMD2<Double>) -> Double {
        mixFrequency + atan2(sum.y, sum.x) * rate / (2 * .pi)
    }

    private func push(_ products: [SIMD2<Float>]) {
        for d in products {
            sampleIndex += 1
            if reception != nil { reception!.buf.append(d) }
            recent.append(d)
            hopSum += d
            hopFill += 1
            if hopFill == Self.hop {
                hops.append(Float(Self.frequency(SIMD2<Double>(Double(hopSum.x), Double(hopSum.y)))))
                hopSum = .zero
                hopFill = 0
                if hops.count > 400 { hops.removeFirst(hops.count - 200) }
                checkVIS()
            }
        }
        if recent.count > 24_000 { recent.removeFirst(recent.count - 12_000) }
        advance()
    }

    // MARK: VIS

    private func checkVIS() {
        let needed = Self.cell * Self.visCells
        guard hops.count >= needed, sampleIndex - lastVIS > Int(Self.rate) else { return }
        let start = hops.count - needed
        func cellValue(_ c: Int) -> Float {
            let from = start + c * Self.cell + 2
            let values = hops[from..<from + Self.cell - 4].sorted()
            return (values[3] + values[4]) / 2
        }
        let cells = (0..<Self.visCells).map(cellValue)
        let leader = cells[0..<4]
        guard let lo = leader.min(), let hi = leader.max(), hi - lo < 60 else { return }
        let leaderMean = Double(leader.reduce(0, +)) / 4
        let offset = leaderMean - 1900
        guard abs(offset) < 150 else { return }
        func near(_ value: Float, _ target: Double) -> Bool { abs(Double(value) - offset - target) < 70 }
        guard near(cells[4], 1200), near(cells[13], 1200) else { return }
        var code = 0, ones = 0
        for k in 0..<8 {
            let v = cells[5 + k]
            let bit: Int
            if near(v, 1100) { bit = 1 } else if near(v, 1300) { bit = 0 } else { return }
            if k < 7 { code |= bit << k }
            ones += bit
        }
        guard ones % 2 == 0, let mode = SSTVMode.from(vis: code) else { return }
        lastVIS = sampleIndex
        if reception != nil { finishReception() }
        begin(mode: mode, offset: offset)
    }

    private func begin(mode: SSTVMode, offset: Double) {
        // Ende des Stoppbits ≈ jetzt (auf ±2 Hops genau); Vorlauf 0,1 s.
        let lead = min(recent.count, 2400)
        let base = sampleIndex - lead
        let leadIn = mode.leadIn.reduce(0) { $0 + $1.duration } * Self.rate
        let nominalB = mode.lineDuration * Self.rate
        let firstSync = Double(lead) + leadIn + mode.syncOffset * Self.rate
        var reception = Reception(mode: mode, offset: offset, base: base, nominalB: nominalB,
                                  fitA: firstSync, fitB: nominalB, image: SSTVImage(mode: mode))
        reception.buf = Array(recent.suffix(lead))
        reception.buf.reserveCapacity(Int(mode.duration * Self.rate) + 24_000)
        self.reception = reception
    }

    // MARK: Zeilen

    private func advance() {
        while var r = reception {
            let n = r.nextLine
            let window = (n < 2 && r.syncs.isEmpty ? 0.012 : 0.003) * Self.rate
            let ratio = r.fitB / r.nominalB
            let predicted = r.fitA + r.fitB * Double(n)
            let lineStart = predicted - r.mode.syncOffset * Self.rate * ratio
            let needed = max(predicted + window + r.mode.syncDuration * Self.rate, lineStart + r.fitB) + 0.003 * Self.rate
            guard Double(r.buf.count) >= needed else { return }
            let syncLength = Int((r.mode.syncDuration * Self.rate * ratio).rounded())
            if let found = findSync(in: r.buf, around: predicted, window: window, length: syncLength, offset: r.offset) {
                r.syncs.append((n, found))
                r.missed = 0
                r.lastSyncLine = n
                fit(&r)
            } else {
                r.missed += 1
            }
            decodeLine(n, &r)
            r.nextLine += 1
            if r.nextLine % 16 == 0 { renderAll(&r) }
            reception = r
            if r.nextLine >= r.mode.transmittedLines || r.missed >= 25 {
                finishReception()
                return
            }
        }
    }

    /// Sucht den Beginn des 1200-Hz-Impulses: Lage mit dem größten Mittel von
    /// (2w − 1) über die Impulslänge, w = 1 bei ≤ 1200 Hz, 0 ab 1400 Hz.
    private func findSync(in buf: [SIMD2<Float>], around center: Double, window: Double, length: Int, offset: Double) -> Double? {
        let smooth = 6                                  // ±0,25 ms glätten
        let from = max(smooth, Int((center - window).rounded(.down)))
        let to = min(buf.count - length - 1 - smooth, Int((center + window).rounded(.up)))
        guard length > 4, to > from else { return nil }
        // Laufende Summe der Produkte für die geglättete Frequenz je Abtastwert.
        let lo = from - smooth, hi = to + length + smooth
        var running = [SIMD2<Double>](repeating: .zero, count: hi - lo + 1)
        for k in lo..<hi {
            running[k - lo + 1] = running[k - lo] + SIMD2<Double>(Double(buf[k].x), Double(buf[k].y))
        }
        var prefix = [Float](repeating: 0, count: to + length - from + 1)
        let base = 1400 + offset
        for k in 0..<(to + length - from) {
            let index = from + k - lo
            let f = Self.frequency(running[index + smooth + 1] - running[index - smooth])
            let w = Float(min(max((base - f) / 200, 0), 1))
            prefix[k + 1] = prefix[k] + 2 * w - 1
        }
        var best: Float = -.infinity
        var bestIndex = from
        for t in from...to {
            let s = prefix[t - from + length] - prefix[t - from]
            if s > best { best = s; bestIndex = t }
        }
        return best / Float(length) > 0.3 ? Double(bestIndex) : nil
    }

    /// Gerade durch die Impulslagen, Steigung schwach zur Sollzeilendauer
    /// gezogen (sonst schwanken die ersten Zeilen); Ausreißer > 1,5 ms fallen raus.
    private func fit(_ r: inout Reception) {
        let b0 = r.nominalB
        // Vorwissen: Takt auf ±0,2 % genau, Impulslage auf ±1 Abtastwert.
        let lambda = 1 / pow(0.002 * b0, 2)
        func solve(_ points: [(line: Int, pos: Double)]) -> (Double, Double) {
            let n = Double(points.count)
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for p in points {
                let x = Double(p.line)
                sx += x; sy += p.pos; sxx += x * x; sxy += x * p.pos
            }
            let a11 = n, a12 = sx, a22 = sxx + lambda
            let r1 = sy, r2 = sxy + lambda * b0
            let det = a11 * a22 - a12 * a12
            guard det > 0 else { return (r1 / n - b0 * sx / n, b0) }
            return ((r1 * a22 - a12 * r2) / det, (a11 * r2 - a12 * r1) / det)
        }
        var (a, b) = solve(r.syncs)
        let limit = 0.0015 * Self.rate
        let inliers = r.syncs.filter { abs($0.pos - (a + b * Double($0.line))) < limit }
        if inliers.count >= 2, inliers.count < r.syncs.count { (a, b) = solve(inliers) }
        // Zeitweise falsch gefundene Impulse nicht dauerhaft mitschleppen.
        if r.syncs.count > 8 {
            r.syncs = r.syncs.filter { abs($0.pos - (a + b * Double($0.line))) < 3 * limit }
        }
        guard abs(b / b0 - 1) < 0.02 else { return }
        r.fitA = a
        r.fitB = b
        r.image.clockPPM = (b / b0 - 1) * 1e6
    }

    /// Tonfrequenz über [t0, t1) (Abtastwerte, gebrochen): arg der gewichteten Summe.
    private static func mean(_ buf: [SIMD2<Float>], _ t0: Double, _ t1: Double) -> Double {
        let a = max(0, t0), b = min(Double(buf.count), t1)
        guard b > a else { return 1500 }
        var sum = SIMD2<Double>.zero
        var t = a
        while t < b {
            let k = Int(t)
            let next = min(Double(k + 1), b)
            sum += SIMD2<Double>(Double(buf[k].x), Double(buf[k].y)) * (next - t)
            t = next
        }
        return frequency(sum)
    }

    /// Bildwerte (0…255) aller Abtaststrecken der Zeile `n`.
    private static func scanValues(_ n: Int, _ r: Reception) -> (values: [SSTVMode.Channel: [Double]], separator: Double?) {
        let ratio = r.fitB / r.nominalB
        var t = r.fitA + r.fitB * Double(n) - r.mode.syncOffset * rate * ratio
        var values: [SSTVMode.Channel: [Double]] = [:]
        var separator: Double?
        let width = r.mode.width
        for (index, segment) in r.mode.segments(line: n).enumerated() {
            let length = segment.duration * rate * ratio
            switch segment {
            case .tone:
                // Robot 36: Trenner nach der Helligkeit (1500 = R−Y, 2300 = B−Y).
                if r.mode.family == .robot36, index == 3 {
                    separator = mean(r.buf, t + length * 0.2, t + length * 0.8) - r.offset
                }
            case .scan(let channel, _):
                let px = length / Double(width)
                values[channel] = (0..<width).map { j in
                    SSTVMode.value(frequency: mean(r.buf, t + Double(j) * px, t + Double(j + 1) * px) - r.offset)
                }
            }
            t += length
        }
        return (values, separator)
    }

    private func decodeLine(_ n: Int, _ r: inout Reception) {
        Self.render(line: n, into: &r)
        r.image.rows = min(r.mode.height, r.mode.family == .pd ? 2 * (n + 1) : n + 1)
    }

    private static func render(line n: Int, into r: inout Reception) {
        r.drawn[n] = placement(n, r)
        let (values, separator) = scanValues(n, r)
        let width = r.mode.width
        switch r.mode.family {
        case .martin, .scottie:
            guard let red = values[.r], let green = values[.g], let blue = values[.b], n < r.mode.height else { return }
            for x in 0..<width {
                r.image.set(row: n, x: x, (UInt8(red[x].rounded()), UInt8(green[x].rounded()), UInt8(blue[x].rounded())))
            }
        case .pd:
            guard let y1 = values[.y], let y2 = values[.y2], let cr = values[.cr], let cb = values[.cb] else { return }
            for x in 0..<width {
                r.image.set(row: 2 * n, x: x, SSTVMode.rgb(y: y1[x], cr: cr[x], cb: cb[x]))
                r.image.set(row: 2 * n + 1, x: x, SSTVMode.rgb(y: y2[x], cr: cr[x], cb: cb[x]))
            }
        case .robot36:
            guard let luma = values[.y], n < r.mode.height else { return }
            let chroma = values[.cr] ?? values[.cb] ?? []
            let isCb = separator.map { $0 > 1900 } ?? (n % 2 == 1)
            r.robotLuma[n] = luma
            r.robotChroma[n] = (isCb, chroma)
            // Zeile mit dem Nachbarn der Zeilenpaarung zusammensetzen.
            let partner = n % 2 == 0 ? n + 1 : n - 1
            for row in [n, partner] where row >= 0 && row < r.mode.height {
                guard let y = r.robotLuma[row] else { continue }
                var crValues = [Double](repeating: 128, count: width)
                var cbValues = crValues
                for source in [row, row % 2 == 0 ? row + 1 : row - 1] {
                    guard let c = r.robotChroma[source], c.values.count == width else { continue }
                    if c.isCb { cbValues = c.values } else { crValues = c.values }
                }
                for x in 0..<width {
                    r.image.set(row: row, x: x, SSTVMode.rgb(y: y[x], cr: crValues[x], cb: cbValues[x]))
                }
            }
        }
    }

    private static func placement(_ n: Int, _ r: Reception) -> (start: Double, length: Double) {
        (r.fitA + r.fitB * Double(n) - r.mode.syncOffset * rate * r.fitB / r.nominalB, r.fitB)
    }

    /// Bisherige Zeilen mit der aktuellen Geraden neu rechnen, soweit sie sich verschoben haben.
    private func renderAll(_ r: inout Reception) {
        for n in 0..<r.nextLine {
            let now = Self.placement(n, r)
            if let old = r.drawn[n], abs(old.start - now.start) < 0.75,
               abs(old.start + old.length - now.start - now.length) < 0.75 { continue }
            Self.render(line: n, into: &r)
        }
    }

    private func finishReception() {
        guard var r = reception else { return }
        reception = nil
        renderAll(&r)
        r.image.complete = r.nextLine >= r.mode.transmittedLines
        if !r.image.complete {
            // Abgerissen: Zeilen nach dem letzten Impuls sind nur Rauschen.
            let rows = min(r.mode.height, (r.lastSyncLine + 1) * (r.mode.family == .pd ? 2 : 1))
            r.image.rows = rows
            for k in (rows * r.mode.width * 4)..<r.image.rgba.count where k % 4 != 3 { r.image.rgba[k] = 0 }
        }
        // Ohne einen einzigen gefundenen Impuls war es kein Bild.
        if !r.syncs.isEmpty { finished.append(r.image) }
    }
}
