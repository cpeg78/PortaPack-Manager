import Foundation

/// Erkennt, ob ein Spruch Sprache ist (Fund 28.10.2026: Der Suchlauf zählte
/// jedes Öffnen der Rauschsperre – Knackser, Trägertasten, Rauschspitzen).
///
/// Gemessen am demodulierten AM-Ton (16 kHz, Modulationsgrad):
/// - **Sprachband** 300–2700 Hz gegen **Oberband** 4–8 kHz. Flugfunk-Sender
///   begrenzen auf etwa 2,5 kHz; Rauschen verteilt sich gleichmäßig (Verhältnis
///   ≈ 0,6), Sprache liegt deutlich darüber.
/// - **Modulation** im Sprachband: Ein leerer Träger (nur getastet) hat kaum welche.
/// - **Dauer**: Kürzer als `minSeconds` ist kein Spruch.
struct AirbandVoiceDetector: Sendable {
    static let minSeconds = 1.0
    static let minBandRatio = 3.0
    static let minModulationRMS = 0.04

    private var voiceHP = Biquad.highpass(cutoff: 300, rate: 16_000)
    private var voiceLP = Biquad.lowpass(cutoff: 2_700, rate: 16_000)
    private var highHP = Biquad.highpass(cutoff: 4_000, rate: 16_000)
    private(set) var voiceEnergy = 0.0
    private(set) var highEnergy = 0.0
    private(set) var samples = 0

    /// Nur Abschnitte über der Schwelle einspeisen (nicht den Nachlauf).
    mutating func feed(_ audio: [Float]) {
        var voice = 0.0, high = 0.0
        for x in audio {
            let v = voiceLP.step(voiceHP.step(x))
            let h = highHP.step(x)
            voice += Double(v * v)
            high += Double(h * h)
        }
        voiceEnergy += voice
        highEnergy += high
        samples += audio.count
    }

    var bandRatio: Double { voiceEnergy / max(highEnergy, 1e-12) }
    var modulationRMS: Double { samples > 0 ? (voiceEnergy / Double(samples)).squareRoot() : 0 }

    /// Sprache, wenn genug Ton im Sprachband liegt und er dort überwiegt.
    var isSpeech: Bool {
        samples >= Int(0.3 * 16_000) && bandRatio >= Self.minBandRatio && modulationRMS >= Self.minModulationRMS
    }
}

/// Biquad (RBJ-Kochbuch), Direktform I.
struct Biquad: Sendable {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    static func lowpass(cutoff: Double, rate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * cutoff / rate, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        return Biquad(b0: Float((1 - c) / 2 / a0), b1: Float((1 - c) / a0), b2: Float((1 - c) / 2 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
    }

    static func highpass(cutoff: Double, rate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * cutoff / rate, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
    }

    mutating func step(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}
