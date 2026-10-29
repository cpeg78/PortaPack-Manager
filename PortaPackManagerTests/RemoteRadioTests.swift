import Foundation
import Testing
@testable import PortaPackManager

/// `/api/fm` des Fernzugriffs: JSON-Form, Aktionen, Gerätebesitz beim Abstimmen.
/// Schreibt nur in eigene UserDefaults und einen eigenen Frequenzspeicher im
/// Temp-Ordner – der Testwirt teilt `.standard` und Application Support mit der App.
@Suite("Fernzugriff: Radio")
@MainActor
struct RemoteRadioTests {
    private func defaults() -> UserDefaults {
        let name = "RemoteRadioTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func memory() -> FrequencyMemory {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteRadioTests-\(UUID().uuidString).json")
        return FrequencyMemory(fileURL: url, defaults: defaults())
    }

    @Test("JSON: vorgesehene Felder, Betriebsart als Kürzel, nichts Geheimes")
    func jsonShape() throws {
        let store = memory()
        let favorites = [RadioFavorite(mhz: 99.2, mode: .wfm, stepKHz: 100, kind: "UKW"),
                         RadioFavorite(mhz: 124.315, mode: .am, stepKHz: 8.333, kind: "Flugfunk")]
        for entry in FrequencyMemory.migrated(favorites) { store.add(entry) }
        // Einträge anderer Seiten erscheinen im Radio-Reiter nicht.
        store.add(FrequencyMemoryEntry(mhz: 433.92, name: "Sensor", page: .sensors))
        let model = RadioModel()
        model.mode = .nfm
        let data = RemoteRadioAPI.encode(RemoteRadioAPI.state(model, remote: false, notice: "Hinweis", memory: store))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowed: Set<String> = ["running", "remote", "owned", "mhz", "mode", "stepKHz", "squelch", "squelchOpen",
                                    "bandwidth", "bandwidths", "aboveFloor", "signalDB", "rdsName", "rdsText", "programType", "stereo", "localMuted",
                                    "favorites", "scanning", "scanProgress", "scanStatus", "scanBand", "scanMode",
                                    "stations", "bands", "notice", "error"]
        #expect(Set(object.keys).isSubset(of: allowed))
        let bands = try #require(object["bands"] as? [[String: Any]])
        #expect(bands.count == ScanBands.all.count)
        #expect(bands.first?["name"] as? String == ScanBands.all.first?.name)
        #expect(object["mode"] as? String == "nfm")
        #expect(object["running"] as? Bool == false)
        #expect(object["owned"] as? Bool == false)
        #expect(object["notice"] as? String == "Hinweis")
        #expect(object["signalDB"] == nil)   // ohne Empfang kein Pegel
        let favs = try #require(object["favorites"] as? [[String: Any]])
        #expect(favs.count == 2)
        #expect(favs.map { $0["mode"] as? String } == ["wfm", "am"])
        #expect(favs.last?["kind"] as? String == "Flugfunk")
        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains("token") && !text.contains("key"))
    }

    @Test("Ohne Empfang wird nicht abgestimmt, sondern ein Hinweis geliefert")
    func noTuneWithoutDevice() {
        let store = memory()
        let model = RadioModel()
        let before = model.frequencyMHz
        for query in [["f": "101.3"], ["step": "1"], ["fav": UUID().uuidString]] {
            let notice = RemoteRadioAPI.apply(query, model: model, memory: store)
            #expect(notice?.contains("umschalten") == true)
        }
        #expect(model.frequencyMHz == before)
    }

    @Test("Betriebsart über Kürzel; Schritt folgt der Betriebsart, Unbekanntes bleibt folgenlos")
    func modeAction() {
        let store = memory()
        let model = RadioModel()
        model.mode = .wfm
        model.stepKHz = 100
        RemoteRadioAPI.apply(["mode": "am"], model: model, memory: store)
        #expect(model.mode == .am)
        #expect(model.stepKHz == RadioMode.am.defaultStepKHz)
        RemoteRadioAPI.apply(["mode": "fm-stereo"], model: model, memory: store)
        #expect(model.mode == .am)
        RemoteRadioAPI.apply(["mode": "NFM"], model: model, memory: store)
        #expect(model.mode == .nfm)
    }

    @Test("Speicher: merken (ohne Doppel) und löschen, nur im übergebenen Speicher")
    func favorites() {
        let store = memory()
        let model = RadioModel()
        model.mode = .am
        model.stepKHz = 8.333
        model.frequencyMHz = 124.315
        RemoteRadioAPI.apply(["addfav": "1"], model: model, memory: store)
        RemoteRadioAPI.apply(["addfav": "1"], model: model, memory: store)
        let list = store.entries
        #expect(list.count == 1)
        #expect(list.first?.radioMode == .am)
        #expect(list.first?.mhz == 124.315)
        #expect(list.first?.page == "radio")
        #expect(list.first?.stepKHz == 8.333)
        RemoteRadioAPI.apply(["delfav": "124.315"], model: model, memory: store)   // alte Kennung: folgenlos
        #expect(store.entries.count == 1)
        RemoteRadioAPI.apply(["delfav": list[0].id.uuidString], model: model, memory: store)
        #expect(store.entries.isEmpty)
    }

    @Test("Zahlen: nur endliche, Komma erlaubt, Bereiche geklemmt")
    func numbers() {
        #expect(RemoteRadioAPI.number("99,2") == 99.2)
        #expect(RemoteRadioAPI.number(" 101.3 ") == 101.3)
        #expect(RemoteRadioAPI.number("nan") == nil)
        #expect(RemoteRadioAPI.number("inf") == nil)
        #expect(RemoteRadioAPI.number("1e999") == nil)
        #expect(RemoteRadioAPI.number("abc") == nil)
        #expect(RemoteRadioAPI.number(nil) == nil)
        #expect(RemoteRadioAPI.clampedMHz(0) == 1.24)
        #expect(RemoteRadioAPI.clampedMHz(9000) == 6000)
        #expect(RemoteRadioAPI.clampedSquelch(-3) == 0)
        #expect(RemoteRadioAPI.clampedSquelch(7.6) == 8)
        #expect(RemoteRadioAPI.clampedSquelch(99) == 20)
    }

    @Test("Gemerkte Frequenz bekommt die Funkart (Rohname) aus dem Band")
    func favoriteKind() {
        let entry = RemoteRadioAPI.memoryEntry(99.2, mode: .wfm, stepKHz: 100, scannedBand: nil, stationName: "NDR 2")
        #expect(entry.kind == RadioFavorite.kind(at: 99.2))
        #expect(entry.name == "NDR 2")
        #expect(entry.mode == RadioMode.wfm.rawValue)
        let air = RemoteRadioAPI.memoryEntry(124.315, mode: .am, stepKHz: 8.33, scannedBand: ScanBands.all.first { $0.name == "Flugfunk" })
        #expect(air.kind == "Flugfunk")
    }

    @Test("SSB/CW und Filterbreite: nur bekannte Kürzel und Breiten der Betriebsart")
    func sidebandModesAndBandwidth() throws {
        let store = memory()
        let model = RadioModel()
        for mode in RadioMode.allCases {
            #expect(RemoteRadioAPI.mode(fromKey: RemoteRadioAPI.key(mode)) == mode)
        }
        RemoteRadioAPI.apply(["mode": "usb"], model: model, memory: store)
        #expect(model.mode == .usb)
        #expect(model.bandwidthHz == 2_400)
        #expect(model.stepKHz == RadioMode.usb.defaultStepKHz)
        #expect(RemoteRadioAPI.apply(["bw": "2700"], model: model, memory: store) == nil)
        #expect(model.bandwidthHz == 2_700)
        // Breite einer anderen Betriebsart, Unsinn, Unendlich: abgelehnt, Wert bleibt.
        for bad in ["500", "2701", "abc", "inf", "-2700", ""] {
            #expect(RemoteRadioAPI.apply(["bw": bad], model: model, memory: store) != nil, "\(bad)")
            #expect(model.bandwidthHz == 2_700)
        }
        // Betriebsart und Breite zusammen: die Breite gilt für die neue Betriebsart.
        RemoteRadioAPI.apply(["mode": "cw", "bw": "250"], model: model, memory: store)
        #expect(model.mode == .cw && model.bandwidthHz == 250)
        RemoteRadioAPI.apply(["mode": "wfm"], model: model, memory: store)
        #expect(RemoteRadioAPI.apply(["bw": "10000"], model: model, memory: store) != nil)
        let data = RemoteRadioAPI.encode(RemoteRadioAPI.state(model, remote: false, memory: store))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["bandwidth"] == nil)
        #expect((object["bandwidths"] as? [Double])?.isEmpty == true)
        RemoteRadioAPI.apply(["mode": "lsb"], model: model, memory: store)
        let lsb = try #require(try JSONSerialization.jsonObject(with: RemoteRadioAPI.encode(RemoteRadioAPI.state(model, remote: false, memory: store))) as? [String: Any])
        #expect(lsb["mode"] as? String == "lsb")
        #expect(lsb["bandwidth"] as? Double == 2_400)
        #expect(lsb["bandwidths"] as? [Double] == RadioMode.lsb.bandwidthOptionsHz)
    }

    @Test("RadioModel: Breite außerhalb der Liste wird zur Vorgabe, select setzt beides")
    func modelBandwidthAPI() {
        let model = RadioModel()
        model.mode = .cw
        #expect(model.bandwidthHz == 500)
        model.bandwidthHz = 1_234
        #expect(model.bandwidthHz == 500)
        model.select(mode: .usb, bandwidthHz: 3_000)
        #expect(model.mode == .usb && model.bandwidthHz == 3_000 && model.stepKHz == RadioMode.usb.defaultStepKHz)
        model.select(mode: .usb, bandwidthHz: nil)
        #expect(model.bandwidthHz == 2_400)
        model.select(mode: .wfm, bandwidthHz: 2_400)
        #expect(model.mode == .wfm && model.bandwidthHz == 0)
    }
}
