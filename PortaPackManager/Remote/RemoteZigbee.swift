import CoreGraphics
import Foundation

/// Zigbee-Netzkarte ohne Oberfläche – für den Fernzugriff. Dieselbe Netzwahl,
/// dieselben „klebrigen“ Layout-Kanten und dasselbe Nachführen wie
/// `ZigbeeMapView` (alles aus `ZigbeeMapLayout`), damit die Karte im Browser
/// so aussieht wie in der App und genauso stillsteht. Gerechnet wird nur, wenn
/// sich Geräte oder Kantenpaare ändern.
final class ZigbeeMapTracker {
    private(set) var pan: UInt16?
    private var sticky: Set<ZigbeeMapLayout.Edge> = []
    private var signature = 0
    private(set) var positions: [UInt16: CGPoint] = [:]
    /// Zahl der Neuberechnungen (für Tests: Stillstand bei gleichem Netz).
    private(set) var layoutRuns = 0

    struct Result {
        var pan: UInt16?
        var networks: [ZigbeeMapLayout.Network]
        /// Geräte des gezeigten Netzes.
        var nodes: [ZigbeeNode]
        /// Alle Verbindungen des Netzes.
        var edges: [ZigbeeMapLayout.Edge]
        /// Die zwei besten je Gerät (Grundeinstellung der Karte).
        var strongest: Set<ZigbeeMapLayout.Edge>
        var positions: [UInt16: CGPoint]
    }

    func update(nodes: [ZigbeeNode], channel: Int, chosenPAN: UInt16?) -> Result {
        let networks = ZigbeeMapLayout.networks(nodes, channel: channel)
        let pan = ZigbeeMapLayout.chosenPAN(chosenPAN, nodes: nodes, networks: networks)
        if pan != self.pan {
            // Anderes Netz: nicht nachführen, sondern neu anordnen.
            self.pan = pan
            sticky = []
            positions = [:]
            signature = 0
        }
        let shown = nodes.filter { $0.key.pan == pan }
        let all = ZigbeeMapLayout.edges(shown)
        sticky = ZigbeeMapLayout.stickyEdges(sticky, all: all)
        let layoutEdges = ZigbeeMapLayout.layoutEdges(all, sticky: sticky)
        let next = ZigbeeMapLayout.signature(shown, layoutEdges)
        if !shown.isEmpty, next != signature || positions.isEmpty {
            let addresses = shown.map(\.key.address)
            positions = ZigbeeMapLayout.layout(addresses, edges: layoutEdges, pinned: addresses.contains(0) ? 0 : nil,
                                               previous: positions)
            signature = next
            layoutRuns += 1
        } else if shown.isEmpty {
            positions = [:]
        }
        let strongest = Set(ZigbeeMapLayout.strongest(all, perNode: 2))
        return Result(pan: pan, networks: networks, nodes: shown, edges: all, strongest: strongest, positions: positions)
    }
}

/// Antwort von `/api/zigbee`: Geräteliste und Netzkarte. Enthält bewusst
/// **keine Schlüssel** (Netzwerk-, Link-, Thread-Schlüssel) und keine
/// Rahmeninhalte – nur, was die Geräteliste der App auch zeigt.
enum RemoteZigbee {
    struct State: Encodable, Equatable {
        var running: Bool
        /// Aus der Ferne gestartet (`RemoteHub.Mode.zigbee`).
        var remote: Bool
        var channel: Int
        var frames: Int
        var rate: Double
        var decrypted: Int
        var noiseDB: Int
        var networks: [Network]
        /// Gezeigtes Netz (PAN, hex).
        var pan: String?
        var devices: [Device]
        var edges: [Link]
    }

    struct Network: Encodable, Equatable {
        var pan: String
        var devices: Int
        var onChannel: Bool
    }

    struct Device: Encodable, Equatable {
        /// Kurzadresse, hex (eindeutig im Netz).
        var addr: String
        var name: String?
        /// Gerätetyp wie in der App („Temperatursensor“, „Router“ …).
        var type: String
        /// `coordinator`, `router` oder `end` (Farbe auf der Karte).
        var role: String
        var ieee: String?
        /// Pegel in dB (geglättet, wie in der App).
        var rssi: Int?
        /// Beste Verbindungsgüte, die ein Nachbar für dieses Gerät meldet (0…255).
        var lqi: Int?
        /// Sekunden seit dem letzten Rahmen.
        var age: Int
        var heard: Int
        var power: String?
        /// Letzte Messwerte/Zustände („Temperatur: 21.50 °C · …“).
        var state: String?
        var links: Int
        /// Platz auf der Karte (−1…1, Außenring bei 1,12; y nach unten).
        var x: Double?
        var y: Double?
    }

    struct Link: Encodable, Equatable {
        var a: String
        var b: String
        /// Güte 0…1.
        var q: Double
        /// Gehört zu den zwei besten Verbindungen eines Endes.
        var top: Bool
    }

    static func hex(_ value: UInt16) -> String { String(format: "%04X", value) }

    static func state(nodes: [ZigbeeNode], channel: Int, running: Bool, remote: Bool, frames: Int, rate: Double,
                      decrypted: Int, noiseDB: Double, chosenPAN: UInt16?, tracker: ZigbeeMapTracker,
                      name: (ZigbeeNode) -> String?, now: Date = Date()) -> State {
        let map = tracker.update(nodes: nodes, channel: channel, chosenPAN: chosenPAN)
        var degree: [UInt16: Int] = [:]
        for edge in map.edges { degree[edge.a, default: 0] += 1; degree[edge.b, default: 0] += 1 }
        // LQI, mit dem die Nachbarn ein Gerät hören (aus deren Nachbartabellen).
        var lqi: [UInt16: Int] = [:]
        for node in map.nodes {
            for (neighbor, value) in node.lqiNeighbors { lqi[neighbor] = max(lqi[neighbor] ?? 0, value) }
        }
        let round = { (value: Double) in (value * 1000).rounded() / 1000 }
        let devices = map.nodes.sorted { $0.key.address < $1.key.address }.map { node -> Device in
            let address = node.key.address
            let role = address == 0 ? "coordinator" : ZigbeeMapLayout.isRouter(node) ? "router" : "end"
            let position = map.positions[address]
            return Device(
                addr: hex(address), name: name(node), type: node.role, role: role,
                ieee: node.ieee.map { String(format: "%016llX", $0) },
                rssi: node.rssiDB.map { Int($0.rounded()) }, lqi: lqi[address],
                age: max(0, Int(now.timeIntervalSince(node.lastSeen))), heard: node.heard,
                power: node.power, state: node.stateLine.isEmpty ? nil : node.stateLine,
                links: degree[address] ?? 0,
                x: position.map { round(Double($0.x)) }, y: position.map { round(Double($0.y)) })
        }
        let edges = map.edges.map {
            Link(a: hex($0.a), b: hex($0.b), q: (($0.quality * 100).rounded()) / 100, top: map.strongest.contains($0))
        }
        return State(
            running: running, remote: remote, channel: channel, frames: frames, rate: (rate * 10).rounded() / 10,
            decrypted: decrypted, noiseDB: Int(noiseDB.rounded()),
            networks: map.networks.map { Network(pan: hex($0.pan), devices: $0.count, onChannel: $0.onChannel) },
            pan: map.pan.map(hex), devices: devices, edges: edges)
    }
}
