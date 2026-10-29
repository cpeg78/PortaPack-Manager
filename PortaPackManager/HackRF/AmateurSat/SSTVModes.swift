import Foundation

/// SSTV-Betriebsarten mit VIS-Code. Zeiten nach der Zusammenstellung von
/// JL Barber („Proposal for SSTV Mode Specifications“) bzw. slowrx/QSSTV.
/// Die ISS sendet bei ARISS-Aktionen meist PD120, manchmal PD180/PD90.
enum SSTVMode: Int, CaseIterable, Identifiable, Sendable, Codable {
    case robot36 = 8
    case martinM1 = 44
    case martinM2 = 40
    case scottieS1 = 60
    case scottieS2 = 56
    case pd50 = 93
    case pd90 = 99
    case pd120 = 95
    case pd180 = 96

    enum Family: Sendable { case martin, scottie, robot36, pd }

    /// Bildkanal einer Abtaststrecke.
    enum Channel: Sendable, Hashable {
        case r, g, b
        /// Helligkeit; bei PD die erste der beiden Zeilen.
        case y
        /// Helligkeit der zweiten Zeile (nur PD).
        case y2
        /// Farbdifferenz R−Y (V) bzw. B−Y (U).
        case cr, cb
    }

    /// Ein Abschnitt einer übertragenen Zeile.
    enum Segment: Sendable {
        case tone(Double, Double)                 // Frequenz (Hz), Dauer (s)
        case scan(Channel, Double)                // Kanal, Dauer (s) über die ganze Breite
        var duration: Double {
            switch self {
            case .tone(_, let d), .scan(_, let d): d
            }
        }
    }

    var id: Int { rawValue }
    /// VIS-Code (7 Bit).
    var vis: Int { rawValue }

    var title: String {
        switch self {
        case .robot36: "Robot 36"
        case .martinM1: "Martin M1"
        case .martinM2: "Martin M2"
        case .scottieS1: "Scottie S1"
        case .scottieS2: "Scottie S2"
        case .pd50: "PD50"
        case .pd90: "PD90"
        case .pd120: "PD120"
        case .pd180: "PD180"
        }
    }

    var family: Family {
        switch self {
        case .robot36: .robot36
        case .martinM1, .martinM2: .martin
        case .scottieS1, .scottieS2: .scottie
        case .pd50, .pd90, .pd120, .pd180: .pd
        }
    }

    var width: Int {
        switch self {
        case .pd120, .pd180: 640
        default: 320
        }
    }

    var height: Int {
        switch self {
        case .robot36: 240
        case .pd120, .pd180: 496
        default: 256
        }
    }

    /// Übertragene Zeilen – PD schickt zwei Bildzeilen in einer.
    var transmittedLines: Int { family == .pd ? height / 2 : height }

    /// Dauer eines Bildpunkts (s) in den Farb-/Helligkeitsstrecken.
    private var pixelTime: Double {
        switch self {
        case .martinM1: 0.4576e-3
        case .martinM2: 0.2288e-3
        case .scottieS1: 0.4320e-3
        case .scottieS2: 0.2752e-3
        case .pd50, .pd180: 0.286e-3
        case .pd90: 0.532e-3
        case .pd120: 0.19e-3
        case .robot36: 88e-3 / 320
        }
    }

    /// Abschnitte der übertragenen Zeile `line` (bei Robot 36 wechselt der
    /// Trenner zwischen geraden und ungeraden Zeilen).
    func segments(line: Int) -> [Segment] {
        let scan = Double(width) * pixelTime
        switch family {
        case .martin:
            let sep = 0.572e-3
            return [.tone(1200, 4.862e-3), .tone(1500, sep), .scan(.g, scan), .tone(1500, sep),
                    .scan(.b, scan), .tone(1500, sep), .scan(.r, scan), .tone(1500, sep)]
        case .scottie:
            let sep = 1.5e-3
            return [.tone(1500, sep), .scan(.g, scan), .tone(1500, sep), .scan(.b, scan),
                    .tone(1200, 9e-3), .tone(1500, sep), .scan(.r, scan)]
        case .robot36:
            let even = line % 2 == 0
            return [.tone(1200, 9e-3), .tone(1500, 3e-3), .scan(.y, 88e-3),
                    .tone(even ? 1500 : 2300, 4.5e-3), .tone(1900, 1.5e-3), .scan(even ? .cr : .cb, 44e-3)]
        case .pd:
            return [.tone(1200, 20e-3), .tone(1500, 2.08e-3), .scan(.y, scan), .scan(.cr, scan),
                    .scan(.cb, scan), .scan(.y2, scan)]
        }
    }

    /// Dauer einer übertragenen Zeile (s).
    var lineDuration: Double { segments(line: 0).reduce(0) { $0 + $1.duration } }

    /// Abstand vom Zeilenbeginn bis zum Beginn des Synchronimpulses (s).
    var syncOffset: Double {
        var t = 0.0
        for segment in segments(line: 0) {
            if case .tone(let f, _) = segment, f == 1200 { return t }
            t += segment.duration
        }
        return 0
    }

    var syncDuration: Double {
        for segment in segments(line: 0) {
            if case .tone(let f, let d) = segment, f == 1200 { return d }
        }
        return 0
    }

    /// Scottie beginnt nach dem VIS mit einem zusätzlichen Synchronimpuls.
    var leadIn: [Segment] { family == .scottie ? [.tone(1200, 9e-3)] : [] }

    /// Gesamtdauer der Übertragung ohne VIS (s).
    var duration: Double {
        leadIn.reduce(0) { $0 + $1.duration } + Double(transmittedLines) * lineDuration
    }

    static func from(vis: Int) -> SSTVMode? { SSTVMode(rawValue: vis) }

    /// Frequenz → Helligkeit 0…255 (1500 Hz schwarz, 2300 Hz weiß).
    /// NaN (z. B. aus einer gestörten Frequenzschätzung) zählt als Schwarz –
    /// `min`/`max` reichen NaN sonst durch, `UInt8(_:)` bricht dann ab.
    static func value(frequency: Double) -> Double {
        guard frequency.isFinite else { return 0 }
        return min(max((frequency - 1500) / 800 * 255, 0), 255)
    }

    static func frequency(value: Double) -> Double { 1500 + value / 255 * 800 }

    /// YCbCr (JFIF, voller Bereich) → RGB, wie slowrx.
    static func rgb(y: Double, cr: Double, cb: Double) -> (UInt8, UInt8, UInt8) {
        func clamp(_ v: Double) -> UInt8 { v.isFinite ? UInt8(min(max(v.rounded(), 0), 255)) : 0 }
        return (clamp(y + 1.402 * (cr - 128)),
                clamp(y - 0.344136 * (cb - 128) - 0.714136 * (cr - 128)),
                clamp(y + 1.772 * (cb - 128)))
    }

    static func ycc(r: Double, g: Double, b: Double) -> (y: Double, cr: Double, cb: Double) {
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        return (y, 128 + 0.5 * r - 0.418688 * g - 0.081312 * b, 128 - 0.168736 * r - 0.331264 * g + 0.5 * b)
    }
}

/// Ein (ggf. noch wachsendes) SSTV-Bild, RGBA mit 8 Bit je Kanal.
struct SSTVImage: Sendable, Identifiable {
    let id = UUID()
    let mode: SSTVMode
    let started: Date
    var rgba: [UInt8]
    /// Bildzeilen, die schon dekodiert sind (von oben).
    var rows = 0
    var complete = false
    /// Gemessene Abweichung des Sendertakts (ppm) aus der Schräglaufkorrektur.
    var clockPPM = 0.0

    var width: Int { mode.width }
    var height: Int { mode.height }

    init(mode: SSTVMode, started: Date = Date()) {
        self.mode = mode
        self.started = started
        rgba = [UInt8](repeating: 0, count: mode.width * mode.height * 4)
        for k in stride(from: 3, to: rgba.count, by: 4) { rgba[k] = 255 }
    }

    mutating func set(row: Int, x: Int, _ c: (UInt8, UInt8, UInt8)) {
        let i = (row * width + x) * 4
        rgba[i] = c.0; rgba[i + 1] = c.1; rgba[i + 2] = c.2
    }

    func pixel(row: Int, x: Int) -> (UInt8, UInt8, UInt8) {
        let i = (row * width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2])
    }
}
