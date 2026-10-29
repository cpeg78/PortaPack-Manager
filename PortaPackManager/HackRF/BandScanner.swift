import Accelerate
import Foundation

/// Ein Frequenzband mit Kanalraster für den Suchlauf.
struct ScanBand: Identifiable, Hashable, Sendable {
    /// Fester (deutscher) Name – wird gespeichert, nicht übersetzen. Anzeige: `title`.
    let name: String
    let mode: RadioMode
    let startMHz: Double
    let endMHz: Double
    /// Kanalraster in kHz (Abstand der Kanalmitten).
    let rasterKHz: Double
    /// Bandbreite, über die je Kanal die Leistung gemessen wird, in kHz.
    let channelWidthKHz: Double
    /// Verweildauer je 20-MHz-Fenster. Lang für Sprechfunk (Funksprüche sind
    /// kurz), kurz für Rundfunk.
    let dwellSeconds: Double
    var firstChannelMHz: Double? = nil

    var id: String { name }

    /// Kanalmitten, per Index berechnet (kein Aufsummieren von Rundungsfehlern).
    var channels: [Double] {
        let first = firstChannelMHz ?? startMHz
        let step = rasterKHz / 1000
        let count = Int(((endMHz - first) / step + 1e-6).rounded(.down)) + 1
        return (0..<max(count, 0)).map { (((first + Double($0) * step) * 100_000).rounded()) / 100_000 }
    }
}

extension ScanBand {
    /// Angezeigter, übersetzbarer Name.
    var title: String {
        switch name {
        case "UKW-Rundfunk": String(localized: "UKW-Rundfunk")
        case "Flugfunk": String(localized: "Flugfunk")
        case "2-m-Amateurfunk": String(localized: "2-m-Amateurfunk")
        case "70-cm-Amateurfunk": String(localized: "70-cm-Amateurfunk")
        case "CB-Funk": String(localized: "CB-Funk")
        case "Seefunk UKW": String(localized: "Seefunk UKW")
        case "Wettersatelliten 137 MHz": String(localized: "Wettersatelliten 137 MHz")
        case "Kurzwelle 49 m": String(localized: "Kurzwelle 49 m")
        case "Kurzwelle 31 m": String(localized: "Kurzwelle 31 m")
        default: name
        }
    }
}

enum ScanBands {
    static let fm = ScanBand(name: "UKW-Rundfunk", mode: .wfm, startMHz: 87.5, endMHz: 108.0,
                             rasterKHz: 100, channelWidthKHz: 120, dwellSeconds: 0.4)
    static let all: [ScanBand] = [
        fm,
        ScanBand(name: "Flugfunk", mode: .am, startMHz: 118.0, endMHz: 136.99167,
                 rasterKHz: 25.0 / 3, channelWidthKHz: 6, dwellSeconds: 3),
        ScanBand(name: "PMR446", mode: .nfm, startMHz: 446.00625, endMHz: 446.19375,
                 rasterKHz: 12.5, channelWidthKHz: 8, dwellSeconds: 4),
        ScanBand(name: "Freenet", mode: .nfm, startMHz: 149.025, endMHz: 149.1125,
                 rasterKHz: 12.5, channelWidthKHz: 8, dwellSeconds: 4),
        ScanBand(name: "2-m-Amateurfunk", mode: .nfm, startMHz: 144.0, endMHz: 146.0,
                 rasterKHz: 12.5, channelWidthKHz: 8, dwellSeconds: 3),
        ScanBand(name: "70-cm-Amateurfunk", mode: .nfm, startMHz: 430.0, endMHz: 440.0,
                 rasterKHz: 12.5, channelWidthKHz: 8, dwellSeconds: 3),
        ScanBand(name: "CB-Funk", mode: .am, startMHz: 26.965, endMHz: 27.405,
                 rasterKHz: 10, channelWidthKHz: 6, dwellSeconds: 3),
        ScanBand(name: "Seefunk UKW", mode: .nfm, startMHz: 156.0, endMHz: 162.025,
                 rasterKHz: 25, channelWidthKHz: 12, dwellSeconds: 3),
        ScanBand(name: "Wettersatelliten 137 MHz", mode: .nfm, startMHz: 137.0, endMHz: 138.0,
                 rasterKHz: 25, channelWidthKHz: 30, dwellSeconds: 2),
        ScanBand(name: "Kurzwelle 49 m", mode: .am, startMHz: 5.9, endMHz: 6.2,
                 rasterKHz: 5, channelWidthKHz: 4, dwellSeconds: 1),
        ScanBand(name: "Kurzwelle 31 m", mode: .am, startMHz: 9.4, endMHz: 9.9,
                 rasterKHz: 5, channelWidthKHz: 4, dwellSeconds: 1),
        ScanBand(name: "433 MHz ISM", mode: .nfm, startMHz: 433.05, endMHz: 434.79,
                 rasterKHz: 25, channelWidthKHz: 20, dwellSeconds: 3),
    ]
}

/// Ein beim Suchlauf gefundener Kanal.
struct FoundStation: Identifiable, Hashable, Sendable {
    let mhz: Double
    let levelDB: Float
    var id: Double { mhz }

    /// Glatte Vielfache von 1 MHz sind beim HackRF oft eigene Störlinien
    /// (Oberwellen der Takte) und keine Sender.
    var possiblySpur: Bool {
        abs(mhz - mhz.rounded()) < 0.0005
    }
}

/// Spektraler Suchlauf: misst ein Band in 20-MHz-Fenstern per FFT mit
/// Spitzenwert-Halten und liefert Kanäle deutlich über dem Rauschboden.
enum BandScanner {
    static let sampleRate: UInt32 = 20_000_000
    static let fftSize = 8192
    /// Nutzbarer Bereich je Fenster (Filterflanken außen, Gleichspannungsspitze innen).
    static let usableHalfSpanMHz = 7.0
    static let dcHoleMHz = 0.06

    /// Mittenfrequenzen der Fenster so, dass jede Kanalfrequenz in mindestens
    /// einem Fenster außerhalb der DC-Lücke liegt.
    static func windowCenters(for band: ScanBand) -> [Double] {
        var centers = [band.startMHz + 3]
        func covered(_ f: Double) -> Bool {
            centers.contains { abs(f - $0) <= usableHalfSpanMHz && abs(f - $0) >= dcHoleMHz }
        }
        // Fenster ergänzen, bis jeder Kanal außerhalb einer DC-Lücke gemessen wird.
        while let gap = band.channels.first(where: { !covered($0) }) {
            centers.append(gap + 3)
        }
        return centers.sorted()
    }

    /// Wertet ein gemitteltes bzw. spitzengehaltenes Leistungsspektrum (linear,
    /// FFT-geshiftet) für die Kanäle eines Fensters aus.
    static func channelLevels(spectrum: [Float], centerMHz: Double, band: ScanBand) -> [Double: Float] {
        let binMHz = Double(sampleRate) / 1e6 / Double(spectrum.count)
        let halfBins = max(1, Int((band.channelWidthKHz / 1000 / 2) / binMHz))
        var result: [Double: Float] = [:]
        for channel in band.channels {
            let delta = channel - centerMHz
            guard abs(delta) <= usableHalfSpanMHz, abs(delta) >= dcHoleMHz else { continue }
            let bin = Int((delta / binMHz).rounded()) + spectrum.count / 2
            let lo = max(0, bin - halfBins), hi = min(spectrum.count - 1, bin + halfBins)
            guard lo <= hi else { continue }
            var mean: Float = 0
            spectrum[lo...hi].withContiguousStorageIfAvailable { vDSP_meanv($0.baseAddress!, 1, &mean, vDSP_Length($0.count)) }
            result[channel] = 10 * log10(max(mean, 1e-20))
        }
        return result
    }

    /// Wählt Kanäle über Rauschboden + Schwelle; benachbarte Treffer (gleiches
    /// Signal über mehrere Raster) werden zum stärksten zusammengefasst.
    static func pickStations(_ levels: [Double: Float], band: ScanBand, thresholdDB: Float = 8) -> [FoundStation] {
        guard !levels.isEmpty else { return [] }
        let sortedValues = levels.values.sorted()
        let floor = sortedValues[sortedValues.count / 2]
        let channels = levels.keys.sorted()
        var found: [FoundStation] = []
        // Ein Signal belegt im feinen Raster mehrere Nachbarkanäle.
        let merge = max(band.channelWidthKHz * 2, band.rasterKHz * 2.5) / 1000
        for channel in channels {
            let level = levels[channel]! - floor
            guard level >= thresholdDB else { continue }
            if let last = found.last, channel - last.mhz <= merge {
                if level > last.levelDB { found[found.count - 1] = FoundStation(mhz: channel, levelDB: level) }
            } else {
                found.append(FoundStation(mhz: channel, levelDB: level))
            }
        }
        return found
    }
}

/// Sammelt während eines Fensters FFTs: je 4 gemittelt, darüber Spitzenwert halten.
final class ScanAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let size = BandScanner.fftSize
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var group: [Float]
    private var groupCount = 0
    private var maxHold: [Float]

    init() {
        log2n = vDSP_Length(log2(Double(BandScanner.fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: BandScanner.fftSize)
        vDSP_hann_window(&w, vDSP_Length(BandScanner.fftSize), Int32(vDSP_HANN_NORM))
        window = w
        group = [Float](repeating: 0, count: BandScanner.fftSize)
        maxHold = [Float](repeating: 0, count: BandScanner.fftSize)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() {
        lock.withLock {
            group = [Float](repeating: 0, count: size)
            groupCount = 0
            maxHold = [Float](repeating: 0, count: size)
        }
    }

    func process(_ iq: Data) {
        let frames = iq.count / (2 * size)
        guard frames > 0 else { return }
        var re = [Float](repeating: 0, count: size)
        var im = [Float](repeating: 0, count: size)
        var power = [Float](repeating: 0, count: size)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for f in 0..<min(frames, 8) {
                let base = f * 2 * size
                for n in 0..<size {
                    re[n] = Float(p[base + 2 * n]) * window[n]
                    im[n] = Float(p[base + 2 * n + 1]) * window[n]
                }
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size))
                    }
                }
                lock.withLock {
                    vDSP_vadd(group, 1, power, 1, &group, 1, vDSP_Length(size))
                    groupCount += 1
                    if groupCount == 4 {
                        vDSP_vmax(maxHold, 1, group, 1, &maxHold, 1, vDSP_Length(size))
                        group = [Float](repeating: 0, count: size)
                        groupCount = 0
                    }
                }
            }
        }
    }

    /// Spitzenwert-Spektrum, FFT-geshiftet (negative Frequenzen links).
    func shiftedMaxHold() -> [Float] {
        let hold = lock.withLock { maxHold }
        let half = size / 2
        return Array(hold[half...] + hold[..<half])
    }
}
