import Foundation
import Testing
@testable import PortaPackManager

/// Regressionstests zum Review vom 28.10.2026: Dateiformate, Antworten aus
/// dem Netz und Datenweitergabe (K1, Y3, Y4, Y6, Y8, Y17 und Nitpicks).
@Suite("Datenprüfung")
struct DataIntegrityTests {

    // MARK: - wM-Bus (K1)

    @Test("wM-Bus Format B: L = 0x80 und 0x81 werden verworfen statt abzustürzen")
    func wmbusFormatBBoundary() {
        let filler = [UInt8](repeating: 0xA5, count: 140)
        #expect(WMBus.stripFormatB([0x80] + filler) == nil)
        #expect(WMBus.stripFormatB([0x81] + filler) == nil)
        // Ab L = 0x82 hat der zweite Block ein Datenbyte – gültig auswertbar.
        let two = WMBus.stripFormatB([0x82] + filler)
        #expect(two?.data.count == 127)
    }

    // MARK: - Belegungsaufzeichnung (Y3)

    private static func recordingData(sliceSeconds: Double = 60, threshold: Float = 10) -> (OccupancyRecording, Data) {
        let plan = OccupancyPlan(startMHz: 433.05, endMHz: 434.79, binKHz: 25)
        var recording = OccupancyRecording(name: "Prüfung", plan: plan, sliceSeconds: sliceSeconds, thresholdDB: threshold)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        recording.slices = (0..<3).map { i in
            OccupancySlice(start: start.addingTimeInterval(Double(i) * 60), floorDB: -60, visits: 1,
                           mean: [UInt8](repeating: 40, count: plan.binCount),
                           peak: [UInt8](repeating: 50, count: plan.binCount),
                           occupancy: [UInt8](repeating: 0, count: plan.binCount))
        }
        return (recording, recording.encoded())
    }

    @Test("Belegungsaufzeichnung: NaN/∞ im Kopf wird abgelehnt", arguments: [12, 20, 28, 36])
    func occupancyRejectsNonFinite(offset: Int) {
        var (_, data) = Self.recordingData()
        if offset == 36 { data.putLE(Float.nan.bitPattern, at: offset) } else { data.putLE(Double.nan.bitPattern, at: offset) }
        #expect(throws: OccupancyRecording.ReadError.self) { try OccupancyRecording.decode(data) }
        if offset == 36 { data.putLE(Float.infinity.bitPattern, at: offset) } else { data.putLE(Double.infinity.bitPattern, at: offset) }
        #expect(throws: OccupancyRecording.ReadError.self) { try OccupancyRecording.decode(data) }
    }

    @Test("Belegungsaufzeichnung: unplausible Scheibenlänge abgelehnt, kaputte Scheibe übersprungen")
    func occupancyRanges() throws {
        let (_, tooLong) = Self.recordingData(sliceSeconds: 1e9)
        #expect(throws: OccupancyRecording.ReadError.self) { try OccupancyRecording.decode(tooLong) }
        var (recording, data) = Self.recordingData()
        data.putLE(Double.nan.bitPattern, at: OccupancyRecording.headerSize + recording.recordSize)
        let decoded = try OccupancyRecording.decode(data)
        #expect(decoded.slices.count == 2)
        recording.slices.remove(at: 1)
        #expect(decoded.slices == recording.slices)
    }

    @Test("Zeitachse: riesige Sprünge zählen als lange Lücke (drei Leerzeilen)")
    func timelineHugeGap() {
        let slices = [0, 1e15].map {
            OccupancySlice(start: Date(timeIntervalSince1970: $0), floorDB: 0, visits: 0, mean: [1], peak: [1], occupancy: [0])
        }
        let timeline = OccupancyTimeline(slices: slices, sliceSeconds: 60)
        #expect(timeline.count == 5)
        #expect(OccupancyTimeline(slices: slices, sliceSeconds: .nan).count == 5)
    }

    // MARK: - Sondenvorhersage (Y4)

    @Test("Startzeiten außerhalb 0…7/0…23/0…59 werden ignoriert statt überzulaufen")
    func forecastTimesOutOfRange() throws {
        let json = Data("""
        {"10035": {"station_name": "Schleswig", "position": [9.55, 54.53],
                   "times": ["0:9999999999999999:00", "0:12:9999999999999999", "9:12:00", "-1:12:00", "0:24:00", "0:12:00"],
                   "rs_types": ["41"]}}
        """.utf8)
        let site = try #require(try SondeForecast.parseSites(json).first)
        let start = ISO8601DateFormatter().date(from: "2026-10-27T10:45:00Z")!
        let launches = SondeForecast.launches(of: site, from: start, to: start.addingTimeInterval(7200))
        #expect(launches == [start])
    }

    // MARK: - Radiosonden (Y6)

    @Test("RS41: Seriennummer nur aus A–Z und 0–9, sonst wird der Rahmen verworfen",
          arguments: ["V1;34567", "=CMD()12", "s1234567", "S12 4567", "S123\u{7}567"])
    func rs41SerialFilter(serial: String) {
        let frame = SondeSignal.rs41Frame(serial: serial, number: 1, lat: 50, lon: 8, alt: 900,
                                          north: 0, east: 0, up: 5, week: 2390, tow: 1000)
        var calibration: [String: RS41.Calibration] = [:]
        #expect(RS41.parse(frame, calibration: &calibration) == nil)
        #expect(calibration.isEmpty)
    }

    @Test("RS41: gültige Seriennummern bleiben erhalten")
    func rs41SerialValid() {
        #expect(RS41.isValidSerial("V1234567"))
        #expect(RS41.isValidSerial("S2210012"))
        #expect(!RS41.isValidSerial(""))
        #expect(!RS41.isValidSerial("ABCDEFGHI"))
        #expect(!RS41.isValidSerial("Ä1234567"))
    }

    @Test("Sonden-Export: Typ und Seriennummer als formelsichere CSV-Felder")
    func sondeExportCSVFields() {
        let flight = SondeFlight(serial: "=HYPERLINK(1)", type: "RS41;X",
                                 samples: [SondeSample(date: Date(timeIntervalSince1970: 1_800_000_000), altitude: 100)])
        let csv = SondeArchive.csv(flight)
        let row = csv.split(separator: "\n")[1]
        #expect(row.contains("\"'=HYPERLINK(1)\""))
        #expect(row.contains("\"RS41;X\""))
        #expect(SondeArchive.unquote("\"'=HYPERLINK(1)\"") == "=HYPERLINK(1)")
        #expect(SondeArchive.unquote("\"a\"\"b\"") == "a\"b")
        #expect(SondeArchive.unquote("V1") == "V1")
    }

    // MARK: - SondeHub (Y8)

    @Test("SondeHub: 4xx wird verworfen, 5xx, 408, 429 und Netzfehler wiederholt")
    @MainActor
    func sondeHubRetryPolicy() {
        typealias U = SondeHubUploader
        #expect(!U.shouldRetry(U.HTTPStatusError(status: 400, text: "")))
        #expect(!U.shouldRetry(U.HTTPStatusError(status: 403, text: "")))
        #expect(!U.shouldRetry(U.HTTPStatusError(status: 422, text: "")))
        #expect(U.shouldRetry(U.HTTPStatusError(status: 408, text: "")))
        #expect(U.shouldRetry(U.HTTPStatusError(status: 429, text: "")))
        #expect(U.shouldRetry(U.HTTPStatusError(status: 500, text: "")))
        #expect(U.shouldRetry(U.HTTPStatusError(status: 503, text: "")))
        #expect(U.shouldRetry(URLError(.timedOut)))
        #expect(U.maxAttempts >= 2)
    }

    // MARK: - MQTT (Y17)

    @Test("MQTT-Leser: viele kleine Pakete in einem Puffer, Rest bleibt erhalten")
    func mqttReaderOffset() throws {
        var reader = MQTTPacketReader()
        let ping = MQTTPacket.pingreq
        var bulk: [UInt8] = []
        for _ in 0..<20_000 { bulk += ping }
        let publish = MQTTPacket.publish(topic: "a/b", payload: Array("x".utf8), retain: false)
        reader.append(bulk + publish.prefix(3))
        var count = 0
        while let frame = try reader.next() {
            #expect(frame.kind == .pingreq)
            count += 1
        }
        #expect(count == 20_000)
        #expect(reader.pendingCount == 3)
        reader.append(publish.dropFirst(3))
        let frame = try #require(try reader.next())
        #expect(frame.kind == .publish)
        #expect(MQTTPacket.parsePublish(flags: frame.flags, body: frame.body)?.topic == "a/b")
        #expect(try reader.next() == nil)
        #expect(reader.pendingCount == 0)
    }

    // MARK: - EnOcean-Profile (Nitpick)

    @Test("EnOcean-Profile: höchstens 200, die ältesten fliegen zuerst")
    func enoceanProfileBook() {
        var book = EnOceanProfileBook()
        for i in 0..<250 { book.set("A5-02-05", for: String(format: "%08X", i)) }
        #expect(book.profiles.count == EnOceanProfileBook.defaultCapacity)
        #expect(book["00000000"] == nil)
        #expect(book[String(format: "%08X", 249)] == "A5-02-05")
        // Erneutes Setzen frischt auf; gleicher Wert ändert nichts.
        let unchanged = book.set("A5-02-05", for: String(format: "%08X", 50))
        let changed = book.set("A5-04-01", for: String(format: "%08X", 50))
        #expect(!unchanged && changed)
        #expect(book.order.last == String(format: "%08X", 50))
        book.set(nil, for: String(format: "%08X", 50))
        #expect(book[String(format: "%08X", 50)] == nil && !book.order.contains(String(format: "%08X", 50)))
        // Laden: ältere Stände ohne Reihenfolge und zu viele Einträge.
        var many: [String: String] = [:]
        for i in 0..<300 { many[String(format: "%08X", i)] = "A5-02-05" }
        let loaded = EnOceanProfileBook(profiles: many, order: ["0000012B", "unbekannt"])
        #expect(loaded.profiles.count == 200)
        #expect(loaded["0000012B"] == "A5-02-05")
        #expect(loaded.order.count == 200 && Set(loaded.order).count == 200)
    }
}

extension Data {
    /// Little-Endian-Wert an `offset` schreiben (für manipulierte Testdateien).
    mutating func putLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        let bytes = Swift.withUnsafeBytes(of: value.littleEndian) { Array($0) }
        replaceSubrange((startIndex + offset)..<(startIndex + offset + bytes.count), with: bytes)
    }
}
