import Foundation

/// Übersetzt die Geräte der Empfängerseiten in `MQTTValue`s für die
/// Home-Assistant-Brücke. Rein (ohne Netz), damit die Tests es prüfen können.
enum MQTTFeeds {
    // MARK: - Funksensoren und Reifendruck

    static func isTPMS(_ sensor: SensorDevice) -> Bool { sensor.latest.model == "TPMS" }

    static func name(of sensor: SensorDevice) -> String {
        let r = sensor.latest
        if isTPMS(sensor) { return "Reifendrucksensor \(r.id)" }
        return "\(r.model) \(r.id)" + (r.channel.map { " Kanal \($0)" } ?? "")
    }

    static func values(of sensor: SensorDevice) -> [MQTTValue] {
        let r = sensor.latest
        var out: [MQTTValue] = []
        if let v = r.temperatureC { out.append(.number("temperature", "Temperatur", v, unit: "°C", deviceClass: "temperature")) }
        if let v = r.humidity { out.append(.number("humidity", "Luftfeuchte", Double(v), unit: "%", deviceClass: "humidity")) }
        if let v = r.windAverageMS { out.append(.number("wind_speed", "Wind", v, unit: "m/s", deviceClass: "wind_speed")) }
        if let v = r.windGustMS { out.append(.number("wind_gust", "Böen", v, unit: "m/s", deviceClass: "wind_speed")) }
        if let v = r.windDirection { out.append(.number("wind_direction", "Windrichtung", v, unit: "°")) }
        // Regenzähler laufen hoch (und nach Batteriewechsel wieder bei 0 los).
        if let v = r.rainMM {
            out.append(.number("rain", "Regen gesamt", v, unit: "mm", deviceClass: "precipitation", stateClass: "total_increasing"))
        }
        if let v = r.uvIndex { out.append(.number("uv_index", "UV-Index", v, unit: "UV index")) }
        if let v = r.lightLux { out.append(.number("illuminance", "Helligkeit", v, unit: "lx", deviceClass: "illuminance")) }
        if let ok = r.batteryOK { out.append(.flag("battery_low", "Batterie schwach", !ok, deviceClass: "battery")) }
        for (label, text) in r.extra.sorted(by: { $0.key < $1.key }) {
            if let value = extraValue(label: label, text: text) { out.append(value) }
        }
        out.append(.number("rssi", "Pegel", (sensor.rssiDB * 10).rounded() / 10, unit: "dB",
                           deviceClass: "signal_strength", diagnostic: true))
        return out
    }

    /// Zusatzwerte der Dekoder („CO₂“ → „850 ppm“) mit bekannter Einheit.
    static func extraValue(label: String, text: String) -> MQTTValue? {
        let number = Double(text.split(separator: " ").first.map { $0.replacingOccurrences(of: ",", with: ".") } ?? "")
        switch label {
        case "CO₂": return number.map { .number("co2", "CO₂", $0, unit: "ppm", deviceClass: "carbon_dioxide") }
        case "PM2,5": return number.map { .number("pm25", "Feinstaub PM2,5", $0, unit: "μg/m³", deviceClass: "pm25") }
        case "PM10": return number.map { .number("pm10", "Feinstaub PM10", $0, unit: "μg/m³", deviceClass: "pm10") }
        case "Bodenfeuchte": return number.map { .number("moisture", "Bodenfeuchte", $0, unit: "%", deviceClass: "moisture") }
        case "Globetemperatur":
            return number.map { .number("globe_temperature", "Globetemperatur", $0, unit: "°C", deviceClass: "temperature") }
        case "Formaldehyd": return number.map { .number("formaldehyde", "Formaldehyd", $0, unit: "ppb") }
        case "VOC-Stufe": return number.map { .number("voc_level", "VOC-Stufe", $0) }
        default: return nil
        }
    }

    // MARK: - Zigbee

    static func deviceID(of node: ZigbeeNode) -> String {
        if let ieee = node.ieee { return String(format: "%016llx", ieee) }
        return String(format: "%04x_%04x", node.key.pan, node.key.address)
    }

    static func name(of node: ZigbeeNode, stored: String?) -> String {
        if let stored, !stored.isEmpty { return stored }
        if let model = node.model, !model.isEmpty { return "\(model) \(String(format: "0x%04X", node.key.address))" }
        return (node.thread ? "Thread-Gerät " : "Zigbee-Gerät ") + String(format: "0x%04X", node.key.address)
    }

    /// Messgröße (Beschriftung aus `ZigbeeReading.parse`, z. B. „°C“) → Entität.
    private static let zigbeeMetrics: [String: (key: String, name: String, unit: String?, deviceClass: String?, stateClass: String, diagnostic: Bool)] = [
        "°C": ("temperature", "Temperatur", "°C", "temperature", "measurement", false),
        "% rF": ("humidity", "Luftfeuchte", "%", "humidity", "measurement", false),
        "hPa": ("pressure", "Luftdruck", "hPa", "atmospheric_pressure", "measurement", false),
        "lx": ("illuminance", "Helligkeit", "lx", "illuminance", "measurement", false),
        "Batterie V": ("battery_voltage", "Batteriespannung", "V", "voltage", "measurement", true),
        "Batterie %": ("battery", "Batterie", "%", "battery", "measurement", false),
        "W": ("power", "Leistung", "W", "power", "measurement", false),
        "V": ("voltage", "Spannung", "V", "voltage", "measurement", false),
        "A": ("current", "Strom", "A", "current", "measurement", false),
        "Hz": ("frequency", "Netzfrequenz", "Hz", "frequency", "measurement", false),
        "Zähler kWh": ("energy", "Energie", "kWh", "energy", "total_increasing", false),
        "Raum °C": ("room_temperature", "Raumtemperatur", "°C", "temperature", "measurement", false),
        "Soll °C": ("setpoint", "Solltemperatur", "°C", "temperature", "measurement", false),
        "Heizen %": ("heating_demand", "Heizleistung", "%", nil, "measurement", false),
        "Helligkeit %": ("brightness", "Dimmstufe", "%", nil, "measurement", false),
        "Rollladen % zu": ("cover_closed", "Rollladen geschlossen", "%", nil, "measurement", false),
        "K Farbtemperatur": ("color_temperature", "Farbtemperatur", "K", nil, "measurement", false),
        "letzter Pegel dBm": ("last_rssi", "Pegel laut Gerät", "dBm", "signal_strength", "measurement", true),
        "letzte LQI": ("lqi", "LQI", nil, nil, "measurement", true),
    ]

    static func values(of node: ZigbeeNode) -> [MQTTValue] {
        var out: [MQTTValue] = []
        for (label, number) in node.metrics.sorted(by: { $0.key < $1.key }) {
            let normalized = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard let m = zigbeeMetrics[normalized] else { continue }
            out.append(.number(m.key, m.name, number, unit: m.unit, deviceClass: m.deviceClass,
                               stateClass: m.stateClass, diagnostic: m.diagnostic))
        }
        if let onOff = node.state["Ein/Aus"] {
            out.append(.flag("on", "Eingeschaltet", onOff.hasPrefix("Ein"), deviceClass: "power"))
        }
        if let presence = node.state["Anwesenheit"] {
            out.append(.flag("occupancy", "Bewegung", presence.contains("Bewegung erkannt"), deviceClass: "occupancy"))
        }
        if let zone = node.state["Alarmzone (IAS)"] { out.append(.text("ias_zone", "Alarmzone", zone)) }
        if let lock = node.state["Türschloss"] { out.append(.text("lock", "Türschloss", lock)) }
        if let rssi = node.rssiDB {
            out.append(.number("rssi", "Pegel", (rssi * 10).rounded() / 10, unit: "dB", deviceClass: "signal_strength", diagnostic: true))
        }
        // Verbindungsgüte aus Sicht der Nachbarn (ZDO Mgmt_Lqi): der beste Wert.
        if let best = node.lqiNeighbors.values.max() {
            out.append(.number("neighbor_lqi", "Beste Nachbar-LQI", Double(best), diagnostic: true))
        }
        out.append(.number("frames", "Rahmen gehört", Double(node.heard), stateClass: "total_increasing", diagnostic: true))
        return out
    }

    // MARK: - Radiosonden

    static func deviceID(of sonde: Sonde) -> String {
        sonde.latest.serial.isEmpty ? sonde.id : sonde.latest.serial
    }

    static func values(of sonde: Sonde) -> [MQTTValue] {
        let r = sonde.latest
        var out: [MQTTValue] = []
        if let v = r.altitude { out.append(.number("altitude", "Höhe", v.rounded(), unit: "m", deviceClass: "distance")) }
        if let lat = r.latitude, let lon = r.longitude {
            out.append(.number("latitude", "Breite", (lat * 1e5).rounded() / 1e5, unit: "°"))
            out.append(.number("longitude", "Länge", (lon * 1e5).rounded() / 1e5, unit: "°"))
        }
        if let v = r.temperature { out.append(.number("temperature", "Temperatur", (v * 10).rounded() / 10, unit: "°C", deviceClass: "temperature")) }
        if let v = r.humidity { out.append(.number("humidity", "Luftfeuchte", v.rounded(), unit: "%", deviceClass: "humidity")) }
        if let v = r.verticalSpeed { out.append(.number("vertical_speed", "Steigrate", (v * 10).rounded() / 10, unit: "m/s", deviceClass: "speed")) }
        if let v = r.groundSpeed { out.append(.number("ground_speed", "Geschwindigkeit", (v * 10).rounded() / 10, unit: "m/s", deviceClass: "speed")) }
        if let v = r.heading { out.append(.number("heading", "Kurs", v.rounded(), unit: "°")) }
        if let v = r.batteryVolts { out.append(.number("battery_voltage", "Batteriespannung", v, unit: "V", deviceClass: "voltage", diagnostic: true)) }
        if let v = r.satellites { out.append(.number("satellites", "Satelliten", Double(v), diagnostic: true)) }
        if r.frequency > 0 {
            out.append(.number("frequency", "Frequenz", (r.frequency / 1e3).rounded() / 1e3, unit: "MHz", deviceClass: "frequency", diagnostic: true))
        }
        out.append(.flag("burst", "Geplatzt", sonde.burst))
        return out
    }

    static func model(of sonde: Sonde) -> String {
        sonde.latest.model.isEmpty ? sonde.latest.kind.rawValue : sonde.latest.model
    }

    static func manufacturer(of sonde: Sonde) -> String {
        sonde.latest.kind == .rs41 ? "Vaisala" : "Graw"
    }

    // MARK: - ADS-B

    /// Anzahl der Flugzeuge mit Kontakt in der letzten Minute, davon mit Position.
    static func adsbValues(_ planes: [Aircraft], messagesPerSecond: Double, now: Date = Date()) -> [MQTTValue] {
        let recent = planes.filter { now.timeIntervalSince($0.lastSeen) < 60 }
        return [
            .number("aircraft", "Flugzeuge in Reichweite", Double(recent.count)),
            .number("aircraft_with_position", "Flugzeuge mit Position", Double(recent.filter { $0.latitude != nil }.count)),
            .number("messages_per_second", "Nachrichten pro Sekunde", (messagesPerSecond * 10).rounded() / 10,
                    diagnostic: true),
        ]
    }
}

// MARK: - Smart Home 868 MHz

extension MQTTFeeds {
    static func name(of device: SmartHomeDevice) -> String {
        "\(device.radio.rawValue) \(device.address)"
    }

    /// Home-Assistant-Klasse aus der Einheit: Zählerstände (Energie, Wasser,
    /// Gas) laufen als `total_increasing`, alles andere als Momentanwert.
    static func classes(unit: String, name: String) -> (deviceClass: String?, stateClass: String) {
        let lower = name.lowercased()
        switch unit {
        case "°C": return ("temperature", "measurement")
        case "%": return (lower.contains("batter") ? "battery" : lower.contains("feucht") ? "humidity" : nil, "measurement")
        case "W", "kW": return ("power", "measurement")
        case "Wh", "kWh", "MWh": return ("energy", "total_increasing")
        case "J", "kJ", "MJ", "GJ": return ("energy", "total_increasing")
        case "V": return ("voltage", "measurement")
        case "mA", "A": return ("current", "measurement")
        case "Hz": return ("frequency", "measurement")
        case "m³", "l", "L":
            if lower.contains("gas") { return ("gas", "total_increasing") }
            return (lower.contains("wasser") || lower.contains("volumen") || lower.contains("zähler") ? "water" : nil, "total_increasing")
        default: return (nil, "measurement")
        }
    }

    static func values(of device: SmartHomeDevice) -> [MQTTValue] {
        var result = device.values.map { value -> MQTTValue in
            let (deviceClass, stateClass) = classes(unit: value.unit, name: value.name)
            return .number(MQTTDiscovery.sanitize(value.name.lowercased()), value.name, value.value,
                           unit: value.unit.isEmpty ? nil : value.unit, deviceClass: deviceClass, stateClass: stateClass)
        }
        result.append(.number("rssi", "Pegel", device.rssiDB.rounded(), unit: "dB",
                              deviceClass: "signal_strength", diagnostic: true))
        return result
    }
}
