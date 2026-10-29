import Foundation
import Testing
@testable import PortaPackManager

/// `/api/sensors` des Fernzugriffs: JSON-Form, Werte im Klartext, TPMS-Zählung.
@Suite("Fernzugriff: Funksensoren")
@MainActor
struct RemoteSensorsTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func sensor(_ reading: SensorReading, age: TimeInterval) -> SensorDevice {
        SensorDevice(latest: reading, firstSeen: now.addingTimeInterval(-age - 600), lastSeen: now.addingTimeInterval(-age),
                     count: 7, rssiDB: -42.36, snrDB: 18.04, offsetKHz: 30, frequencyMHz: 433.92)
    }

    private static var sensors: [SensorDevice] {
        var weather = SensorReading(model: "Fineoffset-WH24", id: "171", integrity: "CRC")
        weather.temperatureC = 21.46
        weather.humidity = 55
        weather.windAverageMS = 3.2
        weather.windGustMS = 5
        weather.windDirection = 270
        weather.rainMM = 12.3
        weather.batteryOK = false
        weather.extra = ["Taste": "gedrückt"]
        var thermo = SensorReading(model: "Nexus-TH", id: "5", channel: 2, integrity: "keine")
        thermo.temperatureC = -3.0
        var tire = SensorReading(model: "TPMS", id: "1A2B3C4D", integrity: "CRC")
        tire.extra = ["Rohdaten": "1A 2B"]
        return [sensor(thermo, age: 120), sensor(weather, age: 5), sensor(tire, age: 30)]
    }

    private func state() -> RemoteSensorsAPI.State {
        RemoteSensorsAPI.state(sensors: Self.sensors, running: true, remote: true, frequencyMHz: 433.92, packets: 99,
                               decoded: 40, noiseDB: -71.234, error: nil)
    }

    @Test("JSON: vorgesehene Felder, neueste zuerst, TPMS gezählt")
    func jsonShape() throws {
        let data = try JSONEncoder().encode(state())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["running", "remote", "mhz", "packets", "decoded", "noiseDB", "total", "tpms", "sensors", "bands"])
        #expect(object["tpms"] as? Int == 1)
        #expect(object["total"] as? Int == 3)
        #expect(object["noiseDB"] as? Double == -71.2)
        let sensors = try #require(object["sensors"] as? [[String: Any]])
        #expect(sensors.map { $0["sid"] as? String } == ["171", "1A2B3C4D", "5"])
        let allowed: Set<String> = ["key", "model", "sid", "ch", "tpms", "t", "first", "count", "rssi", "snr", "mhz",
                                    "integrity", "temp", "values"]
        for sensor in sensors { #expect(Set(sensor.keys).isSubset(of: allowed)) }
        #expect(sensors[1]["tpms"] as? Bool == true)
        #expect(sensors[2]["ch"] as? Int == 2)
        #expect(sensors[0]["rssi"] as? Double == -42.4)
        #expect(sensors[0]["t"] as? Double == (Self.now.timeIntervalSince1970 - 5) * 1000)
    }

    @Test("Bänder wie am Mac; Hinweis nur, wenn gesetzt")
    func bands() throws {
        let data = try JSONEncoder().encode(RemoteSensorsAPI.state(
            sensors: [], running: true, remote: false, frequencyMHz: 868.3, packets: 0, decoded: 0, noiseDB: -80,
            error: nil, notice: RemoteSensorsAPI.refusedNotice))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let bands = try #require(object["bands"] as? [[String: Any]])
        #expect(bands.map { $0["mhz"] as? Double } == [433.92, 868.3])
        #expect(bands.map { $0["name"] as? String } == ["433,92 MHz", "868,30 MHz"])
        #expect(object["notice"] as? String == RemoteSensorsAPI.refusedNotice)
    }

    @Test("Frequenzwahl: gültige Werte, ohne Empfang nur merken, fremden Strom nie umstimmen")
    func tuning() {
        #expect(RemoteSensorsAPI.requestedMHz(["mhz": "868.3"]) == 868.3)
        #expect(RemoteSensorsAPI.requestedMHz(["mhz": "433,92"]) == 433.92)
        #expect(RemoteSensorsAPI.requestedMHz(["mhz": "315.00049"]) == 315.0)
        #expect(RemoteSensorsAPI.requestedMHz(["mhz": "0.5"]) == nil)
        #expect(RemoteSensorsAPI.requestedMHz(["mhz": "7000"]) == nil)
        #expect(RemoteSensorsAPI.requestedMHz(["mhz": "abc"]) == nil)
        #expect(RemoteSensorsAPI.requestedMHz([:]) == nil)
        #expect(RemoteSensorsAPI.tuneAction(running: false, ownsDevice: false) == .store)
        #expect(RemoteSensorsAPI.tuneAction(running: true, ownsDevice: true) == .tune)
        #expect(RemoteSensorsAPI.tuneAction(running: true, ownsDevice: false) == .refuse)
    }

    @Test("Werte im Klartext mit Einheit, feste Reihenfolge")
    func values() throws {
        let weather = try #require(state().sensors.first)
        #expect(weather.temp == 21.5)
        #expect(weather.values.map(\.n) == ["Temperatur", "Luftfeuchte", "Wind", "Böen", "Windrichtung", "Regen", "Batterie", "Taste"])
        let text = Dictionary(uniqueKeysWithValues: weather.values.map { ($0.n, $0.v) })
        #expect(text["Temperatur"] == "21,5 °C")
        #expect(text["Luftfeuchte"] == "55 %")
        #expect(text["Wind"] == "3,2 m/s (12 km/h)")
        #expect(text["Windrichtung"] == "270° (W)")
        #expect(text["Regen"] == "12,3 mm")
        #expect(text["Batterie"] == "schwach")
    }

    @Test("Himmelsrichtungen")
    func compass() {
        #expect(RemoteSensorsAPI.compass(0) == "N")
        #expect(RemoteSensorsAPI.compass(359) == "N")
        #expect(RemoteSensorsAPI.compass(45) == "NO")
        #expect(RemoteSensorsAPI.compass(200) == "SSW")
        #expect(RemoteSensorsAPI.compass(-90) == "W")
    }
}

/// `/api/smart868` des Fernzugriffs: JSON-Form, Rahmen eines Geräts, keine Schlüssel.
@Suite("Fernzugriff: Smart Home 868")
@MainActor
struct RemoteSmartHomeTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Das OMS-Normbeispiel, mit dem Schlüssel entschlüsselt – so wie die App es mit
    /// einem hinterlegten Zählerschlüssel sähe.
    private static func decryptedMeter() throws -> SmartHomeFrame {
        try #require(WMBus.parse(SmartHomeTestFrames.omsExample, mode: "T1",
                                 keys: ["12345678": SmartHomeTestFrames.omsKey]))
    }

    private static func fixtures() throws -> ([SmartHomeDevice], [SmartHomeReception]) {
        let meter = try decryptedMeter()
        var zwave = SmartHomeFrame(radio: .zwave, mode: "R2 · 40 kbit/s", address: "01020304:05", destination: "01",
                                   kind: "Bericht", summary: "Schalter <an>", checksumOK: true, bytes: [1, 2, 3])
        zwave.fields = [.init(name: "Network Key", value: "geheim"), .init(name: "Befehl", value: "Basic Report")]
        let receptions = [
            SmartHomeReception(id: 0, date: now.addingTimeInterval(-60), frequencyMHz: 868.95, rssiDB: -55.55, snrDB: 20, frame: meter),
            SmartHomeReception(id: 1, date: now.addingTimeInterval(-10), frequencyMHz: 868.42, rssiDB: -40, snrDB: 25, frame: zwave),
            SmartHomeReception(id: 2, date: now.addingTimeInterval(-5), frequencyMHz: 868.95, rssiDB: -50, snrDB: 22, frame: meter),
        ]
        let devices = [
            SmartHomeDevice(id: meter.deviceKey, radio: .wmbus, address: meter.address, deviceType: meter.deviceType,
                            lastSummary: meter.summary, values: meter.values, encrypted: false, rssiDB: -50, snrDB: 22,
                            firstSeen: now.addingTimeInterval(-60), lastSeen: now.addingTimeInterval(-5), count: 2),
            SmartHomeDevice(id: zwave.deviceKey, radio: .zwave, address: zwave.address, deviceType: "",
                            lastSummary: zwave.summary, values: [], encrypted: false, rssiDB: -40, snrDB: 25,
                            firstSeen: now.addingTimeInterval(-10), lastSeen: now.addingTimeInterval(-10), count: 1),
        ]
        return (devices, receptions)
    }

    private func state(selected: String?) throws -> RemoteSmartHomeAPI.State {
        let (devices, receptions) = try Self.fixtures()
        return RemoteSmartHomeAPI.state(devices: devices, receptions: receptions,
                                        radios: [.zwave, .homematic, .wmbus], running: true, remote: false,
                                        frames: 3, bursts: 10, noise: [.wmbus: -70.4, .zwave: -68.6], error: nil,
                                        selected: selected)
    }

    @Test("JSON: vorgesehene Felder, Funkarten mit Zählern, neueste zuerst")
    func jsonShape() throws {
        let data = try JSONEncoder().encode(try state(selected: nil))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["running", "remote", "frames", "bursts", "noise", "radios", "total", "devices"])
        let devices = try #require(object["devices"] as? [[String: Any]])
        #expect(devices.map { $0["radio"] as? String } == ["Wireless M-Bus", "Z-Wave"])
        let allowed: Set<String> = ["id", "radio", "addr", "type", "last", "values", "enc", "rssi", "snr", "t", "first", "count"]
        for device in devices { #expect(Set(device.keys) == allowed) }
        let radios = try #require(object["radios"] as? [[String: Any]])
        #expect(radios.map { $0["name"] as? String } == ["Z-Wave", "Homematic", "EnOcean", "Wireless M-Bus"])
        #expect(radios.map { $0["on"] as? Bool } == [true, true, false, true])
        #expect(radios.map { $0["devices"] as? Int } == [1, 0, 0, 1])
        let volume = try #require((devices[0]["values"] as? [[String: String]])?.first { $0["n"] == "Volumen" })
        #expect(volume["v"] == "28.504,3 m³")
    }

    @Test("Antippen: die letzten Rahmen genau dieses Geräts, neueste zuerst")
    func history() throws {
        let meter = try Self.decryptedMeter()
        let s = try state(selected: meter.deviceKey)
        #expect(s.dev == meter.deviceKey)
        let history = try #require(s.history)
        #expect(history.count == 2)
        #expect(history[0].t > history[1].t)
        #expect(history.allSatisfy { $0.mhz == 868.95 })
        #expect(history[0].values.contains { $0.n == "Volumen" })
        #expect(try state(selected: "Z-Wave|unbekannt").history?.isEmpty == true)
    }

    @Test("Nie Schlüssel: kein wM-Bus-Schlüssel, keine Rohbytes, keine Schlüsselfelder")
    func noKeys() throws {
        let zwaveID = "Z-Wave|01020304:05"
        for selected in [nil, try Self.decryptedMeter().deviceKey, zwaveID] {
            let data = try JSONEncoder().encode(try state(selected: selected))
            let text = String(decoding: data, as: UTF8.self)
            // Der Zählerschlüssel in jeder Schreibweise.
            let key = SmartHomeTestFrames.omsKey
            for variant in [SmartHomeHex.string(key, separator: ""), SmartHomeHex.string(key), SmartHomeHex.string(key, separator: ":")] {
                #expect(!text.uppercased().contains(variant))
            }
            #expect(!text.contains(key.map(String.init).joined(separator: ",")))
            // Weder Schlüssel- noch Rohbyte-Felder.
            let lower = text.lowercased()
            for word in ["\"key", "wmbuskeys", "\"bytes\"", "\"raw", "network key", "geheim"] { #expect(!lower.contains(word)) }
        }
        let zwave = try #require(try state(selected: zwaveID).history?.first)
        #expect(zwave.fields.map(\.n) == ["Befehl"])
        #expect(RemoteSmartHomeAPI.looksSecret("Schlüssel"))
        #expect(RemoteSmartHomeAPI.looksSecret("AES Key"))
        #expect(!RemoteSmartHomeAPI.looksSecret("Entschlüsselt"))
    }
}
