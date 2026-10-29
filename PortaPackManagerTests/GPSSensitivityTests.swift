import Accelerate
import Foundation
import Testing
@testable import PortaPackManager

/// Empfindlichkeit: Schwelle aus der Falschalarmrate, Schwachsignal-Suche,
/// Tracking mit 20 ms, Almanach, Vorhersage, Heißstart (alles synthetisch).
@Suite("GPS-Empfindlichkeit (synthetisch)", .serialized)
struct GPSSensitivityTests {
    static let berlin = GPSTrackingTests.berlin

    /// 4,096 MS/s, 8 Bit → dezimiert auf 2,048 MS/s wie der Empfänger (Summe zweier Werte).
    static func decimate(_ d: Data) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(d.count / 2)
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int8.self)
            var i = 0
            while i + 3 < p.count {
                out.append(Float(p[i]) + Float(p[i + 2])); out.append(Float(p[i + 1]) + Float(p[i + 3]))
                i += 4
            }
        }
        return out
    }

    /// Codefehler (Chips) eines Akquisitionsergebnisses gegen die Wahrheit.
    static func codeError(_ fix: GPSFix, truth: Double) -> Double {
        var dc = (-fix.codePhaseChips - 0.125 - truth).truncatingRemainder(dividingBy: 1023)
        if dc > 511 { dc -= 1023 } else if dc < -511 { dc += 1023 }
        return dc
    }

    @Test("Schwelle: Gamma-Verteilung und Falschalarmrate")
    func schwelle() {
        #expect(abs(GPSDetection.gammaTail(1, 3) - exp(-3)) < 1e-12)
        // P(Gamma(2) > t) = e^−t (1 + t)
        #expect(abs(GPSDetection.gammaTail(2, 5) - exp(-5) * 6) < 1e-12)
        let coarse = GPSDetection.ratioThreshold(blocks: 8, cells: 81 * 2048)
        let weak = GPSDetection.ratioThreshold(blocks: 20, cells: 401 * 2048)
        // Mehr Blöcke → Schwelle näher an 1 (Rauschen mittelt sich heraus).
        #expect(coarse > weak && weak > 1)
        #expect(coarse < pow(10, 0.9))      // früher fest 9 dB
    }

    /// Bei 28 dB-Hz findet die Grobsuche nichts, die Schwachsignal-Suche
    /// (10 ms kohärent, 200 ms, ±10 kHz) alle mit Code und Doppler genau genug
    /// für die Übergabe; reines Rauschen ergibt keinen Treffer.
    @Test("Schwachsignal-Suche findet 28 dB-Hz, die Grobsuche nicht")
    func schwachsignalSuche() {
        let t0 = 200_000.0
        let ephs = GPSTestConstellation.visible(rx: Self.berlin, t: t0, week: 2440, minElevation: 10, count: 4)
        let sim = GPSSignalSimulator(rx: Self.berlin, startTime: t0, ephemerides: ephs, cn0: 28,
                                     firstSubframeStart: (t0 / 30).rounded(.up) * 30, duration: 1, seed: 99)
        let samples = Self.decimate(sim.next(4096 * 200 + 64))
        let acq = GPSAcquirer(dopplerStepHz: 250)
        let truePRNs = Set(ephs.map(\.prn))
        let coarse = acq.acquire(samples)
        #expect(coarse.filter(\.acquired).isEmpty)

        let others = (1...32).filter { !truePRNs.contains($0) }.prefix(6)
        let targets = (Array(truePRNs) + others).map { GPSAcquirer.Target(prn: $0, doppler: -10_000...10_000) }
        let fixes = acq.acquireWeak(samples, targets: targets)
        let found = fixes.filter(\.acquired)
        #expect(Set(found.map(\.prn)).isSubset(of: truePRNs), "Fehlalarm: \(found.map(\.prn))")
        #expect(found.count >= 3, "nur \(found.count) von 4 gefunden")
        for f in found {
            let truth = sim.truth(prn: f.prn, sample: 0)
            #expect(abs(Self.codeError(f, truth: truth.codePhase)) < 0.5)
            #expect(abs(f.dopplerHz - truth.dopplerHz) < 30, "PRN \(f.prn): \(f.dopplerHz) statt \(truth.dopplerHz)")
            // Nur ein Startwert fürs Tracking: Raster- und Codeversatz drücken ihn.
            #expect(f.weak && (21...32).contains(f.cn0), "C/N0-Schätzung \(f.cn0)")
        }
    }

    /// Schwach gestarteter Kanal (Doppler 8 Hz, Code 0,2 Chip daneben) bei
    /// 27 dB-Hz: Bitsync über die Energie, dann 20 ms kohärent mit schmaler PLL;
    /// rastet ein, dekodiert Subframes und bleibt genau. Vorher war bei 33 dB-Hz Schluss.
    @Test("Tracking mit 20 ms hält 27 dB-Hz und dekodiert")
    func schwachesTracking() {
        let t0 = 200_000.0
        let ephs = GPSTestConstellation.visible(rx: Self.berlin, t: t0, week: 2440, minElevation: 20, count: 1)
        let sim = GPSSignalSimulator(rx: Self.berlin, startTime: t0, ephemerides: ephs, cn0: 27,
                                     firstSubframeStart: (t0 / 30).rounded(.up) * 30, duration: 24, seed: 7)
        let prn = ephs[0].prn
        let start = sim.truth(prn: prn, sample: 0)
        let ch = GPSChannel(prn: prn, sampleRate: sim.sampleRate, codePhase: start.codePhase + 0.2,
                            dopplerHz: start.dopplerHz + 8, cn0Hint: 27)
        var floats = [Float](repeating: 0, count: 2 * 409_600)
        var subframes = 0
        for _ in 0..<240 {
            let data = sim.next(409_600)
            data.withUnsafeBytes { raw in
                vDSP_vflt8(raw.bindMemory(to: Int8.self).baseAddress!, 1, &floats, 1, vDSP_Length(2 * 409_600))
            }
            floats.withUnsafeBufferPointer { subframes += ch.process($0.baseAddress!, count: 409_600).count }
        }
        let truth = sim.truth(prn: prn, sample: sim.sampleIndex)
        var codeError = ch.state.code_phase - truth.codePhase
        if codeError > 511 { codeError -= 1023 } else if codeError < -511 { codeError += 1023 }
        #expect(!ch.lost)
        #expect(ch.locked && ch.longIntegration)
        #expect(subframes >= 2, "\(subframes) Subframes")
        #expect(ch.isSynchronized)
        #expect(abs(ch.carrierHz - truth.dopplerHz) < 3)
        #expect(abs(codeError) < 0.05, "Codefehler \(codeError) Chip")
        #expect(abs(ch.cn0 - 27) < 2, "C/N0 \(ch.cn0)")
    }

    /// Almanachseite kodieren → dekodieren; die Almanachbahn trifft die
    /// Ephemeride auf wenige km, der vorhergesagte Doppler den des Simulators auf < 30 Hz.
    @Test("Almanach dekodieren und Doppler vorhersagen")
    func almanachUndVorhersage() throws {
        let t0 = 200_000.0
        let ephs = GPSTestConstellation.visible(rx: Self.berlin, t: t0, week: 2440, minElevation: 5, count: 6)
        let now = 2440 * GPSConst.weekSeconds + t0
        for eph in ephs {
            let page = GPSSubframe(words: GPSNavBuilder.almanacPage(eph: eph, towCount: Int(t0 / 6)))
            let alm = try #require(GPSAlmanac(page: page, nearAbsolute: now))
            #expect(alm.prn == eph.prn && alm.health == 0)
            for dt in [0.0, 3600, -7200] {
                let d = alm.position(atAbsolute: now + dt) - eph.position(at: t0 + dt)
                #expect((d * d).sum().squareRoot() < 10_000, "PRN \(eph.prn) bei \(dt) s: \((d * d).sum().squareRoot()) m")
            }
        }
        // Vorhersage gegen die Wahrheit des Signalgenerators.
        let pages = ephs.map { GPSSubframe(words: GPSNavBuilder.almanacPage(eph: $0, towCount: Int(t0 / 6))) }
        var aiding = GPSAidingData()
        aiding.almanac = pages.compactMap { GPSAlmanac(page: $0, nearAbsolute: now) }
        let sim = GPSSignalSimulator(rx: Self.berlin, startTime: t0, ephemerides: ephs,
                                     firstSubframeStart: (t0 / 30).rounded(.up) * 30, duration: 1)
        let predicted = GPSPredictor.predict(at: now, rx: Self.berlin + SIMD3(2000, 1000, -1500), aiding: aiding)
        #expect(predicted.count == ephs.count)
        for p in predicted {
            let truth = sim.truth(prn: p.prn, sample: 0)
            #expect(abs(p.dopplerHz - truth.dopplerHz) < 30, "PRN \(p.prn): \(p.dopplerHz) statt \(truth.dopplerHz)")
        }
    }

    /// Hilfsdaten über eine Datei (Temp-Ordner): Ein Lauf bei 45 dB-Hz lernt
    /// Bahnen und Ort; der nächste startet damit bei 24 dB-Hz – die gezielte Suche
    /// findet die Satelliten, die Ephemeriden gelten noch (Heißstart), die erste
    /// Position kommt, sobald die Zeit (TOW) dekodiert ist.
    @Test("Heißstart mit gespeicherten Hilfsdaten bei 24 dB-Hz")
    func heissstart() throws {
        let t0 = 518_400.0 - 2.0
        let ephs = GPSTestConstellation.visible(rx: Self.berlin, t: t0, week: 2190, minElevation: 10, count: 7)
        func receiver() -> GPSReceiver {
            var options = GPSReceiver.Options()
            options.asynchronousAcquisition = false
            options.referenceDate = GPSTime.utc(week: 2190, tow: 0, leapSeconds: 0)
            return GPSReceiver(options: options)
        }
        let first = receiver()
        first.configure(aiding: nil, time: GPSTime.utc(week: 2190, tow: t0, leapSeconds: 18), home: nil)
        // Mit Almanachseiten in Subframe 5 (ab 518 424 s, also nach 26 s Signal).
        let sim1 = GPSSignalSimulator(rx: Self.berlin, startTime: t0, ephemerides: ephs,
                                      firstSubframeStart: 518_400, duration: 33, almanac: true)
        for _ in 0..<330 { first.process(sim1.next(409_600)) }
        let learned = first.aidingData
        #expect(learned.ephemerides.count == ephs.count)
        #expect(learned.position != nil && learned.clockOffsetHz != nil)
        let alm = try #require(learned.almanac.first)
        let eph = try #require(ephs.first { $0.prn == alm.prn })
        let d = alm.position(atAbsolute: 2190 * GPSConst.weekSeconds + t0) - eph.position(at: t0)
        #expect((d * d).sum().squareRoot() < 10_000)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GPS-Hilfsdaten-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try learned.save(to: url)
        let loaded = try #require(GPSAidingData.load(from: url))
        #expect(loaded == learned)

        // Zweiter Lauf: 40 s nach dem ersten Start, nur 24 dB-Hz.
        let t1 = t0 + 40
        let second = receiver()
        second.configure(aiding: loaded, time: GPSTime.utc(week: 2190, tow: t1, leapSeconds: 18), home: nil)
        #expect(second.status.hotStart)
        let sim2 = GPSSignalSimulator(rx: Self.berlin, startTime: t1, ephemerides: ephs, cn0: 24,
                                      firstSubframeStart: 518_400, duration: 30, seed: 4711)
        var firstFix: Double?
        for _ in 0..<300 {
            second.process(sim2.next(409_600))
            if firstFix == nil, second.status.solution != nil { firstFix = second.status.elapsed }
        }
        let status = second.status
        #expect(status.channels.count >= 6, "\(status.channels.count) Kanäle")
        #expect(status.channels.allSatisfy { $0.weakAcquired })
        let fix = try #require(firstFix)
        print("GPS Heißstart 24 dB-Hz: erste Position nach \(fix) s")
        #expect(fix < 25)
        let sol = try #require(status.solution)
        let err = sol.ecef - Self.berlin
        #expect((err * err).sum().squareRoot() < 100)
    }

    /// Ein starker Satellit (50 dB-Hz) neben schwachen (27 dB-Hz): Die
    /// Schwachsignal-Suche darf keine Kreuzkorrelation als Satellit übernehmen.
    @Test("Starke und schwache Satelliten: keine Kreuzkorrelation als Kanal")
    func keineKreuzkorrelation() {
        let t0 = 518_400.0 - 2.0
        let ephs = GPSTestConstellation.visible(rx: Self.berlin, t: t0, week: 2190, minElevation: 10, count: 6)
        let cn0s = ephs.indices.map { $0 < 2 ? 50.0 : 27.0 }
        let sim = GPSSignalSimulator(rx: Self.berlin, startTime: t0, ephemerides: ephs, cn0s: cn0s,
                                     firstSubframeStart: 518_400, duration: 30)
        var options = GPSReceiver.Options()
        options.asynchronousAcquisition = false
        options.referenceDate = GPSTime.utc(week: 2190, tow: 0, leapSeconds: 0)
        let receiver = GPSReceiver(options: options)
        var seen = Set<Int>()
        for _ in 0..<300 {
            receiver.process(sim.next(409_600))
            seen.formUnion(receiver.status.channels.map(\.prn))
        }
        // Nie ein Kanal auf einem PRN, der gar nicht sendet; die starken und
        // mindestens zwei der vier schwachen gefunden (Nah-fern-Grenze: Nebenspitzen
        // der 50-dB-Hz-Satelliten liegen bei ≈ 29 dB-Hz).
        #expect(seen.isSubset(of: Set(ephs.map(\.prn))), "Kanäle \(seen.sorted())")
        #expect(seen.count >= 4, "nur \(seen.sorted())")
    }
}
