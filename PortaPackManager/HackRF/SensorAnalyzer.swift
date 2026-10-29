import Foundation

/// Ergebnis der Pulsanalyse eines Pakets – wie `rtl_433 -A`.
struct SensorPulseAnalysis: Sendable, Equatable {
    /// Häufungen ähnlicher Längen (±20 %), nach Mittelwert sortiert.
    struct Bin: Sendable, Equatable {
        var mean: Int
        var min: Int
        var max: Int
        var count: Int
    }

    enum Coding: String, Sendable {
        case single = "Einzelner Puls (FSK oder Störung)"
        case unmodulated = "Unmoduliert (vermutlich Präambel)"
        case ppm = "Pulspositionsmodulation (PPM)"
        case pwmFixedGap = "Pulsbreitenmodulation, feste Pause (PWM)"
        case pwmFixedPeriod = "Pulsbreitenmodulation, feste Periode (PWM)"
        case manchester = "Manchester"
        case pwmMultiPacket = "Pulsbreitenmodulation, mehrere Pakete (PWM)"
        case pcm = "NRZ-Pulscode (PCM)"
        case pwmSync = "Pulsbreitenmodulation mit Sync-Puls (PWM)"
        case unknown = "Unbekannt"

        /// Anzeigename (übersetzbar); `rawValue` bleibt als stabile Kennung.
        var title: String {
            switch self {
            case .single: String(localized: "Einzelner Puls (FSK oder Störung)")
            case .unmodulated: String(localized: "Unmoduliert (vermutlich Präambel)")
            case .ppm: String(localized: "Pulspositionsmodulation (PPM)")
            case .pwmFixedGap: String(localized: "Pulsbreitenmodulation, feste Pause (PWM)")
            case .pwmFixedPeriod: String(localized: "Pulsbreitenmodulation, feste Periode (PWM)")
            case .manchester: String(localized: "Manchester")
            case .pwmMultiPacket: String(localized: "Pulsbreitenmodulation, mehrere Pakete (PWM)")
            case .pcm: String(localized: "NRZ-Pulscode (PCM)")
            case .pwmSync: String(localized: "Pulsbreitenmodulation mit Sync-Puls (PWM)")
            case .unknown: String(localized: "Unbekannt")
            }
        }
    }

    var pulses: [Bin]
    var gaps: [Bin]
    var periods: [Bin]
    var coding: Coding
    /// Abgeleitete Zeiten in µs (0 = nicht verwendet).
    var shortWidth = 0
    var longWidth = 0
    var syncWidth = 0
    /// Bitzeilen mit den abgeleiteten Zeiten, als `{Bits}hex`.
    var rows: [String] = []

    /// Kurzbeschreibung für Listen.
    var summary: String {
        var parts = [coding.title]
        if shortWidth > 0 { parts.append(String(localized: "kurz \(shortWidth) µs")) }
        if longWidth > 0 && longWidth != shortWidth { parts.append(String(localized: "lang \(longWidth) µs")) }
        if syncWidth > 0 { parts.append(String(localized: "Sync \(syncWidth) µs")) }
        return parts.joined(separator: " · ")
    }
}

enum SensorAnalyzer {
    static let tolerance = 0.2

    static func histogram(_ values: [Int]) -> [SensorPulseAnalysis.Bin] {
        var bins: [SensorPulseAnalysis.Bin] = []
        var sums: [Int] = []
        func matches(_ a: Int, _ b: Int) -> Bool { Double(abs(a - b)) < tolerance * Double(max(a, b)) }
        for value in values {
            if let index = bins.indices.first(where: { matches(value, bins[$0].mean) }) {
                bins[index].count += 1
                sums[index] += value
                bins[index].mean = sums[index] / bins[index].count
                bins[index].min = min(bins[index].min, value)
                bins[index].max = max(bins[index].max, value)
            } else {
                bins.append(.init(mean: value, min: value, max: value, count: 1))
                sums.append(value)
            }
        }
        // überlappende Bins verschmelzen
        var n = 0
        while n < bins.count {
            var m = n + 1
            while m < bins.count {
                if matches(bins[n].mean, bins[m].mean) {
                    sums[n] += sums[m]
                    bins[n].count += bins[m].count
                    bins[n].mean = sums[n] / bins[n].count
                    bins[n].min = min(bins[n].min, bins[m].min)
                    bins[n].max = max(bins[n].max, bins[m].max)
                    bins.remove(at: m)
                    sums.remove(at: m)
                } else {
                    m += 1
                }
            }
            n += 1
        }
        return bins.sorted { $0.mean < $1.mean }
    }

    static func analyze(_ train: SensorPulseTrain) -> SensorPulseAnalysis {
        let count = train.count
        var pulses = histogram(train.pulses)
        let gaps = histogram(Array(train.gaps.prefix(max(0, count - 1))))
        let periods = histogram((0..<max(0, count - 1)).map { train.pulses[$0] + train.gaps[$0] })
        if pulses.first?.mean == 0 { pulses.removeFirst() }
        var result = SensorPulseAnalysis(pulses: pulses, gaps: gaps, periods: periods, coding: .unknown)
        guard count > 1 else {
            result.coding = .single
            return result
        }
        let reset = (gaps.last?.max ?? 0) + 1
        var buffers: [SensorBitBuffer] = []

        if pulses.count == 1 && gaps.count == 1 {
            result.coding = .unmodulated
        } else if pulses.count == 1 && gaps.count > 1 {
            result.coding = .ppm
            result.shortWidth = gaps[0].mean
            result.longWidth = gaps[1].mean
            buffers = SensorSlicer.ppm(train, short: gaps[0].mean, long: gaps[1].mean,
                                       gapLimit: gaps[1].max + 1, reset: reset)
        } else if pulses.count == 2 && (gaps.count == 1 || (gaps.count == 2 && periods.count == 1) || gaps.count >= 3) {
            result.coding = gaps.count == 1 ? .pwmFixedGap : gaps.count == 2 ? .pwmFixedPeriod : .pwmMultiPacket
            result.shortWidth = pulses[0].mean
            result.longWidth = pulses[1].mean
            let tolerance = Int(Double(pulses[1].mean - pulses[0].mean) * 0.4)
            buffers = SensorSlicer.pwm(train, short: pulses[0].mean, long: pulses[1].mean,
                                       gapLimit: gaps.count >= 3 ? gaps[1].max + 1 : 0,
                                       reset: reset, tolerance: max(1, tolerance))
        } else if pulses.count == 2 && gaps.count == 2 && periods.count == 3 {
            result.coding = .manchester
            result.shortWidth = min(pulses[0].mean, pulses[1].mean)
            buffers = [manchester(train, halfBit: result.shortWidth, reset: reset)]
        } else if pulses.count >= 3 && gaps.count >= 3 && isNRZ(pulses: pulses, gaps: gaps) {
            result.coding = .pcm
            result.shortWidth = pulses[0].mean
            result.longWidth = pulses[0].mean
            buffers = SensorSlicer.pcm(train, bitWidth: pulses[0].mean, reset: pulses[0].mean * 1024)
        } else if pulses.count == 3 {
            result.coding = .pwmSync
            // seltenster Puls ist vermutlich der Sync
            let byCount = pulses.sorted { $0.count < $1.count }
            let a = byCount[1].mean, b = byCount[2].mean
            result.shortWidth = min(a, b)
            result.longWidth = max(a, b)
            result.syncWidth = byCount[0].mean
            buffers = SensorSlicer.pwm(train, short: result.shortWidth, long: result.longWidth,
                                       sync: result.syncWidth, reset: reset)
        }
        result.rows = buffers.flatMap(\.rows).filter { $0.count > 0 }.prefix(12).map(\.hex)
        return result
    }

    /// Längen sind Vielfache der kürzesten (±1/8): typisch für NRZ.
    private static func isNRZ(pulses: [SensorPulseAnalysis.Bin], gaps: [SensorPulseAnalysis.Bin]) -> Bool {
        let base = pulses[0].mean
        guard base > 0 else { return false }
        func near(_ value: Int, _ factor: Int) -> Bool { abs(value - factor * base) <= base / 8 }
        return near(pulses[1].mean, 2) && near(pulses[2].mean, 3)
            && near(gaps[0].mean, 1) && near(gaps[1].mean, 2) && near(gaps[2].mean, 3)
    }

    /// Manchester mit implizitem Null-Bit am Anfang: Pegel in Halbbits
    /// zerlegen und paarweise auswerten (Wechsel 0→1 = 1, 1→0 = 0).
    static func manchester(_ train: SensorPulseTrain, halfBit: Int, reset: Int) -> SensorBitBuffer {
        var levels: [UInt8] = [0]
        let half = Double(halfBit)
        for n in 0..<train.count {
            for _ in 0..<max(1, Int((Double(train.pulses[n]) / half).rounded())) { levels.append(1) }
            if train.gaps[n] > reset || n == train.count - 1 { break }
            for _ in 0..<max(1, Int((Double(train.gaps[n]) / half).rounded())) { levels.append(0) }
        }
        var bits = SensorBitBuffer()
        var index = 0
        while index + 1 < levels.count {
            if levels[index] == levels[index + 1] {
                bits.addRow()
                index += 1
                continue
            }
            bits.add(levels[index + 1])
            index += 2
        }
        return bits
    }
}
