import Foundation
import Speech
import Testing
@testable import PortaPackManager

/// Grobe Messung der Erkennungsquote mit `say`-Stimmen und AM-Rauschen (kein
/// Pflichttest, Ergebnis in `Docs/Erfahrungen/Flugfunk-VOR.md`):
/// `TEST_RUNNER_STT_MEASURE=1 xcodebuild test … -only-testing:PortaPackManagerTests/AirbandRecognitionMeasurement`
@Suite("Flugfunk – Abschrift: Messung", .enabled(if: ProcessInfo.processInfo.environment["STT_MEASURE"] != nil), .serialized)
struct AirbandRecognitionMeasurement {
    struct Phrase {
        var text: String
        var language: String
        var callsign: String
    }

    static let phrases = [
        Phrase(text: "Lufthansa four alpha bravo, descend flight level eight zero", language: "en", callsign: "DLH4AB"),
        Phrase(text: "Speedbird one two, contact Bremen radar one two three decimal eight seven five", language: "en", callsign: "BAW12"),
        Phrase(text: "Eurowings seven lima november, cleared to land runway two three, wind two four zero degrees eight knots", language: "en", callsign: "EWG7LN"),
        Phrase(text: "Ryanair four five charlie, squawk seven seven one four, climb flight level one two zero", language: "en", callsign: "RYR45C"),
        Phrase(text: "Condor one six two, hold short runway two five, QNH one zero one three", language: "en", callsign: "CFG162"),
        Phrase(text: "Christoph zwo neun, Landung frei Piste zwo drei, Wind zwo vier null Grad, acht Knoten", language: "de", callsign: "CHX29"),
        Phrase(text: "Delta Echo Alpha Bravo Charlie, rollen Sie zum Rollhalt Piste zwo fünf", language: "de", callsign: "DEABC"),
    ]

    static let candidates = ["DLH4AB", "BAW12", "EWG7LN", "RYR45C", "CFG162", "CHX29", "DEABC", "DLH4AC", "BAW21", "EWG7LM"]
        .map { AirbandCallsign(callsign: $0, icao: nil) }

    static func words(_ text: String) -> [String] {
        AirbandTranscriptFormatter.format(text).lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == ".") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    /// Wortfehlerrate (Levenshtein über Wörter / Wörter der Vorlage), nach der
    /// Nachbearbeitung („eight zero“ und „80“ zählen gleich).
    static func wer(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var d = Array(0...h.count)
        for i in 1...r.count {
            var previous = d[0]
            d[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let current = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, previous + (r[i - 1] == h[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return Double(d[h.count]) / Double(r.count)
    }

    /// AM-Kanal grob nachgebildet: Modulationsgrad bis 0,8, weißes Rauschen bei
    /// `snr` dB (bezogen auf den Effektivwert der Sprache), Pausen davor und danach.
    static func channel(_ audio: [Float], snr: Double?, seed: UInt64) -> [Int16] {
        let peak = audio.map(abs).max() ?? 1
        let speech = audio.map { $0 / max(peak, 1e-6) * 0.8 }
        var noise = SplitMixNoise(seed: seed)
        let rms = (speech.reduce(0) { $0 + $1 * $1 } / Float(max(1, speech.count))).squareRoot()
        let sigma = snr.map { Double(rms) / pow(10, $0 / 20) } ?? 0
        let pad = [Float](repeating: 0, count: 6_000)
        return (pad + speech + pad).map { v in
            Int16(max(-1, min(1, Double(v) + sigma * noise.gaussian())) * 32_000)
        }
    }

    /// Varianten der Aufbereitung (zum Vergleich mit der eingebauten).
    static func variant(_ name: String, _ samples: [Int16]) -> [Float]? {
        switch name {
        case "roh": return samples.map { Float($0) / 32_768 }
        case "Sprachband": return AirbandSpeechAudio.prepare(samples, filter: .band)
        case "ohne Filter": return AirbandSpeechAudio.prepare(samples, filter: .none)
        default: return AirbandSpeechAudio.prepare(samples)
        }
    }

    @Test("Erkennungsquote nach Stimme, Rauschen und Aufbereitung")
    func measure() async throws {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { return }
        let recognizer = AnalyzerSpeechRecognizer()
        let voices = ["en": ["Daniel", "Samantha", "Karen"], "de": ["Anna"]]
        var audioCache: [String: [Float]] = [:]
        var rows: [String] = []
        let variants = ["aufbereitet", "roh", "ohne Filter", "Sprachband", "aufbereitet+Hinweise"]
        for snr in [nil, 20.0, 10.0, 5.0] as [Double?] {
            for variant in variants {
                var werSum = 0.0, count = 0, signs = 0, seconds = 0.0, audioSeconds = 0.0, autoRight = 0, autoConf = 0
                for (k, phrase) in Self.phrases.enumerated() {
                    for voice in voices[phrase.language] ?? [] {
                        let key = voice + phrase.text
                        let audio = try audioCache[key] ?? AirbandRealRecognitionTests.synthesize(phrase.text, voice: voice)
                        audioCache[key] = audio
                        let samples = Self.channel(audio, snr: snr, seed: UInt64(k + 1))
                        let base = variant.replacingOccurrences(of: "+Hinweise", with: "")
                        count += 1
                        guard let prepared = Self.variant(base, samples) else { werSum += 1; continue }
                        let context = variant.hasSuffix("Hinweise")
                            ? AirbandPhraseology.contextualStrings(callsigns: Self.candidates, channelNames: ["Bremen Radar"], language: phrase.language)
                            : []
                        let start = Date()
                        let result = try await recognizer.recognize(prepared, language: phrase.language, context: context)
                        seconds += Date().timeIntervalSince(start)
                        audioSeconds += Double(prepared.count) / 16_000
                        let text = result?.text ?? ""
                        werSum += Self.wer(reference: phrase.text, hypothesis: text)
                        if AirbandTranscriptFormatter.matchCallsign(in: text, candidates: Self.candidates)?.callsign == phrase.callsign { signs += 1 }
                        // Automatisch: andere Sprache dagegen.
                        if variant == "aufbereitet" {
                            let other = phrase.language == "en" ? "de" : "en"
                            if let result, let otherResult = try await recognizer.recognize(prepared, language: other, context: []) {
                                if AirbandPhraseology.languageScore(result) >= AirbandPhraseology.languageScore(otherResult) { autoRight += 1 }
                                if (result.confidence ?? 0) >= (otherResult.confidence ?? 0) { autoConf += 1 }
                            } else if result != nil {
                                autoRight += 1; autoConf += 1
                            }
                            if snr == nil || snr == 10 {
                                print("STT-TEXT \(snr.map { "\($0)" } ?? "sauber") \(voice): \(text) [\(String(format: "%.2f", result?.confidence ?? -1))]")
                            }
                        }
                    }
                }
                let line = String(format: "STT | %@ | %@ | WER %.0f %% | Rufzeichen %d/%d | Sprache auto %@ | %.3f s je s Ton",
                                  snr.map { String(format: "%.0f dB", $0) } ?? "sauber", variant, werSum / Double(max(1, count)) * 100,
                                  signs, count, variant == "aufbereitet" ? "\(autoRight)/\(count) (nur Zuversicht \(autoConf))" : "–",
                                  seconds / max(audioSeconds, 0.001))
                rows.append(line)
            }
        }
        print(rows.joined(separator: "\n"))
    }
}
