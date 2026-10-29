import Foundation
import Testing
@testable import PortaPackManager

@Suite("SigMF")
struct SigMFTests {
    /// Eigener Ordner je Test, danach gelöscht.
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sigmf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func meta(_ global: [String: Any], captures: [[String: Any]]? = [["core:sample_start": 0, "core:frequency": 100e6]]) -> Data {
        var object: [String: Any] = ["global": global, "annotations": [Any]()]
        if let captures { object["captures"] = captures }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func writePair(_ folder: URL, name: String, meta: Data, data: Data) throws -> URL {
        let metaURL = folder.appendingPathComponent(name + ".sigmf-meta")
        try meta.write(to: metaURL)
        try data.write(to: folder.appendingPathComponent(name + ".sigmf-data"))
        return metaURL
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Rundlauf: Export und Import liefern dieselben Abtastwerte, Metadaten ohne Standort")
    func roundTrip() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var bytes = [UInt8](repeating: 0, count: 600_002)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i / 7) }
        let source = folder.appendingPathComponent("IQ_test.c8")
        try Data(bytes).write(to: source)
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let rec = IQRecording(name: "IQ_test", centerHz: 1_090_000_000, sampleRate: 2_000_000, date: date,
                              byteCount: bytes.count, lnaGain: 24, vgaGain: 20, amplifier: false)

        let files = try SigMFTransfer.export(rec, from: source, to: folder.appendingPathComponent("Export.sigmf-meta"))
        #expect(files.data.lastPathComponent == "Export.sigmf-data")
        #expect(try Data(contentsOf: files.data) == Data(bytes))

        let json = try object(Data(contentsOf: files.meta))
        let global = try #require(json["global"] as? [String: Any])
        #expect(global["core:datatype"] as? String == "ci8")
        #expect(global["core:version"] as? String == SigMF.version)
        #expect((global["core:sample_rate"] as? NSNumber)?.doubleValue == 2_000_000)
        #expect((global["core:hw"] as? String)?.contains("HackRF") == true)
        #expect((global["core:recorder"] as? String)?.hasPrefix("PortaPack Manager") == true)
        #expect((global["core:description"] as? String)?.contains("LNA 24 dB") == true)
        #expect(global["core:geolocation"] == nil)
        #expect(json["annotations"] is [Any])
        let capture = try #require((json["captures"] as? [[String: Any]])?.first)
        #expect((capture["core:frequency"] as? NSNumber)?.doubleValue == 1_090_000_000)
        #expect((capture["core:sample_start"] as? NSNumber)?.intValue == 0)
        #expect(capture["core:datetime"] as? String == ISOTime.string(date))
        // Kein Standort, auch nicht unter anderem Namen.
        let text = try #require(String(data: Data(contentsOf: files.meta), encoding: .utf8))
        #expect(!text.contains("geolocation") && !text.contains("latitude"))

        let store = folder.appendingPathComponent("Ablage", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let imported = try SigMFTransfer.importFile(at: files.meta, into: store, name: "SigMF_Export", reserveBytes: 0)
        #expect(imported.warnings.isEmpty)
        #expect(imported.recording.centerHz == rec.centerHz)
        #expect(imported.recording.sampleRate == rec.sampleRate)
        #expect(imported.recording.date == date)
        #expect(imported.recording.byteCount == bytes.count)
        #expect(imported.recording.importedFrom == "Export.sigmf-meta")
        #expect(try Data(contentsOf: store.appendingPathComponent("SigMF_Export.c8")) == Data(bytes))
        let stored = try JSONDecoder().decode(IQRecording.self, from: Data(contentsOf: store.appendingPathComponent("SigMF_Export.json")))
        #expect(stored == imported.recording)
        // Auch über die Datendatei gewählt.
        let again = try SigMFTransfer.importFile(at: files.data, into: store, name: "SigMF_Export_2", reserveBytes: 0)
        #expect(again.recording.byteCount == bytes.count)
    }

    @Test("Alte Aufnahme-JSONs ohne die neuen Felder lassen sich weiter lesen")
    func legacyRecordingDecodes() throws {
        let json = #"{"name":"IQ_alt","centerHz":1090000000,"sampleRate":2000000,"date":800000000,"byteCount":4}"#
        let rec = try JSONDecoder().decode(IQRecording.self, from: Data(json.utf8))
        #expect(rec.sigmf == nil && rec.lnaGain == nil && rec.importedFrom == nil)
    }

    @Test("cu8 (rtl_sdr) wird um 128 verschoben")
    func importCU8() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writePair(folder, name: "rtl", meta: meta(["core:datatype": "cu8", "core:sample_rate": 2_400_000, "core:version": "1.0.0"]),
                                data: Data([128, 128, 255, 0, 129, 127]))
        let result = try SigMFTransfer.importFile(at: url, into: folder, name: "out", reserveBytes: 0)
        let out = try Data(contentsOf: folder.appendingPathComponent("out.c8")).map { Int8(bitPattern: $0) }
        #expect(out == [0, 0, 127, -128, 1, -1])
        #expect(result.recording.sampleRate == 2_400_000)
        #expect(result.recording.centerHz == 100_000_000)
    }

    @Test("ci16 (LE und BE) wird so skaliert, dass die Spitze bei 100 liegt")
    func importCI16() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let values: [Int16] = [1000, -1000, 500, 0, -250, 10]
        var le = Data(), be = Data()
        for v in values {
            let u = UInt16(bitPattern: v)
            le.append(contentsOf: [UInt8(u & 0xFF), UInt8(u >> 8)])
            be.append(contentsOf: [UInt8(u >> 8), UInt8(u & 0xFF)])
        }
        for (type, data) in [("ci16_le", le), ("ci16_be", be)] {
            let url = try writePair(folder, name: type, meta: meta(["core:datatype": type, "core:sample_rate": 1e6, "core:version": "1.2.0"]), data: data)
            let result = try SigMFTransfer.importFile(at: url, into: folder, name: "out-" + type, reserveBytes: 0)
            let out = try Data(contentsOf: folder.appendingPathComponent("out-\(type).c8")).map { Int8(bitPattern: $0) }
            #expect(out == [100, -100, 50, 0, -25, 1], "\(type)")
            #expect(result.recording.byteCount == 6)
            #expect(result.warnings.contains { $0.contains("8 Bit") })
        }
    }

    @Test("cf32 wird skaliert; NaN wird 0, ∞ wird begrenzt")
    func importCF32() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let values: [Float] = [0.5, -0.25, .nan, .infinity, -.infinity, 0.001]
        var data = Data()
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        let url = try writePair(folder, name: "gr", meta: meta(["core:datatype": "cf32_le", "core:sample_rate": 2_048_000]), data: data)
        let result = try SigMFTransfer.importFile(at: url, into: folder, name: "out", reserveBytes: 0)
        let out = try Data(contentsOf: folder.appendingPathComponent("out.c8")).map { Int8(bitPattern: $0) }
        #expect(out == [100, -50, 0, 127, -127, 0])
        #expect(result.warnings.contains { $0.contains("core:version") })
    }

    @Test("Ganz leise cf32-Daten verlieren nicht alle Bits")
    func quietCF32() {
        let values: [Float] = [0.001, -0.0005, 0.0002, 0]
        var data = Data()
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        let out = data.withUnsafeBytes { raw in
            SigMF.convert(raw, type: .cf32LE, scale: SigMF.scale(for: .cf32LE, peak: SigMF.peak(raw, type: .cf32LE)))
        }.map { Int8(bitPattern: $0) }
        #expect(out == [100, -50, 20, 0])
        // Ohne Signal gilt der Nennbereich.
        #expect(SigMF.scale(for: .cf32LE, peak: 0) == 127)
        #expect(SigMF.scale(for: .ci8, peak: 3) == 1)
    }

    @Test("Klare Fehler bei unbrauchbaren Metadaten")
    func errors() {
        func parse(_ global: [String: Any], captures: [[String: Any]]? = [["core:sample_start": 0]]) throws -> SigMF.Metadata {
            try SigMF.parse(meta(global, captures: captures))
        }
        #expect(throws: SigMF.SigMFError.missing("core:datatype")) { try parse(["core:sample_rate": 1e6]) }
        #expect(throws: SigMF.SigMFError.missing("core:sample_rate")) { try parse(["core:datatype": "ci8"]) }
        #expect(throws: SigMF.SigMFError.unsupportedType("rf32_le")) { try parse(["core:datatype": "rf32_le", "core:sample_rate": 1e6]) }
        #expect(throws: SigMF.SigMFError.wrongType("core:sample_rate")) { try parse(["core:datatype": "ci8", "core:sample_rate": true]) }
        #expect(throws: SigMF.SigMFError.wrongType("core:sample_rate")) { try parse(["core:datatype": "ci8", "core:sample_rate": "2e6"]) }
        #expect(throws: SigMF.SigMFError.invalidValue("core:sample_rate")) { try parse(["core:datatype": "ci8", "core:sample_rate": -5]) }
        #expect(throws: SigMF.SigMFError.invalidValue("core:sample_rate")) { try parse(["core:datatype": "ci8", "core:sample_rate": 1e300]) }
        #expect(throws: SigMF.SigMFError.invalidValue("core:sample_rate")) { try parse(["core:datatype": "ci8", "core:sample_rate": 0]) }
        #expect(throws: SigMF.SigMFError.unsupportedVersion("2.0.0")) { try parse(["core:datatype": "ci8", "core:sample_rate": 1e6, "core:version": "2.0.0"]) }
        #expect(throws: SigMF.SigMFError.multiChannel(2)) { try parse(["core:datatype": "ci8", "core:sample_rate": 1e6, "core:num_channels": 2]) }
        #expect(throws: SigMF.SigMFError.metadataOnly) { try parse(["core:datatype": "ci8", "core:sample_rate": 1e6, "core:metadata_only": true]) }
        #expect(throws: SigMF.SigMFError.invalidValue("core:sample_start")) {
            try parse(["core:datatype": "ci8", "core:sample_rate": 1e6], captures: [["core:sample_start": 1e300]])
        }
        #expect(throws: SigMF.SigMFError.invalidValue("core:sample_start")) {
            try parse(["core:datatype": "ci8", "core:sample_rate": 1e6], captures: [["core:sample_start": 10], ["core:sample_start": 5]])
        }
        #expect(throws: SigMF.SigMFError.invalidValue("core:frequency")) {
            try parse(["core:datatype": "ci8", "core:sample_rate": 1e6], captures: [["core:sample_start": 0, "core:frequency": -1]])
        }
        #expect(throws: SigMF.SigMFError.invalidValue("core:frequency")) {
            try parse(["core:datatype": "ci8", "core:sample_rate": 1e6], captures: [["core:sample_start": 0, "core:frequency": 1e40]])
        }
        #expect(throws: SigMF.SigMFError.unsupportedHeaders) {
            try parse(["core:datatype": "ci8", "core:sample_rate": 1e6], captures: [["core:sample_start": 0], ["core:sample_start": 5, "core:header_bytes": 16]])
        }
        #expect(throws: SigMF.SigMFError.notJSON) { try SigMF.parse(Data("{\"global\": {".utf8)) }
        #expect(throws: SigMF.SigMFError.notJSON) { try SigMF.parse(Data([0xFF, 0xFE, 0x00])) }
        #expect(throws: SigMF.SigMFError.wrongType("(Wurzel)")) { try SigMF.parse(Data("[1,2,3]".utf8)) }
        #expect(throws: SigMF.SigMFError.missing("global")) { try SigMF.parse(Data("{}".utf8)) }
        // NaN gibt es in JSON nicht; Überlauf auf ∞ darf trotzdem nicht durchrutschen.
        #expect(throws: (any Error).self) {
            try SigMF.parse(Data(#"{"global":{"core:datatype":"ci8","core:sample_rate":1e999}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try SigMF.parse(Data(#"{"global":{"core:datatype":"ci8","core:sample_rate":NaN}}"#.utf8))
        }
        #expect(throws: SigMF.SigMFError.archive) { try SigMF.companions(of: URL(fileURLWithPath: "/tmp/a.sigmf")) }
        #expect(throws: SigMF.SigMFError.wrongFile) { try SigMF.companions(of: URL(fileURLWithPath: "/tmp/a.wav")) }
        // Jede Meldung ist Klartext.
        #expect(SigMF.SigMFError.dataTooShort(samples: 3, required: 10).errorDescription?.contains("10") == true)
    }

    @Test("Fehlende Erfassungen, Frequenzwechsel, Standort und krumme Raten gehen mit Hinweis durch")
    func warnings() throws {
        let noCaptures = try SigMF.parse(meta(["core:datatype": "ci8", "core:sample_rate": 1e6, "core:version": "1.2.0"], captures: nil))
        #expect(noCaptures.frequency == nil && noCaptures.centerHz == 0)
        #expect(!noCaptures.warnings.isEmpty)

        let hopping = try SigMF.parse(meta(["core:datatype": "ci8", "core:sample_rate": 1e6, "core:version": "1.2.0",
                                            "core:geolocation": ["type": "Point", "coordinates": [8.0, 53.0]]],
                                           captures: [["core:sample_start": 0, "core:frequency": 433.92e6, "core:datetime": "2026-10-29T10:00:00Z"],
                                                      ["core:sample_start": 1000, "core:frequency": 868.3e6]]))
        #expect(hopping.centerHz == 433_920_000)
        #expect(hopping.lastCaptureStart == 1000)
        #expect(hopping.datetime == ISOTime.date("2026-10-29T10:00:00Z"))
        #expect(hopping.warnings.count == 2)

        let odd = try SigMF.parse(meta(["core:datatype": "CI8", "core:sample_rate": 2_400_000.4, "core:version": "1.0.0"],
                                       captures: [["core:sample_start": 0, "core:datetime": "gestern"]]))
        #expect(odd.sampleRateHz == 2_400_000)
        #expect(odd.warnings.count == 3)   // Rundung, Zeitpunkt, fehlende Mitte
    }

    @Test("Datendatei kleiner als angegeben, fehlend oder leer")
    func dataProblems() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let short = try writePair(folder, name: "kurz",
                                  meta: meta(["core:datatype": "ci16_le", "core:sample_rate": 1e6],
                                             captures: [["core:sample_start": 0], ["core:sample_start": 1000]]),
                                  data: Data(count: 40))
        #expect(throws: SigMF.SigMFError.dataTooShort(samples: 10, required: 1001)) {
            try SigMFTransfer.importFile(at: short, into: folder, name: "x", reserveBytes: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("x.c8").path))

        let empty = try writePair(folder, name: "leer", meta: meta(["core:datatype": "ci8", "core:sample_rate": 1e6]), data: Data([1]))
        #expect(throws: SigMF.SigMFError.empty) { try SigMFTransfer.importFile(at: empty, into: folder, name: "y", reserveBytes: 0) }

        let lonely = folder.appendingPathComponent("allein.sigmf-meta")
        try meta(["core:datatype": "ci8", "core:sample_rate": 1e6]).write(to: lonely)
        #expect(throws: SigMF.SigMFError.dataMissing("allein.sigmf-data")) {
            try SigMFTransfer.importFile(at: lonely, into: folder, name: "z", reserveBytes: 0)
        }

        // Kopfbereich wird übersprungen, angebrochener Rest weggelassen.
        let headed = try writePair(folder, name: "kopf",
                                   meta: meta(["core:datatype": "ci8", "core:sample_rate": 1e6],
                                              captures: [["core:sample_start": 0, "core:header_bytes": 3]]),
                                   data: Data([9, 9, 9, 1, 2, 3, 4, 5]))
        let result = try SigMFTransfer.importFile(at: headed, into: folder, name: "k", reserveBytes: 0)
        #expect(try Data(contentsOf: folder.appendingPathComponent("k.c8")) == Data([1, 2, 3, 4]))
        #expect(result.warnings.contains { $0.contains("angebrochen") })

        // `core:dataset` darf nicht aus dem Ordner führen.
        let dataset = try SigMF.parse(meta(["core:datatype": "ci8", "core:sample_rate": 1e6, "core:dataset": "../../etc/passwd"]))
        #expect(dataset.dataset == "passwd")
    }

    @Test("Ablagename ist unbedenklich und eindeutig")
    func storeNames() {
        let url = URL(fileURLWithPath: "/tmp/Mein Signal: 433 MHz!.sigmf-meta")
        let name = SigMFTransfer.storeName(for: url, existing: [])
        #expect(name == "SigMF_Mein_Signal__433_MHz_")
        #expect(SigMFTransfer.storeName(for: url, existing: [name]) == name + "_2")
        #expect(SigMFTransfer.storeName(for: URL(fileURLWithPath: "/tmp/..x.sigmf-meta"), existing: []) == "SigMF_x")
        #expect(!SigMFTransfer.storeName(for: URL(fileURLWithPath: "/tmp/a/b.sigmf-data"), existing: []).contains("/"))
    }

    @Test("Fuzz: zufällige und verstümmelte Metadaten führen nie zum Absturz")
    func fuzz() throws {
        var rng = SplitMix(seed: 0x5161_4D46)
        let base = meta(["core:datatype": "ci16_le", "core:sample_rate": 2e6, "core:version": "1.2.0", "core:hw": "x"],
                        captures: [["core:sample_start": 0, "core:frequency": 1e8, "core:datetime": "2026-10-29T10:00:00Z"]])
        let values: [Any] = [NSNull(), true, false, 0, -1, 1, 1e308, -1e308, 4.5e15, 1.5, "", "ci8", "1.2.0", "x", [Any](), [String: Any](),
                             [1, 2], ["core:sample_start": "a"], Int.max, Int.min]
        let keys = ["core:datatype", "core:sample_rate", "core:version", "core:num_channels", "core:metadata_only",
                    "core:trailing_bytes", "core:dataset", "core:hw", "core:geolocation"]
        let captureKeys = ["core:sample_start", "core:frequency", "core:datetime", "core:header_bytes"]
        var parsed = 0
        for _ in 0..<3000 {
            var data: Data
            switch rng.next() % 3 {
            case 0:
                // Bytes verändern, abschneiden oder anhängen.
                data = base
                for _ in 0..<(1 + Int(rng.next() % 6)) {
                    let i = Int(rng.next() % UInt64(data.count))
                    data[i] = UInt8(truncatingIfNeeded: rng.next())
                }
                if rng.next() % 4 == 0 { data = data.prefix(Int(rng.next() % UInt64(data.count))) }
            case 1:
                // Strukturell gültiges JSON mit zufälligen Werten.
                var global: [String: Any] = [:]
                for key in keys where rng.next() % 2 == 0 { global[key] = values[Int(rng.next() % UInt64(values.count))] }
                var captures: [Any] = []
                for _ in 0..<Int(rng.next() % 4) {
                    var capture: [String: Any] = [:]
                    for key in captureKeys where rng.next() % 2 == 0 { capture[key] = values[Int(rng.next() % UInt64(values.count))] }
                    captures.append(rng.next() % 8 == 0 ? values[Int(rng.next() % UInt64(values.count))] : capture)
                }
                var object: [String: Any] = ["global": rng.next() % 10 == 0 ? values[Int(rng.next() % UInt64(values.count))] : global]
                if rng.next() % 5 != 0 { object["captures"] = captures }
                data = try JSONSerialization.data(withJSONObject: object)
            default:
                data = Data((0..<Int(rng.next() % 200)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            }
            if let meta = try? SigMF.parse(data) {
                parsed += 1
                #expect(meta.sampleRate.isFinite && meta.sampleRate >= 1_000 && meta.sampleRate <= Double(UInt32.max))
                #expect(meta.frequency.map { $0.isFinite && $0 >= 0 } ?? true)
                #expect(meta.headerBytes >= 0 && meta.trailingBytes >= 0 && meta.lastCaptureStart >= 0)
                _ = meta.sampleRateHz
                _ = meta.centerHz
                _ = try? meta.sampleCount(fileSize: Int(rng.next() % 1_000_000))
            }
        }
        #expect(parsed > 0)
    }
}

/// Reproduzierbarer Zufall für den Fuzz-Test.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
