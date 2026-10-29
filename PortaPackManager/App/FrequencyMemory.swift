import Foundation
import Observation
import OSLog

/// Ein Eintrag im gemeinsamen Frequenzspeicher (alle Seiten mit Frequenzfeld).
///
/// `mode` ist der Rohwert der Radio-Betriebsart (`RadioMode.rawValue`) als Text –
/// so passen später ergänzte Betriebsarten (SSB, CW …) ohne Umbau, und ein
/// unbekannter Wert (aus einer CSV-Datei) bleibt erhalten statt zu verschwinden.
/// `page` ist der Rohwert der Zielseite (`SidebarItem.rawValue`).
struct FrequencyMemoryEntry: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var frequencyHz: Int64
    var mode: String?
    var bandwidthHz: Int?
    /// Abstimmschritt des Radios (aus den alten Radio-Favoriten übernommen).
    var stepKHz: Double?
    /// Funkart: roher Name des Schnellwahl-Bandes (`ScanBand.name`, z. B. „Flugfunk“) –
    /// gespeichert unübersetzt, angezeigt über `ScanBand.title`.
    var kind: String?
    var page: String?
    var note = ""
    var group = ""
    var created: Date?

    init(id: UUID = UUID(), name: String = "", frequencyHz: Int64, mode: String? = nil, bandwidthHz: Int? = nil,
         stepKHz: Double? = nil, kind: String? = nil, page: String? = nil, note: String = "", group: String = "",
         created: Date? = nil) {
        self.id = id
        self.name = name
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.stepKHz = stepKHz
        self.kind = kind
        self.page = page
        self.note = note
        self.group = group
        self.created = created
    }

    init(mhz: Double, name: String = "", mode: String? = nil, page: SidebarItem? = nil) {
        self.init(name: name, frequencyHz: Self.hz(mhz), mode: mode, page: page?.rawValue, created: Self.now())
    }

    /// Lesen ist nachsichtig: fehlende Felder bekommen ihre Vorgabe (spätere
    /// Fassungen dürfen Felder ergänzen, ohne dass alte Dateien unlesbar werden).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        frequencyHz = try c.decode(Int64.self, forKey: .frequencyHz)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        bandwidthHz = try c.decodeIfPresent(Int.self, forKey: .bandwidthHz)
        stepKHz = try c.decodeIfPresent(Double.self, forKey: .stepKHz)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        page = try c.decodeIfPresent(String.self, forKey: .page)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created)
    }

    var mhz: Double { Double(frequencyHz) / 1e6 }

    static func hz(_ mhz: Double) -> Int64 { Int64((mhz * 1e6).rounded()) }

    /// Jetzt auf ganze Sekunden – so übersteht das Datum den Rundlauf über ISO 8601.
    static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    var sidebarItem: SidebarItem? { page.flatMap(SidebarItem.init(rawValue:)) }

    /// Betriebsart fürs Radio, falls der Rohwert eine bekannte ist.
    var radioMode: RadioMode? { mode.flatMap(FrequencyMemory.radioMode(fromStored:)) }

    /// Gleiche Frequenz (auf 10 Hz genau).
    func matches(mhz: Double) -> Bool { abs(frequencyHz - Self.hz(mhz)) <= 10 }
}

/// Gemeinsamer Frequenzspeicher als JSON-Datei in Application Support
/// (`Frequenzspeicher.json`). Löst die Radio-Favoriten ab (UserDefaults-Schlüssel
/// `radioFavorites`), die beim ersten Laden verlustfrei übernommen werden.
@MainActor
@Observable
final class FrequencyMemory {
    static let shared = FrequencyMemory(fileURL: AppFiles.support.appendingPathComponent(fileName), defaults: .standard)
    static let fileName = "Frequenzspeicher.json"
    /// Schlüssel der alten Radio-Favoriten (JSON-Text bzw. noch ältere Komma-Liste).
    static let legacyRadioKey = "radioFavorites"
    static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Frequenzspeicher")

    private struct Stored: Codable {
        var version = 1
        var entries: [FrequencyMemoryEntry]
    }

    let fileURL: URL
    private let defaults: UserDefaults
    private(set) var entries: [FrequencyMemoryEntry] = []
    /// Letzter Fehler beim Lesen oder Schreiben (für die Verwaltungsansicht).
    private(set) var error: String?

    init(fileURL: URL, defaults: UserDefaults) {
        self.fileURL = fileURL
        self.defaults = defaults
        load()
    }

    // MARK: Laden und Sichern

    private func load() {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                entries = Self.sorted(try JSONDecoder.memory.decode(Stored.self, from: data).entries)
            } catch {
                // Unlesbare Datei nicht überschreiben: beiseitelegen, leer beginnen.
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("Frequenzspeicher-unlesbar-\(stamp).json")
                try? fm.moveItem(at: fileURL, to: backup)
                self.error = String(localized: "Der Frequenzspeicher war unlesbar und wurde als „\(backup.lastPathComponent)“ beiseitegelegt.")
                Self.log.error("Frequenzspeicher unlesbar: \(error.localizedDescription, privacy: .public)")
                entries = []
            }
            return
        }
        // Erster Start mit Frequenzspeicher: alte Radio-Favoriten übernehmen.
        guard let raw = defaults.string(forKey: Self.legacyRadioKey), !raw.isEmpty else { return }
        entries = Self.sorted(Self.migrated(RadioFavorite.decode(raw)))
        // Altschlüssel erst entfernen, wenn die Datei geschrieben und zurückgelesen ist.
        if save(), let back = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder.memory.decode(Stored.self, from: back), stored.entries.count == entries.count {
            defaults.removeObject(forKey: Self.legacyRadioKey)
            Self.log.notice("\(self.entries.count) Radio-Favoriten in den Frequenzspeicher übernommen")
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            let data = try JSONEncoder.memory.encode(Stored(entries: entries))
            try data.write(to: fileURL, options: .atomic)
            error = nil
            return true
        } catch {
            self.error = String(localized: "Frequenzspeicher konnte nicht gesichert werden: \(error.localizedDescription)")
            Self.log.error("Frequenzspeicher nicht gesichert: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Ändern

    func add(_ entry: FrequencyMemoryEntry) {
        entries = Self.sorted(entries + [entry])
        save()
    }

    func update(_ entry: FrequencyMemoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        entries = Self.sorted(entries)
        save()
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func entry(id: UUID) -> FrequencyMemoryEntry? { entries.first { $0.id == id } }

    /// Eintrag dieser Frequenz für diese Seite (bzw. ohne Seite).
    func entry(atMHz mhz: Double, page: SidebarItem?) -> FrequencyMemoryEntry? {
        entries.first { $0.matches(mhz: mhz) && ($0.page == nil || $0.page == page?.rawValue) }
    }

    /// Einträge einer Seite – mit `all` alle. Einträge ohne Seite gelten überall.
    func entries(for page: SidebarItem?, all: Bool = false) -> [FrequencyMemoryEntry] {
        Self.filter(entries, page: page, all: all)
    }

    /// Ordner (Gruppen) in der gespeicherten Schreibweise, alphabetisch.
    var groups: [String] {
        Array(Set(entries.map(\.group).filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: CSV

    /// Liest eine CSV-Datei ein; Doppel (gleiche Frequenz, Name und Seite) werden übersprungen.
    @discardableResult
    func importCSV(_ text: String) -> FrequencyMemoryCSV.ImportResult {
        var result = FrequencyMemoryCSV.parse(text)
        var fresh: [FrequencyMemoryEntry] = []
        for entry in result.entries {
            if (entries + fresh).contains(where: { Self.isDuplicate($0, entry) }) { result.duplicates += 1 } else { fresh.append(entry) }
        }
        result.entries = fresh
        if !fresh.isEmpty {
            entries = Self.sorted(entries + fresh)
            save()
        }
        return result
    }

    func exportCSV(_ selection: [FrequencyMemoryEntry]? = nil) -> String {
        FrequencyMemoryCSV.export(selection ?? entries)
    }

    // MARK: Reine Funktionen

    /// Alte Radio-Favoriten → Einträge (Frequenz, Betriebsart, Schritt und Funkart unverändert).
    nonisolated static func migrated(_ favorites: [RadioFavorite]) -> [FrequencyMemoryEntry] {
        favorites.map {
            FrequencyMemoryEntry(frequencyHz: FrequencyMemoryEntry.hz($0.mhz), mode: $0.mode.rawValue, stepKHz: $0.stepKHz,
                                 kind: $0.kind, page: SidebarItem.radio.rawValue)
        }
    }

    nonisolated static func filter(_ entries: [FrequencyMemoryEntry], page: SidebarItem?, all: Bool) -> [FrequencyMemoryEntry] {
        guard !all, let page else { return entries }
        return entries.filter { $0.page == nil || $0.page == page.rawValue }
    }

    nonisolated static func sorted(_ entries: [FrequencyMemoryEntry]) -> [FrequencyMemoryEntry] {
        entries.sorted { a, b in
            if a.group != b.group {
                if a.group.isEmpty || b.group.isEmpty { return b.group.isEmpty }
                return a.group.localizedStandardCompare(b.group) == .orderedAscending
            }
            return a.frequencyHz != b.frequencyHz ? a.frequencyHz < b.frequencyHz : a.name < b.name
        }
    }

    nonisolated static func isDuplicate(_ a: FrequencyMemoryEntry, _ b: FrequencyMemoryEntry) -> Bool {
        abs(a.frequencyHz - b.frequencyHz) <= 10 && a.page == b.page
            && a.name.trimmingCharacters(in: .whitespaces).lowercased() == b.name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Kurzform der Betriebsart: Klammerinhalt („UKW (WFM)“ → „WFM“), sonst der Rohwert.
    nonisolated static func modeCode(_ raw: String) -> String {
        if let open = raw.lastIndex(of: "("), let close = raw.lastIndex(of: ")"), open < close {
            return String(raw[raw.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    /// Bekannte Radio-Betriebsart zu einem gespeicherten Rohwert oder Kürzel
    /// („WFM“, „nfm“, „AM“ …). „FM“ heißt in Kanallisten (CHIRP) Schmalband-FM.
    nonisolated static func radioMode(fromStored text: String) -> RadioMode? {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let mode = RadioMode.allCases.first(where: { $0.rawValue.lowercased() == key || modeCode($0.rawValue).lowercased() == key }) {
            return mode
        }
        if key == "fm" || key == "nbfm" { return radioMode(fromStored: "nfm") }
        if key == "wbfm" || key == "ukw" { return radioMode(fromStored: "wfm") }
        return nil
    }

    /// Betriebsart als gespeicherter Rohwert: bekannte Kürzel werden zum Rohwert
    /// der Radio-Betriebsart, Unbekanntes bleibt als Text stehen.
    nonisolated static func storedMode(fromCode code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return radioMode(fromStored: trimmed)?.rawValue ?? trimmed.uppercased()
    }

    /// Betriebsart fürs Radio, wenn nur die Frequenz bekannt ist (Spektrum, Speicher
    /// ohne Betriebsart): Flugfunk und Kurzwelle AM, UKW-Rundfunk WFM, sonst NFM
    /// (2 m, 70 cm, PMR, ISM …) – dieselbe Regel wie im Belegungsmonitor.
    nonisolated static func suggestedRadioMode(mhz: Double) -> RadioMode {
        OccupancyPreset.radioMode(for: mhz)
    }
}

/// CSV-Austausch des Frequenzspeichers. Spalten wie in SDR++/CHIRP-Listen
/// üblich: `Name;Frequenz (MHz);Modus;Bandbreite (kHz);Notiz;Gruppe;Seite`.
/// Beim Einlesen gelten `;`, Tabulator und `,` als Trenner, Dezimalkomma und
/// -punkt, Frequenzen in MHz (Einheit erlaubt) oder in Hz (ab 100 000).
enum FrequencyMemoryCSV {
    struct ImportResult: Equatable {
        var entries: [FrequencyMemoryEntry] = []
        var duplicates = 0
        var invalid = 0
    }

    static let header = ["Name", "Frequenz (MHz)", "Modus", "Bandbreite (kHz)", "Notiz", "Gruppe", "Seite"]

    private enum Column { case name, frequency, mode, bandwidth, note, group, page }

    static func export(_ entries: [FrequencyMemoryEntry]) -> String {
        var lines = [header.joined(separator: ";")]
        for e in entries {
            let fields = [
                e.name,
                number(e.mhz, decimals: 6),
                e.mode.map(FrequencyMemory.modeCode) ?? "",
                e.bandwidthHz.map { number(Double($0) / 1000, decimals: 3) } ?? "",
                e.note,
                e.group,
                e.page ?? "",
            ]
            lines.append(fields.map { quote($0, separator: ";") }.joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func parse(_ text: String) -> ImportResult {
        var result = ImportResult()
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard let firstLine = body.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return result
        }
        let separator: Character = firstLine.contains(";") ? ";" : firstLine.contains("\t") ? "\t" : ","
        var rows = records(body, separator: separator)
        guard !rows.isEmpty else { return result }

        // Kopfzeile erkennen; sonst die feste Reihenfolge.
        var columns: [Column?] = [.name, .frequency, .mode, .bandwidth, .note, .group, .page]
        var bandwidthUnit: Double?   // Hz je Einheit, falls die Kopfzeile sie nennt
        if let head = rows.first, head.contains(where: { column(for: $0) == .frequency }) {
            columns = head.map(column(for:))
            if let cell = head.first(where: { column(for: $0) == .bandwidth })?.lowercased() {
                bandwidthUnit = cell.contains("khz") ? 1000 : cell.contains("mhz") ? 1e6 : cell.contains("hz") ? 1 : nil
            }
            rows.removeFirst()
        }

        for row in rows where row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            func cell(_ c: Column) -> String {
                guard let i = columns.firstIndex(of: c), i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let mhz = frequencyMHz(cell(.frequency)), mhz > 0, mhz <= 7250 else { result.invalid += 1; continue }
            let pageText = cell(.page)
            let page = SidebarItem(rawValue: pageText)
                ?? SidebarItem.allCases.first { $0.title.caseInsensitiveCompare(pageText) == .orderedSame }
            result.entries.append(FrequencyMemoryEntry(
                name: cell(.name), frequencyHz: FrequencyMemoryEntry.hz(mhz),
                mode: FrequencyMemory.storedMode(fromCode: cell(.mode)),
                bandwidthHz: bandwidthHz(cell(.bandwidth), unit: bandwidthUnit),
                page: page?.rawValue, note: cell(.note), group: cell(.group), created: FrequencyMemoryEntry.now()))
        }
        return result
    }

    /// MHz aus einer Zelle; reine Zahlen ab 100 000 gelten als Hz (SDR++ speichert Hz).
    static func frequencyMHz(_ text: String) -> Double? {
        guard let value = FrequencyInput.parseMHz(text), value.isFinite else { return nil }
        return value >= 100_000 ? value / 1e6 : value
    }

    /// Bandbreite in Hz: mit Einheit in der Zelle oder Kopfzeile genau, sonst
    /// bis 1000 als kHz, darüber als Hz.
    static func bandwidthHz(_ text: String, unit: Double?) -> Int? {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return nil }
        if lower.hasSuffix("hz") {
            guard let mhz = FrequencyInput.parseMHz(lower), mhz > 0 else { return nil }
            return Int((mhz * 1e6).rounded())
        }
        guard let value = FrequencyInput.parseMHz(lower), value > 0 else { return nil }
        let factor = unit ?? (value <= 1000 ? 1000 : 1)
        return Int((value * factor).rounded())
    }

    private static func column(for title: String) -> Column? {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("freq") { return .frequency }
        if t.hasPrefix("name") || t == "bezeichnung" || t == "label" { return .name }
        if t.hasPrefix("mod") { return .mode }
        if t.hasPrefix("bandbreite") || t.hasPrefix("bandwidth") || t == "bw" { return .bandwidth }
        if t.hasPrefix("notiz") || t.hasPrefix("note") || t.hasPrefix("comment") || t.hasPrefix("kommentar") { return .note }
        if t.hasPrefix("gruppe") || t.hasPrefix("group") || t.hasPrefix("ordner") || t.hasPrefix("folder") || t == "list" { return .group }
        if t.hasPrefix("seite") || t.hasPrefix("page") { return .page }
        return nil
    }

    /// Zerlegt CSV in Zeilen und Felder; Anführungszeichen dürfen Trenner,
    /// Zeilenumbrüche und verdoppelte `""` enthalten.
    static func records(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text).makeIterator()
        var pending: Character?
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); field = ""
                if row.count > 1 || !row[0].isEmpty { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
        }
        row.append(field)
        if row.count > 1 || !row[0].isEmpty { rows.append(row) }
        return rows
    }

    private static func quote(_ text: String, separator: Character) -> String {
        guard text.contains(separator) || text.contains("\"") || text.contains("\n") || text.contains("\r") else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Zahl mit Punkt, ohne überflüssige Nullen (unabhängig vom Gebietsschema).
    private static func number(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}

private extension JSONEncoder {
    static var memory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var memory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
