import CoreGraphics
import simd
import Testing
@testable import PortaPackManager

@Suite("Zigbee-Netzkarte")
struct ZigbeeMapLayoutTests {
    @Test("Koordinator in der Mitte, alles im Bild, gute Verbindungen liegen näher")
    func layout() {
        let edges = [
            ZigbeeMapLayout.Edge(a: 0, b: 1, quality: 1.0),
            ZigbeeMapLayout.Edge(a: 0, b: 2, quality: 0.1),
            ZigbeeMapLayout.Edge(a: 1, b: 3, quality: 0.9),
        ]
        let positions = ZigbeeMapLayout.layout([0, 1, 2, 3, 4], edges: edges, pinned: 0)
        #expect(positions.count == 5)
        #expect(positions[0] == .zero)
        #expect(positions.values.allSatisfy { abs($0.x) <= 1.13 && abs($0.y) <= 1.13 })
        let near = hypot(positions[1]!.x, positions[1]!.y)
        let far = hypot(positions[2]!.x, positions[2]!.y)
        #expect(near < far)
        // Deterministisch: zweimal gerechnet, gleiches Bild.
        #expect(ZigbeeMapLayout.layout([0, 1, 2, 3, 4], edges: edges, pinned: 0) == positions)
    }

    @Test("Beste Verbindungen je Gerät, Beschriftungen ohne Überlappung")
    func filtering() {
        let edges = (1...5).map { ZigbeeMapLayout.Edge(a: 0, b: UInt16($0), quality: Double($0) / 5) }
            + [ZigbeeMapLayout.Edge(a: 1, b: 2, quality: 0.05)]
        let kept = ZigbeeMapLayout.strongest(edges, perNode: 2)
        // Jedes Blatt behält seine Verbindung zum Koordinator, die schwache Querkante fällt nicht weg,
        // weil sie für Gerät 2 zu dessen zwei besten gehört.
        #expect(kept.contains(ZigbeeMapLayout.Edge(a: 0, b: 1, quality: 0.2)))
        #expect(kept.count == edges.count)
        // Eine schwache Kante zwischen zwei Geräten, die beide bessere haben, fällt weg.
        let extra = [ZigbeeMapLayout.Edge(a: 3, b: 6, quality: 0.9), ZigbeeMapLayout.Edge(a: 4, b: 6, quality: 0.9),
                     ZigbeeMapLayout.Edge(a: 3, b: 4, quality: 0.05)]
        let crowded = ZigbeeMapLayout.strongest(edges + extra, perNode: 2)
        #expect(!crowded.contains(ZigbeeMapLayout.Edge(a: 3, b: 4, quality: 0.05)))
        let labels = ZigbeeMapLayout.placeLabels([
            (1, CGRect(x: 0, y: 0, width: 50, height: 15)),
            (2, CGRect(x: 10, y: 5, width: 50, height: 15)),
            (3, CGRect(x: 100, y: 0, width: 50, height: 15)),
        ])
        #expect(labels == [1, 3])
    }

    @Test("Nachführen: bekannte Geräte bleiben praktisch stehen, neue landen neben ihren Nachbarn")
    func warmStart() {
        let edges = [ZigbeeMapLayout.Edge(a: 0, b: 1, quality: 0.9), ZigbeeMapLayout.Edge(a: 0, b: 2, quality: 0.9),
                     ZigbeeMapLayout.Edge(a: 1, b: 3, quality: 0.8)]
        let first = ZigbeeMapLayout.layout([0, 1, 2, 3, 9], edges: edges, pinned: 0)
        let more = edges + [ZigbeeMapLayout.Edge(a: 2, b: 4, quality: 0.8)]
        let second = ZigbeeMapLayout.layout([0, 1, 2, 3, 4, 9, 10], edges: more, pinned: 0, previous: first)
        for id: UInt16 in [1, 2, 3] {
            #expect(hypot(second[id]!.x - first[id]!.x, second[id]!.y - first[id]!.y) < 0.25)
        }
        #expect(second[9] == first[9])                       // Außenring unverändert
        #expect(hypot(second[10]!.x, second[10]!.y) > 1.05)   // neues Gerät ohne Kante außen
        let d24 = hypot(second[4]!.x - second[2]!.x, second[4]!.y - second[2]!.y)
        let d14 = hypot(second[4]!.x - second[1]!.x, second[4]!.y - second[1]!.y)
        #expect(d24 < d14)
    }

    @Test("3D: Koordinator in der Mitte, alle Achsen genutzt, Außenring in der xz-Ebene")
    func layout3D() {
        let edges = (1...6).map { ZigbeeMapLayout.Edge(a: 0, b: UInt16($0), quality: 0.9) }
            + [ZigbeeMapLayout.Edge(a: 1, b: 2, quality: 0.9), ZigbeeMapLayout.Edge(a: 3, b: 4, quality: 0.9)]
        let p = ZigbeeMapLayout.layout3D(Array(0...8), edges: edges, pinned: 0)
        #expect(p.count == 9)
        #expect(p[0] == .zero)
        #expect(p.values.allSatisfy { simd_length($0) <= 1.13 })
        let spread = (0..<3).map { axis in p.values.map { $0[axis] }.max()! - p.values.map { $0[axis] }.min()! }
        #expect(spread.allSatisfy { $0 > 0.3 })
        #expect(p[7]!.y == 0 && p[8]!.y == 0 && simd_length(p[7]!) > 1.05)
    }
}
