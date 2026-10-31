import Foundation
import Testing
@testable import PortaPackManager

/// Whisper als zweite Flugfunk-Erkennung (seit 30.10.2026): Modelle, Prüfsumme,
/// Vorgabe-Text, Erfindungen bei Rauschen. Ohne Modell und ohne Netz – die echte
/// Erkennung misst `AirbandRecognitionMeasurement.measureWhisper` (mit geladenem Modell).
@Suite("Flugfunk: Whisper")
struct WhisperTests {
    @Test("Modelle: Dateinamen, Größen, Prüfsummen, Adresse bei Hugging Face")
    func models() {
        #expect(WhisperModel.standard == .small)
        for model in WhisperModel.allCases {
            #expect(model.file.hasPrefix("ggml-") && model.file.hasSuffix(".bin"))
            #expect(model.sha256.count == 64 && model.sha256.allSatisfy(\.isHexDigit))
            #expect(model.bytes > 50_000_000)
            #expect(model.url.absoluteString == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + model.file)
            #expect(WhisperModelStore.url(for: model).lastPathComponent == model.file)
        }
        #expect(Set(WhisperModel.allCases.map(\.file)).count == WhisperModel.allCases.count)
    }

    @Test("SHA-256 einer Datei (stückweise gelesen)")
    func checksum() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try WhisperModelStore.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Vorgabe-Text: Phraseologie der Sprache plus Rufzeichen, begrenzt")
    func prompt() {
        let en = WhisperSpeechRecognizer.prompt(language: "en", context: ["Lufthansa four alpha charlie", "Hamburg Tower"])
        #expect(en.hasPrefix("Air traffic control radio."))
        #expect(en.contains("Lufthansa four alpha charlie, Hamburg Tower."))
        #expect(WhisperSpeechRecognizer.prompt(language: "de", context: []).hasPrefix("Flugfunk."))
        let long = WhisperSpeechRecognizer.prompt(language: "en", context: Array(repeating: String(repeating: "x", count: 50), count: 100))
        #expect(long.count <= 700)
    }

    @Test("Typische Whisper-Erfindungen bei Rauschen werden verworfen, echte Sprüche nicht")
    func hallucinations() {
        for text in ["Thank you.", " thanks for watching!", "[Musik]", "(Applaus)", "* Musik *", "Untertitel im Auftrag des ZDF, 2021",
                     "Vielen Dank.", "...", "", "you"] {
            #expect(WhisperSpeechRecognizer.isHallucination(text), "\(text)")
        }
        for text in ["Lufthansa 4AC, climb flight level 240", "Thank you, good day, Speedbird 12", "Danke, Piste 23 frei"] {
            #expect(!WhisperSpeechRecognizer.isHallucination(text), "\(text)")
        }
    }
}
