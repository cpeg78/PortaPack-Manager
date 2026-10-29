import CoreGraphics
import Foundation
import Observation

/// Steuert den Empfang im HackRF-Modus und hält Spektrum und Wasserfall.
@MainActor
@Observable
final class SpectrumModel {
    var centerMHz: Double = 100.0
    var sampleRateMHz: Double = 10
    var lnaGain = GainProfile.preset(.spectrum).lna
    var vgaGain = GainProfile.preset(.spectrum).vga
    var amplifier = GainProfile.preset(.spectrum).amplifier
    var antennaPower = false
    var minDB: Double = -100
    var maxDB: Double = -20
    /// Skala folgt Rauschboden (Median) und Spitze – wie im Fernzugriff.
    var autoScale = UserDefaults.standard.object(forKey: "spectrumAutoScale") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoScale, forKey: "spectrumAutoScale") }
    }
    var averaging: Double = 0.5

    private(set) var running = false
    private(set) var spectrum: [Float] = []
    private(set) var waterfall: CGImage?
    private(set) var error: String?
    private(set) var throughput: Double = 0
    /// Max-Hold: höchster Pegel je Bin seit dem Einschalten bzw. Zurücksetzen.
    var maxHoldEnabled = false {
        didSet { if !maxHoldEnabled { maxHold = [] } }
    }
    private(set) var maxHold: [Float] = []
    /// Bis zu vier Marker (⌥-Klick), Frequenz fest – der Pegel kommt aus dem Spektrum.
    private(set) var markers: [SpectrumMarker] = []

    private let analyzer = SpectrumAnalyzer(fftSize: 1024)
    private var rows: [[Float]] = []
    private let maxRows = 240
    private var updateTask: Task<Void, Never>?
    private let byteCounter = ByteCounter()

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            try apply(to: device)
            let analyzer = analyzer
            let counter = byteCounter
            try device.startReceiving(owner: self) { block in
                counter.add(block.count)
                analyzer.process(block)
            }
            running = true
            error = nil
            updateTask = Task { [weak self] in
                var lastCount = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(66))
                    guard let self else { return }
                    if let fresh = self.analyzer.takeSpectrum() {
                        self.ingest(fresh)
                    }
                    let now = Date()
                    if now.timeIntervalSince(lastCount) >= 1 {
                        self.throughput = Double(self.byteCounter.take()) / now.timeIntervalSince(lastCount) / 2
                        lastCount = now
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop(on device: HackRFDevice?) {
        updateTask?.cancel()
        updateTask = nil
        device?.stopReceiving(owner: self)
        running = false
    }

    /// Überträgt alle Einstellungen ans Gerät (auch während des Empfangs).
    func apply(to device: HackRFDevice) throws {
        try device.setSampleRate(UInt32(sampleRateMHz * 1_000_000))
        try device.setFrequency(UInt64(centerMHz * 1_000_000))
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    func applyQuietly(to device: HackRFDevice?) {
        guard let device else { return }
        do {
            try apply(to: device)
            maxHold = []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resetMaxHold() { maxHold = [] }

    // MARK: Marker

    /// Marker an der Frequenz setzen – auf die Spitze in der Nähe gezogen. Sind
    /// schon vier gesetzt, wandert der nächstgelegene.
    func placeMarker(at mhz: Double) {
        let snapped = SpectrumMath.snapToPeak(mhz: mhz, values: spectrum, centerMHz: centerMHz, spanMHz: sampleRateMHz)
        markers = SpectrumMath.placeMarker(markers, at: snapped)
    }

    /// Marker 1 auf das stärkste Signal (ohne DC-Spitze).
    func markerToPeak() {
        guard let peak else { return }
        markers = SpectrumMath.moveMarker(markers, id: 1, to: peak.mhz)
    }

    func removeMarker(_ id: Int) { markers.removeAll { $0.id == id } }
    func clearMarkers() { markers = [] }

    /// Pegel am Marker im angezeigten Spektrum; `nil` außerhalb des Bereichs.
    func level(at mhz: Double) -> Float? {
        SpectrumMath.level(at: mhz, values: spectrum, centerMHz: centerMHz, spanMHz: sampleRateMHz)
    }

    func tune(to mhz: Double, device: HackRFDevice?) {
        centerMHz = max(1, min(6000, mhz))
        guard let device else { return }
        do {
            try device.setFrequency(UInt64(centerMHz * 1_000_000))
            rows.removeAll()
            maxHold = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ingest(_ fresh: [Float]) {
        if spectrum.count == fresh.count, averaging > 0 {
            let a = Float(averaging)
            spectrum = zip(spectrum, fresh).map { a * $0 + (1 - a) * $1 }
        } else {
            spectrum = fresh
        }
        if maxHoldEnabled { maxHold = SpectrumMath.maxHold(maxHold, fresh) }
        if autoScale, !spectrum.isEmpty { followScale() }
        rows.insert(fresh, at: 0)
        if rows.count > maxRows { rows.removeLast(rows.count - maxRows) }
        waterfall = renderWaterfall()
    }

    /// Frequenz und Pegel des stärksten Signals (ohne den DC-Spike in der Mitte).
    var peak: (mhz: Double, db: Float)? {
        guard let best = SpectrumMath.peakIndex(spectrum) else { return nil }
        return (SpectrumMath.mhz(bin: best, count: spectrum.count, centerMHz: centerMHz, spanMHz: sampleRateMHz), spectrum[best])
    }

    /// Unten 5 dB unter dem Rauschboden, oben über der stärksten Spitze (mind.
    /// 30 dB Spanne), auf 5 dB gerundet und träge, damit das Bild nicht flackert.
    private func followScale() {
        let sorted = spectrum.sorted()
        let floor = Double(sorted[sorted.count / 2]), peak = Double(sorted[sorted.count - 1])
        let low = ((floor - 5) / 5).rounded(.down) * 5
        let high = max(low + 30, ((peak + 5) / 5).rounded(.up) * 5)
        if abs(low - minDB) >= 5 { minDB += (low - minDB) * 0.3 }
        if abs(high - maxDB) >= 5 { maxDB += (high - maxDB) * 0.3 }
    }

    private func renderWaterfall() -> CGImage? {
        guard let width = rows.first?.count, width > 0 else { return nil }
        let height = rows.count
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let low = Float(minDB), span = Float(max(1, maxDB - minDB))
        for (y, row) in rows.enumerated() {
            for x in 0..<width {
                let t = max(0, min(1, (row[x] - low) / span))
                let c = Self.palette[Int(t * 255)]
                let o = (y * width + x) * 4
                pixels[o] = c.0
                pixels[o + 1] = c.1
                pixels[o + 2] = c.2
                pixels[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Farbtabelle in 256 Stufen – einmal gerechnet. Vorher entstand je Pixel
    /// ein neues Stützstellen-Array (≈ 3,7 Mio. Allokationen/s auf dem Main Actor).
    private static let palette: [(UInt8, UInt8, UInt8)] = (0..<256).map { colormap(Float($0) / 255) }

    /// Schwarz → Blau → Cyan → Gelb → Rot → Weiß.
    private static func colormap(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let stops: [(Float, Float, Float)] = [(0, 0, 0), (0, 0, 0.6), (0, 0.7, 0.9), (0.95, 0.9, 0.1), (0.95, 0.15, 0.1), (1, 1, 1)]
        let scaled = t * Float(stops.count - 1)
        let i = min(Int(scaled), stops.count - 2)
        let f = scaled - Float(i)
        let a = stops[i], b = stops[i + 1]
        return (UInt8((a.0 + (b.0 - a.0) * f) * 255), UInt8((a.1 + (b.1 - a.1) * f) * 255), UInt8((a.2 + (b.2 - a.2) * f) * 255))
    }
}

/// Marker im Spektrum (Nummer 1–4, Frequenz in MHz).
struct SpectrumMarker: Identifiable, Equatable, Sendable {
    let id: Int
    var mhz: Double
}

/// Rechenteile von Spektrum, Max-Hold und Markern – rein, testbar.
/// Bin `i` von `count` liegt bei `Mitte + (i/count − ½) · Breite`.
enum SpectrumMath {
    static let maxMarkers = 4

    /// Max-Hold: höchster Wert je Bin. Andere Länge (neue FFT) beginnt neu.
    static func maxHold(_ held: [Float], _ fresh: [Float]) -> [Float] {
        guard held.count == fresh.count else { return fresh }
        return zip(held, fresh).map { max($0, $1) }
    }

    /// Stärkster Bin ohne die DC-Spitze (± `guardBins` um die Mitte); `nil` bei zu wenig Werten.
    static func peakIndex(_ values: [Float], guardBins: Int = 2) -> Int? {
        guard values.count > 8 else { return nil }
        let mid = values.count / 2
        var best: Int?
        for i in values.indices where abs(i - mid) > guardBins && values[i].isFinite {
            if best == nil || values[i] > values[best!] { best = i }
        }
        return best
    }

    static func mhz(bin: Int, count: Int, centerMHz: Double, spanMHz: Double) -> Double {
        centerMHz + (Double(bin) / Double(count) - 0.5) * spanMHz
    }

    /// Bin zur Frequenz; `nil` außerhalb des angezeigten Bereichs.
    static func bin(mhz: Double, count: Int, centerMHz: Double, spanMHz: Double) -> Int? {
        guard count > 0, spanMHz > 0 else { return nil }
        let i = Int((((mhz - centerMHz) / spanMHz + 0.5) * Double(count)).rounded())
        return (0..<count).contains(i) ? i : nil
    }

    static func level(at mhz: Double, values: [Float], centerMHz: Double, spanMHz: Double) -> Float? {
        bin(mhz: mhz, count: values.count, centerMHz: centerMHz, spanMHz: spanMHz).map { values[$0] }
    }

    /// Frequenz der höchsten Stelle im Umkreis von `radius` Bins (Klick neben die Spitze).
    static func snapToPeak(mhz: Double, values: [Float], centerMHz: Double, spanMHz: Double, radius: Int = 4) -> Double {
        guard let center = bin(mhz: mhz, count: values.count, centerMHz: centerMHz, spanMHz: spanMHz) else { return mhz }
        let range = max(0, center - radius)...min(values.count - 1, center + radius)
        guard let best = range.max(by: { values[$0] < values[$1] }) else { return mhz }
        return self.mhz(bin: best, count: values.count, centerMHz: centerMHz, spanMHz: spanMHz)
    }

    /// Neuen Marker setzen (kleinste freie Nummer); sind alle vergeben, wandert der nächstgelegene.
    static func placeMarker(_ markers: [SpectrumMarker], at mhz: Double) -> [SpectrumMarker] {
        var result = markers
        if result.count < maxMarkers {
            let id = (1...maxMarkers).first { n in !result.contains { $0.id == n } } ?? result.count + 1
            result.append(SpectrumMarker(id: id, mhz: mhz))
        } else if let nearest = result.indices.min(by: { abs(result[$0].mhz - mhz) < abs(result[$1].mhz - mhz) }) {
            result[nearest].mhz = mhz
        }
        return result.sorted { $0.id < $1.id }
    }

    /// Marker `id` auf eine Frequenz setzen (anlegen, falls es ihn nicht gibt).
    static func moveMarker(_ markers: [SpectrumMarker], id: Int, to mhz: Double) -> [SpectrumMarker] {
        var result = markers.filter { $0.id != id }
        result.append(SpectrumMarker(id: id, mhz: mhz))
        return result.sorted { $0.id < $1.id }
    }

    /// Abstand zu Marker 1: Frequenz (MHz) und Pegel (dB); `nil` ohne Bezug.
    static func delta(of marker: SpectrumMarker, reference: SpectrumMarker?, level: Float?, referenceLevel: Float?)
        -> (mhz: Double, db: Float?)? {
        guard let reference, reference.id != marker.id else { return nil }
        let db: Float? = if let level, let referenceLevel { level - referenceLevel } else { nil }
        return (marker.mhz - reference.mhz, db)
    }
}

/// Zählt empfangene Bytes threadsicher.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.withLock { count += n } }
    func take() -> Int { lock.withLock { defer { count = 0 }; return count } }
}
