import Foundation
import Testing
@testable import PortaPackManager

@Suite("Belegungsmonitor")
struct OccupancyTests {
    private static let noise: Float = 1e-6   // −60 dB

    /// Deterministischer Zufall (Tests sollen reproduzierbar sein).
    private struct LCG {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
    }

    private let plan = OccupancyPlan(startMHz: 433.05, endMHz: 434.79, binKHz: 10)

    /// Gruppe mit Rauschen (Mittel = `noise`, nie > +1,8 dB) und optional
    /// einem Träger auf allen FFT-Bins eines Rasterbins.
    private func frame(mapping: OccupancyMapping, rng: inout LCG, carrierGrid: Int?, carrierDB: Float) -> [Float] {
        var p = (0..<mapping.fftSize).map { _ in Self.noise * (0.5 + rng.next()) }
        if let carrierGrid, let j = mapping.grid.firstIndex(of: Int32(carrierGrid)) {
            for k in Int(mapping.lo[j])...Int(mapping.hi[j]) { p[k] = Self.noise * pow(10, carrierDB / 10) }
        }
        return p
    }

    @Test("Fensterplan: schmales Band in einem festen Fenster, ohne DC-Lücke")
    func narrowPlan() {
        #expect(plan.isNarrow)
        #expect(plan.binCount == 174)
        #expect(plan.fftSize == 2048)
        #expect(plan.centers(round: 0) == plan.centers(round: 1))
        let mapping = plan.mapping(centerMHz: plan.centers(round: 0)[0], fftSize: plan.fftSize)
        #expect(Set(mapping.grid.map(Int.init)) == Set(0..<plan.binCount))
    }

    @Test("Fensterplan: breites Band – jedes Bin in mindestens einer Runde gemessen")
    func widePlanCoversEverything() {
        for p in [OccupancyPlan(startMHz: 118, endMHz: 137, binKHz: 8.33), OccupancyPlan(startMHz: 100, endMHz: 160, binKHz: 50),
                  OccupancyPlan(startMHz: 430, endMHz: 440, binKHz: 12.5)] {
            #expect(!p.isNarrow)
            var covered = Set<Int>()
            var perRound: [Set<Int>] = []
            for round in 0..<2 {
                var set = Set<Int>()
                for c in p.centers(round: round) {
                    let m = p.mapping(centerMHz: c, fftSize: p.fftSize)
                    set.formUnion(m.grid.map(Int.init))
                }
                perRound.append(set)
                covered.formUnion(set)
            }
            #expect(covered == Set(0..<p.binCount), "Band \(p.startMHz)–\(p.endMHz)")
            // Die DC-Lücke fehlt höchstens in einer der beiden Runden.
            #expect(perRound[0].count < p.binCount || perRound[1].count < p.binCount || perRound[0] == perRound[1])
            // Fenster bleiben im nutzbaren Bereich (±7 MHz).
            for c in p.centers(round: 0) + p.centers(round: 1) {
                let m = p.mapping(centerMHz: c, fftSize: p.fftSize)
                #expect(!m.grid.isEmpty)
            }
        }
    }

    @Test("Rauschboden, Schwelle und Belegung aus synthetischen Spektren")
    func thresholdAndFloor() throws {
        let center = plan.centers(round: 0)[0]
        let mapping = plan.mapping(centerMHz: center, fftSize: plan.fftSize)
        let carrier = try #require(plan.binIndex(forMHz: 433.92))
        var rng = LCG(state: 42)

        // Erster Besuch: Boden noch unbekannt → kein Urteil.
        var first = OccupancyVisitAccumulator(mapping: mapping, thresholdLinear: nil)
        for i in 0..<100 { first.add(shiftedPower: frame(mapping: mapping, rng: &rng, carrierGrid: i < 25 ? carrier : nil, carrierDB: 20)) }
        let v1 = first.result()
        #expect(v1.judged == 0)
        #expect(abs(v1.floorDB - (-60)) < 1, "Boden \(v1.floorDB)")

        // Zweiter Besuch mit Schwelle Boden + 10 dB: genau 25 % belegt, sonst nichts.
        let threshold = Float(pow(10, Double(v1.floorDB + 10) / 10))
        var second = OccupancyVisitAccumulator(mapping: mapping, thresholdLinear: threshold)
        for i in 0..<100 { second.add(shiftedPower: frame(mapping: mapping, rng: &rng, carrierGrid: i % 4 == 0 ? carrier : nil, carrierDB: 20)) }
        let v2 = second.result()
        #expect(v2.judged == 100)
        let j = try #require(v2.grid.firstIndex(of: Int32(carrier)))
        #expect(v2.over[j] == 25)
        #expect(v2.over.enumerated().allSatisfy { $0.offset == j || $0.element == 0 })

        // Zu einer Scheibe zusammengefasst.
        var slicer = OccupancySlicer(binCount: plan.binCount, sliceSeconds: 60)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // glatte Minute
        #expect(slicer.add(v1, at: t0.addingTimeInterval(5)) == nil)
        #expect(slicer.add(v2, at: t0.addingTimeInterval(20)) == nil)
        let closedSlice = slicer.close()
        let slice = try #require(closedSlice)
        #expect(slice.start == t0)
        #expect(slice.visits == 2)
        #expect(slice.occupancyFraction(carrier) == 0.25)
        #expect(slice.occupancyFraction(carrier + 3) == 0)
        #expect(abs((slice.peakDB(carrier) ?? 0) - (-40)) <= 0.5)
        // Mittel: 0,75 · n + 0,25 · 100 · n ≈ 25,75 · n → −45,9 dB
        #expect(abs((slice.meanDB(carrier) ?? 0) - Float(10 * log10(25.75e-6))) < 0.6)
        #expect(abs((slice.meanDB(carrier + 3) ?? 0) - (-60)) < 0.6)
        #expect(abs(slice.floorDB - (-60)) < 1)
    }

    @Test("Zeitscheiben beginnen auf vollen Minuten und schließen beim Wechsel")
    func sliceBoundaries() throws {
        let mapping = plan.mapping(centerMHz: plan.centers(round: 0)[0], fftSize: plan.fftSize)
        var rng = LCG(state: 7)
        func visit() -> OccupancyVisit {
            var acc = OccupancyVisitAccumulator(mapping: mapping, thresholdLinear: 1e-5)
            for _ in 0..<4 { acc.add(shiftedPower: frame(mapping: mapping, rng: &rng, carrierGrid: nil, carrierDB: 0)) }
            return acc.result()
        }
        var slicer = OccupancySlicer(binCount: plan.binCount, sliceSeconds: 60)
        let minute = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(slicer.add(visit(), at: minute.addingTimeInterval(30)) == nil)
        #expect(slicer.add(visit(), at: minute.addingTimeInterval(50)) == nil)
        let third = slicer.add(visit(), at: minute.addingTimeInterval(70))
        let closed = try #require(third)
        #expect(closed.start == minute)
        #expect(closed.visits == 2)
        #expect(slicer.sliceStart == minute.addingTimeInterval(60))
        let remaining = slicer.close()
        let rest = try #require(remaining)
        #expect(rest.visits == 1)
        #expect(slicer.close() == nil)
    }

    @Test("Kodierung der Pegel und Belegung")
    func quantization() {
        #expect(OccupancySlice.decodeDB(OccupancySlice.encodeDB(-60)) == -60)
        #expect(OccupancySlice.decodeDB(OccupancySlice.encodeDB(-60.3)) == -60.5)
        #expect(OccupancySlice.decodeDB(OccupancySlice.encodeDB(-200)) == -127.5)
        #expect(OccupancySlice.decodeDB(0) == nil)
        #expect(OccupancySlice.decodeOccupancy(OccupancySlice.encodeOccupancy(0.25)) == 0.25)
        #expect(OccupancySlice.decodeOccupancy(OccupancySlice.encodeOccupancy(nil)) == nil)
        #expect(OccupancySlice.decodeOccupancy(OccupancySlice.encodeOccupancy(1.7)) == 1)
    }

    private func randomSlices(_ count: Int, bins: Int, start: Date) -> [OccupancySlice] {
        var rng = LCG(state: 99)
        return (0..<count).map { i in
            OccupancySlice(start: start.addingTimeInterval(Double(i) * 60), floorDB: -61.5 + Float(i), visits: UInt32(10 + i),
                           mean: (0..<bins).map { _ in UInt8(rng.next() * 255) },
                           peak: (0..<bins).map { _ in UInt8(rng.next() * 255) },
                           occupancy: (0..<bins).map { _ in UInt8(rng.next() * 255) })
        }
    }

    @Test("Speicherformat: schreiben und lesen ergibt dasselbe")
    func fileRoundTrip() throws {
        var rec = OccupancyRecording(name: "433 MHz ISM – Test äöü", plan: plan, sliceSeconds: 60, thresholdDB: 10)
        rec.slices = randomSlices(5, bins: plan.binCount, start: Date(timeIntervalSince1970: 1_800_000_000))
        let data = rec.encoded()
        #expect(data.count == OccupancyRecording.headerSize + 5 * (16 + 3 * plan.binCount))
        let back = try OccupancyRecording.decode(data)
        #expect(back.name == rec.name)
        #expect(back.plan == rec.plan)
        #expect(back.sliceSeconds == 60)
        #expect(back.thresholdDB == 10)
        #expect(back.slices == rec.slices)
        // Abgeschnittenes Ende (Absturz beim Schreiben) wird ignoriert.
        let cut = try OccupancyRecording.decode(data.prefix(data.count - 7))
        #expect(cut.slices == Array(rec.slices.prefix(4)))
        #expect(throws: OccupancyRecording.ReadError.self) { try OccupancyRecording.decode(Data(repeating: 0, count: 200)) }
    }

    @Test("Größenbegrenzung entfernt die ältesten Scheiben")
    func sizeLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("occ-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = OccupancyStore(folder: folder)
        let url = store.newURL()
        var rec = OccupancyRecording(name: "Grenze", plan: plan, sliceSeconds: 60, thresholdDB: 10)
        let slices = randomSlices(40, bins: plan.binCount, start: Date(timeIntervalSince1970: 1_800_000_000))
        let recordSize = 16 + 3 * plan.binCount
        let limit = OccupancyRecording.headerSize + 20 * recordSize
        for slice in slices { try store.append(slice, to: &rec, url: url, maxBytes: limit) }
        let onDisk = try store.load(url)
        #expect(onDisk.slices == rec.slices)
        #expect(onDisk.slices.count <= 20)
        #expect(onDisk.slices.count >= 10)
        #expect(onDisk.slices.last == slices.last)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size <= limit)
        #expect(store.list().map(\.url.lastPathComponent) == [url.lastPathComponent])
    }

    @Test("Aktivste Frequenzen mit Zeiträumen")
    func mostActive() {
        let p = OccupancyPlan(startMHz: 144, endMHz: 144.4, binKHz: 12.5)   // 32 Bins
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func slice(_ i: Int, _ occ: [Int: Double]) -> OccupancySlice {
            var o = [UInt8](repeating: 0, count: p.binCount)
            for (bin, v) in occ { o[bin] = OccupancySlice.encodeOccupancy(v) }
            var peak = [UInt8](repeating: OccupancySlice.encodeDB(-60), count: p.binCount)
            for bin in occ.keys { peak[bin] = OccupancySlice.encodeDB(-40) }
            return OccupancySlice(start: start.addingTimeInterval(Double(i) * 60), floorDB: -60, visits: 10,
                                  mean: [UInt8](repeating: OccupancySlice.encodeDB(-60), count: p.binCount), peak: peak, occupancy: o)
        }
        let slices = [slice(0, [5: 0.5, 6: 0.1]), slice(1, [5: 0.5]), slice(2, [20: 0.2]), slice(3, [:]), slice(4, [5: 0.3])]
        let summary = OccupancyAnalysis.summary(slices, binCount: p.binCount)
        #expect(abs((summary.occupancy[5] ?? 0) - 0.26) < 1e-9)
        #expect(summary.peakAboveFloor[5] == 20)
        let active = OccupancyAnalysis.mostActive(summary, slices: slices, plan: p, mergeBins: 2)
        #expect(active.map(\.bin) == [5, 20])
        #expect(abs(active[0].mhz - 144.06875) < 1e-9)
        #expect(active[0].activeSlices == 3)
        // Neueste zuerst: 4. Minute, dann 0.–1. Minute zusammengefasst.
        #expect(active[0].episodes.count == 2)
        #expect(active[0].episodes[0].start == start.addingTimeInterval(240))
        #expect(active[0].episodes[1].start == start)
        #expect(active[0].episodes[1].end == start.addingTimeInterval(120))
    }

    @Test("Zeitachse: kurze Lücken bleiben, lange werden gekürzt")
    func timeline() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let slices = [0.0, 60, 300, 100_000].map {
            OccupancySlice(start: start.addingTimeInterval($0), floorDB: -60, visits: 1, mean: [1], peak: [1], occupancy: [0])
        }
        let t = OccupancyTimeline(slices: slices, sliceSeconds: 60)
        #expect(t.rows == [0, 1, nil, nil, nil, 2, nil, nil, nil, 3])
        #expect(t.dates[2] == start.addingTimeInterval(120))
    }

    @Test("FFT-Weg: Träger 1 MHz über der Mitte landet im richtigen Rasterbin")
    func collectorFrequencySign() throws {
        let p = OccupancyPlan(startMHz: 100, endMHz: 103, binKHz: 50)
        let center = p.centers(round: 0)[0]          // 99,7 MHz
        let mapping = p.mapping(centerMHz: center, fftSize: p.fftSize)
        let collector = OccupancyCollector(fftSize: p.fftSize)
        collector.begin(mapping: mapping, thresholdLinear: nil)
        let toneHz = 1_300_000.0                      // → 101,0 MHz
        var iq = Data(count: 2 * p.fftSize * 8)
        iq.withUnsafeMutableBytes { raw in
            let b = raw.bindMemory(to: Int8.self)
            for n in 0..<(p.fftSize * 8) {
                let phase = 2 * Double.pi * toneHz * Double(n) / OccupancyPlan.sampleRate
                b[2 * n] = Int8((60 * cos(phase)).rounded())
                b[2 * n + 1] = Int8((60 * sin(phase)).rounded())
            }
        }
        collector.process(iq)
        let visit = try #require(collector.finish())
        #expect(visit.frames == 2)
        let best = try #require(visit.maximum.indices.max { visit.maximum[$0] < visit.maximum[$1] })
        let mhz = p.binCenterMHz(Int(visit.grid[best]))
        #expect(abs(mhz - 101.0) <= 0.05, "gefunden bei \(mhz) MHz")
    }

    @Test("Funkbetriebsart je Frequenz fürs Radio")
    func radioModes() {
        #expect(OccupancyPreset.radioMode(for: 124.5) == .am)
        #expect(OccupancyPreset.radioMode(for: 446.05) == .nfm)
        #expect(OccupancyPreset.radioMode(for: 99.0) == .wfm)
        #expect(OccupancyPreset.radioMode(for: 27.1) == .am)
    }
}
