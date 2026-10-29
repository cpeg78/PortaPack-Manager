import Accelerate
import Foundation
import Testing
@testable import PortaPackManager

@Suite("GPS-Tracking und Ortung (synthetisch)", .serialized)
struct GPSTrackingTests {
    static let berlin = GPSGeo.ecef(lat: 52.520008 * .pi / 180, lon: 13.404954 * .pi / 180, height: 50)

    /// Ein Kanal, gestartet mit Akquisitionsgenauigkeit (Doppler +110 Hz,
    /// Codephase +0,2 Chip daneben), muss bei 45 dB-Hz einrasten, Code und
    /// Träger genau nachführen und die Bitgrenze finden.
    @Test("Tracking rastet ein, Bitsync findet die Bitgrenze")
    func tracking() {
        let t0 = 200_000.0
        let ephs = GPSTestConstellation.visible(rx: Self.berlin, t: t0, week: 2440, minElevation: 20, count: 1)
        let sim = GPSSignalSimulator(rx: Self.berlin, startTime: t0, ephemerides: ephs,
                                     firstSubframeStart: (t0 / 30).rounded(.up) * 30, duration: 5)
        let prn = ephs[0].prn
        let start = sim.truth(prn: prn, sample: 0)
        let ch = GPSChannel(prn: prn, sampleRate: sim.sampleRate, codePhase: start.codePhase + 0.2,
                            dopplerHz: start.dopplerHz + 110)
        var floats = [Float]()
        let block = 409_600
        for _ in 0..<40 {          // 4 s
            let data = sim.next(block)
            floats = [Float](repeating: 0, count: 2 * block)
            data.withUnsafeBytes { raw in
                vDSP_vflt8(raw.bindMemory(to: Int8.self).baseAddress!, 1, &floats, 1, vDSP_Length(2 * block))
            }
            floats.withUnsafeBufferPointer { _ = ch.process($0.baseAddress!, count: block) }
        }
        let truth = sim.truth(prn: prn, sample: sim.sampleIndex)
        var codeError = ch.state.code_phase - truth.codePhase
        if codeError > 511 { codeError -= 1023 } else if codeError < -511 { codeError += 1023 }
        #expect(ch.locked)
        #expect(abs(ch.carrierHz - truth.dopplerHz) < 3, "Doppler \(ch.carrierHz) statt \(truth.dopplerHz)")
        #expect(abs(codeError) < 0.03, "Codefehler \(codeError) Chip")
        #expect(abs(ch.cn0 - 45) < 2.5, "C/N0 \(ch.cn0)")
        #expect(ch.stage >= .bitSync)
        // Bitgrenze: Sendezeit am Beginn der Bitperiode ist ein Vielfaches von 20 ms.
        if let phase = ch.bitPhase {
            let epochsToBoundary = (phase - ch.epoch % 20 + 20) % 20
            let tAtBoundary = truth.transmitTime + Double(epochsToBoundary) * 1e-3 - ch.state.code_phase / GPSConst.chipRate
            let frac = (tAtBoundary / 0.02 - (tAtBoundary / 0.02).rounded()) * 20
            #expect(abs(frac) < 0.05, "Bitgrenze um \(frac) ms daneben")
        }
    }

    /// Ende-zu-Ende: Signal von 7 Satelliten (45 dB-Hz, Rauschen, 8 Bit) →
    /// Akquisition → Tracking → Navigationsnachricht → Position.
    @Test("Vom Signal bis zur Position")
    func endeZuEnde() {
        let t0 = 518_400.0 - 2.0      // 2 s vor einem Rahmenbeginn
        let ephs = GPSTestConstellation.visible(rx: Self.berlin, t: t0, week: 2190, minElevation: 10, count: 7)
        #expect(ephs.count >= 5)
        let sim = GPSSignalSimulator(rx: Self.berlin, startTime: t0, ephemerides: ephs,
                                     firstSubframeStart: 518_400, duration: 24)
        var options = GPSReceiver.Options()
        options.asynchronousAcquisition = false
        options.referenceDate = GPSTime.utc(week: 2190, tow: 0, leapSeconds: 0)
        let receiver = GPSReceiver(options: options)
        let started = Date()
        var firstFix: Double?
        for _ in 0..<(24 * 10) {
            receiver.process(sim.next(409_600))
            if firstFix == nil, receiver.status.solution != nil { firstFix = receiver.status.elapsed }
        }
        let status = receiver.status
        let runtime = Date().timeIntervalSince(started)
        print("GPS Ende-zu-Ende: \(runtime) s Rechenzeit, erste Lösung nach \(firstFix ?? -1) s Signal")
        #expect(status.channels.count == ephs.count)
        #expect(status.ephemerisCount == ephs.count)
        for (got, want) in zip(receiver.currentEphemerides.values.sorted { $0.prn < $1.prn }, ephs.sorted { $0.prn < $1.prn }) {
            #expect(got == want)
        }
        #expect(status.week == 2190)
        guard let sol = status.solution else { Issue.record("keine Lösung"); return }
        let err = sol.ecef - Self.berlin
        let dist = (err * err).sum().squareRoot()
        print("GPS Ende-zu-Ende: Fehler \(dist) m, HDOP \(sol.hdop), Rest \(sol.rmsResidual) m")
        #expect(dist < 10, "Positionsfehler \(dist) m")
        #expect((sol.speed ?? 99) < 0.5)
        #expect(abs(sol.gpsTime - (t0 + status.elapsed)) < 1e-6)
        #expect(firstFix != nil && firstFix! < 22)
    }
}
