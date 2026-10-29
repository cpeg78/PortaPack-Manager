import Foundation
import Testing
@testable import PortaPackManager

@Suite("Amateurfunksatelliten")
struct AmateurSatTests {
    private func frame(_ source: String, _ destination: String, _ info: String, path: [String] = []) -> AX25Frame {
        AX25Frame(destination: AX25Address(destination), source: AX25Address(source),
                  digipeaters: path.map { AX25Address($0) }, info: Array(info.utf8))
    }

    // MARK: Sender für die Tests

    /// AFSK 1200 (Bell 202) als Momentanfrequenz relativ zur Mitte bei 2,4 MS/s.
    private func afsk(_ frames: [AX25Frame], offset: Double) -> [Double] {
        let rate = SatChannelizer.inputRate
        var freq = [Double](repeating: offset, count: Int(rate * 0.05))
        var tonePhase = 0.0, clock = 0.0
        for frame in frames {
            let levels = HDLCEncoder.nrzi(HDLCEncoder.bits(for: frame.encoded(), leadingFlags: 12, trailingFlags: 3))
            for level in levels {
                clock += rate / 1200
                let count = Int(clock.rounded())
                clock -= Double(count)
                for _ in 0..<count {
                    tonePhase += 2 * .pi * (level == 1 ? 1200.0 : 2200.0) / rate
                    freq.append(offset + 3_000 * sin(tonePhase))
                }
            }
            freq += [Double](repeating: offset, count: Int(rate * 0.1))
        }
        return freq
    }

    /// 9600 Bd G3RUH: HDLC → NRZI → Verwürfler → GFSK (BT 0,5, Hub ±`deviation`).
    private func g3ruh(_ frames: [AX25Frame], offset: Double, deviation: Double = 2_400) -> [Double] {
        let rate = SatChannelizer.inputRate
        let perBit = rate / 9600                       // 250
        var symbols: [Double] = []
        var scrambler = G3RUHScrambler()
        for frame in frames {
            var bits = HDLCEncoder.bits(for: frame.encoded(), leadingFlags: 24, trailingFlags: 4)
            bits += [UInt8](repeating: 0, count: 64)   // Nachlauf
            for level in HDLCEncoder.nrzi(bits) {
                symbols.append(scrambler.scramble(level) == 1 ? 1 : -1)
            }
        }
        // Gauß-gefilterter Rechteckimpuls, t in Bitdauern um die Bitmitte.
        let k = Double.pi * 0.5 * (2 / log(2.0)).squareRoot()
        func g(_ t: Double) -> Double { 0.5 * (erf(k * (t + 0.5)) - erf(k * (t - 0.5))) }
        let total = Int(Double(symbols.count) * perBit)
        var freq = [Double](repeating: offset, count: Int(rate * 0.02))
        freq.reserveCapacity(total + freq.count * 2)
        for n in 0..<total {
            let t = Double(n) / perBit
            let center = Int(t)
            var v = 0.0
            for j in max(0, center - 2)...min(symbols.count - 1, center + 2) {
                v += symbols[j] * g(t - Double(j) - 0.5)
            }
            freq.append(offset + deviation * v)
        }
        freq += [Double](repeating: offset, count: Int(rate * 0.02))
        return freq
    }

    private func run(_ iq: Data, channels: [SatChannelizer.Channel], doppler: Double, decode: ([Float]) -> [[UInt8]],
                     channel index: Int = 0) -> [AX25Frame] {
        let front = SatChannelizer(channels: channels)
        front.setDoppler(factor: doppler)
        var out: [AX25Frame] = []
        for block in TestSignals.blocks(iq) {
            out += decode(front.process(block)[index]).compactMap(AX25Frame.parse)
        }
        return out
    }

    // MARK: AX.25

    @Test("ISS-APRS: AFSK mit 3,4 kHz Doppler wird nach der Korrektur dekodiert (zwei Kanäle wie bei der ISS)")
    func afskWithDoppler() {
        let frames = [frame("DL1ABC-7", "CQ", "=5340.80N/00940.80E-Gruss ueber die ISS", path: ["ARISS"]),
                      frame("RS0ISS", "APRS", ">ARISS-Digipeater")]
        let iss = AmateurSatellite.catalog.first { $0.id == AmateurSatellite.issID }!
        let center = iss.centerFrequency
        let factor = 3_400 / 145_825_000.0
        let offset = 145_825_000 - center
        let iq = TestSignals.iq(carriers: [afsk(frames, offset: offset + factor * 145_825_000)], noise: 4)
        let channels = iss.channels.map {
            SatChannelizer.Channel(offset: $0.frequency - center, frequency: $0.frequency, cutoff: $0.mode.channelCutoff)
        }
        let demod = AFSKDemodulator()
        let decoded = run(iq, channels: channels, doppler: factor, decode: demod.process, channel: 1)
        #expect(decoded == frames)
        #expect(decoded.first?.digipeaters.first?.call == "ARISS")
    }

    @Test("G3RUH 9600 Bd mit 8,7 kHz Doppler (70 cm) kommt samt CRC zurück, auch mit umgekehrtem Hub")
    func g3ruhWithDoppler() {
        let frames = [frame("OM9GRB", "CQ", "GRBBeta Telemetrie 0123456789 ABCDEF"),
                      AX25Frame(destination: AX25Address("TLM"), source: AX25Address("OM9GRB"),
                                info: (0..<64).map { UInt8($0 * 7 & 0xFF) })]
        let f = 436_785_000.0
        let factor = 8_700 / f
        let channels = [SatChannelizer.Channel(offset: 0, frequency: f, cutoff: AmateurMode.g3ruh9600.channelCutoff)]
        for deviation in [2_400.0, -2_400.0] {
            let iq = TestSignals.iq(carriers: [g3ruh(frames, offset: factor * f, deviation: deviation)], noise: 8)
            let demod = G3RUHDemodulator()
            let decoded = run(iq, channels: channels, doppler: factor, decode: demod.process)
            #expect(decoded == frames, "Hub \(deviation)")
        }
    }

    @Test("G3RUH: verfälschtes Byte fällt an der CRC durch")
    func g3ruhCRC() {
        let original = frame("OM9GRB", "CQ", "Pruefsumme")
        let bytes = original.encoded()
        // Bitfolge mit gültiger FCS bauen, danach ein Nutzbit kippen.
        var bits = HDLCEncoder.bits(for: bytes, leadingFlags: 24, trailingFlags: 4)
        let flip = 24 * 8 + 20 * 8 + 3
        bits[flip] ^= 1
        var scrambler = G3RUHScrambler(), descrambler = G3RUHScrambler()
        var nrzi = NRZIDecoder()
        var deframer = HDLCDeframer(minimumBytes: 16, maximumBytes: 400)
        var got: [[UInt8]] = []
        for level in HDLCEncoder.nrzi(bits + [UInt8](repeating: 0, count: 40)) {
            let line = scrambler.scramble(level)
            if let f = deframer.push(nrzi.decode(descrambler.descramble(line))) { got.append(f) }
        }
        #expect(got.isEmpty)
        // Gegenprobe: unverfälscht kommt der Rahmen durch.
        var scrambler2 = G3RUHScrambler(), descrambler2 = G3RUHScrambler()
        var nrzi2 = NRZIDecoder()
        var deframer2 = HDLCDeframer(minimumBytes: 16, maximumBytes: 400)
        var good: [[UInt8]] = []
        let clean = HDLCEncoder.bits(for: bytes, leadingFlags: 24, trailingFlags: 4)
        for level in HDLCEncoder.nrzi(clean + [UInt8](repeating: 0, count: 40)) {
            if let f = deframer2.push(nrzi2.decode(descrambler2.descramble(scrambler2.scramble(level)))) { good.append(f) }
        }
        #expect(good.compactMap(AX25Frame.parse) == [original])
    }

    @Test("Verwürfler und Entwürfler heben sich auf")
    func scramblerRoundTrip() {
        var tx = G3RUHScrambler(), rx = G3RUHScrambler()
        var rng = TestSignals.Noise(state: 5)
        let bits = (0..<2000).map { _ in UInt8(rng.next() < 0.5 ? 0 : 1) }
        let back = bits.map { rx.descramble(tx.scramble($0)) }
        #expect(back == bits)
        // Lange Nullfolgen werden aufgebrochen, sobald der Verwürfler nicht leer ist.
        var seeded = G3RUHScrambler()
        _ = seeded.scramble(1)
        let after = (0..<200).map { _ in seeded.scramble(0) }
        #expect(after.filter { $0 == 1 }.count > 40)
    }

    @Test("Aus Rauschen entstehen keine Rahmen")
    func noiseOnly() {
        let iq = TestSignals.iq(carriers: [], noise: 20, seed: 7) + TestSignals.iq(carriers: [[Double](repeating: 0, count: 2_400_000)], noise: 20, seed: 9)
        let channels = [SatChannelizer.Channel(offset: 0, frequency: 436e6, cutoff: 12_000)]
        let g = G3RUHDemodulator()
        #expect(run(iq, channels: channels, doppler: 0, decode: g.process).isEmpty)
        let a = AFSKDemodulator()
        #expect(run(iq, channels: channels, doppler: 0, decode: a.process).isEmpty)
    }

    @Test("Rahmenanzeige: Text, Hex und fremde Rahmen")
    func frameDisplay() {
        let text = AmateurFrame(bytes: frame("RS0ISS", "CQ", "Hallo", path: ["WIDE2-1"]).encoded(), satellite: "ISS", channel: "APRS")
        #expect(text.source == "RS0ISS" && text.destination == "CQ" && text.path == "WIDE2-1")
        #expect(text.text == "Hallo")
        let binary = AmateurFrame(bytes: AX25Frame(destination: AX25Address("TLM"), source: AX25Address("OM9GRB"),
                                                   info: [0x00, 0x01, 0xFF, 0x80]).encoded(), satellite: "GRBBeta", channel: "TLM")
        #expect(binary.text == nil)
        #expect(binary.hex == "00 01 FF 80")
        let foreign = AmateurFrame(bytes: [0x01, 0x02, 0x03], satellite: "X", channel: "Y")
        #expect(foreign.source == "–" && foreign.hex == "01 02 03")
    }

    // MARK: Liste und Doppler

    @Test("Satellitenliste: eindeutige Nummern, Frequenzen in den Amateurbändern")
    func catalog() {
        let ids = AmateurSatellite.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains(25544))
        for sat in AmateurSatellite.catalog {
            #expect(!sat.channels.isEmpty)
            for channel in sat.channels {
                let mhz = channel.frequency / 1e6
                #expect((144...146).contains(mhz) || (435...438).contains(mhz), "\(sat.name) \(mhz)")
            }
        }
        let iss = AmateurSatellite.lookup(25544)
        #expect(iss?.channels.map(\.mode) == [.sstv, .afsk1200])
        #expect(iss?.channels.map(\.frequency) == [145_800_000, 145_825_000])
    }

    @Test("Doppler aus SGP4: beim Aufgang positiv, am Gipfel nahe null, beim Untergang negativ")
    func doppler() throws {
        let tles = TLE.parse(SatelliteTests.tleText)
        let station = GroundStation(latitude: 53.55, longitude: 9.99, altitudeKm: 0.05)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12, minute: 56))!
        let pass = try #require(PassPredictor.passes(WeatherSatellite.all[1], tle: tles[1], station: station,
                                                     from: start, hours: 6, minElevation: 30).first)
        let f = 137_900_000.0
        let rise = try #require(Doppler.geometry(tle: tles[1], station: station, at: pass.start.addingTimeInterval(30)))
        let top = try #require(Doppler.geometry(tle: tles[1], station: station, at: pass.culmination))
        let set = try #require(Doppler.geometry(tle: tles[1], station: station, at: pass.end.addingTimeInterval(-30)))
        #expect(rise.factor * f > 2_000 && rise.factor * f < 3_500, "Aufgang \(rise.factor * f) Hz")
        #expect(abs(top.factor * f) < 400, "Gipfel \(top.factor * f) Hz")
        #expect(set.factor * f < -2_000 && set.factor * f > -3_500, "Untergang \(set.factor * f) Hz")
        #expect(abs(top.elevation - pass.maxElevation) < 1)
    }
}

@Suite("Empfangsplan: Amateurfunksatelliten")
struct AmateurPlannerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func pass(_ id: Int, _ name: String, at minutes: Double, length: Double = 10, elevation: Double = 40) -> SatellitePass {
        let start = t0.addingTimeInterval(minutes * 60)
        return SatellitePass(satellite: WeatherSatellite(id: id, name: name, frequency: 145_800_000),
                             start: start, end: start.addingTimeInterval(length * 60),
                             culmination: start.addingTimeInterval(length * 30), maxElevation: elevation,
                             startAzimuth: 200, endAzimuth: 40, sunElevation: 10)
    }

    private typealias Planner = ReceptionPlanner

    @Test("Amateur-Termine: eine Minute Vorlauf, 30 s Nachlauf, eigene Kennung")
    func jobTimes() {
        let p = pass(25544, "ISS", at: 10)
        let job = Planner.Job(kind: .amateur(p))
        #expect(job.start == p.start.addingTimeInterval(-60))
        #expect(job.end == p.end.addingTimeInterval(30))
        #expect(job.id.hasPrefix("amsat-"))
        #expect(job.title == "ISS (40°)")
        #expect(job.isAmateur && !job.isPass && !job.isSonde)
        #expect(Planner.Job(kind: .pass(p)).id != job.id)
    }

    @Test("Neu gerechnete Vorhersage gilt als derselbe Termin")
    func sameJob() {
        let a = Planner.Job(kind: .amateur(pass(25544, "ISS", at: 10)))
        let shifted = Planner.Job(kind: .amateur(pass(25544, "ISS", at: 11)))
        let other = Planner.Job(kind: .amateur(pass(26931, "PCSAT (NO-44)", at: 10)))
        let meteor = Planner.Job(kind: .pass(pass(25544, "ISS", at: 10)))
        #expect(a.same(as: shifted))
        #expect(!a.same(as: other))
        #expect(!a.same(as: meteor))
    }

    @Test("Plan: Mindesthöhe je Art, sortiert nach Beginn")
    func schedule() {
        let jobs = Planner.schedule(
            meteor: [pass(57166, "METEOR-M2-3", at: 50, elevation: 20)], minElevation: 25,
            amateur: [pass(25544, "ISS", at: 30, elevation: 15), pass(25544, "ISS", at: 120, elevation: 60),
                      pass(26931, "PCSAT (NO-44)", at: 5, elevation: 25)],
            amateurMinElevation: 20,
            sonde: [Planner.SondeWindow(start: t0.addingTimeInterval(60 * 60), end: t0.addingTimeInterval(180 * 60))],
            now: t0)
        #expect(jobs.map(\.title) == ["PCSAT (NO-44) (25°)", "Radiosonden", "ISS (60°)"])
    }

    @Test("Vorrang: METEOR vor ISS vor Sonden, übersprungene Termine zählen nicht")
    func priority() {
        let meteor = Planner.Job(kind: .pass(pass(57166, "METEOR-M2-3", at: 5)))
        let iss = Planner.Job(kind: .amateur(pass(25544, "ISS", at: 0)))
        let sonde = Planner.Job(kind: .sonde(Planner.SondeWindow(start: t0.addingTimeInterval(-3600), end: t0.addingTimeInterval(3600))))
        let now = t0.addingTimeInterval(6 * 60)
        #expect(Planner.due([sonde, iss, meteor], now: now, skipped: [])?.id == meteor.id)
        #expect(Planner.due([sonde, iss], now: now, skipped: [])?.id == iss.id)
        #expect(Planner.due([sonde, iss], now: now, skipped: [iss.id])?.id == sonde.id)
        // Vor dem Vorlauf der ISS läuft nur das Sondenfenster.
        #expect(Planner.due([sonde, iss], now: t0.addingTimeInterval(-120), skipped: [])?.id == sonde.id)
        // Nach dem Untergang (+30 s) ist die ISS vorbei.
        #expect(Planner.due([iss], now: t0.addingTimeInterval(10 * 60 + 31), skipped: []) == nil)
    }

    @Test("Überflüge der ISS mit SGP4-Bahn (Testbahn aus METEOR-Daten unter ISS-Nummer)")
    func passesForAmateur() throws {
        // Kein eingecheckter ISS-Datensatz: die Rechnung ist für alle Satelliten
        // dieselbe, geprüft wird hier, dass `passTarget` Name und Nummer trägt.
        let tles = TLE.parse(SatelliteTests.tleText)
        let iss = try #require(AmateurSatellite.lookup(AmateurSatellite.issID))
        let station = GroundStation(latitude: 53.55, longitude: 9.99)
        let passes = PassPredictor.passes(iss.passTarget, tle: tles[0], station: station, from: t0, hours: 24, minElevation: 10)
        #expect(!passes.isEmpty)
        #expect(passes.allSatisfy { $0.satellite.id == 25544 && $0.satellite.name == "ISS" })
        #expect(passes.allSatisfy { Planner.Job(kind: .amateur($0)).id.hasPrefix("amsat-25544-") })
    }
}

@Suite("Empfangsplan: Sondenfenster folgt dem Empfang")
struct SondeWindowFollowTests {
    @Test("Nach Fensterende weiter, bis die Sonde 5 Minuten still ist")
    func tail() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let planned = start.addingTimeInterval(7200)
        #expect(ReceptionPlanner.sondeWindowEnd(planned: planned, start: start, heard: nil) == planned)
        let late = planned.addingTimeInterval(120)
        #expect(ReceptionPlanner.sondeWindowEnd(planned: planned, start: start, heard: late) == late.addingTimeInterval(300))
        // Früh gehört: das geplante Ende bleibt.
        #expect(ReceptionPlanner.sondeWindowEnd(planned: planned, start: start, heard: start.addingTimeInterval(600)) == planned)
        // Höchstens 5 h ab Fensterbeginn.
        #expect(ReceptionPlanner.sondeWindowEnd(planned: planned, start: start, heard: start.addingTimeInterval(6 * 3600)) == start.addingTimeInterval(5 * 3600))
    }

    @Test("Vorzeitig zu Ende: gehörte Sonde 10 Minuten still oder 30 Minuten gar keine")
    func early() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(7200)
        let now = end.addingTimeInterval(-3600)
        #expect(!ReceptionPlanner.endSondeEarly(heard: nil, now: start.addingTimeInterval(20 * 60), start: start, end: end))
        #expect(ReceptionPlanner.endSondeEarly(heard: nil, now: start.addingTimeInterval(30 * 60), start: start, end: end))
        #expect(!ReceptionPlanner.endSondeEarly(heard: now.addingTimeInterval(-300), now: now, start: start, end: end))
        #expect(ReceptionPlanner.endSondeEarly(heard: now.addingTimeInterval(-600), now: now, start: start, end: end))
        #expect(!ReceptionPlanner.endSondeEarly(heard: now.addingTimeInterval(-900), now: end, start: start, end: end))
    }
}
