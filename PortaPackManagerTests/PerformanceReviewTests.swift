import Foundation
import Testing
@testable import PortaPackManager

/// Leistungs-Review 29.10.2026 (L1, L4–L7): gleiche Ergebnisse wie vorher,
/// gemessen schneller. Laufzeiten nur mit `-configuration Release ENABLE_TESTABILITY=YES`
/// aussagekräftig; sie stehen im Protokoll des Testlaufs.
@Suite("Leistung: Zeitstempel, Blockstatistik, Archiv")
struct PerformanceReviewTests {
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    // MARK: L1 ISO-8601

    /// Zeilen wie in den echten Protokollen (aus `SondeArchiveTests`).
    private static let lines = [
        "2026-10-28T10:47:02Z;RS41;V3051090;1060;404.900;53.64949;10.11973;753;3.7;7.2;89;;;2.9",
        "2026-10-28T10:47:04Z;RS41;V3051090;1061;404.900;53.64949;10.11983;757;3.8;6.0;92;12.5;80;2.9",
        "2026-10-28T10:50:00Z;DFM;D123;;403.500;;;;;;;;;",
        "2026-10-28T11:38:24Z;RS41;V3051090;4100;404.900;53.91543;10.57704;16733;4.8;20;60;-60.5;5;2.6",
    ]

    @Test("ISOTime liest alles wie ISO8601DateFormatter und schreibt dasselbe Format")
    func isoCompatible() {
        let old = ISO8601DateFormatter()
        let texts = Self.lines.map { String($0.prefix { $0 != ";" }) } + [
            "2026-10-27T10:45:00Z", "2026-10-27T10:45:00+02:00", "2026-10-27T10:45:00-01:30", "2026-10-27T10:45:00+0200",
            "2026-10-27T10:45:00z", " 2026-10-27T10:45:00Z", "1969-12-31T23:59:58Z", "2026-02-29T00:00:00Z",
        ]
        for text in texts {
            #expect(ISOTime.date(text) == old.date(from: text), "\(text)")
        }
        // Was der alte nicht las, liest auch der neue nicht.
        for text in ["", "kaputt", "2026-10-27", "2026-10-27 10:45:00Z", "2026-10-27T10:45:00", "20261027T104500Z"] {
            #expect(ISOTime.date(text) == nil, "\(text)")
            #expect(old.date(from: text) == nil, "\(text)")
        }
        // Schreiben: ganze Sekunden bitgleich, Rundlauf exakt.
        for t in stride(from: 1_700_000_000.0, to: 1_800_000_000, by: 7_777_777.0) {
            let date = Date(timeIntervalSince1970: t)
            #expect(ISOTime.string(date) == old.string(from: date))
            #expect(ISOTime.date(ISOTime.string(date)) == date)
        }
        // Millisekunden: Format wie mit `.withFractionalSeconds`.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = Date(timeIntervalSince1970: 1_793_097_900.5)
        #expect(ISOTime.fractionalString(date) == fractional.string(from: date))
        #expect(ISOTime.fractionalString(date) == "2026-10-27T10:45:00.500Z")
        #expect(ISOTime.date("2026-10-27T10:45:00.500Z") == date)
    }

    @Test("Sondenprotokoll: Rundlauf Zeile → Archiv → Zeile, gleiche Zeitstempel")
    func sondeRoundTrip() throws {
        let old = ISO8601DateFormatter()
        let rows = SondeArchive.parse(SondeLog.header + Self.lines.joined(separator: "\n") + "\n")
        #expect(rows.count == 4)
        for (row, line) in zip(rows, Self.lines) {
            #expect(row.sample.date == old.date(from: String(line.prefix { $0 != ";" })))
        }
        let flight = try #require(SondeArchive.flights(from: rows).first { $0.serial == "V3051090" })
        let csv = SondeArchive.csv(flight).split(separator: "\n").dropFirst()
        #expect(csv.first?.hasPrefix("2026-10-28T10:47:02Z;") == true)
        // Meldungszeile wie bisher.
        var report = SondeReport(kind: .rs41, serial: "V1", model: "RS41")
        report.frequency = 404.9e6
        let line = SondeLog.line(report, received: Date(timeIntervalSince1970: 1_793_097_900))
        #expect(line.hasPrefix(old.string(from: Date(timeIntervalSince1970: 1_793_097_900)) + ";RS41;V1;"))
    }

    @Test("Benchmark: Sondenarchiv lesen (12 000 Zeilen)")
    func sondeParseBenchmark() {
        var text = SondeLog.header
        let start = Date(timeIntervalSince1970: 1_793_097_900)
        for k in 0..<12_000 {
            text += ISOTime.string(start.addingTimeInterval(Double(k))) + ";RS41;V3051090;\(k);404.900;53.64949;10.11973;753;3.7;7.2;89;12.5;80;2.9\n"
        }
        let clock = ContinuousClock()
        var rows: [SondeArchive.Row] = []
        let new = clock.measure { rows = SondeArchive.parse(text) }
        // Zum Vergleich der frühere Weg: dieselbe Zerlegung mit `ISO8601DateFormatter`.
        let old = clock.measure {
            let iso = ISO8601DateFormatter()
            var n = 0
            for line in text.split(separator: "\n") {
                let f = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                if f.count >= 14, iso.date(from: f[0]) != nil { n += 1 }
            }
            #expect(n == 12_000)
        }
        print(String(format: "Sondenarchiv 12 000 Zeilen: alt %.0f ms, neu %.1f ms", Self.seconds(old) * 1000, Self.seconds(new) * 1000))
        #expect(rows.count == 12_000)
        #expect(rows.last?.sample.date == start.addingTimeInterval(11_999))
        #if !DEBUG
        #expect(Self.seconds(new) < Self.seconds(old) / 5)
        #endif
    }

    // MARK: L4 Blockstatistik

    /// Die frühere Fassung, als Referenz.
    private static func referenceStatistics(_ data: Data) -> (clipped: Double, rmsDBFS: Double, peakDBFS: Double) {
        guard !data.isEmpty else { return (0, -100, -100) }
        var n = 0, sum = 0, peak = 0
        for byte in data {
            let v = Int(Int8(bitPattern: byte))
            if v >= 127 || v <= -127 { n += 1 }
            sum += v * v
            peak = max(peak, abs(v))
        }
        let mean = Double(sum) / Double(data.count) / (128 * 128)
        return (Double(n) / Double(data.count), 10 * log10(max(mean, 1e-10)), 20 * log10(max(Double(peak) / 128, 1e-5)))
    }

    @Test("Blockstatistik: bitgleich zur früheren Schleife")
    func blockStatistics() {
        var state: UInt64 = 42
        func byte() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        let random = Data((0..<262_151).map { _ in byte() })
        let quiet = Data(random.map { UInt8(bitPattern: Int8(bitPattern: $0) / 16) })
        let blocks = [random, quiet, Data(repeating: 0x80, count: 1 << 20), Data(repeating: 0x7F, count: 70_000),
                      Data(repeating: 0, count: 5), Data(), random.subdata(in: 3..<100_003)]
        for data in blocks {
            let a = HackRFDevice.blockStatistics(data), b = Self.referenceStatistics(data)
            #expect(a.clipped == b.clipped && a.rmsDBFS == b.rmsDBFS && a.peakDBFS == b.peakDBFS, "\(data.count) Byte")
        }
        let clock = ContinuousClock()
        let new = clock.measure { for _ in 0..<50 { _ = HackRFDevice.blockStatistics(random) } }
        let old = clock.measure { for _ in 0..<50 { _ = Self.referenceStatistics(random) } }
        print(String(format: "Blockstatistik 256 KiB: alt %.0f µs, neu %.0f µs", Self.seconds(old) / 50 * 1e6, Self.seconds(new) / 50 * 1e6))
    }

    // MARK: L5/L6 Verkehrsarchiv


    @Test("Archiv: Schreiben im Hintergrund, letzte Fassung gewinnt")
    @MainActor func backgroundSave() async {
        let db = TestDatabase()
        defer { db.remove() }
        let archive = TrafficArchive(kind: .adsb, database: db.database)
        let now = Date()
        for k in 0..<5 {
            archive.record([SightingUpdate(key: "ABC", lastSeen: now.addingTimeInterval(Double(k)), messages: k + 1,
                                           latitude: 53 + Double(k) * 0.1, longitude: 10)], home: nil)
            archive.save()
        }
        await archive.flush()
        let day = TrafficArchive.dayStamp(now)
        let onDisk = try! db.database.sync { try $0.sightings(kind: .adsb, days: [day]) }
        #expect(onDisk.count == 1)
        #expect(onDisk.first?.messages == 5)
        #expect(onDisk.first?.track.count == 5)
    }

    @Test("Archiv: alte Ziele werden vergessen, ohne doppelte Sichtung")
    @MainActor func pruneKeys() async {
        let db = TestDatabase()
        defer { db.remove() }
        let archive = TrafficArchive(kind: .adsb, database: db.database)
        let old = Date().addingTimeInterval(-40 * 60)
        let update = SightingUpdate(key: "OLD", lastSeen: old, messages: 3, latitude: 53, longitude: 10)
        archive.record([update], home: nil)
        archive.save()                                    // vergisst „OLD“ (40 min still)
        archive.record([update], home: nil)               // Empfänger meldet den alten Stand weiter
        await archive.flush()
        #expect(archive.sightings(day: TrafficArchive.dayStamp(old)).count == 1)
        // Neue Meldung nach der Lücke: neue Sichtung wie bisher.
        archive.record([SightingUpdate(key: "OLD", lastSeen: Date(), messages: 4, latitude: 53, longitude: 10)], home: nil)
        let all = archive.sightings(day: TrafficArchive.dayStamp(Date())) + (TrafficArchive.dayStamp(old) == TrafficArchive.dayStamp(Date())
            ? [] : archive.sightings(day: TrafficArchive.dayStamp(old)))
        #expect(all.count == 2)
    }

    // MARK: Belegungs-CSV

    @Test("Belegung: Zeitscheiben-CSV bitgleich zur früheren Fassung")
    func occupancySlicesCSV() {
        let plan = OccupancyPlan(startMHz: 433.05, endMHz: 434.79, binKHz: 25)
        var recording = OccupancyRecording(name: "Prüfung", plan: plan, sliceSeconds: 60, thresholdDB: 10)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        recording.slices = (0..<3).map { i in
            OccupancySlice(start: start.addingTimeInterval(Double(i) * 60), floorDB: -60.25, visits: 1,
                           mean: (0..<plan.binCount).map { UInt8(($0 * 7 + i) % 200) },
                           peak: (0..<plan.binCount).map { UInt8(($0 * 3 + i) % 220) },
                           occupancy: (0..<plan.binCount).map { UInt8(($0 * 5) % 255) })
        }
        // Die frühere Fassung (`ISO8601DateFormatter`, Frequenz je Zeile formatiert).
        let iso = ISO8601DateFormatter()
        var expected = "zeit_utc;frequenz_mhz;mittel_dbfs;spitze_dbfs;belegung_prozent;boden_dbfs\n"
        for slice in recording.slices {
            let t = iso.string(from: slice.start)
            for g in 0..<plan.binCount {
                guard let mean = slice.meanDB(g) else { continue }
                let occ = slice.occupancyFraction(g).map { String(format: "%.1f", $0 * 100) } ?? ""
                expected += "\(t);\(String(format: "%.5f", plan.binCenterMHz(g)));\(String(format: "%.1f", mean));"
                expected += "\(slice.peakDB(g).map { String(format: "%.1f", $0) } ?? "");\(occ);\(String(format: "%.1f", slice.floorDB))\n"
            }
        }
        #expect(OccupancyMonitor.slicesCSV(recording) == expected)
    }
}
