import Foundation
import Testing
@testable import PortaPackManager

/// `/api/zigbee` des Fernzugriffs: Form der JSON-Antwort, Netzkarte wie in
/// der App, keine Schlüssel.
@Suite("Fernzugriff: Zigbee")
struct RemoteZigbeeTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func node(_ address: UInt16, pan: UInt16 = 0x1A62, channel: Int = 15, age: TimeInterval = 5,
                             _ change: (inout ZigbeeNode) -> Void = { _ in }) -> ZigbeeNode {
        var node = ZigbeeNode(key: .init(pan: pan, address: address), channel: channel, lastSeen: now.addingTimeInterval(-age))
        change(&node)
        return node
    }

    /// Koordinator, zwei Router, ein Endgerät, ein Gerät ohne Verbindung, dazu ein fremdes Netz.
    private static var network: [ZigbeeNode] {
        [node(0x0000) { $0.lqiNeighbors = [0x1111: 200, 0x2222: 120]; $0.rssiDB = -41.4; $0.heard = 30 },
         node(0x1111) { $0.lqiNeighbors = [0x0000: 210, 0x3333: 90]; $0.ieee = 0x00124B00_1A2B3C4D; $0.mainsPowered = true },
         node(0x2222) { $0.router = true; $0.rssiDB = -70.6 },
         node(0x3333, age: 125) { $0.deviceType = "Temperatursensor"; $0.state = ["Temperatur": "21.50 °C"] },
         node(0x4444),
         node(0x0000, pan: 0x5FF5, channel: 25)]
    }

    private func state(_ nodes: [ZigbeeNode] = network, tracker: ZigbeeMapTracker = ZigbeeMapTracker(),
                       pan: UInt16? = nil) -> RemoteZigbee.State {
        RemoteZigbee.state(nodes: nodes, channel: 15, running: true, remote: true, frames: 1234, rate: 12.345,
                           decrypted: 99, noiseDB: -63.4, chosenPAN: pan, tracker: tracker,
                           name: { $0.key.address == 0x3333 ? "Küche <b>" : nil }, now: Self.now)
    }

    @Test("JSON: genau die vorgesehenen Felder, keine Schlüssel")
    func jsonShape() throws {
        let data = try JSONEncoder().encode(state())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["running", "remote", "channel", "frames", "rate", "decrypted", "noiseDB",
                                     "networks", "pan", "devices", "edges"])
        let devices = try #require(object["devices"] as? [[String: Any]])
        let allowed: Set<String> = ["addr", "name", "type", "role", "ieee", "rssi", "lqi", "age", "heard", "power",
                                    "state", "links", "x", "y"]
        for device in devices { #expect(Set(device.keys).isSubset(of: allowed)) }
        let edge = try #require((object["edges"] as? [[String: Any]])?.first)
        #expect(Set(edge.keys) == ["a", "b", "q", "top"])
        // Nichts, was nach Schlüsselmaterial aussieht.
        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains("key") && !text.contains("schlüssel"))
        #expect(object["rate"] as? Double == 12.3)
        #expect(object["noiseDB"] as? Int == -63)
    }

    @Test("Geräteliste: Rolle, Typ, LQI aus den Nachbartabellen, Alter, Pegel")
    func devices() throws {
        let s = state()
        #expect(s.pan == "1A62")
        #expect(s.devices.map(\.addr) == ["0000", "1111", "2222", "3333", "4444"])
        let byAddress = Dictionary(uniqueKeysWithValues: s.devices.map { ($0.addr, $0) })
        #expect(byAddress["0000"]?.role == "coordinator")
        #expect(byAddress["1111"]?.role == "router" && byAddress["2222"]?.role == "router")
        #expect(byAddress["3333"]?.role == "end" && byAddress["3333"]?.type == "Temperatursensor")
        #expect(byAddress["3333"]?.name == "Küche <b>")        // Escapen übernimmt die Webseite
        #expect(byAddress["3333"]?.age == 125)
        #expect(byAddress["3333"]?.state == "21.50 °C")
        #expect(byAddress["1111"]?.lqi == 200)                  // so hört der Koordinator den Router
        #expect(byAddress["0000"]?.lqi == 210)
        #expect(byAddress["3333"]?.lqi == 90)
        #expect(byAddress["4444"]?.lqi == nil)
        #expect(byAddress["0000"]?.rssi == -41 && byAddress["2222"]?.rssi == -71)
        #expect(byAddress["1111"]?.ieee == "00124B001A2B3C4D")
        #expect(byAddress["1111"]?.power == "Netzstrom")
        #expect(s.networks.map(\.pan) == ["1A62", "5FF5"])
        #expect(s.networks.first?.onChannel == true && s.networks.last?.onChannel == false)
    }

    @Test("Netzkarte: Koordinator in der Mitte, alle Geräte platziert, Kanten mit Güte")
    func map() throws {
        let s = state()
        let byAddress = Dictionary(uniqueKeysWithValues: s.devices.map { ($0.addr, $0) })
        #expect(byAddress["0000"]?.x == 0 && byAddress["0000"]?.y == 0)
        for device in s.devices {
            let x = try #require(device.x), y = try #require(device.y)
            #expect(hypot(x, y) <= ZigbeeMapLayout.outerRing + 0.001)
        }
        // Ohne Verbindung: auf dem Außenring.
        let lone = try #require(byAddress["4444"])
        #expect(abs(hypot(lone.x!, lone.y!) - ZigbeeMapLayout.outerRing) < 0.01)
        let edge = try #require(s.edges.first { $0.a == "0000" && $0.b == "1111" })
        #expect(edge.q == 0.82)                                 // max(200, 210) / 255
        #expect(edge.top)
        #expect(byAddress["0000"]?.links == 2)
    }

    @Test("Netzkarte steht still und folgt der Netzwahl")
    func tracker() {
        let tracker = ZigbeeMapTracker()
        let first = state(tracker: tracker)
        let runs = tracker.layoutRuns
        // Gleiches Netz, nur andere Güte: keine Neuberechnung, gleiche Plätze.
        var changed = Self.network
        changed[0].lqiNeighbors[0x1111] = 150
        changed[1].lqiNeighbors[0x0000] = 140
        let second = state(changed, tracker: tracker)
        #expect(tracker.layoutRuns == runs)
        #expect(first.devices.map(\.x) == second.devices.map(\.x))
        // Anderes Netz gewählt: nur dessen Geräte.
        let other = state(tracker: tracker, pan: 0x5FF5)
        #expect(other.pan == "5FF5" && other.devices.map(\.addr) == ["0000"])
        // Unbekanntes Netz: zurück zum ersten der Liste.
        #expect(state(tracker: tracker, pan: 0xBEEF).pan == "1A62")
    }

    @Test("Leeres Netz: gültige Antwort ohne Geräte")
    func empty() throws {
        let s = state([])
        #expect(s.devices.isEmpty && s.edges.isEmpty && s.pan == nil && s.networks.isEmpty)
        _ = try JSONEncoder().encode(s)
    }

    @Test("Fernzugriff kennt Zigbee als Empfänger")
    func mode() {
        #expect(RemoteHub.Mode(rawValue: "zigbee") == .zigbee)
        #expect(RemoteHub.Mode.zigbee.title == "Zigbee")
        #expect(RemotePage.html.contains("data-tab=\"zigbee\"") && RemotePage.html.contains("/api/zigbee"))
    }
}
