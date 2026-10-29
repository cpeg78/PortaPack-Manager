import Foundation
import Network
import Testing
@testable import PortaPackManager

@Suite("MQTT / Home Assistant")
struct MQTTTests {
    // MARK: - Paketkodierung

    @Test("Restlänge: Grenzwerte aus der Norm (1 bis 4 Byte)", arguments: [
        (0, [0x00]), (127, [0x7F]), (128, [0x80, 0x01]), (16_383, [0xFF, 0x7F]),
        (16_384, [0x80, 0x80, 0x01]), (2_097_151, [0xFF, 0xFF, 0x7F]),
        (2_097_152, [0x80, 0x80, 0x80, 0x01]), (268_435_455, [0xFF, 0xFF, 0xFF, 0x7F]),
    ] as [(Int, [UInt8])])
    func remainingLength(value: Int, bytes: [UInt8]) {
        #expect(MQTTPacket.encodeRemainingLength(value) == bytes)
        #expect(MQTTPacket.decodeRemainingLength([0x30] + bytes, from: 1) == .value(value, consumed: bytes.count))
    }

    @Test("Restlänge: fehlende Bytes und mehr als 4 Byte erkannt")
    func remainingLengthErrors() {
        #expect(MQTTPacket.decodeRemainingLength([0x30, 0x80], from: 1) == .needMore)
        #expect(MQTTPacket.decodeRemainingLength([0x30, 0x80, 0x80, 0x80, 0x80, 0x01], from: 1) == .malformed)
    }

    @Test("CONNECT mit Benutzer, Passwort und Last Will – Byte für Byte")
    func connectPacket() {
        let packet = MQTTPacket.connect(clientID: "a", username: "u", password: "p", keepAlive: 60,
                                        will: .init(topic: "t", payload: Array("x".utf8), retain: true))
        let expected: [UInt8] = [0x10, 25,
                                 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04,
                                 0xE6,                  // Benutzer, Passwort, Will-Retain, Will, Clean Session
                                 0x00, 0x3C,
                                 0x00, 0x01, 0x61,      // Client-ID
                                 0x00, 0x01, 0x74,      // Will-Thema
                                 0x00, 0x01, 0x78,      // Will-Nachricht
                                 0x00, 0x01, 0x75,      // Benutzer
                                 0x00, 0x01, 0x70]      // Passwort
        #expect(packet == expected)
    }

    @Test("CONNECT ohne Benutzer lässt auch das Passwort weg")
    func connectWithoutUser() {
        let packet = MQTTPacket.connect(clientID: "abc", username: "", password: "geheim", keepAlive: 30, will: nil)
        #expect(packet == [0x10, 15, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x1E, 0x00, 0x03, 0x61, 0x62, 0x63])
    }

    @Test("PUBLISH QoS 0 mit Retain und mehrbytiger Restlänge")
    func publishPacket() {
        #expect(MQTTPacket.publish(topic: "a/b", payload: Array("hi".utf8), retain: true)
                == [0x31, 0x07, 0x00, 0x03, 0x61, 0x2F, 0x62, 0x68, 0x69])
        let long = MQTTPacket.publish(topic: "t", payload: [UInt8](repeating: 0x41, count: 200), retain: false)
        #expect(Array(long.prefix(6)) == [0x30, 0xCB, 0x01, 0x00, 0x01, 0x74])     // 3 + 200 = 203
        #expect(long.count == 3 + 203)
    }

    @Test("SUBSCRIBE, PINGREQ, DISCONNECT")
    func smallPackets() {
        #expect(MQTTPacket.subscribe(packetID: 1, topic: "ha/status")
                == [0x82, 0x0E, 0x00, 0x01, 0x00, 0x09] + Array("ha/status".utf8) + [0x00])
        #expect(MQTTPacket.pingreq == [0xC0, 0x00])
        #expect(MQTTPacket.disconnect == [0xE0, 0x00])
    }

    @Test("Leser setzt zerstückelte Pakete zusammen und deutet PUBLISH mit QoS 1")
    func reader() throws {
        var reader = MQTTPacketReader()
        let stream = MQTTPacket.connack(returnCode: 0) + [0x32, 0x08, 0x00, 0x01, 0x74, 0x12, 0x34, 0x6F, 0x6E, 0x21] + MQTTPacket.pingresp
        reader.append(stream.prefix(3))
        #expect(try reader.next() == nil)
        reader.append(stream.dropFirst(3).prefix(5))
        let connack = try #require(try reader.next())
        #expect(connack.kind == .connack && MQTTPacket.connackCode(connack.body) == 0)
        #expect(try reader.next() == nil)
        reader.append(stream.dropFirst(8))
        let publish = try #require(try reader.next())
        let parsed = try #require(MQTTPacket.parsePublish(flags: publish.flags, body: publish.body))
        #expect(parsed.topic == "t" && parsed.payload == Array("on!".utf8))
        #expect(try reader.next()?.kind == .pingresp)
    }

    // MARK: - Discovery

    private func sensorDevice(temperature: Double = 21.5, battery: Bool? = true) -> SensorDevice {
        let reading = SensorReading(model: "Nexus-TH", id: "123", channel: 1, batteryOK: battery, temperatureC: temperature,
                                    humidity: 40, integrity: "CRC")
        return SensorDevice(latest: reading, firstSeen: Date(), lastSeen: Date(), count: 1, rssiDB: -12.34,
                            snrDB: 20, offsetKHz: 0, frequencyMHz: 433.92)
    }

    private func json(_ message: MQTTDiscovery.Message) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(message.payload)) as? [String: Any])
    }

    @Test("Discovery: Sensor mit device_class, Einheit, state_class, expire_after und Gerät")
    func discoveryConfig() throws {
        let sensor = sensorDevice()
        let messages = MQTTDiscovery.configs(settings: MQTTSettings(), source: .sensors, deviceID: sensor.id,
                                             name: MQTTFeeds.name(of: sensor), model: "Nexus-TH", manufacturer: nil,
                                             values: MQTTFeeds.values(of: sensor))
        let temperature = try #require(messages.first { $0.topic == "homeassistant/sensor/sensors_Nexus-TH_123_1/temperature/config" })
        let config = try json(temperature)
        #expect(config["device_class"] as? String == "temperature")
        #expect(config["unit_of_measurement"] as? String == "°C")
        #expect(config["state_class"] as? String == "measurement")
        #expect(config["expire_after"] as? Int == MQTTSource.sensors.expireAfter)
        #expect(config["state_topic"] as? String == "portapack/sensors/Nexus-TH_123_1/state")
        #expect(config["value_template"] as? String == "{{ value_json['temperature'] }}")
        #expect(config["unique_id"] as? String == "portapack_portapack_sensors_Nexus-TH_123_1_temperature")
        let availability = try #require(config["availability"] as? [[String: String]])
        #expect(availability == [["topic": "portapack/status"]])
        let device = try #require(config["device"] as? [String: Any])
        #expect(device["identifiers"] as? [String] == ["portapack_portapack_sensors_Nexus-TH_123_1"])
        #expect(device["name"] as? String == "Nexus-TH 123 Kanal 1")
        #expect(device["via_device"] as? String == "portapack_portapack")
        // Batterie als binary_sensor, „zuletzt gehört“ als Zeitstempel.
        let battery = try json(try #require(messages.first { $0.topic.hasSuffix("/binary_sensor/sensors_Nexus-TH_123_1/battery_low/config") }))
        #expect(battery["device_class"] as? String == "battery")
        #expect(battery["unit_of_measurement"] == nil)
        let lastSeen = try json(try #require(messages.first { $0.topic.hasSuffix("/last_seen/config") }))
        #expect(lastSeen["device_class"] as? String == "timestamp")
        #expect(lastSeen["entity_category"] as? String == "diagnostic")
        #expect(!messages.contains { $0.topic.contains("device_tracker") })
        #expect(messages.allSatisfy { !$0.retain })
    }

    @Test("Discovery: eigene Präfixe, Position wird zum device_tracker")
    func discoveryTracker() throws {
        var settings = MQTTSettings()
        settings.baseTopic = "/funk/"
        settings.discoveryPrefix = "ha"
        let values: [MQTTValue] = [.number("latitude", "Breite", 52.1, unit: "°"), .number("longitude", "Länge", 13.2, unit: "°"),
                                   .number("altitude", "Höhe", 20_000, unit: "m", deviceClass: "distance")]
        let messages = MQTTDiscovery.configs(settings: settings, source: .sondes, deviceID: "S1234567", name: "Radiosonde S1234567",
                                             model: "RS41-SG", manufacturer: "Vaisala", values: values)
        let tracker = try json(try #require(messages.first { $0.topic == "ha/device_tracker/sondes_S1234567/position/config" }))
        #expect(tracker["json_attributes_topic"] as? String == "funk/sondes/S1234567/state")
        #expect(tracker["source_type"] as? String == "gps")
        let bridge = MQTTDiscovery.bridgeConfig(settings: settings)
        #expect(bridge.topic == "ha/binary_sensor/portapack_funk/connectivity/config")
        #expect(try json(bridge)["state_topic"] as? String == "funk/status")
    }

    @Test("Zustand als JSON mit last_seen, Kennungen bereinigt")
    func statePayload() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = MQTTDiscovery.statePayload([.number("temperature", "T", 21.5), .flag("battery_low", "B", false),
                                                  .text("lock", "S", "verriegelt"), .number("nan", "N", .nan)], lastSeen: date)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any])
        #expect(object["temperature"] as? Double == 21.5)
        #expect(object["battery_low"] as? Bool == false)
        #expect(object["lock"] as? String == "verriegelt")
        #expect(object["nan"] == nil)
        #expect(object["last_seen"] as? String == "2027-01-15T08:00:00Z")
        #expect(MQTTDiscovery.sanitize("Nexus|123|-") == "Nexus_123_-")
        #expect(MQTTDiscovery.sanitize("a/b+#c") == "a_b_c")
        #expect(MQTTDiscovery.sanitize("|||") == "unbekannt")
    }

    @Test("Drosselung: gleiche Werte frühestens nach 30 s, geänderte sofort")
    func throttle() {
        var throttle = MQTTThrottle(interval: 30)
        let t0 = Date()
        let a: [MQTTValue] = [.number("temperature", "T", 20)]
        let b: [MQTTValue] = [.number("temperature", "T", 21)]
        var results: [Bool] = []
        results.append(throttle.shouldSend("x", values: a, now: t0))
        results.append(throttle.shouldSend("x", values: a, now: t0.addingTimeInterval(10)))
        results.append(throttle.shouldSend("x", values: a, now: t0.addingTimeInterval(29.9)))
        results.append(throttle.shouldSend("x", values: a, now: t0.addingTimeInterval(30)))
        results.append(throttle.shouldSend("x", values: b, now: t0.addingTimeInterval(31)))
        results.append(throttle.shouldSend("y", values: b, now: t0.addingTimeInterval(31)))
        throttle.reset()
        results.append(throttle.shouldSend("x", values: b, now: t0.addingTimeInterval(32)))
        #expect(results == [true, false, false, true, true, true, true])
    }

    @Test("Einstellungen: Vorgabe aus, TPMS aus; Liste „nur diese Geräte“")
    func settings() throws {
        let defaults = try #require(UserDefaults(suiteName: "mqtt-test-\(UUID())"))
        let loaded = MQTTSettings.load(from: defaults)
        #expect(!loaded.enabled)
        #expect(loaded.port == 1883)
        #expect(loaded.sources.contains("sensors") && !loaded.sources.contains("tpms"))
        var changed = loaded
        changed.enabled = true
        changed.port = 8883
        changed.sources = ["zigbee"]
        changed.allowlist = "nexus, 0x1a2b"
        changed.save(to: defaults)
        #expect(MQTTSettings.load(from: defaults) == changed)
        #expect(changed.allows(name: "Nexus-TH 123", deviceID: "x"))
        #expect(changed.allows(name: "Lampe", deviceID: "0x1A2B"))
        #expect(!changed.allows(name: "TPMS", deviceID: "abcd"))
    }

    // MARK: - Quellen

    @Test("Funksensor: Werte mit Home-Assistant-Klassen")
    func sensorValues() {
        var sensor = sensorDevice(battery: false)
        sensor.latest.extra = ["CO₂": "850 ppm", "PM2,5": "12 µg/m³", "Taste": "gedrückt"]
        let values = Dictionary(uniqueKeysWithValues: MQTTFeeds.values(of: sensor).map { ($0.key, $0) })
        #expect(values["temperature"]?.reading == .number(21.5))
        #expect(values["humidity"]?.deviceClass == "humidity")
        #expect(values["battery_low"]?.reading == .flag(true))
        #expect(values["co2"]?.reading == .number(850))
        #expect(values["pm25"]?.unit == "μg/m³")
        #expect(values["rssi"]?.reading == .number(-12.3))
        #expect(values["rssi"]?.diagnostic == true)
        #expect(values.count == 6)
        var tpms = sensorDevice()
        tpms.latest = SensorReading(model: "TPMS", id: "abcd1234", integrity: "CRC")
        #expect(MQTTFeeds.isTPMS(tpms))
    }

    @Test("Zigbee: ZCL-Messwerte, Schaltzustand und Pegel")
    func zigbeeValues() {
        var node = ZigbeeNode(key: .init(pan: 0x1A62, address: 0x1234), ieee: 0x00124B0012345678, channel: 15,
                              heard: 7, rssiDB: -60, lastSeen: Date())
        node.apply(readings: ["21.50 °C"], cluster: 0x0402)
        node.apply(readings: ["Batterie 2.9 V"], cluster: 0x0001)
        node.apply(readings: ["Ein"], cluster: 0x0006)
        node.lqiNeighbors = [0x0000: 180, 0x0001: 220]
        let values = Dictionary(uniqueKeysWithValues: MQTTFeeds.values(of: node).map { ($0.key, $0) })
        #expect(values["temperature"]?.reading == .number(21.5))
        #expect(values["battery_voltage"]?.unit == "V")
        #expect(values["on"]?.reading == .flag(true))
        #expect(values["neighbor_lqi"]?.reading == .number(220))
        #expect(values["rssi"]?.reading == .number(-60))
        #expect(MQTTFeeds.deviceID(of: node) == "00124b0012345678")
    }

    @Test("ADS-B: Anzahl der Flugzeuge der letzten Minute")
    func adsbValues() {
        let now = Date()
        var a = Aircraft(icao: 1, lastSeen: now)
        a.latitude = 52
        let b = Aircraft(icao: 2, lastSeen: now.addingTimeInterval(-30))
        let c = Aircraft(icao: 3, lastSeen: now.addingTimeInterval(-120))
        let values = MQTTFeeds.adsbValues([a, b, c], messagesPerSecond: 12.34, now: now)
        #expect(values.map(\.reading) == [.number(2), .number(1), .number(12.3)])
    }

    // MARK: - Gegen einen lokalen Test-Broker

    @Test("Client: CONNECT, Abo, PUBLISH und Keep-Alive beim Test-Broker")
    func clientAgainstBroker() async throws {
        let broker = try await TestBroker.start()
        defer { broker.stop() }
        let client = MQTTClient(configuration: .init(
            host: "127.0.0.1", port: broker.port, username: "ha", password: "geheim", clientID: "test-client",
            keepAlive: 1, will: .init(topic: "pp/status", payload: Array("offline".utf8), retain: true),
            subscriptions: ["homeassistant/status"]))
        client.start()
        defer { client.stop() }
        try await waitUntil { client.currentState == .connected }
        let connect = try #require(broker.connects.first)
        #expect(connect.clientID == "test-client")
        #expect(connect.username == "ha" && connect.password == "geheim")
        #expect(connect.willTopic == "pp/status" && connect.willPayload == "offline" && connect.willRetain)
        #expect(connect.keepAlive == 1)
        try await waitUntil { broker.subscriptions == ["homeassistant/status"] }
        client.publish(topic: "pp/x", payload: Array("{\"a\":1}".utf8), retain: true)
        try await waitUntil { broker.publishes.contains { $0.topic == "pp/x" } }
        let message = try #require(broker.publishes.first { $0.topic == "pp/x" })
        #expect(message.payload == "{\"a\":1}" && message.retain)
        // Keep-Alive 1 s → PINGREQ spätestens nach etwa 0,5 s.
        try await waitUntil(timeout: 3) { broker.pings > 0 }
    }

    @Test("Client: falsches Passwort meldet „Verbindung testen“ im Klartext")
    func probeRejected() async throws {
        let broker = try await TestBroker.start(returnCode: 4)
        defer { broker.stop() }
        let result = await MQTTClient.probe(.init(host: "127.0.0.1", port: broker.port, username: "ha",
                                                  password: "falsch", clientID: "probe"))
        #expect(result == "Broker lehnt ab: Benutzer oder Passwort falsch")
        let ok = try await TestBroker.start()
        defer { ok.stop() }
        #expect(await MQTTClient.probe(.init(host: "127.0.0.1", port: ok.port, clientID: "probe")) == nil)
    }

    @Test("Client: verbindet nach Abbruch selbst wieder")
    func reconnect() async throws {
        let broker = try await TestBroker.start()
        defer { broker.stop() }
        let client = MQTTClient(configuration: .init(host: "127.0.0.1", port: broker.port, clientID: "re",
                                                     initialBackoff: 0.2))
        client.start()
        defer { client.stop() }
        try await waitUntil { client.currentState == .connected }
        broker.dropConnections()
        try await waitUntil { broker.connects.count >= 2 }
        try await waitUntil { client.currentState == .connected }
    }

    @Test("Brücke: Verfügbarkeit, Discovery einmal je Gerät, gedrosselte Zustände, erneut nach HA-Neustart")
    @MainActor
    func bridgeEndToEnd() async throws {
        let broker = try await TestBroker.start()
        defer { broker.stop() }
        let defaults = try #require(UserDefaults(suiteName: "mqtt-bridge-test-\(UUID())"))
        let bridge = MQTTBridge(defaults: defaults, passwordStore: .memory())
        // Aus: nichts wird gemeldet, nichts verbunden.
        bridge.report(source: .sensors, deviceID: "a", name: "A", values: [.number("temperature", "T", 1)])
        #expect(bridge.deviceList.isEmpty && bridge.status == .off)

        var settings = MQTTSettings()
        settings.enabled = true
        settings.host = "127.0.0.1"
        settings.port = broker.port
        settings.username = "ha"
        bridge.apply(settings, password: "geheim")
        try await waitUntil { if case .connected = bridge.status { true } else { false } }
        #expect(broker.connects.first?.password == "geheim")
        try await waitUntil { broker.publishes.contains { $0.topic == "portapack/status" && $0.payload == "online" && $0.retain } }

        let sensor = sensorDevice()
        bridge.report(source: .sensors, deviceID: sensor.id, name: MQTTFeeds.name(of: sensor), values: MQTTFeeds.values(of: sensor))
        let stateTopic = "portapack/sensors/Nexus-TH_123_1/state"
        try await waitUntil { broker.publishes.contains { $0.topic == stateTopic } }
        let configCount = broker.publishes.filter { $0.topic.hasSuffix("/config") && $0.topic.contains("sensors_Nexus") }.count
        #expect(configCount == MQTTFeeds.values(of: sensor).count + 1)      // + last_seen

        // Gleiche Werte gleich noch einmal: gedrosselt, keine neue Discovery.
        bridge.report(source: .sensors, deviceID: sensor.id, name: MQTTFeeds.name(of: sensor), values: MQTTFeeds.values(of: sensor))
        // Geänderter Wert: sofort, wieder ohne Discovery.
        let warmer = sensorDevice(temperature: 22)
        bridge.report(source: .sensors, deviceID: warmer.id, name: MQTTFeeds.name(of: warmer), values: MQTTFeeds.values(of: warmer))
        try await waitUntil { broker.publishes.filter { $0.topic == stateTopic }.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(broker.publishes.filter { $0.topic == stateTopic }.count == 2)
        #expect(broker.publishes.filter { $0.topic.hasSuffix("/config") && $0.topic.contains("sensors_Nexus") }.count == configCount)
        // Y17: ohne Änderung von Name/Modell/Wertschlüsseln keine neu gebauten Konfigurationen.
        #expect(bridge.configBuilds == 1)
        // Abgeschaltete Quelle: TPMS ist ab Werk aus.
        bridge.report(source: .tpms, deviceID: "abcd", name: "TPMS", values: [.number("rssi", "Pegel", -20)])
        #expect(!bridge.deviceList.contains { $0.name == "TPMS" })

        // Home Assistant startet neu → alles erneut bekanntgeben.
        broker.publishToClients(topic: "homeassistant/status", payload: "online")
        try await waitUntil {
            broker.publishes.filter { $0.topic.hasSuffix("/config") && $0.topic.contains("sensors_Nexus") }.count == 2 * configCount
        }
        try await waitUntil { broker.publishes.filter { $0.topic == stateTopic }.count == 3 }

        bridge.shutdown()
        try await waitUntil { broker.publishes.contains { $0.topic == "portapack/status" && $0.payload == "offline" } }
    }

    @Test("Brücke: verdrängte Geräte verschwinden aus HA, neue Geräte nur begrenzt je Stunde")
    @MainActor
    func bridgeRemovesAndLimits() async throws {
        let broker = try await TestBroker.start()
        defer { broker.stop() }
        let defaults = try #require(UserDefaults(suiteName: "mqtt-bridge-test-\(UUID())"))
        let bridge = MQTTBridge(defaults: defaults, passwordStore: .memory())
        bridge.deviceLimit = 2
        bridge.newDeviceBudget = MQTTDeviceBudget(burst: 3, perHour: 0)
        var settings = MQTTSettings()
        settings.enabled = true
        settings.host = "127.0.0.1"
        settings.port = broker.port
        bridge.apply(settings)
        try await waitUntil { if case .connected = bridge.status { true } else { false } }

        let start = Date()
        for (i, id) in ["a", "b", "c"].enumerated() {
            bridge.report(source: .sensors, deviceID: id, name: id.uppercased(), values: [.number("temperature", "T", 20)],
                          seen: start.addingTimeInterval(Double(i)))
        }
        // „a“ wurde verdrängt: leere, gehaltene Konfigurationen für alle seine Themen.
        let topicA = "homeassistant/sensor/sensors_a/temperature/config"
        try await waitUntil { broker.publishes.contains { $0.topic == topicA && $0.payload.isEmpty && $0.retain } }
        #expect(broker.publishes.contains { $0.topic == "homeassistant/sensor/sensors_a/last_seen/config" && $0.payload.isEmpty })
        #expect(!broker.publishes.contains { $0.topic.contains("sensors_b") && $0.payload.isEmpty })
        #expect(Set(bridge.deviceList.map(\.name)) == ["B", "C"])

        // Eimer leer: „d“ wird zurückgehalten, ein bekanntes Gerät meldet weiter.
        bridge.report(source: .sensors, deviceID: "d", name: "D", values: [.number("temperature", "T", 20)], seen: start.addingTimeInterval(5))
        #expect(bridge.heldBackDevices == 1)
        #expect(!bridge.deviceList.contains { $0.name == "D" })
        bridge.report(source: .sensors, deviceID: "c", name: "C", values: [.number("temperature", "T", 21)], seen: start.addingTimeInterval(6))
        #expect(bridge.deviceList.contains { $0.name == "C" })

        // Mit Allowlist kommt „d“ trotzdem.
        settings.allowlist = "d"
        bridge.apply(settings)
        bridge.report(source: .sensors, deviceID: "d", name: "D", values: [.number("temperature", "T", 20)], seen: start.addingTimeInterval(7))
        #expect(bridge.deviceList.contains { $0.name == "D" })
        #expect(bridge.heldBackDevices == 0)
        bridge.shutdown()
    }
}

// MARK: - Hilfen

private func waitUntil(timeout: Double = 5, isolation: isolated (any Actor)? = #isolation,
                       _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "Zeitüberschreitung beim Warten")
    throw CancellationError()
}

/// Kleiner MQTT-Broker für die Tests (nur 127.0.0.1): nimmt CONNECT an (oder
/// lehnt mit `returnCode` ab), beantwortet PINGREQ und SUBSCRIBE, merkt sich alles.
private final class TestBroker: @unchecked Sendable {
    struct Connect: Sendable {
        var clientID = "", username: String?, password: String?
        var willTopic: String?, willPayload: String?, willRetain = false
        var keepAlive = 0
    }
    struct Publish: Sendable { var topic: String; var payload: String; var retain: Bool }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "mqtt-test-broker")
    private let lock = NSLock()
    private let returnCode: UInt8
    private var connections: [NWConnection] = []
    private var _connects: [Connect] = []
    private var _publishes: [Publish] = []
    private var _subscriptions: [String] = []
    private var _pings = 0

    var connects: [Connect] { lock.withLock { _connects } }
    var publishes: [Publish] { lock.withLock { _publishes } }
    var subscriptions: [String] { lock.withLock { _subscriptions } }
    var pings: Int { lock.withLock { _pings } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private init(returnCode: UInt8) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.returnCode = returnCode
    }

    static func start(returnCode: UInt8 = 0) async throws -> TestBroker {
        let broker = try TestBroker(returnCode: returnCode)
        broker.listener.newConnectionHandler = { [weak broker] connection in broker?.accept(connection) }
        broker.listener.start(queue: broker.queue)
        try await waitUntil { broker.port != 0 }
        return broker
    }

    func stop() {
        listener.cancel()
        dropConnections()
    }

    func dropConnections() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections = []
        }
    }

    func publishToClients(topic: String, payload: String) {
        let packet = Data(MQTTPacket.publish(topic: topic, payload: Array(payload.utf8), retain: false))
        queue.async { self.connections.forEach { $0.send(content: packet, completion: .idempotent) } }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        read(connection, reader: MQTTPacketReader())
    }

    private func read(_ connection: NWConnection, reader: MQTTPacketReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var reader = reader
            if let data { reader.append(data) }
            while let frame = try? reader.next() { self.handle(frame, connection) }
            if !complete && error == nil { self.read(connection, reader: reader) }
        }
    }

    private func handle(_ frame: MQTTPacket.Frame, _ connection: NWConnection) {
        switch frame.kind {
        case .connect:
            let connect = Self.parseConnect(frame.body)
            lock.withLock { _connects.append(connect) }
            connection.send(content: Data(MQTTPacket.connack(returnCode: returnCode)), completion: .idempotent)
        case .publish:
            if let p = MQTTPacket.parsePublish(flags: frame.flags, body: frame.body) {
                lock.withLock { _publishes.append(Publish(topic: p.topic, payload: String(decoding: p.payload, as: UTF8.self), retain: p.retain)) }
            }
        case .subscribe:
            var index = 2
            var topics: [String] = []
            while index + 2 <= frame.body.count {
                let length = Int(frame.body[index]) << 8 | Int(frame.body[index + 1])
                topics.append(String(decoding: frame.body[(index + 2)..<(index + 2 + length)], as: UTF8.self))
                index += 3 + length
            }
            lock.withLock { _subscriptions += topics }
            connection.send(content: Data([0x90, 0x03, frame.body[0], frame.body[1], 0x00]), completion: .idempotent)
        case .pingreq:
            lock.withLock { _pings += 1 }
            connection.send(content: Data(MQTTPacket.pingresp), completion: .idempotent)
        default:
            break
        }
    }

    /// Eigene, von `MQTTPacket` unabhängige Deutung des CONNECT-Rumpfs.
    static func parseConnect(_ body: [UInt8]) -> Connect {
        var index = 0
        func string() -> String {
            let length = Int(body[index]) << 8 | Int(body[index + 1])
            defer { index += 2 + length }
            return String(decoding: body[(index + 2)..<(index + 2 + length)], as: UTF8.self)
        }
        _ = string()                                // „MQTT“
        index += 1                                  // Protokollstufe
        let flags = body[index]
        index += 1
        var connect = Connect()
        connect.keepAlive = Int(body[index]) << 8 | Int(body[index + 1])
        index += 2
        connect.clientID = string()
        if flags & 0x04 != 0 {
            connect.willTopic = string()
            connect.willPayload = string()
            connect.willRetain = flags & 0x20 != 0
        }
        if flags & 0x80 != 0 { connect.username = string() }
        if flags & 0x40 != 0 { connect.password = string() }
        return connect
    }
}

@Suite("MQTT – Smart Home 868")
struct MQTTSmartHomeFeedTests {
    @Test("Zählerstände laufen als total_increasing, Temperaturen als Messwert")
    func classes() {
        #expect(MQTTFeeds.classes(unit: "kWh", name: "Energie") == ("energy", "total_increasing"))
        #expect(MQTTFeeds.classes(unit: "m³", name: "Wasser").deviceClass == "water")
        #expect(MQTTFeeds.classes(unit: "m³", name: "Gas").deviceClass == "gas")
        #expect(MQTTFeeds.classes(unit: "°C", name: "Temperatur") == ("temperature", "measurement"))
        #expect(MQTTFeeds.classes(unit: "%", name: "Batterie").deviceClass == "battery")
    }

    @Test("Werte eines Geräts samt Pegel, Schlüssel ASCII")
    func values() {
        let device = SmartHomeDevice(id: "wmbus-12345678", radio: .wmbus, address: "12345678", deviceType: "Wasser",
                                     lastSummary: "", values: [SmartHomeValue(name: "Zählerstand", unit: "m³", value: 28504.27)],
                                     encrypted: false, rssiDB: -71.4, snrDB: 20, firstSeen: .now, lastSeen: .now, count: 1)
        let values = MQTTFeeds.values(of: device)
        #expect(values.count == 2)
        #expect(values[0].key.allSatisfy { $0.isASCII })
        #expect(values[0].stateClass == "total_increasing")
        #expect(values[1].key == "rssi")
    }
}
