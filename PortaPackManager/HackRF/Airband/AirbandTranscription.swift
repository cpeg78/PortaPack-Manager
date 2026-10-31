import Foundation
import Observation
import OSLog
import Speech

/// Ein Spruch, der auf die Erkennung wartet. Der Ton bleibt nur im Speicher und
/// wird nach der Erkennung verworfen.
struct AirbandTranscriptJob: Sendable {
    var id: UUID
    var samples: [Int16]
    var channelName: String
    /// Rufzeichen der Flugzeuge in Reichweite (Hinweise und Zuordnung).
    var callsigns: [AirbandCallsign]
    /// Zu versuchende Sprachen („en“, „de“); mehrere → höchste Zuversicht gewinnt.
    var languages: [String]
}

/// Ergebnis für einen Spruch: Rohtext, Sprache, Zuversicht, erkanntes Rufzeichen.
struct AirbandTranscriptResult: Sendable, Equatable {
    var id: UUID
    var text: String
    var language: String
    var confidence: Double?
    var callsign: AirbandCallsign?
}

/// Warteschlange der Erkennung: seriell (höchstens eine Erkennung zugleich),
/// abseits des Main Actors, Rückstau begrenzt – bei Überlast fallen die ältesten
/// Sprüche weg (`dropped`). Pausiert, solange die Funktion aus ist oder das
/// Sprachmodell noch lädt.
actor AirbandTranscriptionQueue {
    struct Stats: Sendable, Equatable {
        /// Wartende Sprüche.
        var pending = 0
        /// Gerade in der Erkennung.
        var busy = false
        /// Mit Text erkannt.
        var done = 0
        /// Erkannt, aber kein Text (Rauschen, unverständlich).
        var empty = 0
        /// Zu kurz oder stumm nach der Aufbereitung – gar nicht erst erkannt.
        var skipped = 0
        /// Bei Überlast verworfen.
        var dropped = 0
        var failed = 0
        var lastError: String?
        /// Wartende Sprüche (für „wird erkannt …“ im Verlauf).
        var pendingIDs: [UUID] = []
        var currentID: UUID?
    }

    static let defaultLimit = 12

    private let limit: Int
    private var recognizer: (any AirbandSpeechRecognizing)?
    private var pending: [AirbandTranscriptJob] = []
    private var paused = true
    private var worker: Task<Void, Never>?
    private(set) var stats = Stats()
    private let deliver: @Sendable (AirbandTranscriptResult) async -> Void
    private let onStats: @Sendable (Stats) -> Void

    init(limit: Int = AirbandTranscriptionQueue.defaultLimit,
         deliver: @escaping @Sendable (AirbandTranscriptResult) async -> Void,
         onStats: @escaping @Sendable (Stats) -> Void = { _ in }) {
        self.limit = limit
        self.deliver = deliver
        self.onStats = onStats
    }

    func setRecognizer(_ recognizer: (any AirbandSpeechRecognizing)?) {
        self.recognizer = recognizer
        startWorker()
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        startWorker()
        publish()
    }

    func enqueue(_ job: AirbandTranscriptJob) {
        pending.append(job)
        if pending.count > limit {
            let overflow = pending.count - limit
            pending.removeFirst(overflow)
            stats.dropped += overflow
        }
        publish()
        startWorker()
    }

    /// Verwirft alle wartenden Sprüche (z. B. beim Leeren des Verlaufs).
    func removeAll() {
        pending = []
        publish()
    }

    func remove(_ id: UUID) {
        pending.removeAll { $0.id == id }
        publish()
    }

    /// Für Tests: wartet, bis nichts mehr läuft und – sofern nicht pausiert – nichts mehr wartet.
    func waitUntilIdle() async {
        while worker != nil || (!paused && recognizer != nil && !pending.isEmpty) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func publish() {
        stats.pending = pending.count
        stats.pendingIDs = pending.map(\.id)
        onStats(stats)
    }

    private func startWorker() {
        guard worker == nil, !paused, recognizer != nil, !pending.isEmpty else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while !paused, let recognizer, !pending.isEmpty {
            let job = pending.removeFirst()
            stats.busy = true
            stats.currentID = job.id
            publish()
            let outcome = await Self.run(job, recognizer: recognizer)
            switch outcome {
            case .skipped: stats.skipped += 1
            case .empty: stats.empty += 1
            case .failed(let message):
                stats.failed += 1
                stats.lastError = message
            case .recognized(let result):
                stats.done += 1
                stats.lastError = nil
                await deliver(result)
            }
            stats.busy = false
            stats.currentID = nil
            publish()
        }
        worker = nil
        // Inzwischen Neues gekommen (oder fortgesetzt)?
        startWorker()
    }

    enum Outcome: Sendable, Equatable {
        case skipped, empty, failed(String), recognized(AirbandTranscriptResult)
    }

    /// Aufbereiten, je Sprache erkennen, beste Zuversicht nehmen, Rufzeichen
    /// zuordnen. Läuft auf dem allgemeinen Pool, nicht auf dem Actor.
    @concurrent
    nonisolated static func run(_ job: AirbandTranscriptJob, recognizer: any AirbandSpeechRecognizing) async -> Outcome {
        guard let audio = AirbandSpeechAudio.prepare(job.samples) else { return .skipped }
        var best: AirbandRecognition?
        var lastError: Error?
        for language in job.languages {
            let context = AirbandPhraseology.contextualStrings(
                callsigns: job.callsigns, channelNames: job.channelName.isEmpty ? [] : [job.channelName], language: language)
            do {
                guard let result = try await recognizer.recognize(audio, language: language, context: context),
                      !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if best.map({ AirbandPhraseology.languageScore(result) > AirbandPhraseology.languageScore($0) }) ?? true { best = result }
            } catch {
                lastError = error
            }
        }
        guard let best else {
            if let lastError { return .failed(lastError.localizedDescription) }
            return .empty
        }
        let callsign = AirbandTranscriptFormatter.matchCallsign(in: best.text, candidates: job.callsigns)
        return .recognized(AirbandTranscriptResult(id: job.id, text: best.text, language: best.language,
                                                   confidence: best.confidence, callsign: callsign))
    }
}

/// Spracherkennung der Flugfunk-Seite: Schalter, Sprache, Bereitschaft (Modell,
/// Erlaubnis) und die Warteschlange. Ergebnisse gehen per `setTranscript` in die
/// Datenbank und über `onResult` in den angezeigten Verlauf.
///
/// - macOS 26+: `SpeechAnalyzer`/`SpeechTranscriber`, Modelle über `AssetInventory`
///   (einmaliger Download vom System, danach ohne Netz). Braucht keine Erlaubnis.
/// - macOS 15–25: `SFSpeechRecognizer` mit `requiresOnDeviceRecognition`, nur wenn
///   die Sprache das auf diesem Mac kann; fragt beim Einschalten nach der Erlaubnis.
@MainActor
@Observable
final class AirbandTranscription {
    enum Status: Equatable {
        case off
        case preparing
        /// Sprachmodell wird geladen (0…1).
        case downloading(Double)
        case ready
        case unsupported(String)
        case denied
        case failed(String)
    }

    static let enabledKey = "airbandTranscribe"
    static let languageKey = "airbandTranscribeLanguage"
    static let engineKey = "airbandTranscribeEngine"
    static let whisperModelKey = "airbandWhisperModel"

    /// Welche Erkennung: Apples eingebaute oder Whisper (whisper.cpp, Modell wählbar).
    enum Engine: String, CaseIterable, Identifiable, Sendable {
        case apple, whisper
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apple: String(localized: "Apple (eingebaut)")
            case .whisper: String(localized: "Whisper")
            }
        }
    }
    static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Spracherkennung")

    /// Schalter „Sprüche in Text umwandeln“ (Vorgabe aus).
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? prepare(userInitiated: true) : turnOff()
        }
    }

    var language: AirbandSpeechLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
            if enabled { prepare(userInitiated: true) }
        }
    }

    var engine: Engine {
        didSet {
            guard engine != oldValue else { return }
            UserDefaults.standard.set(engine.rawValue, forKey: Self.engineKey)
            if enabled { prepare(userInitiated: true) }
        }
    }

    var whisperModel: WhisperModel {
        didSet {
            guard whisperModel != oldValue else { return }
            UserDefaults.standard.set(whisperModel.rawValue, forKey: Self.whisperModelKey)
            if enabled, engine == .whisper { prepare(userInitiated: true) }
        }
    }

    /// Geladene Whisper-Modelle (für die Liste; nach Download/Löschen neu gelesen).
    private(set) var installedWhisperModels: Set<WhisperModel> = []

    func refreshInstalledModels() {
        installedWhisperModels = Set(WhisperModel.allCases.filter(WhisperModelStore.isInstalled))
    }

    /// Ein Modell löschen (nicht das gerade benutzte, solange die Erkennung läuft).
    func deleteWhisperModel(_ model: WhisperModel) {
        guard !(enabled && engine == .whisper && model == whisperModel) else { return }
        WhisperModelStore.delete(model)
        refreshInstalledModels()
    }

    private(set) var status: Status = .off
    private(set) var stats = AirbandTranscriptionQueue.Stats()
    /// Welche Erkennung arbeitet (für die Statuszeile).
    private(set) var engineName = ""

    /// Ton der Sprüche wird gebraucht (Empfänger soll ihn mitliefern).
    var wantsAudio: Bool {
        guard enabled else { return false }
        switch status {
        case .preparing, .downloading, .ready: return true
        default: return false
        }
    }

    /// Wartet (oder läuft gerade) auf die Erkennung.
    func isPending(_ id: UUID) -> Bool { stats.currentID == id || stats.pendingIDs.contains(id) }

    /// Neues Ergebnis (Main Actor) – das Model trägt es in den Verlauf ein.
    @ObservationIgnored var onResult: ((AirbandTranscriptResult) -> Void)?
    /// `wantsAudio` hat sich geändert.
    @ObservationIgnored var onWantsAudioChange: ((Bool) -> Void)?

    @ObservationIgnored private var queue: AirbandTranscriptionQueue!
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var lastWantsAudio = false

    init(log: AirbandLog) {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        language = AirbandSpeechLanguage(rawValue: UserDefaults.standard.string(forKey: Self.languageKey) ?? "") ?? .english
        engine = Engine(rawValue: UserDefaults.standard.string(forKey: Self.engineKey) ?? "") ?? .apple
        whisperModel = WhisperModel(rawValue: UserDefaults.standard.string(forKey: Self.whisperModelKey) ?? "") ?? .standard
        let store = log
        queue = AirbandTranscriptionQueue(
            deliver: { [weak self] result in
                store.setTranscript(result.id, text: result.text, language: result.language,
                                    confidence: result.confidence, callsign: result.callsign)
                await MainActor.run { self?.onResult?(result) }
            },
            onStats: { [weak self] stats in
                Task { @MainActor in self?.stats = stats }
            })
        // Nach dem Start der App wieder bereit machen – ohne Dialoge (Erlaubnis
        // fragt nur der Schalter) und nie im Testwirt.
        if enabled, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            prepare(userInitiated: false)
        }
    }

    /// Spruch einreihen (nur, wenn die Funktion an ist).
    func enqueue(_ transmission: AirbandTransmission, samples: [Int16], callsigns: [AirbandCallsign]) {
        guard wantsAudio, !samples.isEmpty else { return }
        let job = AirbandTranscriptJob(id: transmission.id, samples: samples, channelName: transmission.name,
                                       callsigns: callsigns, languages: language.codes)
        let queue = queue!
        Task { await queue.enqueue(job) }
    }

    func cancel(_ id: UUID) {
        let queue = queue!
        Task { await queue.remove(id) }
    }

    func cancelAll() {
        let queue = queue!
        Task { await queue.removeAll() }
    }

    // MARK: Bereitschaft

    private func setStatus(_ new: Status) {
        status = new
        let wants = wantsAudio
        if wants != lastWantsAudio {
            lastWantsAudio = wants
            onWantsAudioChange?(wants)
        }
    }

    private func turnOff() {
        prepareTask?.cancel()
        prepareTask = nil
        let queue = queue!
        Task { await queue.setPaused(true) }
        setStatus(.off)
    }

    /// Prüft Erkennung, Sprache, Erlaubnis und Modelle; danach läuft die Warteschlange.
    func prepare(userInitiated: Bool) {
        prepareTask?.cancel()
        let queue = queue!
        let languages = language.codes
        Task { await queue.setPaused(true) }
        setStatus(.preparing)
        if engine == .whisper {
            prepareWhisper(automatic: language == .automatic)
            return
        }
        prepareTask = Task { [weak self] in
            if #available(macOS 26, *), AnalyzerSpeechRecognizer.isAvailable {
                do {
                    try await AnalyzerSpeechRecognizer.prepare(languages: languages) { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.enabled else { return }
                            if case .ready = self.status { return }
                            self.setStatus(.downloading(fraction))
                        }
                    }
                    guard let self, !Task.isCancelled, self.enabled else { return }
                    self.engineName = "SpeechAnalyzer"
                    await queue.setRecognizer(AnalyzerSpeechRecognizer())
                    await queue.setPaused(false)
                    self.setStatus(.ready)
                    Self.log.notice("Spracherkennung bereit (SpeechAnalyzer, \(languages.joined(separator: "+"), privacy: .public))")
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    Self.log.error("Spracherkennung nicht bereit: \(String(describing: error), privacy: .public)")
                    if let speech = error as? AirbandSpeechError, case .unsupported(let name) = speech {
                        self.setStatus(.unsupported(name))
                    } else {
                        self.setStatus(.failed(error.localizedDescription))
                    }
                }
                return
            }
            // macOS 15–25 (oder kein SpeechTranscriber): SFSpeechRecognizer auf dem Gerät.
            let missing = languages.filter { !LegacySpeechRecognizer.supportsOnDevice($0) }
            guard let self, !Task.isCancelled else { return }
            if missing.count == languages.count {
                self.setStatus(.unsupported(missing.map(AirbandSpeechText.languageName).joined(separator: ", ")))
                return
            }
            var authorization = LegacySpeechRecognizer.authorization
            if authorization == .notDetermined, userInitiated {
                authorization = await LegacySpeechRecognizer.requestAuthorization()
            }
            guard !Task.isCancelled, self.enabled else { return }
            guard authorization == .authorized else {
                self.setStatus(.denied)
                return
            }
            self.engineName = "SFSpeechRecognizer"
            await queue.setRecognizer(LegacyRecognizerFilter(languages: Set(languages.filter { !missing.contains($0) })))
            await queue.setPaused(false)
            self.setStatus(.ready)
        }
    }

    /// Whisper: Modell bei Bedarf laden (Prüfsumme), dann den Kontext abseits des
    /// Main Actor aufbauen (dauert ein paar Sekunden, lädt das Modell in Metal).
    private func prepareWhisper(automatic: Bool) {
        let queue = queue!
        let model = whisperModel
        prepareTask = Task { [weak self] in
            do {
                if !WhisperModelStore.isInstalled(model) {
                    Self.log.notice("Whisper-Modell wird geladen: \(model.file, privacy: .public)")
                    try await WhisperModelStore.download(model) { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.enabled, self.engine == .whisper else { return }
                            if case .ready = self.status { return }
                            self.setStatus(.downloading(fraction))
                        }
                    }
                    self?.refreshInstalledModels()
                }
                try Task.checkCancellation()
                guard let self, self.enabled else { return }
                self.setStatus(.preparing)
                let recognizer = try await Task.detached(priority: .userInitiated) {
                    try WhisperSpeechRecognizer(model: WhisperModelStore.url(for: model), automatic: automatic)
                }.value
                guard !Task.isCancelled, self.enabled, self.engine == .whisper, self.whisperModel == model else { return }
                self.engineName = "Whisper (\(model.title))"
                await queue.setRecognizer(recognizer)
                await queue.setPaused(false)
                self.setStatus(.ready)
                Self.log.notice("Spracherkennung bereit (Whisper \(model.file, privacy: .public))")
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                Self.log.error("Whisper nicht bereit: \(String(describing: error), privacy: .public)")
                self.setStatus(.failed(error.localizedDescription))
            }
        }
    }

    /// Text für die Statuszeile unter dem Schalter.
    var statusText: String? {
        switch status {
        case .off: nil
        case .preparing: String(localized: "Spracherkennung wird vorbereitet …")
        case .downloading(let fraction):
            String(localized: "Sprachmodell wird geladen … \(Int((fraction * 100).rounded())) %")
        case .ready: nil
        case .unsupported(let language):
            String(localized: "Nicht unterstützt: Für \(language) gibt es auf diesem Mac keine Spracherkennung ohne Internet.")
        case .denied:
            String(localized: "Keine Erlaubnis: Erlaube der App die Spracherkennung in den Systemeinstellungen ▸ Datenschutz & Sicherheit ▸ Spracherkennung und schalte die Funktion dann neu ein.")
        case .failed(let message):
            String(localized: "Spracherkennung nicht bereit: \(message)")
        }
    }

    var statusIsProblem: Bool {
        switch status {
        case .unsupported, .denied, .failed: true
        default: false
        }
    }
}

/// Lässt Sprachen aus, die der alte Erkenner nicht auf dem Gerät kann
/// (statt jeden Spruch mit einem Fehler enden zu lassen).
private struct LegacyRecognizerFilter: AirbandSpeechRecognizing {
    let languages: Set<String>
    private let base = LegacySpeechRecognizer()

    func recognize(_ samples: [Float], language: String, context: [String]) async throws -> AirbandRecognition? {
        guard languages.contains(language) else { return nil }
        return try await base.recognize(samples, language: language, context: context)
    }
}
