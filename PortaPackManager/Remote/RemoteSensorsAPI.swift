import Foundation

/// Reiter „Funksensoren“ des Fernzugriffs (`/api/sensors`): alle gehörten
/// Sensoren mit ihren Werten im Klartext. Sortierung, Suche und der
/// TPMS-Filter laufen im Browser. Einzige Aktion: `mhz=` wählt Band bzw.
/// Frequenz (wie die Bandwahl am Mac) – ohne laufenden Empfang wird sie nur
/// gemerkt und gilt beim nächsten Start; umgestimmt wird nur, solange der
/// HackRF den Funksensoren gehört (`isReceiving(for:)`), nie ein fremder Strom.
@MainActor
enum RemoteSensorsAPI {
    /// Höchstens so viele Sensoren (die zuletzt gehörten) ausliefern.
    static let limit = 500

    struct State: Encodable {
        struct Value: Encodable, Equatable {
            /// Name der Messgröße („Temperatur“).
            let n: String
            /// Wert mit Einheit im Klartext („21,5 °C“).
            let v: String
        }
        struct Sensor: Encodable {
            /// Eindeutige Kennung über Pakete hinweg (Modell|ID|Kanal).
            let key: String
            let model: String
            let sid: String
            let ch: Int?
            let tpms: Bool
            /// Zuletzt/zuerst gehört (ms seit 1970).
            let t: Double
            let first: Double
            let count: Int
            let rssi: Double
            let snr: Double
            let mhz: Double
            let integrity: String
            /// Für die Sortierung nach Temperatur.
            let temp: Double?
            let values: [Value]
        }
        let running: Bool
        let remote: Bool
        let mhz: Double
        let packets: Int
        let decoded: Int
        let noiseDB: Double
        let total: Int
        let tpms: Int
        let sensors: [Sensor]
        /// Bänder wie in der Bandwahl am Mac (`SensorModel.Band`).
        let bands: [Band]
        /// Antwort auf die gerade ausgeführte Aktion (z. B. Gerät belegt).
        let notice: String?
        let error: String?
    }

    struct Band: Encodable, Equatable {
        let name: String
        let mhz: Double
    }

    static let bands = SensorModel.Band.allCases.map { Band(name: $0.rawValue, mhz: $0.frequencyMHz) }

    /// Was eine Frequenzwahl bewirkt: ohne Empfang nur merken, mit eigenem
    /// Strom umstimmen, sonst ablehnen (fremder Strom bleibt unberührt).
    enum TuneAction: Equatable { case store, tune, refuse }

    static func tuneAction(running: Bool, ownsDevice: Bool) -> TuneAction {
        !running ? .store : ownsDevice ? .tune : .refuse
    }

    /// `mhz=` aus der Anfrage: 1…6000 MHz, Komma oder Punkt, auf kHz gerundet.
    static func requestedMHz(_ query: [String: String]) -> Double? {
        guard let raw = query["mhz"]?.replacingOccurrences(of: ",", with: "."),
              let value = Double(raw), value.isFinite, (1...6000).contains(value) else { return nil }
        return (value * 1000).rounded() / 1000
    }

    static var refusedNotice: String { String(localized: "Der HackRF gehört gerade einer anderen Seite – Frequenz nicht geändert.") }

    static func handle(_ query: [String: String], hub: RemoteHub) -> Data {
        let model = hub.sensors
        var notice: String?
        if let mhz = requestedMHz(query), abs(mhz - model.frequencyMHz) >= 0.0005 {
            let owns = hub.session?.hackRF.map { $0.isReceiving(for: model) } ?? false
            switch tuneAction(running: model.running, ownsDevice: owns) {
            case .store: model.frequencyMHz = mhz
            case .tune: model.tune(to: mhz)
            case .refuse: notice = refusedNotice
            }
        }
        let s = state(sensors: model.sensors, running: model.running, remote: hub.remoteMode == .sensors,
                      frequencyMHz: model.frequencyMHz, packets: model.packetCount, decoded: model.decodedCount,
                      noiseDB: model.noiseDB, error: model.error, notice: notice)
        return (try? JSONEncoder().encode(s)) ?? Data("{}".utf8)
    }

    static func state(sensors: [SensorDevice], running: Bool, remote: Bool, frequencyMHz: Double, packets: Int,
                      decoded: Int, noiseDB: Double, error: String?, notice: String? = nil) -> State {
        let sorted = sensors.sorted { $0.lastSeen > $1.lastSeen }
        return State(
            running: running, remote: remote, mhz: round(frequencyMHz, 3), packets: packets, decoded: decoded,
            noiseDB: round(noiseDB, 1), total: sensors.count, tpms: sensors.filter(MQTTFeeds.isTPMS).count,
            sensors: sorted.prefix(limit).map { sensor in
                let r = sensor.latest
                return .init(key: sensor.id, model: r.model, sid: r.id, ch: r.channel, tpms: MQTTFeeds.isTPMS(sensor),
                             t: ms(sensor.lastSeen), first: ms(sensor.firstSeen), count: sensor.count,
                             rssi: round(sensor.rssiDB, 1), snr: round(sensor.snrDB, 1), mhz: round(sensor.frequencyMHz, 3),
                             integrity: r.integrity, temp: r.temperatureC.flatMap { $0.isFinite ? round($0, 1) : nil },
                             values: values(of: r))
            },
            bands: bands, notice: notice, error: error)
    }

    /// Alle Werte eines Pakets im Klartext mit Einheit, in fester Reihenfolge.
    static func values(of r: SensorReading) -> [State.Value] {
        var out: [State.Value] = []
        func add(_ name: String, _ value: Double?, digits: Int, unit: String) {
            guard let value, value.isFinite else { return }
            out.append(.init(n: name, v: number(value, digits: digits) + (unit.isEmpty ? "" : " " + unit)))
        }
        add(String(localized: "Temperatur", comment: "Messgröße eines Funksensors"), r.temperatureC, digits: 1, unit: "°C")
        if let h = r.humidity { out.append(.init(n: String(localized: "Luftfeuchte"), v: "\(h) %")) }
        for (name, value) in [(String(localized: "Wind"), r.windAverageMS), (String(localized: "Böen"), r.windGustMS)] {
            guard let value, value.isFinite else { continue }
            out.append(.init(n: name, v: number(value, digits: 1) + " m/s (" + number(value * 3.6, digits: 0) + " km/h)"))
        }
        if let d = r.windDirection, d.isFinite {
            out.append(.init(n: String(localized: "Windrichtung"), v: number(d, digits: 0) + "° (" + compass(d) + ")"))
        }
        add(String(localized: "Regen"), r.rainMM, digits: 1, unit: "mm")
        add(String(localized: "UV-Index"), r.uvIndex, digits: 1, unit: "")
        add(String(localized: "Helligkeit"), r.lightLux, digits: 0, unit: "lx")
        if let ok = r.batteryOK {
            out.append(.init(n: String(localized: "Batterie"),
                             v: ok ? String(localized: "in Ordnung", comment: "Batterie eines Funksensors") : String(localized: "schwach", comment: "Batterie eines Funksensors")))
        }
        for key in r.extra.keys.sorted() { out.append(.init(n: key, v: r.extra[key] ?? "")) }
        return out
    }

    /// Himmelsrichtung in 16 Stufen (Sprache der App; Entwicklungssprache deutsch: NO, O, SO …).
    static func compass(_ degrees: Double) -> String {
        let names = [
            String(localized: "N", comment: "Himmelsrichtung Nord"), String(localized: "NNO", comment: "Himmelsrichtung Nordnordost"),
            String(localized: "NO", comment: "Himmelsrichtung Nordost"), String(localized: "ONO", comment: "Himmelsrichtung Ostnordost"),
            String(localized: "O", comment: "Himmelsrichtung Ost"), String(localized: "OSO", comment: "Himmelsrichtung Ostsüdost"),
            String(localized: "SO", comment: "Himmelsrichtung Südost"), String(localized: "SSO", comment: "Himmelsrichtung Südsüdost"),
            String(localized: "S", comment: "Himmelsrichtung Süd"), String(localized: "SSW", comment: "Himmelsrichtung Südsüdwest"),
            String(localized: "SW", comment: "Himmelsrichtung Südwest"), String(localized: "WSW", comment: "Himmelsrichtung Westsüdwest"),
            String(localized: "W", comment: "Himmelsrichtung West"), String(localized: "WNW", comment: "Himmelsrichtung Westnordwest"),
            String(localized: "NW", comment: "Himmelsrichtung Nordwest"), String(localized: "NNW", comment: "Himmelsrichtung Nordnordwest"),
        ]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((normalized / 22.5).rounded()) % 16]
    }

    private static func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(RemotePage.locale))
    }
    private static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
    private static func round(_ value: Double, _ digits: Int) -> Double {
        guard value.isFinite else { return 0 }
        let f = pow(10, Double(digits))
        return (value * f).rounded() / f
    }
}
