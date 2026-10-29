import Foundation

/// SigMF (Signal Metadata Format, Spezifikation v1.x): Abtastwerte in
/// `<name>.sigmf-data`, Beschreibung als JSON in `<name>.sigmf-meta` mit den
/// Abschnitten `global`, `captures` und `annotations`.
///
/// Export: Die Aufnahmen der App sind schon SigMF-`ci8` (int8, I/Q im Wechsel),
/// die Datendatei wird nur kopiert. **Kein Standort** in den Metadaten
/// (`core:geolocation` bleibt weg) – Gerät und Software ja.
///
/// Import: Die Metadaten kommen aus fremder Hand. `parse` prüft deshalb jedes
/// Feld (Typ, endlich, Bereich) und meldet Fehler im Klartext, statt zu
/// raten; Ungewöhnliches, das sich auflösen lässt, landet in `warnings`.
enum SigMF {
    /// Version, die der Export einträgt.
    static let version = "1.2.0"
    static let dataExtension = "sigmf-data"
    static let metaExtension = "sigmf-meta"
    static let archiveExtension = "sigmf"
    /// Größere Metadaten liest der Import nicht (Annotationen können groß sein,
    /// aber nicht Hunderte MB).
    static let maximumMetaBytes = 64 << 20

    /// Komplexe Datentypen, die der Import versteht.
    enum DataType: String, CaseIterable, Sendable {
        case ci8, cu8
        case ci16LE = "ci16_le", ci16BE = "ci16_be", cu16LE = "cu16_le"
        case cf32LE = "cf32_le", cf32BE = "cf32_be"

        /// Bytes je komplexem Abtastwert (I und Q).
        var bytesPerSample: Int {
            switch self {
            case .ci8, .cu8: 2
            case .ci16LE, .ci16BE, .cu16LE: 4
            case .cf32LE, .cf32BE: 8
            }
        }

        /// 8-Bit-Daten werden unverändert (ci8) bzw. nur verschoben (cu8)
        /// übernommen; breitere Typen brauchen eine Skalierung auf int8.
        var needsScaling: Bool { bytesPerSample > 2 }
    }

    struct Metadata: Sendable, Equatable {
        var dataType: DataType
        var sampleRate: Double
        /// Mittenfrequenz der ersten Erfassung in Hz (nil = nicht angegeben).
        var frequency: Double?
        var datetime: Date?
        /// Bytes vor den Abtastwerten (`core:header_bytes` der ersten Erfassung).
        var headerBytes = 0
        /// Bytes nach den Abtastwerten (`core:trailing_bytes`).
        var trailingBytes = 0
        /// Höchster `core:sample_start` aller Erfassungen – so viele Abtastwerte
        /// muss die Datendatei mindestens enthalten.
        var lastCaptureStart = 0
        /// Abweichender Name der Datendatei (`core:dataset`, nur der Dateiname).
        var dataset: String?
        var hardware: String?
        var recorder: String?
        var description: String?
        var warnings: [String] = []

        /// Ganzzahlige Abtastrate für `IQRecording`.
        var sampleRateHz: UInt32 { UInt32(sampleRate.rounded()) }
        var centerHz: UInt64 { frequency.map { UInt64($0.rounded()) } ?? 0 }

        /// Anzahl vollständiger Abtastwerte bei gegebener Dateigröße; wirft,
        /// wenn die Datei kürzer ist, als die Metadaten verlangen.
        func sampleCount(fileSize: Int) throws -> Int {
            let payload = fileSize - headerBytes - trailingBytes
            guard payload >= dataType.bytesPerSample else { throw SigMFError.empty }
            let count = payload / dataType.bytesPerSample
            guard count > lastCaptureStart else {
                throw SigMFError.dataTooShort(samples: count, required: lastCaptureStart + 1)
            }
            return count
        }
    }

    enum SigMFError: LocalizedError, Equatable {
        case notJSON
        case tooLarge
        case missing(String)
        case wrongType(String)
        case unsupportedVersion(String)
        case unsupportedType(String)
        case invalidValue(String)
        case multiChannel(Int)
        case metadataOnly
        case unsupportedHeaders
        case dataMissing(String)
        case dataTooShort(samples: Int, required: Int)
        case empty
        case archive
        case wrongFile

        var errorDescription: String? {
            switch self {
            case .notJSON:
                String(localized: "Die SigMF-Metadaten sind kein gültiges JSON.")
            case .tooLarge:
                String(localized: "Die SigMF-Metadaten sind zu groß (mehr als 64 MB).")
            case .missing(let field):
                String(localized: "In den SigMF-Metadaten fehlt das Pflichtfeld „\(field)“.")
            case .wrongType(let field):
                String(localized: "Das SigMF-Feld „\(field)“ hat den falschen Typ.")
            case .unsupportedVersion(let version):
                String(localized: "SigMF-Version „\(version)“ wird nicht unterstützt – nur 1.x.")
            case .unsupportedType(let type):
                String(localized: "Datentyp „\(type)“ wird nicht unterstützt. Möglich sind komplexe Daten: ci8, cu8, ci16_le, ci16_be, cu16_le, cf32_le, cf32_be.")
            case .invalidValue(let field):
                String(localized: "Das SigMF-Feld „\(field)“ hat einen ungültigen Wert.")
            case .multiChannel(let n):
                String(localized: "Die Aufnahme hat \(n) Kanäle – nur einkanalige Aufnahmen lassen sich auswerten.")
            case .metadataOnly:
                String(localized: "Diese SigMF-Datei enthält nur Metadaten, keine Abtastwerte.")
            case .unsupportedHeaders:
                String(localized: "Kopfbereiche mitten in der Datendatei („core:header_bytes“ in späteren Erfassungen) werden nicht unterstützt.")
            case .dataMissing(let name):
                String(localized: "Die Datendatei „\(name)“ fehlt neben den Metadaten.")
            case .dataTooShort(let samples, let required):
                String(localized: "Die Datendatei ist kleiner, als die Metadaten angeben: \(samples) Abtastwerte statt mindestens \(required).")
            case .empty:
                String(localized: "Die Datendatei enthält keine Abtastwerte.")
            case .archive:
                String(localized: "SigMF-Archive (.sigmf) lassen sich nicht direkt öffnen. Entpacke das Archiv (Doppelklick im Finder oder „tar -xf“) und öffne die .sigmf-meta-Datei.")
            case .wrongFile:
                String(localized: "Wähle eine .sigmf-meta- oder .sigmf-data-Datei.")
            }
        }
    }

    // MARK: Dateien

    /// Meta- und Datendatei zu einer gewählten Datei (`.sigmf-meta` oder `.sigmf-data`).
    static func companions(of url: URL) throws -> (meta: URL, data: URL) {
        let base = url.deletingPathExtension()
        switch url.pathExtension.lowercased() {
        case metaExtension, dataExtension:
            return (base.appendingPathExtension(metaExtension), base.appendingPathExtension(dataExtension))
        case archiveExtension:
            throw SigMFError.archive
        default:
            throw SigMFError.wrongFile
        }
    }

    // MARK: Export

    /// Metadaten einer Aufnahme der App (Datentyp `ci8`). Absichtlich ohne
    /// Standort: `core:geolocation` würde den Ort der Antenne verraten.
    static func metadata(for rec: IQRecording, appVersion: String = SigMF.appVersion) -> Data {
        var description = "PortaPack Manager, \(rec.name)"
        var gains: [String] = []
        if let lna = rec.lnaGain { gains.append("LNA \(lna) dB") }
        if let vga = rec.vgaGain { gains.append("VGA \(vga) dB") }
        if let amp = rec.amplifier { gains.append(amp ? "Verstärker an (+14 dB)" : "Verstärker aus") }
        if !gains.isEmpty { description += " – " + gains.joined(separator: ", ") }
        let global: [String: Any] = [
            "core:datatype": DataType.ci8.rawValue,
            "core:sample_rate": Double(rec.sampleRate),
            "core:version": version,
            "core:num_channels": 1,
            "core:hw": "HackRF One + PortaPack (Mayhem)",
            "core:recorder": "PortaPack Manager \(appVersion)",
            "core:description": description,
        ]
        let capture: [String: Any] = [
            "core:sample_start": 0,
            "core:frequency": Double(rec.centerHz),
            "core:datetime": ISOTime.string(rec.date),
        ]
        let object: [String: Any] = ["global": global, "captures": [capture], "annotations": [Any]()]
        // Kann nicht scheitern: nur Zeichenketten, endliche Zahlen, Felder.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: Import

    /// Liest und prüft Metadaten. Wirft `SigMFError` mit Klartext.
    static func parse(_ data: Data) throws -> Metadata {
        guard data.count <= maximumMetaBytes else { throw SigMFError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw SigMFError.notJSON
        }
        guard let object = root as? [String: Any] else { throw SigMFError.wrongType("(Wurzel)") }
        guard let globalAny = object["global"] else { throw SigMFError.missing("global") }
        guard let global = globalAny as? [String: Any] else { throw SigMFError.wrongType("global") }
        var warnings: [String] = []

        // Version: Pflicht laut Spezifikation, fehlt aber in manchen Werkzeugen.
        if let versionAny = global["core:version"] {
            guard let version = versionAny as? String else { throw SigMFError.wrongType("core:version") }
            guard version.split(separator: ".").first == "1" else { throw SigMFError.unsupportedVersion(String(version.prefix(40))) }
        } else {
            warnings.append(String(localized: "„core:version“ fehlt – gelesen wie SigMF 1.x."))
        }

        guard let typeAny = global["core:datatype"] else { throw SigMFError.missing("core:datatype") }
        guard let typeName = typeAny as? String else { throw SigMFError.wrongType("core:datatype") }
        guard let type = DataType(rawValue: typeName.lowercased()) else {
            throw SigMFError.unsupportedType(String(typeName.prefix(40)))
        }

        guard let rateAny = global["core:sample_rate"] else { throw SigMFError.missing("core:sample_rate") }
        guard let rate = number(rateAny) else { throw SigMFError.wrongType("core:sample_rate") }
        // `IQRecording.sampleRate` ist UInt32; unter 1 kS/s ergibt keine Auswertung Sinn.
        guard rate.isFinite, rate >= 1_000, rate <= Double(UInt32.max) else { throw SigMFError.invalidValue("core:sample_rate") }

        if let channelsAny = global["core:num_channels"] {
            guard let channels = integer(channelsAny) else { throw SigMFError.invalidValue("core:num_channels") }
            if channels != 1 { throw SigMFError.multiChannel(channels) }
        }
        if let onlyAny = global["core:metadata_only"], (onlyAny as? Bool) == true { throw SigMFError.metadataOnly }

        var meta = Metadata(dataType: type, sampleRate: rate)
        if let trailing = global["core:trailing_bytes"] {
            guard let value = integer(trailing) else { throw SigMFError.invalidValue("core:trailing_bytes") }
            meta.trailingBytes = value
        }
        if let dataset = global["core:dataset"] {
            guard let name = dataset as? String else { throw SigMFError.wrongType("core:dataset") }
            // Nur der Dateiname – kein Pfad aus fremden Metadaten.
            let last = (name as NSString).lastPathComponent
            if !last.isEmpty, last != ".", last != ".." { meta.dataset = last }
        }
        meta.hardware = text(global["core:hw"])
        meta.recorder = text(global["core:recorder"])
        meta.description = text(global["core:description"])
        if global["core:geolocation"] != nil {
            warnings.append(String(localized: "Die Datei enthält einen Standort („core:geolocation“); er wird nicht übernommen."))
        }

        // Erfassungen: Mitte und Zeit aus der ersten, der Rest wird nur geprüft.
        let captures: [[String: Any]]
        if let capturesAny = object["captures"] {
            guard let list = capturesAny as? [Any] else { throw SigMFError.wrongType("captures") }
            captures = try list.map {
                guard let entry = $0 as? [String: Any] else { throw SigMFError.wrongType("captures") }
                return entry
            }
        } else {
            captures = []
        }
        if captures.isEmpty {
            warnings.append(String(localized: "Keine Erfassung („captures“) – Mittenfrequenz und Zeit unbekannt."))
        }
        var previousStart = -1
        var frequencies: [Double] = []
        for (index, capture) in captures.enumerated() {
            var start = 0
            if let startAny = capture["core:sample_start"] {
                guard let value = integer(startAny) else { throw SigMFError.invalidValue("core:sample_start") }
                start = value
            } else if index > 0 {
                throw SigMFError.missing("core:sample_start")
            }
            guard start > previousStart else { throw SigMFError.invalidValue("core:sample_start") }
            previousStart = start
            meta.lastCaptureStart = start
            if let headerAny = capture["core:header_bytes"] {
                guard let header = integer(headerAny) else { throw SigMFError.invalidValue("core:header_bytes") }
                if index == 0 { meta.headerBytes = header } else if header > 0 { throw SigMFError.unsupportedHeaders }
            }
            if let frequencyAny = capture["core:frequency"] {
                guard let frequency = number(frequencyAny) else { throw SigMFError.wrongType("core:frequency") }
                // Bis 1 THz – darüber hinaus gibt es keinen sinnvollen HF-Empfang (und UInt64 bleibt sicher).
                guard frequency.isFinite, frequency >= 0, frequency <= 1e12 else { throw SigMFError.invalidValue("core:frequency") }
                frequencies.append(frequency)
                if index == 0 { meta.frequency = frequency }
            }
            if index == 0, let dateAny = capture["core:datetime"] {
                if let text = dateAny as? String, let date = ISOTime.date(text) {
                    meta.datetime = date
                } else {
                    warnings.append(String(localized: "„core:datetime“ ist kein gültiger Zeitpunkt – übernommen wird das Dateidatum."))
                }
            }
        }
        if !captures.isEmpty, meta.frequency == nil {
            warnings.append(String(localized: "Die erste Erfassung nennt keine Mittenfrequenz („core:frequency“). ADS-B, GPS, Fernsehen, DAB+ und Zigbee erwarten eine bestimmte Mitte."))
        }
        if let first = frequencies.first, frequencies.contains(where: { abs($0 - first) > 1 }) {
            warnings.append(String(format: String(localized: "Die Aufnahme wechselt die Frequenz (%d Erfassungen); übernommen wird die erste: %.6f MHz."),
                                   captures.count, first / 1_000_000))
        }
        if abs(rate - rate.rounded()) > 0.01 {
            warnings.append(String(format: String(localized: "Abtastrate %.3f S/s gerundet auf %d S/s."), rate, Int(rate.rounded())))
        }
        meta.warnings = warnings
        return meta
    }

    /// Endliche Zahl (keine Wahrheitswerte – JSON `true` käme sonst als 1 an).
    private static func number(_ any: Any) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let value = n.doubleValue
        return value.isFinite ? value : nil
    }

    /// Nicht negative ganze Zahl in einem sicheren Bereich (Bytes, Abtastwerte).
    private static func integer(_ any: Any) -> Int? {
        guard let value = number(any), value >= 0, value <= 1e15, value == value.rounded() else { return nil }
        return Int(value)
    }

    /// Freitext, auf eine vernünftige Länge gekürzt.
    private static func text(_ any: Any?) -> String? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return String(s.prefix(500))
    }

    // MARK: Umwandlung nach int8

    /// Skalierung breiter Datentypen auf int8: Der höchste Betrag im Anfang
    /// der Datei (bis 1 Mio. Abtastwerte) landet bei ±100 – Luft für lautere
    /// Stellen später, und leise Aufnahmen (typisch für cf32 aus GNU Radio)
    /// verlieren nicht alle Bits. Ohne Signal gilt der Nennbereich des Typs.
    static func scale(for type: DataType, peak: Float) -> Float {
        guard type.needsScaling else { return 1 }
        if peak > 0, peak.isFinite {
            let s = 100 / peak
            if s.isFinite { return s }
        }
        switch type {
        case .ci16LE, .ci16BE, .cu16LE: return 127 / 32767
        default: return 127
        }
    }

    /// Höchster Betrag einer Komponente in `bytes` (NaN/∞ übersprungen).
    static func peak(_ bytes: UnsafeRawBufferPointer, type: DataType) -> Float {
        var peak: Float = 0
        forEachComponent(bytes, type: type) { v in
            let a = abs(v)
            if a.isFinite, a > peak { peak = a }
        }
        return peak
    }

    /// Wandelt ganze Abtastwerte in int8-IQ (`ci8`) um; ein angebrochener
    /// Abtastwert am Ende wird ignoriert.
    static func convert(_ bytes: UnsafeRawBufferPointer, type: DataType, scale: Float) -> Data {
        let usable = bytes.count / type.bytesPerSample * type.bytesPerSample
        let components = usable / type.bytesPerSample * 2
        var out = Data(count: components)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let dst = raw.bindMemory(to: Int8.self)
            switch type {
            case .ci8:
                dst.baseAddress!.update(from: bytes.baseAddress!.assumingMemoryBound(to: Int8.self), count: components)
            case .cu8:
                for i in 0..<components { dst[i] = Int8(bitPattern: bytes[i] ^ 0x80) }
            default:
                var i = 0
                forEachComponent(UnsafeRawBufferPointer(rebasing: bytes[0..<usable]), type: type) { v in
                    let scaled = v * scale
                    dst[i] = scaled.isNaN ? 0 : Int8(max(-127, min(127, scaled.rounded())))
                    i += 1
                }
            }
        }
        return out
    }

    /// Ruft `body` mit jeder Komponente (I, Q, I, Q …) als Float auf –
    /// ganze Werte unskaliert, cu16 um die Mitte verschoben.
    private static func forEachComponent(_ bytes: UnsafeRawBufferPointer, type: DataType, _ body: (Float) -> Void) {
        let usable = bytes.count / type.bytesPerSample * type.bytesPerSample
        switch type {
        case .ci8:
            for i in 0..<usable { body(Float(Int8(bitPattern: bytes[i]))) }
        case .cu8:
            for i in 0..<usable { body(Float(Int(bytes[i]) - 128)) }
        case .ci16LE, .ci16BE, .cu16LE:
            var i = 0
            while i < usable {
                let raw = type == .ci16BE ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
                                          : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i])
                body(type == .cu16LE ? Float(Int(raw) - 32768) : Float(Int16(bitPattern: raw)))
                i += 2
            }
        case .cf32LE, .cf32BE:
            var i = 0
            while i < usable {
                let b0 = UInt32(bytes[i]), b1 = UInt32(bytes[i + 1]), b2 = UInt32(bytes[i + 2]), b3 = UInt32(bytes[i + 3])
                let bits = type == .cf32LE ? b3 << 24 | b2 << 16 | b1 << 8 | b0 : b0 << 24 | b1 << 16 | b2 << 8 | b3
                body(Float(bitPattern: bits))
                i += 4
            }
        }
    }
}

/// Export und Import von SigMF-Dateien für die Aufnahmeseite. Läuft abseits
/// des Main Actors (große Dateien); Fortschritt 0…1, kooperativ abbrechbar.
enum SigMFTransfer {
    struct ImportResult: Sendable {
        var recording: IQRecording
        var warnings: [String]
    }

    /// Schreibt `<basis>.sigmf-data` (Kopie, auf APFS ein Klon) und
    /// `<basis>.sigmf-meta`. Vorhandene Dateien gleichen Namens werden ersetzt.
    static func export(_ rec: IQRecording, from source: URL, to chosen: URL) throws -> (meta: URL, data: URL) {
        let base = chosen.pathExtension.lowercased() == SigMF.metaExtension || chosen.pathExtension.lowercased() == SigMF.dataExtension
            ? chosen.deletingPathExtension() : chosen
        let data = base.appendingPathExtension(SigMF.dataExtension)
        let meta = base.appendingPathExtension(SigMF.metaExtension)
        let fm = FileManager.default
        if data.standardizedFileURL != source.standardizedFileURL {
            if fm.fileExists(atPath: data.path) { try fm.removeItem(at: data) }
            try fm.copyItem(at: source, to: data)
        }
        try SigMF.metadata(for: rec).write(to: meta, options: .atomic)
        return (meta, data)
    }

    /// Liest eine SigMF-Aufnahme, wandelt sie nach int8-IQ und legt sie als
    /// `<name>.c8` + JSON in `folder` ab. `reserveBytes` bleibt auf dem
    /// Laufwerk frei (wie bei der Aufnahme).
    static func importFile(at url: URL, into folder: URL, name: String,
                           reserveBytes: Int64 = IQRecorder.reserveBytes,
                           progress: @Sendable (Double) -> Void = { _ in },
                           isCancelled: @Sendable () -> Bool = { false }) throws -> ImportResult {
        let files = try SigMF.companions(of: url)
        let metaData: Data
        do {
            let size = (try? files.meta.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= SigMF.maximumMetaBytes else { throw SigMF.SigMFError.tooLarge }
            metaData = try Data(contentsOf: files.meta)
        }
        var meta = try SigMF.parse(metaData)
        let dataURL = meta.dataset.map { files.meta.deletingLastPathComponent().appendingPathComponent($0) } ?? files.data
        guard let fileSize = (try? dataURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            throw SigMF.SigMFError.dataMissing(dataURL.lastPathComponent)
        }
        let samples = try meta.sampleCount(fileSize: fileSize)
        let payload = fileSize - meta.headerBytes - meta.trailingBytes
        if payload % meta.dataType.bytesPerSample != 0 {
            meta.warnings.append(String(localized: "Die Datendatei endet mit einem angebrochenen Abtastwert; er wird weggelassen."))
        }
        let outputBytes = samples * 2
        if let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           Int64(outputBytes) > free - reserveBytes {
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let output = folder.appendingPathComponent(name + ".c8")
        let input = try FileHandle(forReadingFrom: dataURL)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: output.path])
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        let bps = meta.dataType.bytesPerSample
        let chunkSamples = 262_144
        try input.seek(toOffset: UInt64(meta.headerBytes))
        var scale: Float = 1
        if meta.dataType.needsScaling {
            let probe = try input.read(upToCount: min(samples, 1 << 20) * bps) ?? Data()
            scale = SigMF.scale(for: meta.dataType, peak: probe.withUnsafeBytes { SigMF.peak($0, type: meta.dataType) })
            try input.seek(toOffset: UInt64(meta.headerBytes))
        }
        var done = 0
        while done < samples {
            if isCancelled() { throw CancellationError() }
            let count = min(chunkSamples, samples - done)
            guard let chunk = try input.read(upToCount: count * bps), chunk.count == count * bps else {
                throw SigMF.SigMFError.dataTooShort(samples: done, required: samples)
            }
            try writer.write(contentsOf: chunk.withUnsafeBytes { SigMF.convert($0, type: meta.dataType, scale: scale) })
            done += count
            progress(Double(done) / Double(samples))
        }
        try writer.close()

        let date = meta.datetime
            ?? (try? dataURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date()
        var rec = IQRecording(name: name, centerHz: meta.centerHz, sampleRate: meta.sampleRateHz, date: date, byteCount: outputBytes)
        rec.importedFrom = files.meta.lastPathComponent
        let json = try JSONEncoder().encode(rec)
        try json.write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
        completed = true
        if meta.dataType.needsScaling {
            meta.warnings.append(String(format: String(localized: "%@ wurde auf 8 Bit umgerechnet (Faktor %.3g, Spitze ≈ 100 von 127)."), meta.dataType.rawValue, scale))
        }
        return ImportResult(recording: rec, warnings: meta.warnings)
    }

    /// Name für die Ablage: Dateiname ohne Endung, nur unbedenkliche Zeichen,
    /// eindeutig gegenüber `existing`.
    static func storeName(for url: URL, existing: Set<String>) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var cleaned = String(String.UnicodeScalarView(base.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if cleaned.isEmpty { cleaned = "Import" }
        var name = "SigMF_" + cleaned
        var n = 2
        while existing.contains(name) {
            name = "SigMF_\(cleaned)_\(n)"
            n += 1
        }
        return name
    }
}
