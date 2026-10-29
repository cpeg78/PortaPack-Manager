import AVFoundation
import Foundation
import Speech
import Testing
@testable import PortaPackManager

@Suite("Flugfunk – Abschrift: Vorverarbeitung")
struct AirbandSpeechAudioTests {
    private func tone(_ hz: Double, seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / 16_000)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot()
    }

    @Test("Sprachband: 1 kHz bleibt, 100 Hz und 6 kHz fallen weg")
    func bandpass() {
        let pass = AirbandSpeechAudio.bandpass(tone(1_000, seconds: 1))
        let low = AirbandSpeechAudio.bandpass(tone(100, seconds: 1))
        let high = AirbandSpeechAudio.bandpass(tone(6_000, seconds: 1))
        // Einschwingen überspringen.
        let a = rms(pass[4000...]), b = rms(low[4000...]), c = rms(high[4000...])
        #expect(a > 0.18)
        #expect(b < a / 20, "100 Hz: \(b)")
        #expect(c < a / 20, "6 kHz: \(c)")
    }

    @Test("Pausen und Rauschen am Anfang und Ende werden abgeschnitten, Pegel angeglichen")
    func trimAndNormalize() throws {
        let lead = AirbandVoiceTests.noise(seconds: 1.5, rms: 0.005, seed: 1)
        let speech = AirbandVoiceTests.speech(seconds: 2).map { $0 * 0.3 }
        let tail = AirbandVoiceTests.noise(seconds: 1.5, rms: 0.005, seed: 2)
        let samples = (lead + speech + tail).map { Int16(max(-1, min(1, $0)) * 32_000) }
        let prepared = try #require(AirbandSpeechAudio.prepare(samples))
        let seconds = Double(prepared.count) / 16_000
        // 2 s Sprache + höchstens 0,2 s vorne und 0,3 s hinten (und ein Rahmen Spiel).
        #expect(seconds > 1.8 && seconds < 2.6, "\(seconds) s")
        let level = rms(prepared[...])
        #expect(abs(level - AirbandSpeechAudio.targetRMS) < 0.02 || prepared.map(abs).max()! > 0.85, "RMS \(level)")
        #expect(prepared.map(abs).max()! <= AirbandSpeechAudio.peakLimit + 1e-4)
    }

    @Test("Zu kurz oder stumm: keine Erkennung")
    func tooShort() {
        #expect(AirbandSpeechAudio.prepare(AirbandVoiceTests.speech(seconds: 0.6)) == nil)
        #expect(AirbandSpeechAudio.prepare([Float](repeating: 0, count: 32_000)) == nil)
        // Lang genug, aber nach dem Abschneiden nur 0,3 s Sprache übrig.
        let short = [Float](repeating: 0, count: 16_000) + AirbandVoiceTests.speech(seconds: 0.25) + [Float](repeating: 0, count: 16_000)
        #expect(AirbandSpeechAudio.prepare(short) == nil)
    }

    @Test("Durchgehende Sprache ohne Pausen bleibt ganz")
    func continuous() throws {
        let speech = AirbandVoiceTests.speech(seconds: 1.5)
        let prepared = try #require(AirbandSpeechAudio.prepare(speech))
        #expect(prepared.count >= speech.count - 2 * AirbandSpeechAudio.frame)
    }
}

@Suite("Flugfunk – Abschrift: Nachbearbeitung")
struct AirbandTranscriptFormatterTests {
    @Test("Zahlwörter werden Ziffern, wo es eindeutig ist", arguments: [
        ("Lufthansa 4 Alpha Bravo, descend flight level eight zero.", "Lufthansa 4 Alpha Bravo, descend flight level 80."),
        ("Contact Bremen Radar 123 decimal 875.", "Contact Bremen Radar 123.875."),
        ("contact tower one one eight decimal zero zero five", "contact tower 118.005"),
        ("Wind 240 8 Knoten", "Wind 240 8 Knoten"),
        ("climb altitude two thousand five hundred feet", "climb altitude 2500 feet"),
        ("descend fife thousand", "descend 5000"),
        ("runway two", "runway 2"),
        ("you are number one", "you are number one"),
        ("Landung frei Piste zwo drei", "Landung frei Piste 23"),
        ("squawk seven seven zero zero", "squawk 7700"),
        ("QNH one zero one three, niner", "QNH 1013, niner"),
        ("Christoph 29, Landung frei", "Christoph 29, Landung frei"),
        ("decimal", "decimal"),
    ])
    func numbers(input: String, expected: String) {
        #expect(AirbandTranscriptFormatter.format(input) == expected)
    }

    private let candidates = [
        AirbandCallsign(callsign: "DLH4AB", icao: "3C6544"),
        AirbandCallsign(callsign: "BAW12", icao: "400ABC"),
        AirbandCallsign(callsign: "DEABC", icao: "3D0001"),
        AirbandCallsign(callsign: "EWG7LN", icao: "3C1234"),
    ]

    @Test("Rufzeichen aus ADS-B im Text finden", arguments: [
        ("Lufthansa 4 Alpha Bravo, descend flight level 80", "DLH4AB"),
        ("lufthansa four alpha bravo contact radar", "DLH4AB"),
        ("Lufthansa 4AB, roger", "DLH4AB"),
        ("Speedbird one two, cleared to land", "BAW12"),
        ("Eurowings seven lima november", "EWG7LN"),
        ("Delta Echo Alpha Bravo Charlie, Piste 23", "DEABC"),
        ("Delta Bravo Charlie, Landung frei", "DEABC"),
        // Hörfehler im Rufnamen, wie sie die Erkennung bei der Messung lieferte.
        ("Speedbud 12 Contact Breman Radar 123 decimal 875.", "BAW12"),
        ("Speed Bid 12 contact Bremen Radar", "BAW12"),
        ("Eurowing 7 Lima, November, cleared to land runway 23", "EWG7LN"),
    ])
    func callsignFound(text: String, expected: String) {
        #expect(AirbandTranscriptFormatter.matchCallsign(in: text, candidates: candidates)?.callsign == expected)
    }

    @Test("Nichts erfinden: ähnliche oder unvollständige Rufzeichen zählen nicht", arguments: [
        "Lufthansa 4 Alpha Charlie, descend",
        "Lufthansa, good day",
        "Delta",
        "Speedbird one three",
        "contact Bremen radar 123.875",
        "Speedbud 21, contact radar",
    ])
    func callsignNotFound(text: String) {
        #expect(AirbandTranscriptFormatter.matchCallsign(in: text, candidates: candidates) == nil)
    }

    @Test("Sprechweise der Rufzeichen und Hinweisliste")
    func spokenForms() {
        #expect(AirbandPhraseology.spokenForms(of: "DLH4AB") == ["Lufthansa four alpha bravo", "Lufthansa 4AB"])
        #expect(AirbandPhraseology.spokenForms(of: "DEABC") == ["Delta Echo Alpha Bravo Charlie"])
        #expect(AirbandPhraseology.spokenForms(of: "XYZ12") == ["x-ray yankee zulu one two"])
        let context = AirbandPhraseology.contextualStrings(callsigns: candidates, channelNames: ["Bremen Radar"], language: "en")
        #expect(context.count <= 100)
        #expect(context.first == "Lufthansa four alpha bravo")
        #expect(context.contains("Bremen Radar"))
        #expect(context.contains("squawk"))
        #expect(Set(context.map { $0.lowercased() }).count == context.count)
        let german = AirbandPhraseology.contextualStrings(callsigns: [], channelNames: [], language: "de")
        #expect(german.contains("Rollhalt"))
        #expect(!german.contains("wilco"))
    }

    @Test("Wortlisten ohne Doppel (Set-/Dictionary-Literale stürzen sonst ab)")
    func tables() {
        #expect(AirbandPhraseology.icaoLetters.count == 26)
        #expect(AirbandPhraseology.digitWords["niner"] == "9")
        #expect(AirbandPhraseology.telephonyPrefixes["speedbird"] == "BAW")
        #expect(AirbandPhraseology.telephonyPrefixes["airfrance"] == "AFR")
    }
}

/// Erkenner für die Tests: Text und Zuversicht je Sprache, zählt gleichzeitige Aufrufe.
private actor FakeRecognizerState {
    var calls: [(language: String, context: [String])] = []
    var running = 0
    var maxRunning = 0
    func begin(_ language: String, _ context: [String]) { calls.append((language, context)); running += 1; maxRunning = max(maxRunning, running) }
    func end() { running -= 1 }
}

private struct FakeRecognizer: AirbandSpeechRecognizing {
    var answers: [String: AirbandRecognition?]
    var delay: Duration = .milliseconds(5)
    var error: AirbandSpeechError?
    let state = FakeRecognizerState()

    func recognize(_ samples: [Float], language: String, context: [String]) async throws -> AirbandRecognition? {
        await state.begin(language, context)
        try? await Task.sleep(for: delay)
        await state.end()
        if let error { throw error }
        return answers[language] ?? nil
    }
}

private actor Delivered {
    var results: [AirbandTranscriptResult] = []
    func add(_ result: AirbandTranscriptResult) { results.append(result) }
}

@Suite("Flugfunk – Abschrift: Warteschlange")
struct AirbandTranscriptionQueueTests {
    private func job(_ seconds: Double = 2, languages: [String] = ["en"], callsigns: [AirbandCallsign] = []) -> AirbandTranscriptJob {
        let samples = AirbandVoiceTests.speech(seconds: seconds).map { Int16($0 * 32_000) }
        return AirbandTranscriptJob(id: UUID(), samples: samples, channelName: "Turm", callsigns: callsigns, languages: languages)
    }

    @Test("Automatisch: beide Sprachen, die höhere Zuversicht gewinnt; Rufzeichen wird zugeordnet")
    func bestLanguage() async {
        let fake = FakeRecognizer(answers: [
            "en": AirbandRecognition(text: "Christoph two nine, landing", confidence: 0.42, language: "en"),
            "de": AirbandRecognition(text: "Christoph 29, Landung frei Piste 23", confidence: 0.88, language: "de"),
        ])
        let delivered = Delivered()
        let queue = AirbandTranscriptionQueue(deliver: { await delivered.add($0) })
        await queue.setRecognizer(fake)
        await queue.setPaused(false)
        let item = job(languages: ["en", "de"], callsigns: [AirbandCallsign(callsign: "CHX29", icao: "3DD29A")])
        await queue.enqueue(item)
        await queue.waitUntilIdle()
        let results = await delivered.results
        #expect(results.count == 1)
        #expect(results.first?.id == item.id)
        #expect(results.first?.language == "de")
        #expect(results.first?.text == "Christoph 29, Landung frei Piste 23")
        #expect(results.first?.callsign?.icao == "3DD29A")
        let calls = await fake.state.calls
        #expect(calls.map(\.language) == ["en", "de"])
        // Hinweise: Rufzeichen zuerst, dann Kanalname, dann Sprechgruppen der Sprache.
        #expect(calls.first?.context.first == "Christoph two nine")
        #expect(calls.first?.context.contains("Turm") == true)
        #expect(calls.last?.context.contains("Rollhalt") == true)
    }

    @Test("Rückstau begrenzt: älteste fallen weg, höchstens eine Erkennung zugleich")
    func backlog() async {
        let fake = FakeRecognizer(answers: ["en": AirbandRecognition(text: "roger", confidence: 0.9, language: "en")],
                                  delay: .milliseconds(20))
        let delivered = Delivered()
        let queue = AirbandTranscriptionQueue(limit: 3, deliver: { await delivered.add($0) })
        await queue.setRecognizer(fake)
        // Pausiert (Vorgabe): nichts läuft.
        let jobs = (0..<5).map { _ in job() }
        for item in jobs { await queue.enqueue(item) }
        var stats = await queue.stats
        #expect(stats.pending == 3)
        #expect(stats.dropped == 2)
        #expect(stats.pendingIDs == jobs.suffix(3).map(\.id))
        #expect(await fake.state.calls.isEmpty)
        await queue.setPaused(false)
        // Während es läuft, kommt Neues dazu.
        await queue.enqueue(jobs[0])
        await queue.waitUntilIdle()
        stats = await queue.stats
        #expect(stats.done == 4)
        #expect(stats.pending == 0)
        #expect(!stats.busy)
        #expect(await delivered.results.map(\.id) == jobs.suffix(3).map(\.id) + [jobs[0].id])
        #expect(await fake.state.maxRunning == 1)
    }

    @Test("Zu kurz: nicht erkennen; leeres Ergebnis und Fehler werden gezählt")
    func skippedEmptyFailed() async {
        let delivered = Delivered()
        let empty = FakeRecognizer(answers: ["en": nil])
        let queue = AirbandTranscriptionQueue(deliver: { await delivered.add($0) })
        await queue.setRecognizer(empty)
        await queue.setPaused(false)
        await queue.enqueue(job(0.5))
        await queue.enqueue(job())
        await queue.waitUntilIdle()
        var stats = await queue.stats
        #expect(stats.skipped == 1)
        #expect(stats.empty == 1)
        #expect(await empty.state.calls.count == 1)
        let failing = FakeRecognizer(answers: [:], error: .notAuthorized)
        await queue.setRecognizer(failing)
        await queue.enqueue(job())
        await queue.waitUntilIdle()
        stats = await queue.stats
        #expect(stats.failed == 1)
        #expect(stats.lastError == AirbandSpeechError.notAuthorized.localizedDescription)
        #expect(await delivered.results.isEmpty)
    }

    @Test("Pause hält an, Entfernen nimmt wartende Sprüche heraus")
    func pauseAndRemove() async {
        let fake = FakeRecognizer(answers: ["en": AirbandRecognition(text: "wilco", confidence: 0.8, language: "en")])
        let delivered = Delivered()
        let queue = AirbandTranscriptionQueue(deliver: { await delivered.add($0) })
        await queue.setRecognizer(fake)
        let a = job(), b = job(), c = job()
        for item in [a, b, c] { await queue.enqueue(item) }
        await queue.remove(b.id)
        #expect(await queue.stats.pendingIDs == [a.id, c.id])
        await queue.setPaused(false)
        await queue.waitUntilIdle()
        #expect(await delivered.results.map(\.id) == [a.id, c.id])
        await queue.setPaused(true)
        await queue.enqueue(job())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await delivered.results.count == 2)
        await queue.removeAll()
        #expect(await queue.stats.pending == 0)
    }
}

@Suite("Flugfunk – Abschrift: Datenbank")
struct AirbandTranscriptDatabaseTests {
    @Test("Abschrift mit Rufzeichen speichern, Volltext und Rufzeichen suchen")
    func storeAndSearch() async throws {
        let db = TestDatabase()
        defer { db.remove() }
        let log = AirbandLog(folder: db.folder.appendingPathComponent("Flugfunk"), database: db.database)
        let a = AirbandTransmission(start: Date(timeIntervalSince1970: 1_000), duration: 3, index: 600, name: "Radar", peakDB: 20)
        let b = AirbandTransmission(start: Date(timeIntervalSince1970: 2_000), duration: 2, index: 601, name: "Turm", peakDB: 15)
        log.insert([a, b])
        log.setTranscript(a.id, text: "Lufthansa 4 Alpha Bravo, contact Bremen Radar 123 decimal 875", language: "en", confidence: 0.74,
                          callsign: AirbandCallsign(callsign: "DLH4AB", icao: "3C6544"))
        log.setTranscript(b.id, text: "Christoph 29, Landung frei Piste 23", language: "de", confidence: 0.88)
        await db.database.flush()
        let stored = try #require(log.load().first { $0.id == a.id })
        #expect(stored.callsign == "DLH4AB")
        #expect(stored.aircraftICAO == "3C6544")
        #expect(stored.transcriptConfidence == 0.74)
        #expect(await log.search(userInput: "bremen rad").map(\.id) == [a.id])
        #expect(await log.search(userInput: "piste 23").map(\.id) == [b.id])
        #expect(await log.search(userInput: "123.875").map(\.id) == [a.id])
        #expect(await log.search(userInput: "DLH4AB").map(\.id) == [a.id])
        #expect(await log.search(userInput: "\"; DROP TABLE x --").isEmpty)
        #expect(await log.search(userInput: "  ").isEmpty)
    }

    @Test("Suchtext wird zu einer sicheren FTS5-Abfrage")
    func ftsQuery() {
        #expect(AirbandLog.ftsQuery("118.005 tow") == "\"118.005\" \"tow\"*")
        #expect(AirbandLog.ftsQuery("say \"again\"") == "\"say\" \"again\"*")
        #expect(AirbandLog.ftsQuery(" - * ") == "")
    }

    @Test("Schema 1 → 2: Rufzeichen-Spalten kommen dazu, Einträge bleiben")
    func migration() throws {
        let db = TestDatabase()
        defer { db.remove() }
        let url = db.folder.appendingPathComponent("alt.sqlite")
        do {
            let old = try SQLiteConnection(url: url)
            try old.execute(ArchiveDatabase.migrations[0])
            try old.setUserVersion(1)
            try old.run("INSERT INTO airband_transmissions (uuid, start, duration, channel, transcript) VALUES ('x', 1, 2, 3, 'roger')")
        }
        let database = ArchiveDatabase(url: url)
        let (version, columns, rows) = try database.sync { conn in
            (conn.userVersion,
             try conn.query("PRAGMA table_info(airband_transmissions)") { $0.text(1) ?? "" },
             try conn.recentTransmissions(limit: 10))
        }
        #expect(version == ArchiveDatabase.schemaVersion)
        #expect(columns.contains("transcript_callsign"))
        #expect(columns.contains("transcript_icao"))
        #expect(columns.contains("transcript_text"))
        #expect(rows.count == 1)
        #expect(rows.first?.transcript == "roger")
        #expect(rows.first?.callsign == nil)
        // Der neu aufgebaute Volltextindex kennt die alte Abschrift.
        #expect(try database.sync { try $0.searchTransmissions("roger", limit: 5) }.count == 1)
    }

    @Test("Rufzeichen der letzten ADS-B-Sichtungen als Hinweise")
    func recentCallsigns() async throws {
        let db = TestDatabase()
        defer { db.remove() }
        let now = Date().timeIntervalSince1970
        try db.database.sync { conn in
            for (sid, key, name, last) in [("a", "3C6544", "DLH4AB", now - 60), ("b", "400ABC", "BAW12 ", now - 600),
                                           ("c", "3C1234", "EWG7LN", now - 5 * 3600), ("d", "3D0001", "", now - 30)] {
                try conn.run("INSERT INTO sightings (kind, sid, key, day, name, first, last) VALUES (0, ?, ?, '2026-10-29', ?, ?, ?)",
                             [sid, key, name, last - 100, last])
            }
        }
        let log = AirbandLog(folder: db.folder.appendingPathComponent("Flugfunk"), database: db.database)
        let signs = await log.recentCallsigns(hours: 3)
        #expect(signs == [AirbandCallsign(callsign: "DLH4AB", icao: "3C6544"), AirbandCallsign(callsign: "BAW12", icao: "400ABC")])
    }

    @Test("Fernzugriff: Text aufbereitet, Rohtext und Rufzeichen dabei")
    @MainActor
    func remote() {
        var item = AirbandTransmission(start: Date(timeIntervalSince1970: 10), duration: 2.04, index: 600, name: "Radar", peakDB: 12.34)
        item.transcript = "descend flight level eight zero"
        item.transcriptConfidence = 0.734
        item.callsign = "DLH4AB"
        let state = RemoteAirband.transmission(item, name: "Radar")
        #expect(state.text == "descend flight level 80")
        #expect(state.raw == "descend flight level eight zero")
        #expect(state.conf == 0.73)
        #expect(state.cs == "DLH4AB")
        #expect(state.dur == 2)
    }
}

/// Echte Erkennung (macOS 26+, nur wenn das englische Modell schon installiert
/// ist – lädt nichts nach, fragt nach nichts). Testton mit `say`.
@Suite("Flugfunk – Abschrift: echte Erkennung", .serialized)
struct AirbandRealRecognitionTests {
    static func synthesize(_ text: String, voice: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stt-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func englishInstalled() async -> Bool {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier.hasPrefix("en_US") || $0.identifier == "en-US" }
    }

    /// „Lufthansa“ erkannte die Erkennung mit Daniels Stimme als „Left hands are“ –
    /// Condor klappt mit allen drei englischen Stimmen (Messung 29.10.2026).
    @Test("Condor-Spruch wird erkannt, aufbereitet und zugeordnet")
    func condor() async throws {
        guard #available(macOS 26, *), await Self.englishInstalled() else { return }
        let audio = try Self.synthesize("Condor one six two, hold short runway two five, QNH one zero one three", voice: "Daniel")
        let samples = audio.map { Int16(max(-1, min(1, $0 * 0.6)) * 32_000) }
        let delivered = Delivered()
        let queue = AirbandTranscriptionQueue(deliver: { await delivered.add($0) })
        await queue.setRecognizer(AnalyzerSpeechRecognizer())
        await queue.setPaused(false)
        await queue.enqueue(AirbandTranscriptJob(id: UUID(), samples: samples, channelName: "Bremen Radar",
                                                 callsigns: [AirbandCallsign(callsign: "CFG162", icao: "3C4B26"),
                                                             AirbandCallsign(callsign: "CFG126", icao: "3C4B27")],
                                                 languages: ["en"]))
        await queue.waitUntilIdle()
        let result = try #require(await delivered.results.first)
        let text = AirbandTranscriptFormatter.format(result.text)
        #expect(result.callsign?.icao == "3C4B26", "erkannt: \(result.text) (\(result.confidence ?? -1))")
        #expect(text.contains("25") && text.contains("1013"), "erkannt: \(text)")
        #expect((result.confidence ?? 0) > 0.3)
    }
}
