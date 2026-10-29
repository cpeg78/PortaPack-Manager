import AVFoundation
import Foundation

/// Verlauf der Übertragungen in der Archiv-Datenbank (Tabelle
/// `airband_transmissions` samt Volltextindex für spätere Abschriften; bis
/// 29.10.2026 `Flugfunk/Verlauf.json`) und Mitschnitte (AAC in `.m4a`, 16 kHz
/// mono, 24 kbit/s – rund ein Zehntel von WAV; WAV nur als Rückfall) unter
/// Application Support. Bleibt auf dem Mac – nichts davon geht ins Netz.
///
/// Die Seite zeigt die letzten `limit` Einträge; nur deren Mitschnitte bleiben.
/// Ältere Einträge bleiben in der Datenbank (Aufbewahrung wie die übrigen Archive).
struct AirbandLog: Sendable {
    static let limit = 1000

    let folder: URL
    let database: ArchiveDatabase
    var recordingsFolder: URL { folder.appendingPathComponent("Mitschnitte", isDirectory: true) }

    static let standard = AirbandLog(folder: AppFiles.support.appendingPathComponent("Flugfunk", isDirectory: true),
                                     database: .shared)

    init(folder: URL, database: ArchiveDatabase) {
        self.folder = folder
        self.database = database
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Mitschnitte", isDirectory: true),
                                                 withIntermediateDirectories: true)
    }

    /// Die letzten `limit` Einträge, neueste zuerst (synchron, abseits des Main Actors).
    func load() -> [AirbandTransmission] {
        (try? database.sync { try $0.recentTransmissions(limit: Self.limit) }) ?? []
    }

    /// Die letzten `limit` Einträge, asynchron.
    func loadRecent() async -> [AirbandTransmission] {
        (try? await database.read { try $0.recentTransmissions(limit: Self.limit) }) ?? []
    }

    /// Neue Einträge sichern (eine Transaktion, abseits des Main Actors).
    func insert(_ items: [AirbandTransmission]) {
        guard !items.isEmpty else { return }
        database.write("Flugfunk-Verlauf sichern") { try $0.insertTransmissions(items) }
    }

    /// Hängt neue Einträge vorne an die angezeigte Liste, kürzt auf `limit` und
    /// löscht die Mitschnitte der herausgefallenen Einträge (in der Datenbank
    /// bleibt der Eintrag, ohne Mitschnitt).
    func merge(_ new: [AirbandTransmission], into list: [AirbandTransmission]) -> [AirbandTransmission] {
        var result = new.sorted { $0.start > $1.start } + list
        if result.count > Self.limit {
            let dropped = result[Self.limit...].filter { $0.recording != nil }
            for item in dropped { deleteRecording(of: item) }
            let ids = dropped.map(\.id.uuidString)
            if !ids.isEmpty {
                database.write("Mitschnitte austragen") { db in
                    for id in ids { try db.run("UPDATE airband_transmissions SET recording = NULL WHERE uuid = ?", [id]) }
                }
            }
            result.removeLast(result.count - Self.limit)
        }
        return result
    }

    /// Einen Eintrag samt Mitschnitt löschen.
    func delete(_ item: AirbandTransmission) {
        deleteRecording(of: item)
        let id = item.id.uuidString
        database.write("Flugfunk-Eintrag löschen") { try $0.run("DELETE FROM airband_transmissions WHERE uuid = ?", [id]) }
    }

    /// Volltextsuche in den Abschriften (FTS5-Syntax, z. B. `"runway 23"` oder `tower*`).
    func search(_ match: String, limit: Int = 200) async -> [AirbandTransmission] {
        (try? await database.read { try $0.searchTransmissions(match, limit: limit) }) ?? []
    }

    /// Suche aus einem Suchfeld: Jedes Wort muss vorkommen, das letzte auch als
    /// Wortanfang („tow“ findet „tower“). Sieht die Eingabe wie ein Rufzeichen aus
    /// („DLH4AB“), kommen die Sprüche dazu, in denen es erkannt wurde.
    func search(userInput: String, limit: Int = 200) async -> [AirbandTransmission] {
        let input = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        let match = Self.ftsQuery(input)
        let sign = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        let looksLikeCallsign = sign.count >= 4 && sign.count <= 8 && sign.allSatisfy { $0.isLetter || $0.isNumber }
        return (try? await database.read { db -> [AirbandTransmission] in
            var result = match.isEmpty ? [] : try db.searchTransmissions(match, limit: limit)
            if looksLikeCallsign {
                let known = Set(result.map(\.id))
                result += try db.transmissions(callsign: sign, limit: limit).filter { !known.contains($0.id) }
            }
            return result
        }) ?? []
    }

    /// Freitext → FTS5-Abfrage ohne Sonderzeichen: jedes Wort in Anführungszeichen
    /// (sonst wären „118.005“ oder „-“ Syntaxfehler), das letzte als Präfix.
    static func ftsQuery(_ input: String) -> String {
        let words = input.split(whereSeparator: \.isWhitespace)
            .map { $0.filter { $0 != "\"" } }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard !words.isEmpty else { return "" }
        return words.enumerated().map { k, word in
            "\"\(word)\"" + (k == words.count - 1 ? "*" : "")
        }.joined(separator: " ")
    }

    /// Abschrift eines Eintrags setzen (Rohtext der Spracherkennung, dazu ein erkanntes Rufzeichen).
    func setTranscript(_ id: UUID, text: String?, language: String?, confidence: Double?, callsign: AirbandCallsign? = nil) {
        database.write("Abschrift sichern") {
            try $0.setTranscript(id: id, text: text, language: language, confidence: confidence,
                                 callsign: callsign?.callsign, icao: callsign?.icao)
        }
    }

    /// Rufzeichen der ADS-B-Sichtungen der letzten Stunden (Hinweise für die Erkennung).
    func recentCallsigns(hours: Double = 3, limit: Int = 60) async -> [AirbandCallsign] {
        let since = Date().addingTimeInterval(-hours * 3600)
        return (try? await database.read { try $0.recentCallsigns(since: since, limit: limit) }) ?? []
    }

    func recordingURL(_ name: String) -> URL { recordingsFolder.appendingPathComponent(name) }

    func deleteRecording(of transmission: AirbandTransmission) {
        guard let name = transmission.recording else { return }
        try? FileManager.default.removeItem(at: recordingURL(name))
    }

    /// Leert den ganzen Verlauf samt aller Mitschnitte (auch älterer Einträge).
    func deleteAll(_ list: [AirbandTransmission]) {
        for item in list { deleteRecording(of: item) }
        let folder = recordingsFolder
        database.write("Flugfunk-Verlauf leeren") { db in
            for name in try db.transmissionRecordings() {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            try db.run("DELETE FROM airband_transmissions")
        }
    }

    /// Schreibt einen Mitschnitt; liefert den Dateinamen.
    func writeRecording(_ samples: [Int16], for transmission: AirbandTransmission) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'_'HH-mm-ss"
        let base = "\(formatter.string(from: transmission.start))_\(AirbandGrid.channelName(transmission.index))"
        if Self.writeAAC(samples, rate: 16_000, to: recordingURL(base + ".m4a")) { return base + ".m4a" }
        do {
            try Self.wav(samples, rate: 16_000).write(to: recordingURL(base + ".wav"), options: .atomic)
            return base + ".wav"
        } catch {
            return nil
        }
    }

    /// AAC-LC mono über `AVAudioFile`; `false`, wenn der Kodierer nicht will.
    static func writeAAC(_ samples: [Int16], rate: Double, to url: URL) -> Bool {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        for (i, v) in samples.enumerated() { channel[i] = Float(v) / 32_768 }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24_000]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    /// RIFF/WAVE, PCM 16 Bit mono.
    static func wav(_ samples: [Int16], rate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer { append(sample) }
        }
        return data
    }
}
