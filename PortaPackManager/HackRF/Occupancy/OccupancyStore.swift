import Foundation

/// Eine Aufzeichnung des Belegungsmonitors: Kopf + Zeitscheiben.
///
/// Dateiformat (little-endian), Endung `.ppocc`:
///
/// | Bytes | Inhalt |
/// |---|---|
/// | 0–3 | Kennung `PPOC` |
/// | 4–5 | Version (1) |
/// | 6–7 | reserviert |
/// | 8–11 | Anzahl Rasterbins (UInt32) |
/// | 12–19 | Startfrequenz MHz (Float64) |
/// | 20–27 | Rasterbreite kHz (Float64) |
/// | 28–35 | Scheibenlänge s (Float64) |
/// | 36–39 | Schwelle dB (Float32) |
/// | 40–63 | reserviert |
/// | 64–127 | Name (UTF-8, mit Nullen aufgefüllt) |
///
/// Danach Scheiben fester Länge: Beginn (Float64, Unix-Sekunden), Boden dB
/// (Float32), Besuche (UInt32), dann je Bin Mittel, Spitze, Belegung (je 1 Byte,
/// Kodierung siehe `OccupancySlice`). 4000 Bins × 1 min ≈ 17 MB am Tag.
struct OccupancyRecording: Sendable {
    static let magic: [UInt8] = Array("PPOC".utf8)
    static let version: UInt16 = 1
    static let headerSize = 128
    static let fileExtension = "ppocc"

    var name: String
    var plan: OccupancyPlan
    var sliceSeconds: Double
    var thresholdDB: Float
    var slices: [OccupancySlice] = []

    var recordSize: Int { Self.recordSize(binCount: plan.binCount) }
    static func recordSize(binCount: Int) -> Int { 16 + 3 * binCount }

    /// Passen Band, Raster und Scheibenlänge? Dann kann ein Lauf angehängt werden.
    func matches(plan other: OccupancyPlan, sliceSeconds seconds: Double) -> Bool {
        abs(plan.startMHz - other.startMHz) < 1e-6 && abs(plan.binKHz - other.binKHz) < 1e-6
            && plan.binCount == other.binCount && abs(sliceSeconds - seconds) < 1e-6
    }

    // MARK: Kodieren

    func headerData() -> Data {
        var d = Data(count: Self.headerSize)
        d.replaceSubrange(0..<4, with: Self.magic)
        d.put(Self.version, at: 4)
        d.put(UInt32(plan.binCount), at: 8)
        d.put(plan.startMHz.bitPattern, at: 12)
        d.put(plan.binKHz.bitPattern, at: 20)
        d.put(sliceSeconds.bitPattern, at: 28)
        d.put(thresholdDB.bitPattern, at: 36)
        let nameBytes = Array(name.utf8.prefix(63))
        d.replaceSubrange(64..<(64 + nameBytes.count), with: nameBytes)
        return d
    }

    static func recordData(_ slice: OccupancySlice) -> Data {
        var d = Data(count: 16)
        d.put(slice.start.timeIntervalSince1970.bitPattern, at: 0)
        d.put(slice.floorDB.bitPattern, at: 8)
        d.put(slice.visits, at: 12)
        d.append(contentsOf: slice.mean)
        d.append(contentsOf: slice.peak)
        d.append(contentsOf: slice.occupancy)
        return d
    }

    func encoded() -> Data {
        var d = headerData()
        d.reserveCapacity(Self.headerSize + slices.count * recordSize)
        for slice in slices { d.append(Self.recordData(slice)) }
        return d
    }

    // MARK: Lesen

    enum ReadError: Error, LocalizedError {
        case notARecording, unsupportedVersion(UInt16)
        var errorDescription: String? {
            switch self {
            case .notARecording: String(localized: "Keine Aufzeichnung des Belegungsmonitors.")
            case let .unsupportedVersion(v): String(localized: "Aufzeichnungsformat \(v) wird nicht unterstützt.")
            }
        }
    }

    /// Längste zulässige Zeitscheibe (ein Tag).
    static let maxSliceSeconds = 86_400.0
    /// Zeitstempel jenseits ±10¹¹ s (≈ 3000 Jahre) gelten als kaputt.
    static let maxAbsTime = 1e11

    /// Liest Kopf und alle vollständigen Scheiben (ein abgeschnittenes Ende
    /// nach einem Absturz wird ignoriert).
    static func decode(_ data: Data, headerOnly: Bool = false) throws -> OccupancyRecording {
        guard data.count >= headerSize, Array(data.prefix(4)) == magic else { throw ReadError.notARecording }
        let version: UInt16 = data.get(at: 4)
        guard version == Self.version else { throw ReadError.unsupportedVersion(version) }
        let bins = Int(data.get(at: 8) as UInt32)
        let start = Double(bitPattern: data.get(at: 12))
        let binKHz = Double(bitPattern: data.get(at: 20))
        let sliceSeconds = Double(bitPattern: data.get(at: 28))
        let threshold = Float(bitPattern: data.get(at: 36))
        // Gleitkommafelder aus der Datei vor jeder Rechnung prüfen: NaN/∞ brächten
        // `Int(_:)` in Plan, Zeitachse und Ansicht zum Absturz – und die letzte
        // Aufzeichnung wird bei jedem Start wieder geöffnet (Review Y3).
        guard start.isFinite, (1...6000).contains(start),
              binKHz.isFinite, binKHz > 0, binKHz <= 100_000,
              sliceSeconds.isFinite, (1...Self.maxSliceSeconds).contains(sliceSeconds),
              threshold.isFinite, (-100...100).contains(threshold) else { throw ReadError.notARecording }
        let nameBytes = data.subdata(in: data.startIndex + 64 ..< data.startIndex + 128).prefix { $0 != 0 }
        let name = String(decoding: nameBytes, as: UTF8.self)
        let plan = OccupancyPlan(startMHz: start, endMHz: start + Double(bins) * binKHz / 1000, binKHz: binKHz)
        guard plan.binCount == bins, bins > 0 else { throw ReadError.notARecording }
        var recording = OccupancyRecording(name: name, plan: plan, sliceSeconds: sliceSeconds, thresholdDB: threshold)
        guard !headerOnly else { return recording }
        let size = recordSize(binCount: bins)
        let count = (data.count - headerSize) / size
        recording.slices.reserveCapacity(count)
        for i in 0..<count {
            let o = headerSize + i * size
            let base = data.startIndex + o
            let startTime = Double(bitPattern: data.get(at: o))
            let floorDB = Float(bitPattern: data.get(at: o + 8))
            // Kaputte Scheiben (Zeit/Boden nicht endlich oder Zeit unsinnig) überspringen.
            guard startTime.isFinite, abs(startTime) < Self.maxAbsTime, floorDB.isFinite else { continue }
            let slice = OccupancySlice(
                start: Date(timeIntervalSince1970: startTime),
                floorDB: floorDB,
                visits: data.get(at: o + 12),
                mean: [UInt8](data[(base + 16)..<(base + 16 + bins)]),
                peak: [UInt8](data[(base + 16 + bins)..<(base + 16 + 2 * bins)]),
                occupancy: [UInt8](data[(base + 16 + 2 * bins)..<(base + 16 + 3 * bins)]))
            recording.slices.append(slice)
        }
        return recording
    }

    /// Wie viele der neuesten Scheiben in `maxBytes` passen (mindestens eine).
    func slicesFitting(maxBytes: Int) -> Int {
        max(1, (maxBytes - Self.headerSize) / recordSize)
    }
}

/// Ablage der Aufzeichnungen unter Application Support.
final class OccupancyStore: Sendable {
    let folder: URL

    static let shared = OccupancyStore(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("de.christiangolz.portapackmanager/Belegung", isDirectory: true))

    init(folder: URL) {
        self.folder = folder
    }

    struct Entry: Identifiable, Hashable, Sendable {
        var url: URL
        var name: String
        var startMHz: Double
        var endMHz: Double
        var bytes: Int
        var modified: Date
        var id: URL { url }
    }

    func list() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == OccupancyRecording.fileExtension }.compactMap { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: OccupancyRecording.headerSize),
                  let rec = try? OccupancyRecording.decode(head, headerOnly: true) else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return Entry(url: url, name: rec.name, startMHz: rec.plan.startMHz, endMHz: rec.plan.endMHz,
                         bytes: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }

    func newURL(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return folder.appendingPathComponent("Belegung_\(formatter.string(from: date)).\(OccupancyRecording.fileExtension)")
    }

    func load(_ url: URL) throws -> OccupancyRecording {
        try OccupancyRecording.decode(Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Schreibt die Aufzeichnung vollständig neu.
    func write(_ recording: OccupancyRecording, to url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try recording.encoded().write(to: url, options: .atomic)
    }

    /// Hängt eine Scheibe an. Wird die Datei größer als `maxBytes`, fliegen die
    /// ältesten Scheiben heraus (Datei wird mit 75 % der Grenze neu geschrieben).
    /// Liefert, wie viele Scheiben vorn entfernt wurden.
    @discardableResult
    func append(_ slice: OccupancySlice, to recording: inout OccupancyRecording, url: URL, maxBytes: Int) throws -> Int {
        recording.slices.append(slice)
        let total = OccupancyRecording.headerSize + recording.slices.count * recording.recordSize
        if total > maxBytes {
            let keep = recording.slicesFitting(maxBytes: maxBytes * 3 / 4)
            let removed = max(0, recording.slices.count - keep)
            recording.slices.removeFirst(removed)
            try write(recording, to: url)
            return removed
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try write(recording, to: url)
            return 0
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // Unvollständige Scheibe am Ende (Absturz beim Schreiben) abschneiden.
        let expected = UInt64(OccupancyRecording.headerSize + (recording.slices.count - 1) * recording.recordSize)
        try handle.truncate(atOffset: expected)
        try handle.seekToEnd()
        try handle.write(contentsOf: OccupancyRecording.recordData(slice))
        return 0
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

fileprivate extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        let bytes = Swift.withUnsafeBytes(of: value.littleEndian) { Array($0) }
        replaceSubrange((startIndex + offset)..<(startIndex + offset + bytes.count), with: bytes)
    }

    func get<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        let slice = self[(startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)]
        Swift.withUnsafeMutableBytes(of: &value) { dest in dest.copyBytes(from: slice) }
        return T(littleEndian: value)
    }
}
