import Foundation

/// Beschreibt eine IQ-Aufnahme (Rohdaten als signierte 8-Bit-IQ-Paare, `.c8`).
/// Wird als JSON-Begleitdatei neben der `.c8`-Datei abgelegt.
struct IQRecording: Codable, Identifiable, Sendable, Hashable {
    var name: String
    var centerHz: UInt64
    var sampleRate: UInt32
    var date: Date
    var byteCount: Int
    /// Verstärkung beim Aufnehmen (für die SigMF-Beschreibung; fehlt bei
    /// älteren Aufnahmen und Importen).
    var lnaGain: Int?
    var vgaGain: Int?
    var amplifier: Bool?
    /// Als SigMF aufgenommen: Daten in `<name>.sigmf-data`, daneben
    /// `<name>.sigmf-meta` (statt `.c8`).
    var sigmf: Bool?
    /// Aus einer SigMF-Datei übernommen (Name der Metadatei).
    var importedFrom: String?

    var id: String { name }
    /// Dauer in Sekunden (ein IQ-Paar = 2 Byte).
    var duration: TimeInterval { Double(byteCount / 2) / Double(sampleRate) }
    var centerMHz: Double { Double(centerHz) / 1_000_000 }
    var sampleRateMHz: Double { Double(sampleRate) / 1_000_000 }
}

/// Verwaltet den Ordner mit IQ-Aufnahmen.
enum IQStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("de.christiangolz.portapackmanager/Aufnahmen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func dataURL(for name: String) -> URL { folder.appendingPathComponent(name + ".c8") }
    static func metaURL(for name: String) -> URL { folder.appendingPathComponent(name + ".json") }
    static func sigmfDataURL(for name: String) -> URL { folder.appendingPathComponent(name + "." + SigMF.dataExtension) }
    static func sigmfMetaURL(for name: String) -> URL { folder.appendingPathComponent(name + "." + SigMF.metaExtension) }

    /// Datendatei einer Aufnahme – `.c8` oder, als SigMF aufgenommen, `.sigmf-data`.
    static func dataURL(for rec: IQRecording) -> URL {
        rec.sigmf == true ? sigmfDataURL(for: rec.name) : dataURL(for: rec.name)
    }

    static func list() -> [IQRecording] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(IQRecording.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    static func save(_ meta: IQRecording) {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL(for: meta.name))
        }
        // Als SigMF aufgenommen: die Beschreibung im Standardformat daneben.
        if meta.sigmf == true {
            try? SigMF.metadata(for: meta).write(to: sigmfMetaURL(for: meta.name), options: .atomic)
        }
    }

    /// Freier Platz auf dem Volume des Aufnahmeordners (für wichtige Daten).
    static func availableBytes() -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func delete(_ meta: IQRecording) {
        for url in [dataURL(for: meta.name), sigmfDataURL(for: meta.name), sigmfMetaURL(for: meta.name), metaURL(for: meta.name)] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Schreibt den laufenden IQ-Strom in eine Datei (`.c8`). Schreibfehler und
/// das Größenlimit beenden das Schreiben; `failure` sagt dann, warum.
final class IQRecorder: @unchecked Sendable {
    /// Auf dem Volume freizuhaltender Platz – die Aufnahme stoppt vorher.
    static let reserveBytes: Int64 = 2_000_000_000

    private let lock = NSLock()
    private var handle: FileHandle?
    private var written = 0
    private var limit = Int.max
    private var peak: Int8 = 0
    private var failureText: String?

    var bytesWritten: Int { lock.withLock { written } }
    /// Grund, warum das Schreiben vorzeitig endete (`nil`, solange alles läuft).
    var failure: String? { lock.withLock { failureText } }

    func start(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let newHandle = try FileHandle(forWritingTo: url)
        let free = (try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        lock.withLock {
            try? handle?.close()
            handle = newHandle
            written = 0
            peak = 0
            failureText = nil
            limit = free.map { Int(max(0, $0 - Self.reserveBytes)) } ?? Int.max
        }
    }

    func write(_ block: Data) {
        lock.withLock {
            guard let handle else { return }
            guard written + block.count <= limit else {
                finish(failure: String(localized: "Aufnahme gestoppt: Auf dem Laufwerk bleiben weniger als 2 GB frei."))
                return
            }
            do {
                try handle.write(contentsOf: block)
            } catch {
                finish(failure: String(localized: "Aufnahme gestoppt: \(error.localizedDescription)"))
                return
            }
            written += block.count
            block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for v in raw.bindMemory(to: Int8.self) {
                    let a = Int8(abs(Int(v)).clamped(to: 0...127))
                    if a > peak { peak = a }
                }
            }
        }
    }

    /// Unter `lock` aufrufen.
    private func finish(failure: String) {
        try? handle?.close()
        handle = nil
        failureText = failure
    }

    /// Spitzenpegel seit dem letzten Abruf (0…1), danach zurückgesetzt.
    func takePeak() -> Double {
        lock.withLock {
            let p = Double(peak) / 127
            peak = 0
            return p
        }
    }

    func stop() -> Int {
        lock.withLock {
            try? handle?.close()
            handle = nil
            return written
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
