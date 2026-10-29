import Foundation
import Observation

/// Stammdaten eines Flugzeugs (Kennzeichen, Typ, Betreiber) zu einer
/// ICAO-Adresse – ADS-B selbst sendet davon nichts.
struct AircraftInfo: Equatable, Sendable, Codable {
    var registration = ""
    var typeCode = ""
    var manufacturer = ""
    var model = ""
    var operatorName = ""
    var operatorCallsign = ""
    var owner = ""
    var category = ""

    /// „Airbus A320-214 (A320)“ bzw. nur der Typcode, wenn das Modell fehlt.
    /// Bei OpenSky steckt der Hersteller oft schon im Modell („Airbus A320
    /// 251NSL“, „BOEING 737-8AS“ zu „The Boeing Company“) – dann nicht doppeln.
    var typeText: String {
        let key = manufacturer.lowercased().split(separator: " ").first { $0 != "the" }.map(String.init) ?? ""
        let repeated = !key.isEmpty && model.lowercased().contains(key)
        let name = [repeated ? "" : manufacturer, model].filter { !$0.isEmpty }.joined(separator: " ")
        if name.isEmpty { return typeCode }
        return typeCode.isEmpty || typeCode == "ZZZZ" ? name : "\(name) (\(typeCode))"
    }

    /// Betreiber, sonst Halter.
    var operatorText: String { operatorName.isEmpty ? owner : operatorName }
}

/// Wandelt die OpenSky-Datenbank (CSV, ~95 MB, 27 Spalten) in die kompakte
/// Ablage der App um: je Flugzeug eine Zeile, Tabulator-getrennt, nur die
/// Spalten, die die App zeigt. Richtiges CSV: Anführungszeichen, Kommas und
/// Zeilenumbrüche in Feldern, `""` als Anführungszeichen im Feld.
enum AircraftCSV {
    /// Spaltenfolge der kompakten Datei.
    static let columns = ["icao24", "registration", "typecode", "manufacturername", "model",
                          "operator", "operatorcallsign", "owner", "categoryDescription"]

    /// Liefert die kompakte Datei und die Zahl der übernommenen Flugzeuge.
    static func convert(_ csv: Data) -> (tsv: Data, count: Int) {
        let bytes = [UInt8](csv)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count / 3)
        var count = 0

        var header: [String] = []
        var wanted: [Int] = []            // Spaltenindex je Ausgabespalte (−1 = fehlt)
        var manufacturerFallback = -1     // manufacturericao, falls der Name fehlt

        var fields: [(range: Range<Int>, escaped: Bool)] = []
        fields.reserveCapacity(32)
        var i = 0
        let n = bytes.count

        func fieldBytes(_ f: (range: Range<Int>, escaped: Bool)) -> ArraySlice<UInt8> {
            if !f.escaped { return bytes[f.range] }
            var result = [UInt8]()
            var j = f.range.lowerBound
            while j < f.range.upperBound {
                let b = bytes[j]
                result.append(b)
                if b == UInt8(ascii: "\""), j + 1 < f.range.upperBound, bytes[j + 1] == UInt8(ascii: "\"") { j += 1 }
                j += 1
            }
            return result[...]
        }

        func finishRecord() {
            defer { fields.removeAll(keepingCapacity: true) }
            if header.isEmpty {
                header = fields.map { String(decoding: fieldBytes($0), as: UTF8.self) }
                wanted = columns.map { name in header.firstIndex(of: name) ?? -1 }
                manufacturerFallback = header.firstIndex(of: "manufacturericao") ?? -1
                return
            }
            guard wanted[0] >= 0, wanted[0] < fields.count else { return }
            let icao = fieldBytes(fields[wanted[0]])
            guard icao.count == 6, icao.allSatisfy(isHexDigit) else { return }
            var line = [UInt8]()
            var hasData = false
            for (k, column) in wanted.enumerated() {
                if k > 0 { line.append(UInt8(ascii: "\t")) }
                var index = column
                if k == 3, index >= 0, index < fields.count, fields[index].range.isEmpty { index = manufacturerFallback }
                guard index >= 0, index < fields.count else { continue }
                for b in fieldBytes(fields[index]) {
                    // Tabulator und Zeilenumbruch sind Trennzeichen der Ablage.
                    line.append(b == UInt8(ascii: "\t") || b == UInt8(ascii: "\n") || b == UInt8(ascii: "\r") ? UInt8(ascii: " ") : b)
                    if k > 0 { hasData = true }
                }
            }
            guard hasData else { return }
            out.append(contentsOf: line)
            out.append(UInt8(ascii: "\n"))
            count += 1
        }

        while i < n {
            // Ein Feld
            if bytes[i] == UInt8(ascii: "\"") {
                i += 1
                let start = i
                var escaped = false
                while i < n {
                    if bytes[i] == UInt8(ascii: "\"") {
                        if i + 1 < n, bytes[i + 1] == UInt8(ascii: "\"") { escaped = true; i += 2; continue }
                        break
                    }
                    i += 1
                }
                fields.append((start..<min(i, n), escaped))
                i += 1   // schließendes Anführungszeichen
                // bis zum Komma/Zeilenende überlesen (fehlerhafte Zeilen)
                while i < n, bytes[i] != UInt8(ascii: ","), bytes[i] != UInt8(ascii: "\n"), bytes[i] != UInt8(ascii: "\r") { i += 1 }
            } else {
                let start = i
                while i < n, bytes[i] != UInt8(ascii: ","), bytes[i] != UInt8(ascii: "\n"), bytes[i] != UInt8(ascii: "\r") { i += 1 }
                fields.append((start..<i, false))
            }
            // Trennzeichen
            if i >= n { finishRecord(); break }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "\r") { i += 1 }
            if i < n, bytes[i] == UInt8(ascii: "\n") { i += 1 }
            finishRecord()
        }
        return (Data(out), count)
    }

    private static func isHexDigit(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "f"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "F"))
    }

    /// Für Tests: die hexdb.io-Antwort ohne Main Actor zerlegen.
    static func parseHexDBForTest(_ data: Data) -> AircraftInfo? { AircraftDatabase.parseHexDB(data) }

    /// Sechs Hex-Zeichen → Adresse.
    static func icao(_ bytes: ArraySlice<UInt8>) -> UInt32? {
        guard bytes.count == 6 else { return nil }
        var value: UInt32 = 0
        for b in bytes {
            let digit: UInt32
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(b - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(b - UInt8(ascii: "A") + 10)
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }
}

/// Die kompakte Datei im Speicher: ein Byte-Puffer plus Zeilenanfang je
/// Adresse. ≈ 500 000 Einträge brauchen so rund 50 MB statt der ~150 MB
/// einzelner Strings; ein Eintrag wird erst beim Nachschlagen zerlegt.
struct AircraftIndex: Sendable {
    let storage: [UInt8]
    let offsets: [UInt32: Int]
    var count: Int { offsets.count }

    init(tsv: Data) {
        let bytes = [UInt8](tsv)
        var offsets = [UInt32: Int](minimumCapacity: bytes.count / 70)
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
            if end - start > 7, let icao = AircraftCSV.icao(bytes[start..<(start + 6)]) { offsets[icao] = start }
            start = end + 1
        }
        storage = bytes
        self.offsets = offsets
    }

    func info(for icao: UInt32) -> AircraftInfo? {
        guard let start = offsets[icao] else { return nil }
        var end = start
        while end < storage.count, storage[end] != UInt8(ascii: "\n") { end += 1 }
        let fields = storage[start..<end].split(separator: UInt8(ascii: "\t"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        func field(_ k: Int) -> String { k < fields.count ? fields[k] : "" }
        return AircraftInfo(registration: field(1), typeCode: field(2), manufacturer: field(3), model: field(4),
                            operatorName: field(5), operatorCallsign: field(6), owner: field(7), category: field(8))
    }
}

/// Flugzeugdatenbank der App: einmal von OpenSky laden, danach offline.
@MainActor
@Observable
final class AircraftDatabase {
    static let shared = AircraftDatabase()

    static let sourceURL = URL(string: "https://s3.opensky-network.org/data-samples/metadata/aircraftDatabase.csv")!
    /// Im Cache-Ordner: lässt sich jederzeit neu laden (siehe `AppFiles`).
    static let fileURL = AppFiles.cacheFile("Flugzeugdatenbank.tsv")

    private(set) var index: AircraftIndex?
    private(set) var updated: Date?
    private(set) var loading = false
    private(set) var downloading = false
    /// 0…1 während des Ladens; `nil` = unbestimmt (Umwandeln).
    fileprivate(set) var progress: Double?
    private(set) var error: String?

    @ObservationIgnored private var cache: [UInt32: AircraftInfo?] = [:]
    @ObservationIgnored private var loadStarted = false
    /// Laufender Download (nur das Laden, nicht das Umwandeln) – für „Abbrechen“.
    @ObservationIgnored private var downloadTask: Task<Data, Error>?

    // --- Online-Rückfall (hexdb.io) für Adressen, die die Datei nicht kennt ---

    /// Schalter aus den Einstellungen (ADS-B-Seite); ohne ihn geht nichts nach außen.
    var onlineLookup: Bool {
        get { UserDefaults.standard.object(forKey: "adsbOnlineLookup") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "adsbOnlineLookup"); if newValue { pumpOnline() } }
    }
    /// Online gefundene Einträge (beobachtet – die Ansicht zieht nach).
    private(set) var onlineEntries: [UInt32: AircraftInfo] = [:]
    private(set) var onlineQueued = 0
    private(set) var onlineError: String?
    /// Fehlanzeigen mit Zeitpunkt – frühestens nach einem Tag erneut fragen.
    @ObservationIgnored private var onlineMisses: [UInt32: Date] = [:]
    @ObservationIgnored private var onlineQueue: [UInt32] = []
    @ObservationIgnored private var onlineInFlight: Set<UInt32> = []
    @ObservationIgnored private var onlineWorker: Task<Void, Never>?
    @ObservationIgnored private var onlineStoreLoaded = false

    static let onlineURL = URL(string: "https://hexdb.io/api/v1/aircraft/")!
    static let onlineStoreURL = AppFiles.cacheFile("Flugzeugdatenbank-online.json")
    private static let missRetry: TimeInterval = 24 * 3600

    var count: Int { index?.count ?? 0 }
    var isLoaded: Bool { index != nil }

    /// Stammdaten zur Adresse; `nil`, wenn unbekannt oder noch nicht geladen.
    /// Unbekannte Adressen werden – wenn erlaubt – online nachgeschlagen; das
    /// Ergebnis erscheint beim nächsten Aufruf.
    func info(for icao: UInt32) -> AircraftInfo? {
        if let online = onlineEntries[icao] { return online }
        if let index {
            if let cached = cache[icao] { if let cached { return cached } }
            else {
                let info = index.info(for: icao)
                if cache.count > 5000 { cache.removeAll(keepingCapacity: true) }
                cache[icao] = info
                if let info { return info }
            }
        } else if loading || (!loadStarted && FileManager.default.fileExists(atPath: Self.fileURL.path)) {
            return nil   // Datei kommt gleich – nicht vorschnell nach außen fragen
        }
        enqueueOnline(icao)
        return nil
    }

    private func enqueueOnline(_ icao: UInt32) {
        guard onlineLookup, !onlineInFlight.contains(icao), !onlineQueue.contains(icao) else { return }
        if let missed = onlineMisses[icao], Date().timeIntervalSince(missed) < Self.missRetry { return }
        onlineQueue.append(icao)
        pumpOnline()
    }

    /// Arbeitet die Warteschlange nacheinander ab, höchstens vier Anfragen je Sekunde.
    private func pumpOnline() {
        guard onlineWorker == nil, onlineLookup else { return }
        onlineWorker = Task { [weak self] in
            defer { self?.onlineWorker = nil }
            guard let self else { return }
            self.loadOnlineStoreIfNeeded()
            while !Task.isCancelled, self.onlineLookup, let icao = self.onlineQueue.first {
                self.onlineQueue.removeFirst()
                if self.onlineEntries[icao] != nil { continue }
                self.onlineInFlight.insert(icao)
                self.onlineQueued = self.onlineQueue.count + self.onlineInFlight.count
                await self.fetchOnline(icao)
                self.onlineInFlight.remove(icao)
                self.onlineQueued = self.onlineQueue.count + self.onlineInFlight.count
                try? await Task.sleep(for: .milliseconds(250))
            }
            self.saveOnlineStore()
        }
    }

    private func fetchOnline(_ icao: UInt32) async {
        let url = Self.onlineURL.appendingPathComponent(String(format: "%06x", icao))
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.limitedData(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 {
                onlineMisses[icao] = Date()
                return
            }
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            guard let info = Self.parseHexDB(data) else { onlineMisses[icao] = Date(); return }
            onlineEntries[icao] = info
            onlineError = nil
        } catch {
            // Netz weg o. Ä.: nicht hämmern – wie eine Fehlanzeige behandeln, aber kurz.
            onlineMisses[icao] = Date().addingTimeInterval(-Self.missRetry + 120)
            onlineError = error.localizedDescription
        }
    }

    /// Antwort von hexdb.io: {"Registration","Manufacturer","ICAOTypeCode","Type","RegisteredOwners","OperatorFlagCode"}.
    nonisolated static func parseHexDB(_ data: Data) -> AircraftInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func field(_ key: String) -> String {
            let value = (object[key] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return value == "n/a" ? "" : value
        }
        var info = AircraftInfo()
        info.registration = field("Registration")
        info.typeCode = field("ICAOTypeCode")
        info.manufacturer = field("Manufacturer")
        info.model = field("Type")
        info.operatorName = field("RegisteredOwners")
        info.operatorCallsign = field("OperatorFlagCode")
        guard info != AircraftInfo() else { return nil }
        return info
    }

    /// Online-Funde und Fehlanzeigen überdauern den Programmlauf.
    private func loadOnlineStoreIfNeeded() {
        guard !onlineStoreLoaded else { return }
        onlineStoreLoaded = true
        guard let data = try? Data(contentsOf: Self.onlineStoreURL),
              let store = try? JSONDecoder().decode(OnlineStore.self, from: data) else { return }
        var entries: [UInt32: AircraftInfo] = [:]
        for (hex, info) in store.entries { if let icao = AircraftCSV.icao(Array(hex.utf8)[...]) { entries[icao] = info } }
        for (hex, date) in store.misses { if let icao = AircraftCSV.icao(Array(hex.utf8)[...]) { onlineMisses[icao] = date } }
        onlineEntries.merge(entries) { current, _ in current }
    }

    private func saveOnlineStore() {
        var store = OnlineStore()
        for (icao, info) in onlineEntries { store.entries[String(format: "%06x", icao)] = info }
        let cutoff = Date().addingTimeInterval(-Self.missRetry)
        for (icao, date) in onlineMisses where date > cutoff { store.misses[String(format: "%06x", icao)] = date }
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: Self.onlineStoreURL, options: .atomic) }
    }

    private struct OnlineStore: Codable {
        var entries: [String: AircraftInfo] = [:]
        var misses: [String: Date] = [:]
    }

    /// Liest die gespeicherte Datei im Hintergrund – einmal je Programmlauf.
    func loadIfNeeded() {
        guard !loadStarted else { return }
        loadStarted = true
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        loading = true
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        Task.detached(priority: .utility) {
            let index = (try? Data(contentsOf: url)).map { AircraftIndex(tsv: $0) }
            await MainActor.run {
                self.index = index
                self.updated = index == nil ? nil : modified
                self.loading = false
                self.cache.removeAll()
            }
        }
    }

    /// Lädt die OpenSky-Datenbank, wandelt sie um und übernimmt sie.
    func download() async {
        guard !downloading else { return }
        downloading = true
        progress = 0
        error = nil
        defer { downloading = false; progress = nil }
        do {
            // Empfang abseits des Main Actors – 95 MB Byte für Byte wären dort
            // Sekunden Blockade; der Fortschritt kommt je MB zurück.
            let source = Self.sourceURL
            let task = Task.detached(priority: .userInitiated) { () throws -> Data in
                let (bytes, response) = try await URLSession.shared.bytes(from: source)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                // Die Datei hat ≈ 94 MB; mehr als 300 MB kann nur eine kaputte oder
                // falsche Antwort sein – nicht blind reservieren und volllaufen lassen.
                let limit = 300_000_000
                guard http.expectedContentLength <= Int64(limit) else { throw URLError(.dataLengthExceedsMaximum) }
                let expected = Double(http.expectedContentLength)
                var data = Data()
                data.reserveCapacity(expected > 0 ? Int(expected) : 100_000_000)
                var chunk = [UInt8]()
                chunk.reserveCapacity(1 << 20)
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count == 1 << 20 {
                        try Task.checkCancellation()
                        data.append(contentsOf: chunk)
                        chunk.removeAll(keepingCapacity: true)
                        if data.count > limit { throw URLError(.dataLengthExceedsMaximum) }
                        if expected > 0 {
                            let fraction = min(0.95, Double(data.count) / expected * 0.95)
                            await MainActor.run { AircraftDatabase.shared.progress = fraction }
                        }
                    }
                }
                data.append(contentsOf: chunk)
                return data
            }
            downloadTask = task
            let data = try await task.value
            downloadTask = nil
            progress = nil   // Umwandeln, Dauer unbestimmt
            let csv = data
            let url = Self.fileURL
            let index = try await Task.detached(priority: .userInitiated) { () throws -> AircraftIndex in
                let (tsv, _) = AircraftCSV.convert(csv)
                try tsv.write(to: url, options: .atomic)
                return AircraftIndex(tsv: tsv)
            }.value
            guard index.count > 0 else { throw URLError(.cannotParseResponse) }
            self.index = index
            self.updated = Date()
            self.cache.removeAll()
            self.loadStarted = true
        } catch {
            downloadTask = nil
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            self.error = cancelled ? String(localized: "Download abgebrochen.") : error.localizedDescription
        }
    }

    /// Bricht das Herunterladen ab; das Umwandeln danach läuft zu Ende.
    func cancelDownload() {
        downloadTask?.cancel()
    }
}
