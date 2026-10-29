import Accelerate
import Foundation

/// Bereitet den AM-Ton eines Spruchs (16 kHz, Modulationsgrad) für die
/// Spracherkennung auf: Pausen und Rauschen am Anfang und Ende abschneiden
/// (gemessen im Sprachband 300–3000 Hz), Hochpass 300 Hz, Pegel angleichen.
/// Zu kurze Sprüche fallen weg.
///
/// Der Ton bleibt nur im Speicher – gespeichert wird er ausschließlich mit
/// „Sprüche aufzeichnen“, und das unabhängig von der Erkennung.
enum AirbandSpeechAudio {
    static let rate = 16_000.0
    /// Kürzer (nach dem Abschneiden) lohnt keine Erkennung – meist nur „Roger“-Knackser.
    static let minSeconds = 0.8
    /// Rahmen für die Pegelmessung beim Abschneiden (20 ms).
    static let frame = 320
    /// Rand, der vor dem ersten und nach dem letzten lauten Rahmen stehen bleibt.
    static let leadSeconds = 0.2
    static let tailSeconds = 0.3
    /// Zielpegel: Effektivwert ≈ −20 dBFS, Spitzen höchstens 0,9.
    static let targetRMS: Float = 0.1
    static let peakLimit: Float = 0.9

    /// Filter für den Ton, der an die Erkennung geht. Die Grenzen des Spruchs
    /// bestimmt immer das Sprachband 300–3000 Hz.
    enum Filter: Sendable {
        /// Ungefiltert.
        case none
        /// Nur Hochpass 300 Hz (Brummen, Trägerrest).
        case highpass
        /// Sprachband 300–3000 Hz.
        case band
    }

    /// Vorgabe nach der Messung vom 29.10.2026 (`Flugfunk-VOR.md`): Das Sprachband
    /// als Erkennungs-Eingang verschlechterte die Wortfehlerrate bei Rauschen
    /// deutlich (20 dB: 47 % statt 32 %); Abschneiden und Pegel halfen (5 dB:
    /// 63 % statt 71 % roh). Hochpass und ungefiltert lagen gleichauf – der
    /// Hochpass bleibt gegen Brummen und Trägerschwankungen echter AM-Sender.
    static let defaultFilter = Filter.highpass

    /// Fertig aufbereitet für die Erkennung oder `nil`, wenn zu kurz oder stumm.
    static func prepare(_ samples: [Int16], filter: Filter = defaultFilter) -> [Float]? {
        prepare(samples.map { Float($0) / 32_768 }, filter: filter)
    }

    static func prepare(_ samples: [Float], filter: Filter = defaultFilter) -> [Float]? {
        guard Double(samples.count) >= minSeconds * rate else { return nil }
        guard let range = speechRange(bandpass(samples)) else { return nil }
        var audio: [Float]
        switch filter {
        case .none: audio = Array(samples[range])
        case .highpass: audio = Array(highpass(samples)[range])
        case .band: audio = Array(bandpass(samples)[range])
        }
        guard Double(audio.count) >= minSeconds * rate else { return nil }
        guard normalize(&audio) else { return nil }
        return audio
    }

    /// Hochpass 300 Hz, Butterworth 4. Ordnung.
    static func highpass(_ samples: [Float]) -> [Float] {
        var filters = [Biquad.highpass(cutoff: 300, rate: rate, q: 0.5412), Biquad.highpass(cutoff: 300, rate: rate, q: 1.3066)]
        var out = samples
        for k in filters.indices {
            for n in out.indices { out[n] = filters[k].step(out[n]) }
        }
        return out
    }

    /// Sprachband 300–3000 Hz: je zwei Biquads (Butterworth 4. Ordnung) als Hoch-
    /// und Tiefpass. Unten fällt das Brummen und der Rest des Trägers weg, oben
    /// das Rauschen, das bei AM über der Sprache liegt.
    static func bandpass(_ samples: [Float]) -> [Float] {
        var filters = [
            Biquad.highpass(cutoff: 300, rate: rate, q: 0.5412), Biquad.highpass(cutoff: 300, rate: rate, q: 1.3066),
            Biquad.lowpass(cutoff: 3_000, rate: rate, q: 0.5412), Biquad.lowpass(cutoff: 3_000, rate: rate, q: 1.3066),
        ]
        var out = samples
        for k in filters.indices {
            for n in out.indices { out[n] = filters[k].step(out[n]) }
        }
        return out
    }

    /// Pegel je Rahmen in dB.
    static func frameLevels(_ samples: [Float]) -> [Float] {
        let count = samples.count / frame
        return (0..<count).map { k in
            let slice = samples[(k * frame)..<((k + 1) * frame)]
            let power = slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame)
            return 10 * log10(max(power, 1e-12))
        }
    }

    /// Bereich vom ersten bis zum letzten lauten Rahmen samt Rand. Laut heißt:
    /// deutlich über dem Boden (10. Perzentil), mindestens 6 dB und ein Drittel
    /// des Abstands zwischen Boden und lauten Stellen (95. Perzentil). Ohne
    /// erkennbaren Unterschied bleibt alles (Sprache ohne Pausen).
    static func speechRange(_ samples: [Float]) -> Range<Int>? {
        let levels = frameLevels(samples)
        guard !levels.isEmpty else { return nil }
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let top = sorted[Int(Double(sorted.count - 1) * 0.95)]
        // Praktisch stumm (Effektivwert unter ≈ −70 dBFS): nichts zu erkennen.
        guard top > -70 else { return nil }
        guard top - floor >= 6 else { return 0..<samples.count }
        let threshold = floor + max(6, (top - floor) / 3)
        guard let first = levels.firstIndex(where: { $0 >= threshold }),
              let last = levels.lastIndex(where: { $0 >= threshold }) else { return nil }
        let start = max(0, first * frame - Int(leadSeconds * rate))
        let end = min(samples.count, (last + 1) * frame + Int(tailSeconds * rate))
        return start..<end
    }

    /// Effektivwert auf `targetRMS`, Spitzen auf `peakLimit` begrenzt (nur
    /// Verstärkung, kein Begrenzer – die Form bleibt). `false` bei Stille.
    @discardableResult
    static func normalize(_ samples: inout [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        let rms = vDSP.rootMeanSquare(samples)
        let peak = vDSP.maximumMagnitude(samples)
        guard rms > 1e-5, peak > 0 else { return false }
        let gain = min(targetRMS / rms, peakLimit / peak)
        samples = vDSP.multiply(gain, samples)
        return true
    }
}
