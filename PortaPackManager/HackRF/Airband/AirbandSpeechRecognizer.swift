import AVFoundation
import Foundation
import Speech

/// Ergebnis einer Erkennung (Rohtext, wie ihn das System liefert).
struct AirbandRecognition: Sendable, Equatable {
    var text: String
    /// 0…1, Mittel über die Wörter (nach Zeichen gewichtet); `nil`, wenn das System keine liefert.
    var confidence: Double?
    /// „en“ oder „de“.
    var language: String
}

/// Eine Spracherkennung, die nur auf dem Mac rechnet. Im Test ersetzt ein Fake
/// die echte (`AirbandTranscriptionQueue` kennt nur dieses Protokoll).
protocol AirbandSpeechRecognizing: Sendable {
    /// `samples`: aufbereiteter Ton, 16 kHz mono (`AirbandSpeechAudio.prepare`).
    /// `nil`, wenn nichts erkannt wurde.
    func recognize(_ samples: [Float], language: String, context: [String]) async throws -> AirbandRecognition?
}

enum AirbandSpeechError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case notAuthorized
    case timeout

    var errorDescription: String? {
        switch self {
        case .unsupported(let language):
            String(localized: "Für \(language) gibt es auf diesem Mac keine Spracherkennung, die ohne Internet arbeitet.")
        case .notAuthorized:
            String(localized: "Die Spracherkennung ist nicht erlaubt (Systemeinstellungen ▸ Datenschutz & Sicherheit ▸ Spracherkennung).")
        case .timeout:
            String(localized: "Die Spracherkennung hat nicht rechtzeitig geantwortet.")
        }
    }
}

enum AirbandSpeechText {
    static func languageName(_ code: String) -> String {
        code == "de" ? String(localized: "Deutsch") : String(localized: "Englisch")
    }

    /// Mittel der Zuversicht über alle Zeichen.
    static func weightedMean(_ parts: [(confidence: Double, length: Int)]) -> Double? {
        let total = parts.reduce(0) { $0 + $1.length }
        guard total > 0 else { return nil }
        return parts.reduce(0.0) { $0 + $1.confidence * Double($1.length) } / Double(total)
    }

    /// Mono-Puffer im gewünschten Format (Float32 oder Int16, 16 kHz); bei
    /// anderer Abtastrate über `AVAudioConverter`.
    static func buffer(_ samples: [Float], rate: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { return nil }
        for (i, v) in samples.enumerated() { channel[i] = v }
        input.frameLength = AVAudioFrameCount(samples.count)
        if format.sampleRate == rate, format.channelCount == 1 {
            switch format.commonFormat {
            case .pcmFormatFloat32 where !format.isInterleaved || format.channelCount == 1:
                if format == source { return input }
            case .pcmFormatInt16:
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                      let target = output.int16ChannelData?[0] else { return nil }
                for (i, v) in samples.enumerated() { target[i] = Int16(max(-1, min(1, v)) * 32_767) }
                output.frameLength = AVAudioFrameCount(samples.count)
                return output
            default:
                break
            }
        }
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / rate) + 1024)
        else { return nil }
        let feeder = ConverterFeeder(input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in feeder.next(status) }
        return error == nil ? output : nil
    }

    /// Liefert dem Wandler den Eingangspuffer genau einmal.
    private final class ConverterFeeder: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else {
                status.pointee = .endOfStream
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}

// MARK: - macOS 26+: SpeechAnalyzer

/// Erkennung mit `SpeechAnalyzer` + `SpeechTranscriber` (ab macOS 26). Rechnet
/// immer auf dem Gerät; die Sprachmodelle lädt das System über `AssetInventory`
/// (`prepare`). Je Spruch ein eigener Analysator – das Modell bleibt dank
/// `.lingering` geladen (gemessen: 8 s Ton in 0,1–0,25 s).
@available(macOS 26, *)
final class AnalyzerSpeechRecognizer: AirbandSpeechRecognizing {
    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    private static func locale(_ language: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: AirbandSpeechLanguage.locale(for: language))
    }

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.transcriptionConfidence])
    }

    /// Prüft die Sprachen und lädt fehlende Modelle; `progress` 0…1 während des Ladens.
    static func prepare(languages: [String], progress: @escaping @Sendable (Double) -> Void) async throws {
        var modules: [any SpeechModule] = []
        for language in languages {
            guard let locale = await locale(language) else {
                throw AirbandSpeechError.unsupported(AirbandSpeechText.languageName(language))
            }
            modules.append(transcriber(locale))
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        progress(0)
        let watcher = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    func recognize(_ samples: [Float], language: String, context: [String]) async throws -> AirbandRecognition? {
        guard let locale = await Self.locale(language) else {
            throw AirbandSpeechError.unsupported(AirbandSpeechText.languageName(language))
        }
        let transcriber = Self.transcriber(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let buffer = AirbandSpeechText.buffer(samples, rate: AirbandSpeechAudio.rate, format: format) else {
            throw AirbandSpeechError.unsupported(AirbandSpeechText.languageName(language))
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .lingering))
        if !context.isEmpty {
            let analysisContext = AnalysisContext()
            analysisContext.contextualStrings[.general] = context
            try await analyzer.setContext(analysisContext)
        }
        let collector = Task { () -> AttributedString in
            var text = AttributedString()
            for try await result in transcriber.results where result.isFinal { text += result.text }
            return text
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: stream)
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        let text = try await collector.value
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        let parts = text.runs.compactMap { run -> (confidence: Double, length: Int)? in
            guard let confidence = run.transcriptionConfidence else { return nil }
            return (confidence, text[run.range].characters.count)
        }
        return AirbandRecognition(text: plain, confidence: AirbandSpeechText.weightedMean(parts), language: language)
    }
}

// MARK: - macOS 15–25: SFSpeechRecognizer auf dem Gerät

/// Rückfall für macOS 15–25: `SFSpeechRecognizer` mit
/// `requiresOnDeviceRecognition` – nur, wenn die Sprache das auf diesem Mac
/// kann (`supportsOnDeviceRecognition`). Braucht die Erlaubnis
/// „Spracherkennung“ (`NSSpeechRecognitionUsageDescription`).
final class LegacySpeechRecognizer: AirbandSpeechRecognizing {
    static let timeout: Duration = .seconds(30)

    static func supportsOnDevice(_ language: String) -> Bool {
        SFSpeechRecognizer(locale: AirbandSpeechLanguage.locale(for: language))?.supportsOnDeviceRecognition ?? false
    }

    static var authorization: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    /// Fragt nach der Erlaubnis (Dialog des Systems) – nur nach einem Klick des Nutzers.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    func recognize(_ samples: [Float], language: String, context: [String]) async throws -> AirbandRecognition? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw AirbandSpeechError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: AirbandSpeechLanguage.locale(for: language)),
              recognizer.supportsOnDeviceRecognition,
              let format = AVAudioFormat(standardFormatWithSampleRate: AirbandSpeechAudio.rate, channels: 1),
              let buffer = AirbandSpeechText.buffer(samples, rate: AirbandSpeechAudio.rate, format: format) else {
            throw AirbandSpeechError.unsupported(AirbandSpeechText.languageName(language))
        }
        // Rückmeldungen nicht auf dem Main Thread.
        recognizer.queue = OperationQueue()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = context
        request.append(buffer)
        request.endAudio()
        let box = LegacyTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AirbandRecognition?, Error>) in
                box.start(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let best = result.bestTranscription
                        let parts = best.segments.map { (confidence: Double($0.confidence), length: $0.substring.count) }
                        let text = best.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        box.finish(.success(text.isEmpty ? nil
                            : AirbandRecognition(text: text, confidence: AirbandSpeechText.weightedMean(parts), language: language)))
                    } else if let error {
                        // 1110 = „No speech detected“: kein Fehler, nur nichts zu erkennen.
                        box.finish((error as NSError).code == 1110 ? .success(nil) : .failure(error))
                    }
                }
                box.setTask(task)
                Task {
                    try? await Task.sleep(for: Self.timeout)
                    box.finish(.failure(AirbandSpeechError.timeout))
                }
            }
        } onCancel: {
            box.finish(.failure(CancellationError()))
        }
    }

    /// Hält Aufgabe und Fortsetzung; setzt genau einmal fort.
    private final class LegacyTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AirbandRecognition?, Error>?
        private var task: SFSpeechRecognitionTask?
        private var done = false
        /// Abbruch kam, bevor die Fortsetzung stand.
        private var early: Result<AirbandRecognition?, Error>?

        func start(_ continuation: CheckedContinuation<AirbandRecognition?, Error>) {
            let early = lock.withLock { () -> Result<AirbandRecognition?, Error>? in
                if let early = self.early { return early }
                self.continuation = continuation
                return nil
            }
            if let early { continuation.resume(with: early) }
        }

        func setTask(_ task: SFSpeechRecognitionTask) {
            let cancel = lock.withLock { () -> Bool in
                self.task = task
                return done
            }
            if cancel { task.cancel() }
        }

        func finish(_ result: Result<AirbandRecognition?, Error>) {
            let (continuation, task) = lock.withLock { () -> (CheckedContinuation<AirbandRecognition?, Error>?, SFSpeechRecognitionTask?) in
                guard !done else { return (nil, nil) }
                done = true
                if self.continuation == nil { early = result }
                defer { self.continuation = nil }
                return (self.continuation, self.task)
            }
            guard let continuation else { return }
            if case .failure = result { task?.cancel() }
            continuation.resume(with: result)
        }
    }
}
