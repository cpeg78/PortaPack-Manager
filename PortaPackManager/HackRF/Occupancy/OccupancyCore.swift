import Accelerate
import Foundation

// Belegungsmonitor – Rechenkern ohne Gerät (testbar).
//
// Ablauf: Das Band wird in 20-MHz-Fenstern (nutzbar ±7 MHz, Lücke ±60 kHz um
// die Gleichspannungsspitze, wie beim `BandScanner`) beobachtet. Je Fenster
// entsteht ein „Besuch“: FFT-Rahmen werden zu Gruppen gemittelt, jede Gruppe
// auf das Frequenzraster des Bandes abgebildet. Je Rasterbin zählt der Besuch
// Summe, Spitze und – gegen den Rauschboden des vorigen Besuchs desselben
// Fensters – wie viele Gruppen über der Schwelle lagen. Besuche werden zu
// Zeitscheiben (z. B. 1 min) zusammengefasst und gespeichert.

/// Vorlage für ein Band. `id` ist die feste Kennung (gemerkt in den
/// Einstellungen und im Fernzugriff), `name` der übersetzbare Anzeigename.
struct OccupancyPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let startMHz: Double
    let endMHz: Double
    let binKHz: Double
    let mode: RadioMode

    init(_ id: String, name: String? = nil, startMHz: Double, endMHz: Double, binKHz: Double, mode: RadioMode) {
        self.id = id
        self.name = name ?? id
        self.startMHz = startMHz
        self.endMHz = endMHz
        self.binKHz = binKHz
        self.mode = mode
    }

    static let all: [OccupancyPreset] = [
        OccupancyPreset("433 MHz ISM", startMHz: 433.05, endMHz: 434.79, binKHz: 10, mode: .nfm),
        OccupancyPreset("868 MHz SRD", startMHz: 863.0, endMHz: 870.0, binKHz: 25, mode: .nfm),
        OccupancyPreset("2-m-Band", name: String(localized: "2-m-Band"), startMHz: 144.0, endMHz: 146.0, binKHz: 6.25, mode: .nfm),
        OccupancyPreset("70-cm-Band", name: String(localized: "70-cm-Band"), startMHz: 430.0, endMHz: 440.0, binKHz: 12.5, mode: .nfm),
        OccupancyPreset("PMR446", startMHz: 446.0, endMHz: 446.2, binKHz: 3.125, mode: .nfm),
        OccupancyPreset("Flugfunk", name: String(localized: "Flugfunk"), startMHz: 118.0, endMHz: 137.0, binKHz: 8.33, mode: .am),
        OccupancyPreset("Seefunk", name: String(localized: "Seefunk"), startMHz: 156.0, endMHz: 162.05, binKHz: 25, mode: .nfm),
        OccupancyPreset("Freenet", startMHz: 149.0, endMHz: 149.125, binKHz: 3.125, mode: .nfm),
        OccupancyPreset("CB-Funk", name: String(localized: "CB-Funk"), startMHz: 26.96, endMHz: 27.41, binKHz: 5, mode: .am),
    ]

    /// Vorlage zu einer gemerkten Kennung (ältere Stände merkten den Namen – der ist gleich).
    static func with(id: String?) -> OccupancyPreset? {
        id.flatMap { id in all.first { $0.id == id } }
    }

    /// Betriebsart fürs Radio bei einer frei gewählten Frequenz.
    static func radioMode(for mhz: Double) -> RadioMode {
        if let preset = all.first(where: { ($0.startMHz...$0.endMHz).contains(mhz) }) { return preset.mode }
        if (87.5...108).contains(mhz) { return .wfm }
        if mhz < 30 || (108...137).contains(mhz) { return .am }
        return .nfm
    }
}

/// Frequenzraster und Fensterplan eines Bandes.
struct OccupancyPlan: Equatable, Sendable {
    static let sampleRate = 20_000_000.0
    static let usableHalfSpanMHz = 7.0
    static let dcHoleMHz = 0.06
    /// Bis zu dieser Breite bleibt das Band mit festem Abstand neben der Mitte
    /// in einem Fenster – ohne Umstimmen, ohne DC-Lücke im Band.
    static let narrowWidthMHz = 6.5
    /// Größte Breite je Fenster (Rest bis ±7 MHz für den Versatz).
    static let windowWidthMHz = 13.0
    /// Versatz jeder zweiten Runde, damit die DC-Lücke eines Fensters in der
    /// nächsten Runde gemessen wird.
    static let alternateShiftMHz = 0.4

    var startMHz: Double
    var endMHz: Double
    var binKHz: Double

    init(startMHz: Double, endMHz: Double, binKHz: Double) {
        let lo = max(1, min(startMHz, endMHz)), hi = min(6000, max(startMHz, endMHz))
        self.startMHz = lo
        self.endMHz = max(hi, lo + 0.01)
        // Nicht feiner als die feinste FFT (16384 Punkte ≈ 1,22 kHz).
        self.binKHz = max(Self.sampleRate / 16384 / 1000, binKHz)
    }

    var binMHz: Double { binKHz / 1000 }
    var widthMHz: Double { endMHz - startMHz }
    var binCount: Int { max(1, Int((widthMHz / binMHz).rounded())) }

    func binCenterMHz(_ index: Int) -> Double { startMHz + (Double(index) + 0.5) * binMHz }

    func binIndex(forMHz mhz: Double) -> Int? {
        let i = Int(((mhz - startMHz) / binMHz).rounded(.down))
        return (0..<binCount).contains(i) ? i : nil
    }

    /// FFT-Größe: Auflösung mindestens so fein wie das Raster, 1024…16384.
    var fftSize: Int {
        var n = 1024
        while Self.sampleRate / Double(n) > binKHz * 1000 + 1e-6, n < 16384 { n *= 2 }
        return n
    }

    var isNarrow: Bool { widthMHz <= Self.narrowWidthMHz }

    /// Fenstermitten einer Runde. Schmale Bänder: ein festes Fenster, Band
    /// 0,3 MHz oberhalb der Mitte. Breite: so viele Fenster wie nötig,
    /// jede zweite Runde um 0,4 MHz versetzt (DC-Lücke wandert weg).
    func centers(round: Int) -> [Double] {
        if isNarrow { return [startMHz - 0.3] }
        let n = Int((widthMHz / Self.windowWidthMHz).rounded(.up))
        let w = widthMHz / Double(n)
        let shift = round % 2 == 0 ? -Self.alternateShiftMHz / 2 : Self.alternateShiftMHz / 2
        return (0..<n).map { startMHz + (Double($0) + 0.5) * w + shift }
    }

    /// Wie oft sich die Runden wiederholen (1 = jedes Mal dieselben Fenster).
    var roundPeriod: Int { isNarrow ? 1 : 2 }

    /// Abbildung der FFT-Bins eines Fensters auf das Raster.
    func mapping(centerMHz: Double, fftSize: Int) -> OccupancyMapping {
        let binHz = Self.sampleRate / Double(fftSize)
        var grid: [Int32] = [], lo: [Int32] = [], hi: [Int32] = []
        // Nutzbare FFT-Bins (geshiftet: Index 0 = −fs/2).
        func usable(_ k: Int) -> Bool {
            let offset = Double(k - fftSize / 2) * binHz / 1e6
            return abs(offset) <= Self.usableHalfSpanMHz && abs(offset) >= Self.dcHoleMHz
        }
        for g in 0..<binCount {
            let low = startMHz + Double(g) * binMHz - centerMHz
            let high = low + binMHz
            // Bins, deren Mitte im Rasterbin liegt.
            var first = Int((low * 1e6 / binHz).rounded(.up)) + fftSize / 2
            var last = Int((high * 1e6 / binHz).rounded(.up)) - 1 + fftSize / 2
            if first > last {
                let nearest = Int(((low + high) / 2 * 1e6 / binHz).rounded()) + fftSize / 2
                first = nearest; last = nearest
            }
            guard first >= 0, last < fftSize, (first...last).allSatisfy(usable) else { continue }
            grid.append(Int32(g)); lo.append(Int32(first)); hi.append(Int32(last))
        }
        var floorBins: [Int32] = []
        for k in 0..<fftSize where usable(k) { floorBins.append(Int32(k)) }
        return OccupancyMapping(centerMHz: centerMHz, fftSize: fftSize, grid: grid, lo: lo, hi: hi, floorBins: floorBins)
    }
}

/// Welche FFT-Bins (geshiftet) welchen Rasterbin speisen.
struct OccupancyMapping: Sendable {
    let centerMHz: Double
    let fftSize: Int
    let grid: [Int32]
    let lo: [Int32]
    let hi: [Int32]
    /// Bins für die Rauschboden-Schätzung (ganzes nutzbares Fenster).
    let floorBins: [Int32]
}

/// Ergebnis eines Besuchs: Werte je Rasterbin (nur die gemessenen).
struct OccupancyVisit: Sendable {
    var grid: [Int32] = []
    var sum: [Double] = []
    var maximum: [Float] = []
    var frames: Int = 0
    /// Gruppen mit Urteil (Schwelle bekannt) und davon über der Schwelle.
    var judged: Int = 0
    var over: [Int32] = []
    /// Rauschboden dieses Besuchs in dB (unteres Fünftel des mittleren Spektrums).
    var floorDB: Float = -200
}

/// Sammelt die Gruppen eines Besuchs (rein, ohne Sperren).
struct OccupancyVisitAccumulator {
    static let floorPercentile = 0.2

    let mapping: OccupancyMapping
    /// Schwelle als lineare Leistung; `nil` = Boden noch unbekannt.
    let thresholdLinear: Float?
    private var sum: [Double]
    private var maximum: [Float]
    private var over: [Int32]
    private var meanSpectrum: [Double]
    private(set) var frames = 0

    init(mapping: OccupancyMapping, thresholdLinear: Float?) {
        self.mapping = mapping
        self.thresholdLinear = thresholdLinear
        sum = [Double](repeating: 0, count: mapping.grid.count)
        maximum = [Float](repeating: 0, count: mapping.grid.count)
        over = [Int32](repeating: 0, count: mapping.grid.count)
        meanSpectrum = [Double](repeating: 0, count: mapping.floorBins.count)
    }

    /// Eine gemittelte Gruppe, lineare Leistung, FFT-geshiftet.
    mutating func add(shiftedPower p: [Float]) {
        precondition(p.count == mapping.fftSize)
        frames += 1
        p.withUnsafeBufferPointer { power in
            for j in 0..<mapping.grid.count {
                let lo = Int(mapping.lo[j]), hi = Int(mapping.hi[j])
                var s: Float = 0
                for k in lo...hi { s += power[k] }
                let v = s / Float(hi - lo + 1)
                sum[j] += Double(v)
                if v > maximum[j] { maximum[j] = v }
                if let thresholdLinear, v > thresholdLinear { over[j] += 1 }
            }
            for (i, k) in mapping.floorBins.enumerated() { meanSpectrum[i] += Double(power[Int(k)]) }
        }
    }

    func result() -> OccupancyVisit {
        var visit = OccupancyVisit(grid: mapping.grid, sum: sum, maximum: maximum, frames: frames,
                                   judged: thresholdLinear == nil ? 0 : frames, over: over)
        if frames > 0, !meanSpectrum.isEmpty {
            let sorted = meanSpectrum.sorted()
            let value = sorted[min(sorted.count - 1, Int(Double(sorted.count) * Self.floorPercentile))] / Double(frames)
            visit.floorDB = Float(10 * log10(max(value, 1e-20)))
        }
        return visit
    }
}

/// Eine abgeschlossene Zeitscheibe. Werte quantisiert wie in der Datei:
/// Pegel 0 = keine Messung, sonst (dB + 128) · 2 (−127,5 … −0,5 dBFS in
/// 0,5-dB-Stufen); Belegung 0…200 = 0…100 %, 255 = unbekannt.
struct OccupancySlice: Equatable, Sendable {
    var start: Date
    var floorDB: Float
    var visits: UInt32
    var mean: [UInt8]
    var peak: [UInt8]
    var occupancy: [UInt8]

    static let unknownOccupancy: UInt8 = 255

    static func encodeDB(_ db: Float) -> UInt8 {
        guard db.isFinite else { return 1 }
        return UInt8(max(1, min(255, ((db + 128) * 2).rounded())))
    }

    static func decodeDB(_ v: UInt8) -> Float? { v == 0 ? nil : Float(v) / 2 - 128 }

    static func encodeOccupancy(_ fraction: Double?) -> UInt8 {
        guard let fraction else { return unknownOccupancy }
        return UInt8(max(0, min(200, (fraction * 200).rounded())))
    }

    static func decodeOccupancy(_ v: UInt8) -> Double? { v == unknownOccupancy ? nil : Double(v) / 200 }

    func meanDB(_ bin: Int) -> Float? { Self.decodeDB(mean[bin]) }
    func peakDB(_ bin: Int) -> Float? { Self.decodeDB(peak[bin]) }
    func occupancyFraction(_ bin: Int) -> Double? { Self.decodeOccupancy(occupancy[bin]) }
}

/// Fasst Besuche zu Zeitscheiben zusammen. Scheiben beginnen auf glatten
/// Vielfachen der Scheibenlänge (volle Minuten …).
struct OccupancySlicer {
    let binCount: Int
    let sliceSeconds: Double
    private(set) var sliceStart: Date?
    private var sum: [Double]
    private var frames: [Int32]
    private var maximum: [Float]
    private var judged: [Int32]
    private var over: [Int32]
    private var floors: [Float] = []

    init(binCount: Int, sliceSeconds: Double) {
        self.binCount = binCount
        self.sliceSeconds = max(1, sliceSeconds)
        sum = [Double](repeating: 0, count: binCount)
        frames = [Int32](repeating: 0, count: binCount)
        maximum = [Float](repeating: 0, count: binCount)
        judged = [Int32](repeating: 0, count: binCount)
        over = [Int32](repeating: 0, count: binCount)
    }

    func alignedStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / sliceSeconds).rounded(.down) * sliceSeconds)
    }

    var hasData: Bool { !floors.isEmpty }

    /// Nimmt einen Besuch auf; liefert die abgeschlossene Scheibe, wenn der
    /// Besuch schon in eine neue fällt.
    mutating func add(_ visit: OccupancyVisit, at date: Date) -> OccupancySlice? {
        let aligned = alignedStart(date)
        var closed: OccupancySlice?
        if let sliceStart, aligned > sliceStart { closed = close() }
        if sliceStart == nil { sliceStart = aligned }
        for (j, g32) in visit.grid.enumerated() {
            let g = Int(g32)
            guard g < binCount else { continue }
            sum[g] += visit.sum[j]
            frames[g] += Int32(visit.frames)
            maximum[g] = max(maximum[g], visit.maximum[j])
            judged[g] += Int32(visit.judged)
            over[g] += visit.over[j]
        }
        floors.append(visit.floorDB)
        return closed
    }

    /// Schließt die laufende Scheibe ab (auch beim Anhalten).
    mutating func close() -> OccupancySlice? {
        defer { reset() }
        guard let sliceStart, hasData else { return nil }
        var mean = [UInt8](repeating: 0, count: binCount)
        var peak = [UInt8](repeating: 0, count: binCount)
        var occ = [UInt8](repeating: OccupancySlice.unknownOccupancy, count: binCount)
        for g in 0..<binCount where frames[g] > 0 {
            mean[g] = OccupancySlice.encodeDB(Float(10 * log10(max(sum[g] / Double(frames[g]), 1e-20))))
            peak[g] = OccupancySlice.encodeDB(10 * log10(max(maximum[g], 1e-20)))
            if judged[g] > 0 { occ[g] = OccupancySlice.encodeOccupancy(Double(over[g]) / Double(judged[g])) }
        }
        let sortedFloors = floors.sorted()
        return OccupancySlice(start: sliceStart, floorDB: sortedFloors[sortedFloors.count / 2],
                              visits: UInt32(floors.count), mean: mean, peak: peak, occupancy: occ)
    }

    private mutating func reset() {
        sliceStart = nil
        for g in 0..<binCount { sum[g] = 0; frames[g] = 0; maximum[g] = 0; judged[g] = 0; over[g] = 0 }
        floors = []
    }
}

/// Zusammenfassung über viele Scheiben und die Liste der aktivsten Frequenzen.
enum OccupancyAnalysis {
    struct Summary: Sendable {
        /// Mittlere Belegung je Bin (0…1), `nil` ohne Urteil.
        var occupancy: [Double?]
        /// Höchste Spitze über dem Boden der jeweiligen Scheibe (dB).
        var peakAboveFloor: [Float?]
        /// Mittlerer Pegel über alle Scheiben (dB).
        var meanDB: [Float?]
    }

    static func summary(_ slices: [OccupancySlice], binCount: Int) -> Summary {
        var occSum = [Double](repeating: 0, count: binCount)
        var occN = [Int](repeating: 0, count: binCount)
        var peak = [Float?](repeating: nil, count: binCount)
        var power = [Double](repeating: 0, count: binCount)
        var powerN = [Int](repeating: 0, count: binCount)
        for slice in slices where slice.mean.count == binCount {
            for g in 0..<binCount {
                if let o = slice.occupancyFraction(g) { occSum[g] += o; occN[g] += 1 }
                if let p = slice.peakDB(g) {
                    let above = p - slice.floorDB
                    peak[g] = max(peak[g] ?? -.infinity, above)
                }
                if let m = slice.meanDB(g) { power[g] += pow(10, Double(m) / 10); powerN[g] += 1 }
            }
        }
        return Summary(occupancy: (0..<binCount).map { occN[$0] > 0 ? occSum[$0] / Double(occN[$0]) : nil },
                       peakAboveFloor: peak,
                       meanDB: (0..<binCount).map { powerN[$0] > 0 ? Float(10 * log10(power[$0] / Double(powerN[$0]))) : nil })
    }

    struct Episode: Hashable, Sendable {
        var start: Date
        var end: Date
    }

    struct ActiveFrequency: Identifiable, Hashable, Sendable {
        var mhz: Double
        var bin: Int
        var occupancy: Double
        var peakAboveFloorDB: Float
        /// Zeiträume mit Aktivität, neueste zuerst (höchstens fünf).
        var episodes: [Episode]
        var activeSlices: Int
        var id: Int { bin }
    }

    /// Lokale Maxima der Belegung, Nachbarn innerhalb `mergeBins`
    /// zusammengefasst, absteigend nach Belegung.
    static func mostActive(_ summary: Summary, slices: [OccupancySlice], plan: OccupancyPlan,
                           minOccupancy: Double = 0.002, mergeBins: Int = 2, limit: Int = 25,
                           episodeThreshold: Double = 0.02) -> [ActiveFrequency] {
        let candidates = summary.occupancy.enumerated()
            .compactMap { i, o in o.flatMap { $0 >= minOccupancy ? (i, $0) : nil } }
            .sorted { $0.1 > $1.1 }
        var taken: [Int] = []
        var result: [ActiveFrequency] = []
        for (bin, occ) in candidates {
            guard !taken.contains(where: { abs($0 - bin) <= mergeBins }) else { continue }
            taken.append(bin)
            let range = max(0, bin - mergeBins)...min(plan.binCount - 1, bin + mergeBins)
            var episodes: [Episode] = []
            var active = 0
            let sliceLength = slices.count > 1 ? slices[1].start.timeIntervalSince(slices[0].start) : 60
            for slice in slices where slice.occupancy.count == plan.binCount {
                let hot = range.contains { (slice.occupancyFraction($0) ?? 0) >= episodeThreshold }
                guard hot else { continue }
                active += 1
                let end = slice.start.addingTimeInterval(max(1, sliceLength))
                if let last = episodes.last, slice.start.timeIntervalSince(last.end) <= sliceLength * 1.5 {
                    episodes[episodes.count - 1].end = end
                } else {
                    episodes.append(Episode(start: slice.start, end: end))
                }
            }
            result.append(ActiveFrequency(mhz: plan.binCenterMHz(bin), bin: bin, occupancy: occ,
                                          peakAboveFloorDB: summary.peakAboveFloor[bin] ?? 0,
                                          episodes: Array(episodes.suffix(5).reversed()), activeSlices: active))
            if result.count >= limit { break }
        }
        return result
    }
}

/// Ganzzahl zur Anzeige: NaN wird 0, alles andere auf ±10⁹ geklemmt – `Int(_:)`
/// bricht sonst bei NaN/∞ ab (Review Y3).
func displayInt(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(max(-1e9, min(1e9, value)))
}

func displayInt(_ value: Float) -> Int { displayInt(Double(value)) }

/// Zeilen des Wärmebilds: eine je Scheibenlänge, von alt nach neu. Lücken
/// (Pausen) bleiben als leere Zeilen sichtbar; lange Lücken werden auf drei
/// Zeilen gekürzt, damit eine Woche Pause das Bild nicht sprengt.
struct OccupancyTimeline: Sendable {
    /// Scheibenindex je Zeile, `nil` = keine Messung.
    private(set) var rows: [Int?] = []
    /// Beginn je Zeile.
    private(set) var dates: [Date] = []

    init(slices: [OccupancySlice], sliceSeconds: Double, maxGapRows: Int = 30) {
        // NaN/∞ aus einer kaputten Datei dürfen `Int(_:)` nicht erreichen (Review Y3).
        let step = sliceSeconds.isFinite ? max(1, sliceSeconds) : 60
        for (i, slice) in slices.enumerated() {
            if i > 0 {
                let previous = slices[i - 1]
                let ratio = (slice.start.timeIntervalSince(previous.start) / step).rounded()
                // Erst klemmen, dann wandeln: riesige Sprünge zählen als lange Lücke.
                let gap = ratio.isFinite ? Int(max(-1, min(ratio, Double(maxGapRows) + 2))) - 1 : 0
                let shown = gap > maxGapRows ? 3 : max(0, gap)
                for k in 0..<shown {
                    rows.append(nil)
                    dates.append(previous.start.addingTimeInterval(Double(k + 1) * step))
                }
            }
            rows.append(i)
            dates.append(slice.start)
        }
    }

    var count: Int { rows.count }
}

/// FFT, Gruppenbildung und Besuchsverwaltung auf dem Empfangsfaden.
final class OccupancyCollector: @unchecked Sendable {
    static let framesPerGroup = 4

    let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let lock = NSLock()
    private var accumulator: OccupancyVisitAccumulator?
    private var group: [Float]
    private var groupCount = 0

    init(fftSize: Int) {
        self.fftSize = fftSize
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        window = w
        group = [Float](repeating: 0, count: fftSize)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Neuer Besuch: ab jetzt zählen eintreffende Blöcke.
    func begin(mapping: OccupancyMapping, thresholdLinear: Float?) {
        lock.withLock {
            accumulator = OccupancyVisitAccumulator(mapping: mapping, thresholdLinear: thresholdLinear)
            groupCount = 0
            vDSP_vclr(&group, 1, vDSP_Length(fftSize))
        }
    }

    /// Blöcke verwerfen (während des Umstimmens).
    func idle() { lock.withLock { accumulator = nil } }

    /// Beendet den Besuch und liefert ihn.
    func finish() -> OccupancyVisit? {
        lock.withLock {
            defer { accumulator = nil }
            guard let accumulator, accumulator.frames > 0 else { return nil }
            return accumulator.result()
        }
    }

    func process(_ iq: Data) {
        guard lock.withLock({ accumulator != nil }) else { return }
        let n = fftSize
        let frames = iq.count / (2 * n)
        guard frames > 0 else { return }
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        var power = [Float](repeating: 0, count: n)
        let scale = 1 / Float(128 * 128) / Float(n * n) * 4
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: Int8.self).baseAddress!
            for f in 0..<frames {
                let p = base + f * 2 * n
                vDSP_vflt8(p, 2, &re, 1, vDSP_Length(n))
                vDSP_vflt8(p + 1, 2, &im, 1, vDSP_Length(n))
                vDSP_vmul(re, 1, window, 1, &re, 1, vDSP_Length(n))
                vDSP_vmul(im, 1, window, 1, &im, 1, vDSP_Length(n))
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n))
                    }
                }
                lock.withLock {
                    guard accumulator != nil else { return }
                    vDSP_vadd(group, 1, power, 1, &group, 1, vDSP_Length(n))
                    groupCount += 1
                    if groupCount == Self.framesPerGroup {
                        var s = scale / Float(Self.framesPerGroup)
                        vDSP_vsmul(group, 1, &s, &group, 1, vDSP_Length(n))
                        let half = n / 2
                        let shifted = Array(group[half...] + group[..<half])
                        accumulator?.add(shiftedPower: shifted)
                        vDSP_vclr(&group, 1, vDSP_Length(n))
                        groupCount = 0
                    }
                }
            }
        }
    }
}
