import CryptoKit
import Foundation
import OSLog
import whisper

/// Whisper-Modelle zur Wahl (ggml-Format von huggingface.co/ggerganov/whisper.cpp).
/// Größe und SHA-256 stehen hier fest – jeder Download wird damit geprüft.
enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case base
    case small
    case turbo
    case turboFull

    /// Vorgabe nach der Messung vom 30.10.2026 (`AirbandRecognitionMeasurement`):
    /// Small war genauer als Turbo (q5) und dreimal schneller.
    static let standard = WhisperModel.small

    var id: String { rawValue }

    var file: String {
        switch self {
        case .base: "ggml-base-q5_1.bin"
        case .small: "ggml-small-q5_1.bin"
        case .turbo: "ggml-large-v3-turbo-q5_0.bin"
        case .turboFull: "ggml-large-v3-turbo.bin"
        }
    }

    var bytes: Int64 {
        switch self {
        case .base: 59_707_625
        case .small: 190_085_487
        case .turbo: 574_041_195
        case .turboFull: 1_624_555_275
        }
    }

    var sha256: String {
        switch self {
        case .base: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
        case .small: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        case .turbo: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        case .turboFull: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        }
    }

    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }

    var title: String {
        switch self {
        case .base: String(localized: "Klein und schnell (Base)")
        case .small: String(localized: "Ausgewogen (Small, empfohlen)")
        case .turbo: String(localized: "Groß (Large v3 Turbo)")
        case .turboFull: String(localized: "Groß, ungepackt (Large v3 Turbo)")
        }
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Ablage der Whisper-Modelle: Application Support, Unterordner `Whisper` – nicht
/// in Caches, sonst dürfte macOS ein 0,5-GB-Modell stillschweigend löschen.
enum WhisperModelStore {
    static var folder: URL {
        let url = AppFiles.support.appendingPathComponent("Whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(for model: WhisperModel) -> URL { folder.appendingPathComponent(model.file) }

    /// Da und vollständig (Größe stimmt; die Prüfsumme wird beim Download geprüft).
    static func isInstalled(_ model: WhisperModel) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url(for: model).path)[.size] as? NSNumber)?.int64Value
        return size == model.bytes
    }

    static func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: url(for: model))
    }

    enum DownloadError: Error, LocalizedError {
        case http(Int)
        case checksum

        var errorDescription: String? {
            switch self {
            case .http(let code): String(localized: "Das Modell ließ sich nicht laden (HTTP \(code)).")
            case .checksum: String(localized: "Das geladene Modell ist beschädigt (Prüfsumme stimmt nicht) und wurde verworfen.")
            }
        }
    }

    /// Lädt das Modell, prüft SHA-256 und legt es erst danach ab. `progress` 0…1.
    static func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (temporary, response) = try await downloadFile(model.url, progress: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw DownloadError.http(http.statusCode) }
        guard try sha256(of: temporary) == model.sha256 else { throw DownloadError.checksum }
        let target = url(for: model)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
    }

    /// Download mit Fortschritt (alle 300 ms aus `task.progress`); Abbruch der
    /// umgebenden Aufgabe bricht den Download ab.
    private static func downloadFile(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        final class Box: @unchecked Sendable { var task: URLSessionDownloadTask? }
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let location, let response else { continuation.resume(throwing: URLError(.badServerResponse)); return }
                    // Die Datei verschwindet nach dem Rücksprung – sofort umziehen.
                    let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                task.resume()
                Task {
                    while task.state == .running {
                        progress(task.progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Erkennung mit whisper.cpp (Metal) auf dem Mac – Alternative zu Apples
/// Spracherkennung, meist besser bei verrauschtem Funk. Ein Kontext je Modell,
/// Aufrufe nacheinander (der Kontext ist nicht für parallele Aufrufe gedacht; die
/// Warteschlange erkennt ohnehin seriell).
///
/// „Automatisch“: Whisper erkennt die Sprache selbst – ein Durchlauf statt zwei.
/// Die Warteschlange fragt dann „en“ und „de“ an; „en“ läuft mit Spracherkennung,
/// „de“ liefert nichts.
final class WhisperSpeechRecognizer: AirbandSpeechRecognizing, @unchecked Sendable {
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Spracherkennung")

    private let context: OpaquePointer
    private let lock = NSLock()
    private let automatic: Bool

    enum LoadError: Error, LocalizedError {
        case model
        var errorDescription: String? { String(localized: "Das Whisper-Modell ließ sich nicht laden.") }
    }

    init(model: URL, automatic: Bool) throws {
        Self.silenceLibraryLog()
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let context = model.path.withCString({ whisper_init_from_file_with_params($0, params) }) else {
            throw LoadError.model
        }
        self.context = context
        self.automatic = automatic
    }

    deinit { whisper_free(context) }

    /// whisper.cpp schreibt sonst jede Schicht und jeden Durchlauf nach stderr.
    private static let silenced: Void = {
        whisper_log_set({ _, _, _ in }, nil)
    }()
    private static func silenceLibraryLog() { _ = silenced }

    /// Vorgabe-Text, der Whisper auf Flugfunk einstimmt: Phraseologie und die
    /// Rufzeichen in Reichweite. Höchstens ~200 Tokens werden berücksichtigt.
    nonisolated static func prompt(language: String, context: [String]) -> String {
        let intro = language == "de"
            ? "Flugfunk. Hamburg Turm, Piste 23, QNH 1013, Transponder 7000, Wind 270 Grad 10 Knoten."
            : "Air traffic control radio. Hamburg Tower, runway 23, QNH 1013, squawk 7000, climb flight level 240, contact radar 123.875."
        let hints = context.prefix(30).joined(separator: ", ")
        return String((hints.isEmpty ? intro : intro + " " + hints + ".").prefix(700))
    }

    /// Typische Whisper-Erfindungen bei Rauschen/Stille (Untertitel-Abspann u. Ä.).
    nonisolated static func isHallucination(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        if t.isEmpty { return true }
        if let first = text.trimmingCharacters(in: .whitespaces).first, "[(*♪".contains(first) { return true }
        // Ganzer Spruch nur aus einer Floskel – echte Funksprüche haben mehr.
        let alone = ["thank you", "thanks", "you", "bye", "okay", "vielen dank", "danke", "tschüss"]
        // Abspann-Texte aus den Trainingsdaten, auch mit Zusatz („… des ZDF, 2021“).
        let credits = ["thanks for watching", "thank you for watching", "subtitles by", "untertitel", "copyright", "amara.org"]
        return alone.contains(t) || credits.contains { t.hasPrefix($0) }
    }

    func recognize(_ samples: [Float], language: String, context hints: [String]) async throws -> AirbandRecognition? {
        if automatic, language != "en" { return nil }
        return try lock.withLock { try run(samples, language: automatic ? "auto" : language, hints: hints) }
    }

    private func run(_ samples: [Float], language: String, hints: [String]) throws -> AirbandRecognition? {
        try Task.checkCancellation()
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.no_context = true
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0
        params.no_speech_thold = 0.6
        let prompt = Self.prompt(language: language == "auto" ? "en" : language, context: hints)
        let status: Int32 = prompt.withCString { promptPointer in
            language.withCString { languagePointer in
                params.initial_prompt = promptPointer
                params.language = languagePointer
                params.detect_language = false
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard status == 0 else {
            Self.log.error("Whisper: whisper_full fehlgeschlagen (\(status))")
            return nil
        }
        var text = ""
        var probabilities: [Float] = []
        let eot = whisper_token_eot(context)
        for segment in 0..<whisper_full_n_segments(context) {
            if whisper_full_get_segment_no_speech_prob(context, segment) > 0.6 { continue }
            if let pointer = whisper_full_get_segment_text(context, segment) { text += String(cString: pointer) }
            for token in 0..<whisper_full_n_tokens(context, segment)
            where whisper_full_get_token_id(context, segment, token) < eot {
                probabilities.append(whisper_full_get_token_p(context, segment, token))
            }
        }
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty, !Self.isHallucination(plain) else { return nil }
        var detected = language
        if language == "auto", let code = whisper_lang_str(whisper_full_lang_id(context)) {
            detected = String(cString: code)
        }
        // Nur Englisch und Deutsch sind vorgesehen; anderes zählt als Englisch.
        if detected != "de" { detected = "en" }
        let confidence = probabilities.isEmpty ? nil : Double(probabilities.reduce(0, +) / Float(probabilities.count))
        return AirbandRecognition(text: plain, confidence: confidence, language: detected)
    }
}
