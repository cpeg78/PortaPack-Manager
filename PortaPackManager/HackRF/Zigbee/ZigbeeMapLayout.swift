import CoreGraphics
import Foundation
import simd

/// Anordnung der Zigbee-Netzkarte: Kräftemodell (Fruchterman-Reingold) statt
/// fester Ringe. Vorher lagen alle Geräte auf einem Kreis – `router` ist oft
/// unbekannt –, die Beschriftungen überlappten und die Kanten bildeten ein
/// Knäuel (27.10.2026). Jetzt ziehen gute Verbindungen Geräte zusammen, der
/// Koordinator steht fest in der Mitte. Rein rechnerisch, damit testbar.
enum ZigbeeMapLayout {
    struct Edge: Hashable, Sendable {
        let a: UInt16
        let b: UInt16
        /// Verbindungsgüte 0…1 (LQI/255 bzw. Linkkosten).
        let quality: Double
    }

    /// Ungerichtete Kanten: A→B und B→A zusammengefasst, die bessere Güte zählt.
    /// Nur Kanten zwischen bekannten Geräten.
    static func edges(_ nodes: [ZigbeeNode]) -> [Edge] {
        let known = Set(nodes.map(\.key.address))
        var best: [Pair: Double] = [:]
        for node in nodes {
            let links: [UInt16: Double] = node.lqiNeighbors.isEmpty
                ? node.neighbors.mapValues { Double(max(0, 7 - $0.outgoing)) / 7 }
                : node.lqiNeighbors.mapValues { Double($0) / 255 }
            for (other, quality) in links where other != node.key.address && known.contains(other) {
                let pair = Pair(node.key.address, other)
                best[pair] = max(best[pair] ?? 0, quality)
            }
        }
        return best.map { Edge(a: $0.key.low, b: $0.key.high, quality: $0.value) }
            .sorted { ($0.a, $0.b) < ($1.a, $1.b) }
    }

    /// Je Gerät nur die `perNode` besten Verbindungen (eine Kante bleibt, wenn
    /// sie für eines ihrer Enden dazugehört) – zeigt das Gerüst des Netzes.
    static func strongest(_ edges: [Edge], perNode: Int) -> [Edge] {
        var byNode: [UInt16: [Edge]] = [:]
        for edge in edges {
            byNode[edge.a, default: []].append(edge)
            byNode[edge.b, default: []].append(edge)
        }
        var keep = Set<Edge>()
        for list in byNode.values {
            keep.formUnion(list.sorted { $0.quality > $1.quality }.prefix(perNode))
        }
        return edges.filter { keep.contains($0) }
    }

    /// Radius des Außenrings für Geräte ohne bekannte Verbindung.
    static let outerRing = 1.12

    /// Positionen im Bereich −1…1 (Außenring bei `outerRing`). Deterministisch
    /// (Startpunkte auf einer Spirale nach Adresse), damit die Karte bei jedem
    /// Aufbau gleich aussieht. Mit `previous` (der letzten Anordnung) wird nur
    /// nachgeführt: bekannte Geräte bleiben, wo sie waren, neue rücken neben
    /// ihre Nachbarn – sonst sprang die Karte bei jeder neuen Nachbartabelle
    /// (27.10.2026).
    static func layout(_ addresses: [UInt16], edges: [Edge], pinned: UInt16?,
                       previous: [UInt16: CGPoint] = [:], iterations: Int? = nil) -> [UInt16: CGPoint] {
        let prev3 = previous.mapValues { SIMD3(Double($0.x), Double($0.y), 0) }
        return layout3D(addresses, edges: edges, pinned: pinned, previous: prev3, iterations: iterations, dimensions: 2)
            .mapValues { CGPoint(x: $0.x, y: $0.y) }
    }

    /// Wie `layout`, aber im Raum (für die 3D-Ansicht): Koordinaten −1…1,
    /// Außenring in der xz-Ebene.
    static func layout3D(_ addresses: [UInt16], edges: [Edge], pinned: UInt16?,
                         previous: [UInt16: SIMD3<Double>] = [:], iterations: Int? = nil,
                         dimensions: Int = 3) -> [UInt16: SIMD3<Double>] {
        // Geräte ohne bekannte Verbindung (meist Endgeräte, deren Elternrouter
        // keine Tabelle geschickt hat) auf einen Außenring – im Kräftemodell
        // trieben sie weit nach außen und stauchten das eigentliche Netz.
        let linked = Set(edges.flatMap { [$0.a, $0.b] })
        let isolated = addresses.filter { !linked.contains($0) && $0 != pinned }.sorted()
        let networked = addresses.filter { linked.contains($0) || $0 == pinned }
        let warm = !previous.isEmpty
        var result = solve(networked, edges: edges, pinned: pinned, previous: previous,
                           iterations: iterations ?? (warm ? 30 : 400), dimensions: dimensions)
        // Außenring: bekannte bleiben auf ihrem Winkel, neue kommen in die
        // größte Lücke – ein gleichmäßiges Neuverteilen drehte alle mit.
        let ringAxis = dimensions == 2 ? 1 : 2       // 2D: y, 3D: z
        func ringPoint(_ angle: Double) -> SIMD3<Double> {
            var p = SIMD3<Double>(outerRing * cos(angle), 0, 0)
            p[ringAxis] = outerRing * sin(angle)
            return p
        }
        var angles: [Double] = isolated.compactMap { address in
            guard warm, let p = previous[address], hypot(p.x, p[ringAxis]) > 1.05 else { return nil }
            result[address] = p
            return atan2(p[ringAxis], p.x)
        }
        let fresh = isolated.filter { result[$0] == nil }
        for (i, address) in fresh.enumerated() {
            let angle = angles.isEmpty
                ? 2 * Double.pi * (Double(i) + 0.5) / Double(fresh.count) - Double.pi / 2
                : largestGap(angles)
            angles.append(angle)
            result[address] = ringPoint(angle)
        }
        return result
    }

    /// Mitte der größten Lücke zwischen den Winkeln.
    private static func largestGap(_ angles: [Double]) -> Double {
        let sorted = angles.map { $0 < 0 ? $0 + 2 * Double.pi : $0 }.sorted()
        var best = (gap: -1.0, mid: 0.0)
        for (i, a) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1] : sorted[0] + 2 * Double.pi
            if next - a > best.gap { best = (next - a, (a + next) / 2) }
        }
        return best.mid
    }

    /// Kräftemodell (Fruchterman-Reingold) in zwei oder drei Dimensionen.
    private static func solve(_ addresses: [UInt16], edges: [Edge], pinned: UInt16?,
                              previous: [UInt16: SIMD3<Double>], iterations: Int, dimensions: Int) -> [UInt16: SIMD3<Double>] {
        let ids = addresses.sorted()
        guard !ids.isEmpty else { return [:] }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let n = ids.count
        let warm = !previous.isEmpty
        let flat: SIMD3<Double> = dimensions == 2 ? SIMD3(1, 1, 0) : SIMD3(1, 1, 1)
        var pos = (0..<n).map { i -> SIMD3<Double> in
            if dimensions == 2 {
                let r = 0.9 * sqrt((Double(i) + 0.5) / Double(n))
                let a = Double(i) * 2.399963          // goldener Winkel
                return SIMD3(r * cos(a), r * sin(a), 0)
            }
            // Fibonacci-Kugel, innen dichter.
            let r = 0.9 * cbrt((Double(i) + 0.5) / Double(n))
            let y = 1 - 2 * (Double(i) + 0.5) / Double(n)
            let ring = sqrt(max(0, 1 - y * y))
            let a = Double(i) * 2.399963
            return SIMD3(r * ring * cos(a), r * y, r * ring * sin(a))
        }
        if warm {
            // Bekannte Geräte starten an ihrem alten Platz, neue neben dem Mittel
            // ihrer schon platzierten Nachbarn (leicht versetzt, damit sie sich lösen).
            for (i, id) in ids.enumerated() {
                if let p = previous[id], length(p) <= 1.05 { pos[i] = p * flat; continue }
                let near = edges.compactMap { e -> SIMD3<Double>? in
                    let other = e.a == id ? e.b : e.b == id ? e.a : nil
                    return other.flatMap { previous[$0] }
                }
                if !near.isEmpty {
                    let mean = near.reduce(SIMD3<Double>(repeating: 0), +) / Double(near.count)
                    pos[i] = (mean + 0.05 * SIMD3(cos(Double(id)), sin(Double(id)), cos(Double(id) * 0.7))) * flat
                }
            }
        }
        if let pinned, let p = index[pinned] { pos[p] = .zero }
        // Wunschabstand; beim Nachführen der mittlere bisherige Kantenabstand,
        // damit die alte (normierte) Anordnung schon im Gleichgewicht ist.
        var k = (dimensions == 2 ? 2.4 : 2.0) / pow(Double(n), 1 / Double(dimensions))
        if warm {
            let lengths = edges.compactMap { e -> Double? in
                guard let a = previous[e.a], let b = previous[e.b] else { return nil }
                return length(a - b)
            }
            if !lengths.isEmpty { k = max(0.05, lengths.reduce(0, +) / Double(lengths.count)) }
        }
        let links = edges.compactMap { e -> (Int, Int, Double)? in
            guard let i = index[e.a], let j = index[e.b] else { return nil }
            return (i, j, e.quality)
        }
        // Nachführen: höchstens ≈ 0,2 Einheiten Weg je Durchlauf – die Karte darf
        // sich setzen, aber nicht springen.
        var temperature = warm ? 0.006 : 0.12
        for _ in 0..<iterations {
            var shift = [SIMD3<Double>](repeating: .zero, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var d = pos[i] - pos[j]
                    var d2 = length_squared(d)
                    if d2 < 1e-6 { d = SIMD3(0.01 * Double(i - j), 0.01, dimensions == 2 ? 0 : 0.007); d2 = length_squared(d) }
                    let force = k * k / d2          // Abstoßung
                    shift[i] += d * force
                    shift[j] -= d * force
                }
            }
            for (i, j, quality) in links {
                let d = pos[i] - pos[j]
                let dist = max(1e-3, length(d))
                // Gute Verbindungen ziehen stärker – sie liegen dann näher beieinander.
                let force = dist / k * (0.2 + 0.8 * quality)
                shift[i] -= d * force
                shift[j] += d * force
            }
            for i in 0..<n {
                // Schwerkraft zur Mitte hält Geräte ohne Kanten im Bild.
                shift[i] -= pos[i] * 0.05
                shift[i] *= flat
                let len = max(1e-9, length(shift[i]))
                pos[i] += shift[i] / len * min(len, temperature)
            }
            if let pinned, let p = index[pinned] { pos[p] = .zero }
            temperature = max(0.004, temperature * 0.985)
        }
        // Auf −1…1 normieren (Koordinator bleibt in der Mitte). Maßstab nach dem
        // 85-%-Abstand statt dem weitesten Gerät: einzelne Ausreißer stauchten
        // sonst den dichten Kern; sie werden an den Rand geklemmt. Auch beim
        // Nachführen – ohne Normierung wanderten die Geräte über viele Durchläufe
        // nach außen und sammelten sich am Rand (27.10.2026); da die alte
        // Anordnung schon normiert war, liegt der Faktor dann nahe 1.
        let distances = pos.map { length($0) }.sorted()
        let extent = max(1e-6, distances[min(distances.count - 1, Int(Double(distances.count) * 0.85))])
        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            var p = pos[index] / extent
            let r = length(p)
            if r > 1 { p /= r }
            return (id, p)
        })
    }

    /// Beschriftungen ohne Überlappung: der Reihe nach (wichtige zuerst) gesetzt,
    /// was einer schon gesetzten in die Quere käme, entfällt.
    static func placeLabels(_ candidates: [(id: UInt16, rect: CGRect)]) -> Set<UInt16> {
        var placed: [CGRect] = []
        var shown = Set<UInt16>()
        for candidate in candidates where !placed.contains(where: { $0.insetBy(dx: -2, dy: -1).intersects(candidate.rect) }) {
            placed.append(candidate.rect)
            shown.insert(candidate.id)
        }
        return shown
    }

    // MARK: Gemeinsam für App und Fernzugriff

    /// Ein Netz (PAN) in der Auswahl der Karte.
    struct Network: Equatable, Sendable {
        let pan: UInt16
        let latest: Date
        let count: Int
        let onChannel: Bool
    }

    /// Netze: auf dem aktuellen Kanal zuerst, dann das mit den meisten Geräten
    /// (nicht das zuletzt gehörte – ein fremdes Beacon ließ die Karte sonst
    /// kurz auf ein Nachbarnetz umspringen), dann das zuletzt gehörte.
    static func networks(_ nodes: [ZigbeeNode], channel: Int) -> [Network] {
        Dictionary(grouping: nodes, by: \.key.pan).map { pan, list in
            Network(pan: pan, latest: list.map(\.lastSeen).max() ?? .distantPast, count: list.count,
                    onChannel: list.contains { $0.channel == channel })
        }
        .sorted { ($0.onChannel ? 1 : 0, $0.count, $0.latest) > ($1.onChannel ? 1 : 0, $1.count, $1.latest) }
    }

    /// Gezeigtes Netz: das gewählte, solange es Geräte hat, sonst das erste der Liste.
    static func chosenPAN(_ chosen: UInt16?, nodes: [ZigbeeNode], networks: [Network]) -> UInt16? {
        if let chosen, nodes.contains(where: { $0.key.pan == chosen }) { return chosen }
        return networks.first?.pan
    }

    /// Router: ausdrücklich gemeldet oder sendet selbst Verbindungsstatus/LQI-Tabellen
    /// (das tun nur Router) – `router` allein ist oft unbekannt.
    static func isRouter(_ node: ZigbeeNode) -> Bool {
        node.router == true || !node.neighbors.isEmpty || !node.lqiNeighbors.isEmpty
    }

    /// Kanten, nach denen die Anordnung gerechnet wird: rein kommt, was einmal
    /// zu den drei besten eines Geräts gehörte, raus nur, was ganz verschwindet.
    /// Eine Hysterese (rein ab Rang 3, raus ab Rang 5) reichte nicht – LQI-Ränge
    /// schwanken dauernd, die Karte wurde jede Sekunde neu gerechnet und kroch
    /// (28.10.2026). So steht sie still, sobald das Netz bekannt ist.
    /// Die Paare tragen Güte 0 (nur die Enden zählen).
    static func stickyEdges(_ current: Set<Edge>, all: [Edge]) -> Set<Edge> {
        let pairs = { (list: [Edge]) in Set(list.map { Edge(a: $0.a, b: $0.b, quality: 0) }) }
        return pairs(strongest(all, perNode: 3)).union(current.intersection(pairs(all)))
    }

    /// Die Kanten aus `all`, deren Paar in `sticky` steht.
    static func layoutEdges(_ all: [Edge], sticky: Set<Edge>) -> [Edge] {
        all.filter { sticky.contains(Edge(a: $0.a, b: $0.b, quality: 0)) }
    }

    /// Nur Geräte und Kantenpaare – nicht die Güte: die schwankt mit jedem
    /// Verbindungsstatus, und die Karte wurde ständig neu gerechnet.
    static func signature(_ nodes: [ZigbeeNode], _ edges: [Edge]) -> Int {
        var hasher = Hasher()
        for node in nodes.sorted(by: { $0.key.address < $1.key.address }) { hasher.combine(node.key.address) }
        for edge in edges { hasher.combine(edge.a); hasher.combine(edge.b) }
        return hasher.finalize()
    }

    private struct Pair: Hashable {
        let low: UInt16, high: UInt16
        init(_ a: UInt16, _ b: UInt16) { low = min(a, b); high = max(a, b) }
    }
}
