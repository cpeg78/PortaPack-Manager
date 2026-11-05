import Accelerate
import Foundation

/// Stufe der Rauschminderung für Sprechfunk.
enum NoiseReduction: String, CaseIterable, Identifiable, Sendable {
    case off, medium, strong

    var id: Self { self }

    var title: String {
        switch self {
        case .off: String(localized: "Aus")
        case .medium: String(localized: "Mittel")
        case .strong: String(localized: "Stark")
        }
    }

    /// Kleinste Verstärkung je Band in dB – tiefer heißt mehr Rauschminderung,
    /// aber auch mehr Gefahr von „Blubbern“ (musikalischem Rauschen).
    var floorDB: Float? {
        switch self {
        case .off: nil
        case .medium: -12
        case .strong: -20
        }
    }
}

/// Spektrale Rauschminderung für Sprache (16 kHz, AM-Sprechfunk):
///
/// - Kurzzeitspektrum mit 256er-Rahmen (16 ms), halbe Überlappung, Wurzel-
///   Hann-Fenster auf beiden Seiten (Summe der Fensterquadrate = 1).
/// - **Rauschbild nach Minimum-Statistik** (Martin 2001, vereinfacht): geglättete
///   Leistung je Band, Minimum über ≈ 1,5 s in acht Teilfenstern, mal Korrektur
///   1,5 – Sprechpausen von wenigen Zehntelsekunden genügen, kein Sprachdetektor.
/// - **Wiener-Gewicht mit „decision directed“-Schätzung** (Ephraim/Malah):
///   ξ = α · G²·P/N (Vorrahmen) + (1 − α) · max(P/N − 1, 0), G = ξ / (1 + ξ),
///   nach unten auf `floor` begrenzt – die Glättung über α = 0,98 verhindert das
///   typische Blubbern einfacher Spektralsubtraktion.
/// - Außerhalb des Sprachbands 250–3000 Hz immer die Untergrenze (Brummen, Zischen).
///
/// Latenz ein Rahmen (16 ms). Ein Zustand je Kanal – das Rauschen ist je
/// Frequenz verschieden.
struct SpeechDenoiser {
    static let frameLength = 256
    static let hop = frameLength / 2
    static let sampleRate: Float = 16_000

    // 256 ist eine gültige DFT-Länge (2^n) – das Anlegen kann nicht scheitern.
    private let dft = try! vDSP.DiscreteFourierTransform(previous: nil, count: frameLength, direction: .forward,
                                                         transformType: .complexComplex, ofType: Float.self)
    private let idft = try! vDSP.DiscreteFourierTransform(previous: nil, count: frameLength, direction: .inverse,
                                                          transformType: .complexComplex, ofType: Float.self)
    private let window: [Float] = (0..<frameLength).map { n in
        sinf(.pi * Float(n) / Float(frameLength))   // Wurzel aus dem periodischen Hann-Fenster
    }
    /// Sprachband 250–3000 Hz als Maske je Band (Spiegel inklusive).
    private let band: [Bool] = (0..<frameLength).map { k in
        let bin = min(k, frameLength - k)
        let hz = Float(bin) * sampleRate / Float(frameLength)
        return hz >= 250 && hz <= 3000
    }

    var floor: Float

    private var input: [Float] = []
    private var overlap = [Float](repeating: 0, count: hop)
    private var output: [Float] = []
    private var smoothed: [Float] = []
    private var noise: [Float] = []
    private var previousSNR: [Float] = []
    /// Minimum-Statistik: laufendes Minimum des Teilfensters und die letzten Teilfenster-Minima.
    private var subMinimum: [Float] = []
    private var subMinima: [[Float]] = []
    private var framesInSub = 0
    private static let framesPerSub = 24          // 24 × 8 ms ≈ 0,19 s
    private static let subWindows = 8             // ≈ 1,5 s
    private static let bias: Float = 1.5

    init(floorDB: Float) {
        floor = powf(10, floorDB / 20)
    }

    /// Ton im 16-kHz-Takt hinein, gleich viel (um einen Rahmen verzögert) heraus.
    mutating func process(_ samples: [Float]) -> [Float] {
        input += samples
        while input.count >= Self.frameLength {
            processFrame(Array(input.prefix(Self.frameLength)))
            input.removeFirst(Self.hop)
        }
        // Gleich viele Werte wie hinein; zu Beginn mit Stille auffüllen.
        if output.count < samples.count {
            output = [Float](repeating: 0, count: samples.count - output.count) + output
        }
        let out = Array(output.prefix(samples.count))
        output.removeFirst(samples.count)
        return out
    }

    private mutating func processFrame(_ frame: [Float]) {
        let n = Self.frameLength
        let windowed = vDSP.multiply(frame, window)
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        dft.transform(inputReal: windowed, inputImaginary: [Float](repeating: 0, count: n),
                       outputReal: &re, outputImaginary: &im)
        var power = [Float](repeating: 0, count: n)
        for k in 0..<n { power[k] = re[k] * re[k] + im[k] * im[k] + 1e-12 }

        if smoothed.isEmpty {
            smoothed = power
            noise = power
            subMinimum = power
            previousSNR = [Float](repeating: 1, count: n)
        }
        for k in 0..<n {
            smoothed[k] = 0.8 * smoothed[k] + 0.2 * power[k]
            subMinimum[k] = min(subMinimum[k], smoothed[k])
        }
        framesInSub += 1
        if framesInSub == Self.framesPerSub {
            subMinima.append(subMinimum)
            if subMinima.count > Self.subWindows { subMinima.removeFirst() }
            subMinimum = smoothed
            framesInSub = 0
        }
        for k in 0..<n {
            var minimum = subMinimum[k]
            for sub in subMinima { minimum = min(minimum, sub[k]) }
            noise[k] = Self.bias * minimum
        }

        for k in 0..<n {
            let posterior = power[k] / noise[k]
            let prior = 0.98 * previousSNR[k] + 0.02 * max(posterior - 1, 0)
            var gain = prior / (1 + prior)
            gain = band[k] ? max(gain, floor) : floor
            previousSNR[k] = gain * gain * posterior
            re[k] *= gain
            im[k] *= gain
        }

        var timeRe = [Float](repeating: 0, count: n), timeIm = [Float](repeating: 0, count: n)
        idft.transform(inputReal: re, inputImaginary: im, outputReal: &timeRe, outputImaginary: &timeIm)
        let restored = vDSP.multiply(vDSP.multiply(1 / Float(n), timeRe), window)
        // Überlappung addieren: erste Hälfte fertig, zweite für den nächsten Rahmen.
        output += vDSP.add(Array(restored.prefix(Self.hop)), overlap)
        overlap = Array(restored.suffix(Self.hop))
    }
}
