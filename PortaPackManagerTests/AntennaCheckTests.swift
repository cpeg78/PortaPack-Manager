import Foundation
import Testing
@testable import PortaPackManager

@Suite("Antennen-Check")
struct AntennaCheckTests {
    private static let noise: Float = 1e-5

    /// Fenster mit flachem Rauschen und Trägern (MHz absolut, dB über Rauschen).
    private func window(center: Double, carriers: [(mhz: Double, db: Double)] = [], holdCarriers: [(mhz: Double, db: Double)] = [],
                        burst: [Float] = [], clipped: Double = 0) -> AntennaWindowSpectrum {
        let n = AntennaCheck.fftSize
        var mean = [Float](repeating: Self.noise, count: n)
        var hold = [Float](repeating: Self.noise * 3, count: n)
        func put(_ list: [(mhz: Double, db: Double)], into array: inout [Float], base: Float) {
            for c in list {
                let bin = Int(((c.mhz - center) / AntennaCheck.binMHz).rounded()) + n / 2
                array[bin] = base * Float(pow(10, c.db / 10))
            }
        }
        put(carriers, into: &mean, base: Self.noise)
        put(carriers, into: &hold, base: Self.noise * 3)
        put(holdCarriers, into: &hold, base: Self.noise * 3)
        return AntennaWindowSpectrum(centerMHz: center, mean: mean, hold: hold, burst: burst, seconds: 2,
                                     clipped: clipped, rmsDBFS: -30)
    }

    @Test("UKW mit starkem Sender ist gut")
    func fmGood() {
        let m = AntennaCheck.analyze(band: .fm, windows: [
            window(center: 93.5, carriers: [(92.3, 35), (95.1, 18)]),
            window(center: 104.5, carriers: [(103.6, 12)]),
        ])
        #expect(abs(m.strongest - 35) < 0.5)
        #expect(m.countOver10 == 3)
        #expect(AntennaCheck.verdict(for: m).rating == .good)
        #expect(abs(m.floorDBFS - 10 * log10(Double(Self.noise))) < 0.1)
    }

    @Test("UKW knapp und zu schwach")
    func fmMarginalWeak() {
        let marginal = AntennaCheck.analyze(band: .fm, windows: [window(center: 93.5, carriers: [(92.3, 22)])])
        #expect(AntennaCheck.verdict(for: marginal).rating == .marginal)
        let weak = AntennaCheck.analyze(band: .fm, windows: [window(center: 93.5)])
        #expect(AntennaCheck.verdict(for: weak).rating == .weak)
    }

    @Test("Glatte MHz-Werte gelten als Störlinie")
    func spursIgnored() {
        let m = AntennaCheck.analyze(band: .fm, windows: [window(center: 93.5, carriers: [(98.0, 40)])])
        #expect(m.signals.isEmpty)
    }

    @Test("Übersteuerung schlägt jede andere Bewertung")
    func overloaded() {
        let m = AntennaCheck.analyze(band: .fm, windows: [window(center: 93.5, carriers: [(92.3, 40)], clipped: 0.05)])
        #expect(AntennaCheck.verdict(for: m).rating == .overloaded)
        let warn = AntennaCheck.analyze(band: .fm, windows: [window(center: 93.5, carriers: [(92.3, 40)], clipped: 0.002)])
        let v = AntennaCheck.verdict(for: warn)
        #expect(v.rating == .good)
        #expect(v.text.contains("Übersteuerung"))
    }

    @Test("Ohne Aussendung gibt es bei AIS, Sonden und Sensoren keine Aussage")
    func silenceIsNoInformation() {
        for band in [AntennaBand.ais, .sonde, .sensors, .weatherSat, .airband] {
            let m = AntennaCheck.analyze(band: band, windows: band.centersMHz.map { window(center: $0) })
            #expect(AntennaCheck.verdict(for: m).rating == .noInformation, "\(band)")
        }
    }

    @Test("AIS-Aussendung im Spitzenwert zählt, außerhalb der Kanäle nicht")
    func aisBurst() {
        let m = AntennaCheck.analyze(band: .ais, windows: [window(center: 165, holdCarriers: [(162.025, 24), (163.5, 30)])])
        #expect(m.signals.count == 1)
        #expect(abs(m.signals[0].mhz - 162.025) < 0.01)
        #expect(AntennaCheck.verdict(for: m).rating == .good)
    }

    @Test("Sonden-Dauerstörer werden übergangen")
    func sondeBlocked() {
        let list = SondeBlockList(persistent: false)
        list.set([404_625_000...404_650_000])
        let m = AntennaCheck.analyze(band: .sonde, windows: [window(center: 403.2, carriers: [(404.637, 30), (402.5, 12)])],
                                     blocked: list.contains)
        #expect(m.signals.count == 1)
        #expect(abs(m.signals[0].mhz - 402.5) < 0.01)
        #expect(AntennaCheck.verdict(for: m).rating == .marginal)
    }

    @Test("DAB bewertet die Blockleistung")
    func dabBlocks() {
        // 5C = 178,352 MHz: Block über ±700 kHz mit 18 dB.
        let center = 180.0
        let block = stride(from: 177.66, through: 179.04, by: AntennaCheck.binMHz).map { (mhz: $0, db: 18.0) }
        let m = AntennaCheck.analyze(band: .dab, windows: [window(center: center, carriers: block)])
        #expect(m.signals.first?.label == "5C")
        #expect(abs(m.strongest - 18) < 1)
        #expect(AntennaCheck.verdict(for: m).rating == .good)
        let none = AntennaCheck.analyze(band: .dab, windows: AntennaBand.dab.centersMHz.map { window(center: $0) })
        #expect(AntennaCheck.verdict(for: none).rating == .weak)
    }

    @Test("ADS-B: Antworten über 15 dB heißen Flugzeuge hörbar")
    func adsbBursts() {
        var frames = [Float](repeating: 1, count: 10_000)
        for k in stride(from: 0, to: 10_000, by: 500) { frames[k] = 50 }   // 17 dB
        let m = AntennaCheck.analyze(band: .adsb, windows: [window(center: 1087, burst: frames)])
        #expect(abs((m.burstPeakDB ?? 0) - 17) < 0.1)
        #expect(m.burstsPerSecond == 10)
        #expect(AntennaCheck.verdict(for: m).rating == .good)
        let quiet = AntennaCheck.analyze(band: .adsb, windows: [window(center: 1087, burst: [Float](repeating: 1, count: 1000))])
        #expect(AntennaCheck.verdict(for: quiet).rating == .weak)
    }

    @Test("Zusammenfassung nennt Bänder und empfiehlt Antennen")
    func summary() {
        let fm = AntennaCheck.analyze(band: .fm, windows: [window(center: 93.5, carriers: [(92.3, 35)])])
        let sat = AntennaCheck.analyze(band: .weatherSat, windows: [window(center: 140.5)])
        let adsb = AntennaCheck.analyze(band: .adsb, windows: [window(center: 1087, burst: [Float](repeating: 1, count: 100))])
        let s = AntennaCheck.summary([fm, sat, adsb])
        #expect(s.good == ["UKW-Radio"])
        #expect(s.weak == ["Flugzeuge (ADS-B)"])
        #expect(s.noInformation == ["Wettersatelliten"])
        #expect(s.advice.contains { $0.contains("QFH") })
        #expect(s.advice.contains { $0.contains("1090-MHz-Filter") })
    }

    @Test("Ergebnis übersteht Speichern und Laden")
    func roundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "AntennaCheckTests"))
        defer { defaults.removePersistentDomain(forName: "AntennaCheckTests") }
        let m = AntennaCheck.analyze(band: .fm, windows: [window(center: 93.5, carriers: [(92.3, 35)])])
        let result = AntennaCheckResult(date: Date(timeIntervalSince1970: 1_800_000_000), externalAmplifier: true,
                                        antennaPower: false, measurements: [m], complete: false)
        result.save(defaults)
        let loaded = try #require(AntennaCheckResult.load(defaults))
        #expect(loaded.measurements == [m])
        #expect(loaded.date == result.date)
        #expect(loaded.externalAmplifier)
    }

    @Test("Akkumulator findet einen Träger und die Kanalleistung je Rahmen")
    func accumulator() {
        let acc = AntennaCheckAccumulator()
        acc.reset(burstChannel: 1.9...2.1)
        let n = AntennaCheck.fftSize * 16
        var bytes = [Int8](repeating: 0, count: 2 * n)
        let f = 2.0 / 20   // 2 MHz bei 20 MS/s
        for k in 0..<n {
            let phase = 2 * Double.pi * f * Double(k)
            bytes[2 * k] = Int8((60 * cos(phase)).rounded())
            bytes[2 * k + 1] = Int8((60 * sin(phase)).rounded())
        }
        acc.process(bytes.withUnsafeBufferPointer { Data(buffer: $0) })
        let w = acc.snapshot(centerMHz: 100, clipped: 0, rmsDBFS: -10)
        let peak = w.mean.indices.max { w.mean[$0] < w.mean[$1] }!
        #expect(abs(AntennaCheck.offset(of: peak, count: w.mean.count) - 2.0) < AntennaCheck.binMHz)
        #expect(w.burst.count == 16)
        #expect(w.burst.allSatisfy { $0 > 0 })
    }
}
