import Foundation
import Observation
import Security
import os

// MARK: - Schnittstelle für die Empfängerseiten

/// Woher ein Gerät stammt – je Quelle ein Schalter in „Daten teilen“.
/// Neue Seiten legen hier eine Konstante an und nehmen sie in `all` auf.
struct MQTTSource: Hashable, Sendable, Identifiable {
    /// Teil der MQTT-Themen und Kennungen – nie ändern, sonst legt Home
    /// Assistant alle Geräte der Quelle neu an.
    let id: String
    let title: String
    /// Vorgabe des Schalters (der Hauptschalter bleibt trotzdem aus).
    let defaultOn: Bool
    /// `expire_after`: so lange ohne neue Meldung gilt ein Wert in Home
    /// Assistant noch, danach „nicht verfügbar“.
    let expireAfter: Int

    static let sensors = MQTTSource(id: "sensors", title: String(localized: "Funksensoren (Wetter, Thermometer …)"), defaultOn: true, expireAfter: 1800)
    /// Reifendrucksensoren – vorbeifahrende Autos legten sonst laufend neue
    /// Geräte an; deshalb ab Werk aus.
    static let tpms = MQTTSource(id: "tpms", title: String(localized: "Reifendruck (TPMS)"), defaultOn: false, expireAfter: 900)
    static let zigbee = MQTTSource(id: "zigbee", title: String(localized: "Zigbee-Geräte"), defaultOn: true, expireAfter: 3600)
    static let sondes = MQTTSource(id: "sondes", title: String(localized: "Radiosonden"), defaultOn: true, expireAfter: 300)
    static let adsb = MQTTSource(id: "adsb", title: String(localized: "Flugzeuge (ADS-B, Anzahl)"), defaultOn: true, expireAfter: 120)
    /// Seite „Smart Home 868 MHz“ (Z-Wave, Homematic, EnOcean, wM-Bus).
    static let smartHome868 = MQTTSource(id: "smarthome868", title: String(localized: "Smart Home 868 MHz (Z-Wave, Homematic, EnOcean, wM-Bus)"),
                                         defaultOn: true, expireAfter: 3600)

    static let all: [MQTTSource] = [.sensors, .tpms, .zigbee, .sondes, .adsb, .smartHome868]
}

/// Ein Messwert eines Geräts – wird in Home Assistant zu einer Entität.
struct MQTTValue: Sendable, Equatable {
    enum Reading: Sendable, Equatable {
        case number(Double)
        case text(String)
        /// Wird zu einem `binary_sensor` (an/aus).
        case flag(Bool)
    }

    /// Schlüssel im Zustands-JSON und Teil der Kennung – ASCII, klein, `_`.
    var key: String
    /// Anzeigename in Home Assistant (der Gerätename steht davor).
    var name: String
    var reading: Reading
    var unit: String?
    /// Home-Assistant-`device_class`, z. B. `temperature`, `humidity`, `battery`.
    var deviceClass: String?
    /// `measurement`, `total_increasing` … (nur bei Zahlen).
    var stateClass: String?
    /// Als Diagnosewert einsortieren (Pegel, zuletzt gehört …).
    var diagnostic = false

    static func number(_ key: String, _ name: String, _ value: Double, unit: String? = nil, deviceClass: String? = nil,
                       stateClass: String? = "measurement", diagnostic: Bool = false) -> MQTTValue {
        MQTTValue(key: key, name: name, reading: .number(value), unit: unit, deviceClass: deviceClass,
                  stateClass: stateClass, diagnostic: diagnostic)
    }

    static func text(_ key: String, _ name: String, _ value: String, deviceClass: String? = nil,
                     diagnostic: Bool = false) -> MQTTValue {
        MQTTValue(key: key, name: name, reading: .text(value), deviceClass: deviceClass, diagnostic: diagnostic)
    }

    static func flag(_ key: String, _ name: String, _ value: Bool, deviceClass: String? = nil,
                     diagnostic: Bool = false) -> MQTTValue {
        MQTTValue(key: key, name: name, reading: .flag(value), deviceClass: deviceClass, diagnostic: diagnostic)
    }

    var component: String { if case .flag = reading { "binary_sensor" } else { "sensor" } }
}

// MARK: - Einstellungen

struct MQTTSettings: Equatable, Sendable {
    var enabled = false
    var host = ""
    var port: UInt16 = 1883
    var tls = false
    var username = ""
    var baseTopic = "portapack"
    var discoveryPrefix = "homeassistant"
    var sources: Set<String> = Set(MQTTSource.all.filter(\.defaultOn).map(\.id))
    /// Nur Geräte, deren Name oder Kennung einen dieser Begriffe enthält (leer = alle).
    var allowlist = ""

    static let defaultsPrefix = "mqtt."

    static func load(from defaults: UserDefaults) -> MQTTSettings {
        var s = MQTTSettings()
        let p = defaultsPrefix
        s.enabled = defaults.bool(forKey: p + "enabled")
        s.host = defaults.string(forKey: p + "host") ?? ""
        if let port = defaults.object(forKey: p + "port") as? Int, let value = UInt16(exactly: port), value > 0 { s.port = value }
        s.tls = defaults.bool(forKey: p + "tls")
        s.username = defaults.string(forKey: p + "username") ?? ""
        s.baseTopic = defaults.string(forKey: p + "baseTopic") ?? s.baseTopic
        s.discoveryPrefix = defaults.string(forKey: p + "discoveryPrefix") ?? s.discoveryPrefix
        if let list = defaults.string(forKey: p + "sources") {
            s.sources = Set(list.split(separator: ",").map(String.init))
        }
        s.allowlist = defaults.string(forKey: p + "allowlist") ?? ""
        return s
    }

    func save(to defaults: UserDefaults) {
        let p = Self.defaultsPrefix
        defaults.set(enabled, forKey: p + "enabled")
        defaults.set(host, forKey: p + "host")
        defaults.set(Int(port), forKey: p + "port")
        defaults.set(tls, forKey: p + "tls")
        defaults.set(username, forKey: p + "username")
        defaults.set(baseTopic, forKey: p + "baseTopic")
        defaults.set(discoveryPrefix, forKey: p + "discoveryPrefix")
        defaults.set(sources.sorted().joined(separator: ","), forKey: p + "sources")
        defaults.set(allowlist, forKey: p + "allowlist")
    }

    /// Basis-Thema ohne Schrägstriche am Rand, ohne Platzhalter; leer → Vorgabe.
    var base: String { Self.cleanTopic(baseTopic, fallback: "portapack") }
    var prefix: String { Self.cleanTopic(discoveryPrefix, fallback: "homeassistant") }

    static func cleanTopic(_ text: String, fallback: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "+", with: "_").replacingOccurrences(of: "#", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// Begriffe der Liste „Nur Geräte mit …“ (klein, ohne Leerraum).
    var allowlistTerms: [String] {
        allowlist.split(whereSeparator: { $0 == "," || $0.isNewline }).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty }
    }

    /// Ohne TLS, aber mit Passwort: Benutzer und Passwort gehen im Klartext übers Netz.
    /// Zu einem Broker auf diesem Mac ist das egal.
    static func sendsPasswordInClear(tls: Bool, host: String, password: String) -> Bool {
        guard !tls, !password.isEmpty else { return false }
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(h)
    }

    func allows(name: String, deviceID: String) -> Bool {
        let terms = allowlistTerms
        guard !terms.isEmpty else { return true }
        let haystack = (name + " " + deviceID).lowercased()
        return terms.contains { haystack.contains($0) }
    }
}

/// Das Broker-Passwort liegt nur im Schlüsselbund (Tests: im Speicher).
struct MQTTPasswordStore: Sendable {
    var load: @Sendable () -> String
    var save: @Sendable (String) -> Void

    static let keychain: MQTTPasswordStore = {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "de.christiangolz.portapackmanager.mqtt",
                                    kSecAttrAccount as String: "broker-password"]
        nonisolated(unsafe) let base = query
        return MQTTPasswordStore(
            load: {
                var q = base
                q[kSecReturnData as String] = true
                q[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
                return String(decoding: data, as: UTF8.self)
            },
            save: { password in
                if password.isEmpty { SecItemDelete(base as CFDictionary) }
                else { _ = KeychainBlob.save(Data(password.utf8), query: base) }
            })
    }()

    static func memory(_ initial: String = "") -> MQTTPasswordStore {
        final class Box: @unchecked Sendable { let lock = NSLock(); var value = "" }
        let box = Box()
        box.value = initial
        return MQTTPasswordStore(load: { box.lock.withLock { box.value } },
                                 save: { value in box.lock.withLock { box.value = value } })
    }
}

// MARK: - Home-Assistant-MQTT-Discovery (rein, ohne Netz)

enum MQTTDiscovery {
    struct Message: Sendable, Equatable {
        var topic: String
        var payload: [UInt8]
        var retain = false
        var text: String { String(decoding: payload, as: UTF8.self) }
    }

    /// Kennung für Themen und `unique_id`: nur `A–Z a–z 0–9 _ -`, höchstens 64 Zeichen.
    static func sanitize(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var out = String(id.map { allowed.contains($0) ? $0 : "_" }.prefix(64))
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return out.isEmpty ? "unbekannt" : out
    }

    static func availabilityTopic(base: String) -> String { "\(base)/status" }

    static func stateTopic(base: String, source: MQTTSource, deviceID: String) -> String {
        "\(base)/\(source.id)/\(sanitize(deviceID))/state"
    }

    static func bridgeID(base: String) -> String { "portapack_\(sanitize(base))" }

    /// Entfernt Entitäten in Home Assistant: je Discovery-Thema eine leere, gehaltene
    /// (retained) Nachricht – HA löscht die Entität, der Broker die gehaltene Konfiguration.
    static func removal(topics: some Sequence<String>) -> [Message] {
        topics.sorted().map { Message(topic: $0, payload: [], retain: true) }
    }

    static func encode(_ object: Any) -> [UInt8] {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return [UInt8](data)
    }

    private static var origin: [String: Any] {
        ["name": "PortaPack Manager",
         "sw_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         "support_url": "https://github.com/cpeg78"]
    }

    /// Das Gerät „PortaPack Manager“ selbst mit einem Verbindungssensor –
    /// alle Funkgeräte hängen per `via_device` daran.
    static func bridgeConfig(settings: MQTTSettings) -> Message {
        let id = bridgeID(base: settings.base)
        let config: [String: Any] = [
            "name": "Verbindung",
            "unique_id": "\(id)_connectivity",
            "state_topic": availabilityTopic(base: settings.base),
            "payload_on": "online", "payload_off": "offline",
            "device_class": "connectivity",
            "entity_category": "diagnostic",
            "device": ["identifiers": [id], "name": "PortaPack Manager", "manufacturer": "Christian Golz",
                       "model": "PortaPack Manager (macOS)",
                       "sw_version": origin["sw_version"] ?? "0"],
            "origin": origin,
        ]
        return Message(topic: "\(settings.prefix)/binary_sensor/\(id)/connectivity/config", payload: encode(config))
    }

    /// Je Wert eine Konfiguration; mit Breite und Länge dazu ein `device_tracker`.
    static func configs(settings: MQTTSettings, source: MQTTSource, deviceID: String, name: String,
                        model: String?, manufacturer: String?, values: [MQTTValue]) -> [Message] {
        let id = sanitize(deviceID)
        let node = sanitize("\(source.id)_\(id)")
        let unique = "\(bridgeID(base: settings.base))_\(node)"
        let state = stateTopic(base: settings.base, source: source, deviceID: deviceID)
        var device: [String: Any] = ["identifiers": [unique], "name": name,
                                     "via_device": bridgeID(base: settings.base)]
        if let model, !model.isEmpty { device["model"] = model }
        device["manufacturer"] = manufacturer.flatMap { $0.isEmpty ? nil : $0 } ?? "PortaPack Manager (\(source.title))"
        let availability = [["topic": availabilityTopic(base: settings.base)]]

        var out: [Message] = []
        for value in values + [lastSeenValue] {
            let key = sanitize(value.key)
            var config: [String: Any] = [
                "name": value.name,
                "unique_id": "\(unique)_\(key)",
                "state_topic": state,
                "availability": availability,
                "device": device,
                "origin": origin,
                "expire_after": source.expireAfter,
            ]
            switch value.reading {
            case .flag:
                config["value_template"] = "{{ 'ON' if value_json['\(key)'] else 'OFF' }}"
            case .number:
                config["value_template"] = "{{ value_json['\(key)'] }}"
                if let stateClass = value.stateClass { config["state_class"] = stateClass }
                if let unit = value.unit { config["unit_of_measurement"] = unit }
            case .text:
                config["value_template"] = "{{ value_json['\(key)'] }}"
            }
            if let deviceClass = value.deviceClass { config["device_class"] = deviceClass }
            if value.diagnostic { config["entity_category"] = "diagnostic" }
            out.append(Message(topic: "\(settings.prefix)/\(value.component)/\(node)/\(key)/config", payload: encode(config)))
        }
        if hasPosition(values) {
            let config: [String: Any] = [
                "name": "Position",
                "unique_id": "\(unique)_position",
                "json_attributes_topic": state,
                "json_attributes_template":
                    "{{ {'latitude': value_json['latitude'], 'longitude': value_json['longitude'], 'gps_accuracy': 20} | tojson }}",
                "source_type": "gps",
                "availability": availability,
                "device": device,
                "origin": origin,
            ]
            out.append(Message(topic: "\(settings.prefix)/device_tracker/\(node)/position/config", payload: encode(config)))
        }
        return out
    }

    static func hasPosition(_ values: [MQTTValue]) -> Bool {
        let keys = Set(values.compactMap { value -> String? in
            if case .number = value.reading { return value.key } else { return nil }
        })
        return keys.contains("latitude") && keys.contains("longitude")
    }

    /// Jedes Gerät bekommt „zuletzt gehört“ – der Wert selbst kommt aus `statePayload`.
    static let lastSeenValue = MQTTValue.text("last_seen", "Zuletzt gehört", "", deviceClass: "timestamp", diagnostic: true)

    /// Zustand als JSON: je Wert ein Schlüssel, dazu `last_seen` (ISO 8601).
    static func statePayload(_ values: [MQTTValue], lastSeen: Date) -> [UInt8] {
        var object: [String: Any] = [:]
        for value in values {
            switch value.reading {
            case let .number(v) where v.isFinite: object[sanitize(value.key)] = (v * 1e6).rounded() / 1e6
            case .number: continue
            case let .text(t): object[sanitize(value.key)] = t
            case let .flag(b): object[sanitize(value.key)] = b
            }
        }
        object["last_seen"] = ISOTime.string(lastSeen)
        return encode(object)
    }
}

/// Gleiche Werte nicht öfter als alle `interval` Sekunden neu senden;
/// geänderte sofort.
struct MQTTThrottle {
    var interval: TimeInterval = 30
    private var last: [String: (values: [MQTTValue], date: Date)] = [:]

    init(interval: TimeInterval = 30) { self.interval = interval }

    /// `true` = senden (und als gesendet merken).
    mutating func shouldSend(_ key: String, values: [MQTTValue], now: Date = Date()) -> Bool {
        if let previous = last[key], previous.values == values, now.timeIntervalSince(previous.date) < interval {
            return false
        }
        last[key] = (values, now)
        return true
    }

    mutating func reset() { last = [:] }
    mutating func forget(_ key: String) { last[key] = nil }
}

/// Begrenzt, wie viele **neue** Geräte an Home Assistant gehen (Eimer mit Nachfüllung):
/// ab Start `burst`, danach `perHour` je Stunde. Ein Sender in Funkreichweite konnte
/// sonst mit fortlaufenden Kennungen Tausende erfundene Geräte in HA anlegen
/// (Review 29.10.2026, S4). Geräte aus der Liste „Nur Geräte mit …“ zählen nicht.
struct MQTTDeviceBudget: Sendable, Equatable {
    var burst: Double = 40
    var perHour: Double = 20
    private var tokens: Double
    private var updated: Date?

    init(burst: Double = 40, perHour: Double = 20) {
        self.burst = burst
        self.perHour = perHour
        tokens = burst
    }

    /// `true` = ein neues Gerät darf angelegt werden (und verbraucht einen Platz).
    mutating func take(now: Date) -> Bool {
        if let updated {
            let hours = max(0, now.timeIntervalSince(updated)) / 3600
            tokens = min(burst, tokens + hours * perHour)
        }
        updated = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

// MARK: - Brücke

/// Weitergabe an Home Assistant per MQTT (Discovery). Aus, bis in „Daten
/// teilen“ eingeschaltet – vorher wird weder verbunden noch gesendet.
///
/// Seiten melden ihre Geräte über `report(source:deviceID:name:…:values:)`
/// (Main Actor, beliebig oft – gedrosselt wird hier).
@MainActor
@Observable
final class MQTTBridge {
    static let shared = MQTTBridge()
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "MQTT")

    enum Status: Equatable {
        case off
        case connecting
        case connected(since: Date)
        case waiting(reason: String, retry: TimeInterval)
        case failed(String)
    }

    struct DeviceSummary: Identifiable, Equatable {
        var id: String          // Quelle/Kennung
        var source: String
        var name: String
        var lastSeen: Date
    }

    private(set) var settings: MQTTSettings
    private(set) var status: Status = .off
    private(set) var publishedStates = 0
    private(set) var announcedDevices = 0
    /// Neue Geräte, die wegen der Grenze je Stunde zurückgehalten wurden (verschiedene Kennungen).
    private(set) var heldBackDevices = 0
    @ObservationIgnored private var heldBack: Set<String> = []
    /// Grenze für neue Geräte (Tests stellen sie enger).
    @ObservationIgnored var newDeviceBudget = MQTTDeviceBudget()
    /// Höchstzahl gemerkter Geräte (Tests stellen sie kleiner).
    @ObservationIgnored var deviceLimit = MQTTBridge.maxDevices
    /// Wie oft Discovery-Konfigurationen gebaut wurden (für Tests).
    @ObservationIgnored private(set) var configBuilds = 0

    /// Für den Ablauf: Drosselung (Tests stellen sie kürzer).
    var throttleInterval: TimeInterval {
        get { throttle.interval }
        set { throttle.interval = newValue }
    }

    private struct DeviceRecord {
        var source: MQTTSource
        var deviceID: String
        var name: String
        var model: String?
        var manufacturer: String?
        var values: [MQTTValue]
        var lastSeen: Date
        var topicKey: String { "\(source.id)/\(MQTTDiscovery.sanitize(deviceID))" }
    }

    private let defaults: UserDefaults
    private let passwordStore: MQTTPasswordStore
    private var password: String
    private var client: MQTTClient?
    private var connected = false
    /// Zählt die Clients durch – Rückrufe eines abgelösten Clients zählen nicht.
    private var generation = 0
    private var devices: [String: DeviceRecord] = [:]
    /// Je Gerät (`topicKey`) die schon bekanntgegebenen Discovery-Themen.
    private var announced: [String: Set<String>] = [:]
    /// Je Gerät die Merkmale, aus denen die Konfigurationen zuletzt gebaut wurden –
    /// solange sie gleich bleiben, wird nichts neu gebaut (Review Y17).
    private var announcedSignatures: [String: DiscoverySignature] = [:]

    /// Was die Discovery-Konfigurationen eines Geräts bestimmt: Name, Modell,
    /// Hersteller und die Wertschlüssel (samt Komponente).
    private struct DiscoverySignature: Equatable {
        var name: String
        var model: String?
        var manufacturer: String?
        var keys: [String]

        init(_ record: DeviceRecord) {
            name = record.name
            model = record.model
            manufacturer = record.manufacturer
            keys = record.values.map { "\($0.component)/\($0.key)" }
        }
    }
    private var throttle = MQTTThrottle()
    static let maxDevices = 1000

    init(defaults: UserDefaults = .standard, passwordStore: MQTTPasswordStore = .keychain) {
        self.defaults = defaults
        self.passwordStore = passwordStore
        let settings = MQTTSettings.load(from: defaults)
        self.settings = settings
        // Schlüsselbund nur anfassen, wenn die Weitergabe an ist.
        self.password = settings.enabled ? passwordStore.load() : ""
    }

    /// Beim App-Start: verbinden, falls eingeschaltet.
    func bootstrap() {
        if settings.enabled { restartClient() }
    }

    /// Gespeichertes Passwort (für das Formular).
    func storedPassword() -> String { passwordStore.load() }

    /// Neue Einstellungen übernehmen. `password` `nil` = unverändert.
    func apply(_ new: MQTTSettings, password newPassword: String? = nil) {
        var passwordChanged = false
        if let newPassword, newPassword != passwordStore.load() {
            passwordStore.save(newPassword)
            passwordChanged = true
        }
        let old = settings
        let connectionChanged = old.enabled != new.enabled || old.host != new.host || old.port != new.port
            || old.tls != new.tls || old.username != new.username || old.base != new.base || passwordChanged
        // Erst mit den alten Einstellungen trennen – „offline“ gehört unter das alte Basis-Thema.
        if !new.enabled || connectionChanged { stopClient() }
        settings = new
        new.save(to: defaults)
        if !new.enabled {
            devices = [:]
            heldBack = []
            heldBackDevices = 0
            return
        }
        if client == nil {
            password = passwordStore.load()
            restartClient()
        } else if old.prefix != new.prefix || old.sources != new.sources || old.allowlist != new.allowlist {
            // Abgeschaltete Quellen nicht mehr senden; Discovery unter neuem Präfix.
            devices = devices.filter { new.sources.contains($0.value.source.id)
                && new.allows(name: $0.value.name, deviceID: $0.value.deviceID) }
            if connected { announceAll() }
        }
    }

    func isEnabled(_ source: MQTTSource) -> Bool {
        settings.enabled && settings.sources.contains(source.id)
    }

    /// Ein Gerät mit seinen aktuellen Werten melden. Fehlende Werte bleiben
    /// mit dem zuletzt gemeldeten Stand erhalten.
    func report(source: MQTTSource, deviceID: String, name: String, model: String? = nil,
                manufacturer: String? = nil, values: [MQTTValue], seen: Date = Date()) {
        guard isEnabled(source), !values.isEmpty, settings.allows(name: name, deviceID: deviceID) else { return }
        let key = "\(source.id)/\(MQTTDiscovery.sanitize(deviceID))"
        if devices[key] == nil, settings.allowlistTerms.isEmpty, !newDeviceBudget.take(now: seen) {
            // Grenze erreicht: nur noch Geräte aus der Liste „Nur Geräte mit …“.
            if heldBack.count < Self.maxDevices, heldBack.insert(key).inserted {
                heldBackDevices = heldBack.count
                if heldBack.count == 1 || heldBack.count % 100 == 0 {
                    Self.log.notice("Neue Geräte zurückgehalten (Grenze je Stunde): \(self.heldBack.count)")
                }
            }
            return
        }
        if heldBack.remove(key) != nil { heldBackDevices = heldBack.count }
        var record = devices[key] ?? DeviceRecord(source: source, deviceID: deviceID, name: name, model: model,
                                                  manufacturer: manufacturer, values: [], lastSeen: seen)
        let nameChanged = record.name != name || record.model != model || record.manufacturer != manufacturer
        record.name = name
        record.model = model ?? record.model
        record.manufacturer = manufacturer ?? record.manufacturer
        record.lastSeen = seen
        for value in values {
            if let index = record.values.firstIndex(where: { $0.key == value.key }) { record.values[index] = value }
            else { record.values.append(value) }
        }
        if devices[key] == nil { prune(now: seen) }
        devices[key] = record
        guard connected else { return }
        if nameChanged { forgetAnnouncement(key) }
        announce(record)
        publishState(record, force: false)
    }

    /// Kurz vor dem Beenden: „offline“ senden und sauber trennen (wartet höchstens 1 s).
    func shutdown() {
        guard let client else { return }
        self.client = nil
        let done = DispatchSemaphore(value: 0)
        client.stop(farewell: availability(online: false)) { done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    /// „Verbindung testen“ mit den Werten aus dem Formular (ohne sie zu übernehmen).
    func test(_ candidate: MQTTSettings, password: String) async -> String? {
        await MQTTClient.probe(clientConfiguration(candidate, password: password, clientID: clientID + "-test"))
    }

    /// Gemeldete Geräte (neueste zuerst) für die Anzeige.
    var deviceList: [DeviceSummary] {
        devices.map { DeviceSummary(id: $0.key, source: $0.value.source.title, name: $0.value.name, lastSeen: $0.value.lastSeen) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: - Intern

    private var clientID: String {
        if let stored = defaults.string(forKey: MQTTSettings.defaultsPrefix + "clientID") { return stored }
        let new = "portapack-manager-" + UUID().uuidString.prefix(8).lowercased()
        defaults.set(new, forKey: MQTTSettings.defaultsPrefix + "clientID")
        return new
    }

    private func availability(online: Bool) -> (topic: String, payload: [UInt8], retain: Bool) {
        (MQTTDiscovery.availabilityTopic(base: settings.base), Array((online ? "online" : "offline").utf8), true)
    }

    private func clientConfiguration(_ s: MQTTSettings, password: String, clientID: String) -> MQTTClient.Configuration {
        MQTTClient.Configuration(
            host: s.host.trimmingCharacters(in: .whitespaces), port: s.port, tls: s.tls,
            username: s.username.trimmingCharacters(in: .whitespaces), password: password, clientID: clientID,
            will: MQTTPacket.Will(topic: MQTTDiscovery.availabilityTopic(base: s.base), payload: Array("offline".utf8), retain: true),
            subscriptions: ["\(s.prefix)/status"])
    }

    private func stopClient() {
        generation += 1
        client?.stop(farewell: availability(online: false))
        client = nil
        connected = false
        announced = [:]
        announcedSignatures = [:]
        status = .off
    }

    private func restartClient() {
        stopClient()
        guard settings.enabled else { return }
        status = .connecting
        generation += 1
        let generation = generation
        let homeAssistantStatus = "\(settings.prefix)/status"
        let client = MQTTClient(
            configuration: clientConfiguration(settings, password: password, clientID: clientID),
            handlers: MQTTClient.Handlers(
                state: { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.clientState(state)
                    }
                },
                connected: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.didConnect()
                    }
                },
                message: { [weak self] topic, payload in
                    // Home Assistant meldet nach jedem Neustart „online“ – dann alles neu bekanntgeben.
                    guard topic == homeAssistantStatus, String(decoding: payload, as: UTF8.self) == "online" else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.announceAll()
                    }
                }))
        self.client = client
        client.start()
    }

    private func clientState(_ state: MQTTClient.State) {
        guard client != nil else { return }
        switch state {
        case .idle: status = .off
        case .connecting: status = .connecting
        case .connected: break                       // erst in didConnect
        case let .waiting(reason, retry):
            connected = false
            status = .waiting(reason: reason, retry: retry)
        case let .failed(reason):
            connected = false
            status = .failed(reason)
        }
    }

    private func didConnect() {
        guard client != nil else { return }
        connected = true
        status = .connected(since: Date())
        announceAll()
    }

    /// Nach (Neu-)Verbindung oder Home-Assistant-Neustart: Verfügbarkeit,
    /// alle Discovery-Konfigurationen und die letzten Zustände erneut.
    private func announceAll() {
        guard connected, let client else { return }
        announced = [:]
        announcedSignatures = [:]
        throttle.reset()
        let online = availability(online: true)
        client.publish(topic: online.topic, payload: online.payload, retain: true)
        let bridge = MQTTDiscovery.bridgeConfig(settings: settings)
        client.publish(topic: bridge.topic, payload: bridge.payload)
        let now = Date()
        for record in devices.values where now.timeIntervalSince(record.lastSeen) < Double(record.source.expireAfter) {
            announce(record)
            publishState(record, force: true)
        }
    }

    private func announce(_ record: DeviceRecord) {
        guard let client else { return }
        let signature = DiscoverySignature(record)
        guard announcedSignatures[record.topicKey] != signature else { return }
        let messages = MQTTDiscovery.configs(settings: settings, source: record.source, deviceID: record.deviceID,
                                             name: record.name, model: record.model, manufacturer: record.manufacturer,
                                             values: record.values)
        configBuilds += 1
        var topics = announced[record.topicKey] ?? []
        let newDevice = topics.isEmpty
        for message in messages where topics.insert(message.topic).inserted {
            client.publish(topic: message.topic, payload: message.payload)
        }
        announced[record.topicKey] = topics
        announcedSignatures[record.topicKey] = signature
        if newDevice {
            announcedDevices += 1
            Self.log.info("Discovery: \(record.topicKey, privacy: .public)")
        }
    }

    private func publishState(_ record: DeviceRecord, force: Bool) {
        guard let client else { return }
        if !force, !throttle.shouldSend(record.topicKey, values: record.values) { return }
        if force { _ = throttle.shouldSend(record.topicKey, values: record.values) }
        client.publish(topic: MQTTDiscovery.stateTopic(base: settings.base, source: record.source, deviceID: record.deviceID),
                       payload: MQTTDiscovery.statePayload(record.values, lastSeen: record.lastSeen))
        publishedStates += 1
    }

    /// Höchstens `maxDevices` Geräte; zuerst die länger als ihre Ablaufzeit stillen.
    /// Drosselung und Bekanntgaben der entfernten Geräte werden mit entfernt,
    /// sonst wüchsen sie unbegrenzt.
    private func prune(now: Date) {
        guard devices.count >= deviceLimit else { return }
        let expired = devices.filter { now.timeIntervalSince($0.value.lastSeen) >= Double($0.value.source.expireAfter) }.keys
        for key in expired { remove(key) }
        if devices.count >= deviceLimit,
           let oldest = devices.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
            remove(oldest.key)
        }
    }

    /// Entfernt ein Gerät auch aus Home Assistant (leere, gehaltene Konfigurationen) –
    /// vorher blieb die Entität dort für immer stehen.
    private func remove(_ key: String) {
        if connected, let client, let topics = announced[key] {
            for message in MQTTDiscovery.removal(topics: topics) {
                client.publish(topic: message.topic, payload: message.payload, retain: message.retain)
            }
        }
        devices[key] = nil
        throttle.forget(key)
        forgetAnnouncement(key)
    }

    private func forgetAnnouncement(_ key: String) {
        announced[key] = nil
        announcedSignatures[key] = nil
    }
}
