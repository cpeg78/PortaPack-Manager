import Foundation
import Testing
@testable import PortaPackManager

/// Frequenzspeicher: Rundlauf, Übernahme der alten Radio-Favoriten, CSV.
/// Jeder Test hat eigene UserDefaults und eine eigene Datei im Temp-Ordner –
/// der Testwirt teilt `.standard` und Application Support mit der App.
@Suite("Frequenzspeicher")
@MainActor
struct FrequencyMemoryTests {
    private func defaults() -> UserDefaults {
        let name = "FrequencyMemoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func fileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FrequencyMemoryTests-\(UUID().uuidString).json")
    }

    @Test("Rundlauf: Sichern und neu Laden ergibt dieselben Einträge")
    func roundTrip() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrequencyMemory(fileURL: url, defaults: defaults())
        #expect(store.entries.isEmpty)
        var entry = FrequencyMemoryEntry(mhz: 433.92, name: "Thermometer; Garten", mode: nil, page: .sensors)
        entry.note = "Zeile 1\nZeile 2"
        entry.group = "Haus"
        entry.bandwidthHz = 200_000
        store.add(entry)
        store.add(FrequencyMemoryEntry(mhz: 124.315, name: "Turm", mode: RadioMode.am.rawValue, page: .radio))
        let reloaded = FrequencyMemory(fileURL: url, defaults: defaults())
        #expect(reloaded.entries == store.entries)
        #expect(reloaded.entries.count == 2)
        // Ordner zuerst, dann ohne Ordner.
        #expect(reloaded.entries.first?.group == "Haus")

        var changed = reloaded.entries[1]
        changed.name = "Tower"
        reloaded.update(changed)
        reloaded.remove(ids: [reloaded.entries[0].id])
        let again = FrequencyMemory(fileURL: url, defaults: defaults())
        #expect(again.entries.map(\.name) == ["Tower"])
    }

    @Test("Filter: Einträge der Seite und solche ohne Seite; „Alle“ zeigt alles")
    func filter() {
        let entries = [FrequencyMemoryEntry(mhz: 98, page: .radio),
                       FrequencyMemoryEntry(mhz: 433.92, page: .sensors),
                       FrequencyMemoryEntry(mhz: 145.5, page: nil)]
        #expect(FrequencyMemory.filter(entries, page: .radio, all: false).map(\.mhz) == [98, 145.5])
        #expect(FrequencyMemory.filter(entries, page: .sensors, all: false).map(\.mhz) == [433.92, 145.5])
        #expect(FrequencyMemory.filter(entries, page: .radio, all: true).count == 3)
    }

    @Test("Alte Radio-Favoriten werden verlustfrei übernommen, danach ist der Altschlüssel weg")
    func migration() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = defaults()
        let old = [RadioFavorite(mhz: 99.2, mode: .wfm, stepKHz: 100, kind: "UKW"),
                   RadioFavorite(mhz: 124.315, mode: .am, stepKHz: 8.333, kind: "Flugfunk"),
                   RadioFavorite(mhz: 446.00625, mode: .nfm, stepKHz: 6.25, kind: "PMR446")]
        store.set(RadioFavorite.encode(old), forKey: FrequencyMemory.legacyRadioKey)
        let memory = FrequencyMemory(fileURL: url, defaults: store)
        #expect(memory.entries.count == 3)
        for favorite in old {
            let entry = memory.entries.first { $0.matches(mhz: favorite.mhz) }
            #expect(entry?.radioMode == favorite.mode)
            #expect(entry?.stepKHz == favorite.stepKHz)
            #expect(entry?.kind == favorite.kind)   // Rohname, nicht übersetzt
            #expect(entry?.page == SidebarItem.radio.rawValue)
            #expect(entry?.frequencyHz == FrequencyMemoryEntry.hz(favorite.mhz))
        }
        #expect(store.string(forKey: FrequencyMemory.legacyRadioKey) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Zweiter Start: liest die Datei, übernimmt nichts doppelt.
        #expect(FrequencyMemory(fileURL: url, defaults: store).entries.count == 3)
    }

    @Test("Ganz alte Favoriten (nur Frequenzen) bekommen Betriebsart und Funkart")
    func migrationOldestFormat() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = defaults()
        store.set("98.1,123.45", forKey: FrequencyMemory.legacyRadioKey)
        let memory = FrequencyMemory(fileURL: url, defaults: store)
        #expect(memory.entries.map(\.radioMode) == [.wfm, .am])
    }

    @Test("Scheitert das Schreiben, bleibt der Altschlüssel stehen")
    func migrationKeepsLegacyOnFailure() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Frequenzspeicher.json")
        let store = defaults()
        let raw = RadioFavorite.encode([RadioFavorite(mhz: 99.2, mode: .wfm, stepKHz: 100, kind: "UKW")])
        store.set(raw, forKey: FrequencyMemory.legacyRadioKey)
        let memory = FrequencyMemory(fileURL: url, defaults: store)
        #expect(memory.entries.count == 1)
        #expect(memory.error != nil)
        #expect(store.string(forKey: FrequencyMemory.legacyRadioKey) == raw)
    }

    @Test("Unlesbare Datei wird beiseitegelegt, nicht überschrieben")
    func corruptFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FrequencyMemoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(FrequencyMemory.fileName)
        try Data("kein JSON".utf8).write(to: url)
        let memory = FrequencyMemory(fileURL: url, defaults: defaults())
        #expect(memory.entries.isEmpty)
        #expect(memory.error != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("Frequenzspeicher-unlesbar-") })
    }

    // MARK: CSV

    @Test("CSV: Semikolon mit Dezimalkomma, Komma mit Punkt, Kopfzeile in beliebiger Reihenfolge")
    func csvImport() {
        let german = "Name;Frequenz;Modus;Bandbreite;Notiz\nTurm;124,315;AM;8,33;Platzrunde\nPMR 1;446.00625;NFM;12,5;\n"
        let a = FrequencyMemoryCSV.parse(german)
        #expect(a.entries.count == 2)
        #expect(a.entries[0].name == "Turm")
        #expect(a.entries[0].frequencyHz == 124_315_000)
        #expect(a.entries[0].radioMode == .am)
        #expect(a.entries[0].bandwidthHz == 8_330)
        #expect(a.entries[0].note == "Platzrunde")
        #expect(a.entries[1].frequencyHz == 446_006_250)
        #expect(a.entries[1].bandwidthHz == 12_500)

        let english = "frequency,name,mode,bandwidth\n\"99,2\",NDR 2,WFM,200\n101.3,\"Radio \"\"Eins\"\", Berlin\",wfm,\n"
        let b = FrequencyMemoryCSV.parse(english)
        #expect(b.entries.map(\.frequencyHz) == [99_200_000, 101_300_000])
        #expect(b.entries[1].name == "Radio \"Eins\", Berlin")
        #expect(b.entries.allSatisfy { $0.radioMode == .wfm })
        #expect(b.entries[0].bandwidthHz == 200_000)
    }

    @Test("CSV: Hz-Angaben (SDR++), Einheiten, ungültige Zeilen, ohne Kopfzeile")
    func csvUnits() {
        let text = "Name;Frequency (Hz);Mode;Bandwidth (Hz)\nA;433920000;FM;25000\nB;868,3 MHz;USB;\nC;abc;AM;\n\n"
        let r = FrequencyMemoryCSV.parse(text)
        #expect(r.entries.count == 2)
        #expect(r.invalid == 1)
        #expect(r.entries[0].frequencyHz == 433_920_000)
        #expect(r.entries[0].radioMode == .nfm)          // „FM“ heißt in Kanallisten Schmalband-FM
        #expect(r.entries[0].bandwidthHz == 25_000)
        #expect(r.entries[1].frequencyHz == 868_300_000)
        #expect(r.entries[1].radioMode == .usb)          // seit SSB im Radio bekannt
        let odd = FrequencyMemoryCSV.parse("Name;Frequency (Hz);Mode\nD;7074000;DIGU\n")
        #expect(odd.entries.first?.mode == "DIGU")        // unbekannt – bleibt als Text erhalten
        #expect(odd.entries.first?.radioMode == nil)

        let bare = FrequencyMemoryCSV.parse("Bake\t144,800\tNFM\n")
        #expect(bare.entries.first?.name == "Bake")
        #expect(bare.entries.first?.frequencyHz == 144_800_000)
    }

    @Test("CSV: Export und Import ergeben dieselben Einträge, Doppel werden übersprungen")
    func csvRoundTrip() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let memory = FrequencyMemory(fileURL: url, defaults: defaults())
        var a = FrequencyMemoryEntry(mhz: 433.92, name: "Garten; Nord", mode: RadioMode.nfm.rawValue, page: .sensors)
        a.note = "sagt \"hallo\""
        a.group = "Haus"
        a.bandwidthHz = 12_500
        memory.add(a)
        memory.add(FrequencyMemoryEntry(mhz: 98.4, name: "", mode: RadioMode.wfm.rawValue, page: nil))
        let csv = memory.exportCSV()
        #expect(csv.hasPrefix("Name;Frequenz (MHz);Modus;Bandbreite (kHz);Notiz;Gruppe;Seite"))
        #expect(csv.contains("WFM"))

        let parsed = FrequencyMemoryCSV.parse(csv).entries
        #expect(parsed.count == 2)
        let back = parsed.first { $0.name == "Garten; Nord" }
        #expect(back?.frequencyHz == a.frequencyHz)
        #expect(back?.mode == a.mode)
        #expect(back?.bandwidthHz == 12_500)
        #expect(back?.note == a.note)
        #expect(back?.group == "Haus")
        #expect(back?.page == "sensors")

        let result = memory.importCSV(csv)
        #expect(result.entries.isEmpty && result.duplicates == 2)
        #expect(memory.entries.count == 2)
    }

    @Test("Betriebsart: Kürzel ↔ Rohwert, Vorschlag aus dem Band")
    func modes() {
        #expect(FrequencyMemory.modeCode(RadioMode.wfm.rawValue) == "WFM")
        #expect(FrequencyMemory.modeCode(RadioMode.nfm.rawValue) == "NFM")
        #expect(FrequencyMemory.modeCode("AM") == "AM")
        for mode in RadioMode.allCases {
            #expect(FrequencyMemory.radioMode(fromStored: mode.rawValue) == mode)
            #expect(FrequencyMemory.radioMode(fromStored: FrequencyMemory.modeCode(mode.rawValue)) == mode)
        }
        #expect(FrequencyMemory.storedMode(fromCode: "") == nil)
        #expect(FrequencyMemory.storedMode(fromCode: "cw") == "CW")

        #expect(FrequencyMemory.suggestedRadioMode(mhz: 124.315) == .am)    // Flugfunk
        #expect(FrequencyMemory.suggestedRadioMode(mhz: 145.5) == .nfm)     // 2 m
        #expect(FrequencyMemory.suggestedRadioMode(mhz: 438.0) == .nfm)     // 70 cm
        #expect(FrequencyMemory.suggestedRadioMode(mhz: 98.4) == .wfm)      // UKW-Rundfunk
        #expect(FrequencyMemory.suggestedRadioMode(mhz: 1090) == .nfm)      // sonst NFM
    }
}

/// Max-Hold und Marker im Spektrum – reine Funktionen.
@Suite("Spektrum: Max-Hold und Marker")
struct SpectrumMathTests {
    @Test("Max-Hold hält je Bin den Höchstwert; neue Länge beginnt neu")
    func maxHold() {
        var held: [Float] = []
        held = SpectrumMath.maxHold(held, [-80, -70, -90])
        held = SpectrumMath.maxHold(held, [-85, -60, -95])
        #expect(held == [-80, -60, -90])
        #expect(SpectrumMath.maxHold(held, [-100, -100]) == [-100, -100])
    }

    @Test("Spitze ohne DC-Mitte; Frequenz ↔ Bin")
    func peak() {
        var values = [Float](repeating: -90, count: 64)
        values[32] = -10   // DC-Spitze in der Mitte – zählt nicht
        values[10] = -40
        values[50] = -35
        #expect(SpectrumMath.peakIndex(values) == 50)
        #expect(SpectrumMath.peakIndex([Float](repeating: -90, count: 4)) == nil)
        let mhz = SpectrumMath.mhz(bin: 50, count: 64, centerMHz: 100, spanMHz: 6.4)
        #expect(abs(mhz - 101.8) < 1e-9)
        #expect(SpectrumMath.bin(mhz: mhz, count: 64, centerMHz: 100, spanMHz: 6.4) == 50)
        #expect(SpectrumMath.bin(mhz: 110, count: 64, centerMHz: 100, spanMHz: 6.4) == nil)
        #expect(SpectrumMath.level(at: mhz, values: values, centerMHz: 100, spanMHz: 6.4) == -35)
        // Klick knapp daneben landet auf der Spitze.
        let near = SpectrumMath.mhz(bin: 48, count: 64, centerMHz: 100, spanMHz: 6.4)
        #expect(abs(SpectrumMath.snapToPeak(mhz: near, values: values, centerMHz: 100, spanMHz: 6.4) - mhz) < 1e-9)
    }

    @Test("Marker: höchstens vier, der fünfte verschiebt den nächstgelegenen; Delta zu Marker 1")
    func markers() {
        var markers: [SpectrumMarker] = []
        for mhz in [100.0, 101.0, 102.0, 103.0] { markers = SpectrumMath.placeMarker(markers, at: mhz) }
        #expect(markers.map(\.id) == [1, 2, 3, 4])
        markers = SpectrumMath.placeMarker(markers, at: 101.2)
        #expect(markers.count == 4)
        #expect(markers.first { $0.id == 2 }?.mhz == 101.2)
        // Freie Nummer wird wieder vergeben.
        markers.removeAll { $0.id == 3 }
        markers = SpectrumMath.placeMarker(markers, at: 104)
        #expect(markers.first { $0.id == 3 }?.mhz == 104)
        // Marker 1 auf eine neue Frequenz.
        markers = SpectrumMath.moveMarker(markers, id: 1, to: 99.5)
        #expect(markers.first?.id == 1 && markers.first?.mhz == 99.5)

        let m1 = SpectrumMarker(id: 1, mhz: 100), m2 = SpectrumMarker(id: 2, mhz: 100.025)
        let delta = SpectrumMath.delta(of: m2, reference: m1, level: -50, referenceLevel: -40)
        #expect(abs((delta?.mhz ?? 0) - 0.025) < 1e-9)
        #expect(delta?.db == -10)
        #expect(SpectrumMath.delta(of: m1, reference: m1, level: -40, referenceLevel: -40) == nil)
        #expect(SpectrumMath.delta(of: m2, reference: m1, level: nil, referenceLevel: -40)?.db == nil)
    }
}
