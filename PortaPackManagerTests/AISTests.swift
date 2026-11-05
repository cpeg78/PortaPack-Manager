import Foundation
import Testing
@testable import PortaPackManager

@Suite("AIS")
struct AISTests {
    private let type1 = "!AIVDM,1,1,,A,13u?etPv2;0n:dDPwUM1U1Cb069D,0*24"   // oft mit falscher Prüfsumme *23 zitiert
    private let moored = "!AIVDM,1,1,,B,177KQJ5000G?tO`K>RA1wUbN0TKH,0*5C"
    private let static5 = ["!AIVDM,2,1,1,A,55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8,0*1C",
                           "!AIVDM,2,2,1,A,88888888880,2*25"]

    @Test("Positionsmeldung Typ 1 aus NMEA")
    func positionReport() throws {
        let m = try #require(AISNMEA.bits(from: [type1]).flatMap(AISMessage.decode))
        #expect(m.type == 1 && m.mmsi == 265_547_250)
        #expect(m.speedKnots == 13.9)
        #expect(abs(m.longitude! - 11.8329767) < 1e-6)
        #expect(abs(m.latitude! - 57.6603533) < 1e-6)
        #expect(m.courseDegrees == 40.4)
        #expect(m.heading == 41)
    }

    @Test("Festgemachtes Schiff (Beispiel von Eric Raymond)")
    func moredExample() throws {
        let m = try #require(AISNMEA.bits(from: [moored]).flatMap(AISMessage.decode))
        #expect(m.mmsi == 477_553_000)
        #expect(m.status == 5 && AISMessage.statusText(m.status) == "festgemacht")
        #expect(m.speedKnots == 0)
        #expect(abs(m.longitude! + 122.345832) < 1e-5)
        #expect(abs(m.latitude! - 47.582833) < 1e-5)
        #expect(m.courseDegrees == 51)
        #expect(m.heading == 181)
    }

    @Test("Stammdaten Typ 5 aus zwei NMEA-Zeilen")
    func staticData() throws {
        let m = try #require(AISNMEA.bits(from: static5).flatMap(AISMessage.decode))
        #expect(m.type == 5 && m.mmsi == 351_759_000)
        #expect(m.callsign == "3FOF8")
        #expect(m.name == "EVER DIADEM")
        #expect(m.shipType == 70 && AISMessage.shipTypeText(m.shipType) == "Frachter")
        #expect(m.destination == "NEW YORK")
        #expect(m.imo == 9_134_270)
    }

    @Test("NMEA-Erzeugung: Panzerung und Prüfsumme stimmen mit dem Original überein")
    func nmeaRoundTrip() throws {
        let bits = try #require(AISNMEA.bits(from: [type1]))
        #expect(AISNMEA.sentences(for: bits, channel: "A", sequence: 0) == [type1])
        let long = try #require(AISNMEA.bits(from: static5))
        let lines = AISNMEA.sentences(for: long, channel: "A", sequence: 1)
        #expect(lines.count == 2)
        #expect(AISNMEA.bits(from: lines)?.bits == long.bits)
    }

    @Test("Prüfsummenfehler wird erkannt")
    func badChecksum() {
        #expect(AISNMEA.bits(from: [type1.replacingOccurrences(of: "*24", with: "*25")]) == nil)
    }

    /// Nachricht → Bytes → HDLC (Training + Flaggen) → NRZI → GMSK (BT 0,4, ±2,4 kHz).
    private func gmskFrequencies(_ bits: AISBits, leadingSilence: Double) -> [Double] {
        var bytes: [UInt8] = []
        for k in stride(from: 0, to: bits.count, by: 8) {
            var byte: UInt8 = 0
            for b in 0..<8 { byte = byte << 1 | (k + b < bits.count ? bits.bits[k + b] : 0) }
            bytes.append(byte)
        }
        let training: [UInt8] = (0..<24).map { UInt8($0 % 2) }
        let data = training + HDLCEncoder.bits(for: bytes, leadingFlags: 1, trailingFlags: 1) + [0, 0, 0, 0]
        let levels = HDLCEncoder.nrzi(data).map { $0 == 1 ? 1.0 : -1.0 }
        let rate = FMChannelizer.inputRate
        let spb = Int(rate / 9600)   // 250
        // Gauß-Filter (±2 Bit) einmal über ein Rechteckbit gefaltet: Impuls je Bit.
        let sigma = (log(2.0)).squareRoot() / (2 * .pi * 0.4) * Double(spb)
        let taps = (-2 * spb...2 * spb).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = taps.reduce(0, +)
        var running = [Double](repeating: 0, count: taps.count + 1)
        for (k, h) in taps.enumerated() { running[k + 1] = running[k] + h / sum }
        // pulse[m]: Antwort auf ein Bit, das bei m = 2·spb beginnt.
        let pulse = (0..<(5 * spb)).map { m -> Double in
            let hi = min(m, taps.count - 1), lo = max(m - spb + 1, 0)
            return hi >= lo ? running[hi + 1] - running[lo] : 0
        }
        let start = Int(rate * leadingSilence)
        var out = [Double](repeating: 0, count: start + (levels.count + 3) * spb)
        for (b, level) in levels.enumerated() {
            let base = start + b * spb - 2 * spb
            for (m, p) in pulse.enumerated() where base + m >= start {
                out[base + m] += 2_400 * level * p
            }
        }
        return out + [Double](repeating: 0, count: Int(rate * 0.02))
    }

    @Test("Ende zu Ende: GMSK auf beiden Kanälen gleichzeitig")
    func endToEnd() throws {
        let a = try #require(AISNMEA.bits(from: [type1]))
        let b = try #require(AISNMEA.bits(from: [moored]))
        // Kanal A 25 kHz unter, Kanal B 25 kHz über der Mitte; leichte Frequenzablage.
        let fa = gmskFrequencies(a, leadingSilence: 0.010).map { $0 - 25_000 + 300 }
        let fb = gmskFrequencies(b, leadingSilence: 0.017).map { $0 + 25_000 - 400 }
        let iq = TestSignals.iq(carriers: [fa, fb], amplitude: 30, noise: 3)
        let front = FMChannelizer(channelOffsets: AISModel.channels.map(\.offset), stage1Cutoff: 60_000, channelCutoff: 9_000)
        let demods = [GMSKDemodulator(), GMSKDemodulator()]
        var found: [String: [Int]] = [:]
        for block in TestSignals.blocks(iq, size: 65_536) {
            for (index, samples) in front.process(block).enumerated() {
                for frame in demods[index].process(samples) {
                    if let m = AISMessage.decode(AISBits(frameBytes: frame)) {
                        found[AISModel.channels[index].name, default: []].append(m.mmsi)
                    }
                }
            }
        }
        #expect(found["A"] == [265_547_250])
        #expect(found["B"] == [477_553_000])
    }

    /// Bits eines Felds, höchstwertiges zuerst.
    private func field(_ value: Int, _ length: Int) -> [UInt8] {
        (0..<length).map { UInt8((value >> (length - 1 - $0)) & 1) }
    }

    /// 6-Bit-AIS-Text (A–Z, Leerzeichen, Ziffern).
    private func sixBit(_ text: String) -> [UInt8] {
        text.utf8.flatMap { c in field(Int(c) >= 64 ? Int(c) - 64 : Int(c), 6) }
    }

    @Test("Typ 9: SAR-Flugzeug mit Höhe (gpsd-Beispiel)")
    func sarAircraft() throws {
        let m = try #require(AISNMEA.bits(from: ["!AIVDM,1,1,,B,91b55wi;hbOS@OdQAC062Ch2089h,0*30"]).flatMap(AISMessage.decode))
        #expect(m.type == 9 && m.mmsi == 111_232_511)
        #expect(m.isSARAircraft)
        #expect(m.altitudeMeters == 303)
        #expect(m.speedKnots == 42)
        #expect(abs(m.longitude! + 6.27884) < 1e-4)
        #expect(abs(m.latitude! - 58.144) < 1e-3)
        #expect(m.courseDegrees == 154.5)
        var tracker = AISTracker()
        tracker.ingest(m, channel: "B")
        let vessel = try #require(tracker.vessels[111_232_511])
        #expect(vessel.kindText == "Rettungsflugzeug (SAR)")
        #expect(MapShip(vessel, now: Date()).symbol == .plane)
    }

    @Test("Typ 8 DAC 1/FI 31: Wetter und Pegel einer Messstation (IMO 289)")
    func metHydro() throws {
        var bits = [UInt8](repeating: 0, count: 360)
        func set(_ start: Int, _ length: Int, _ value: Int) {
            let v = value < 0 ? value + (1 << length) : value
            for k in 0..<length { bits[start + k] = UInt8((v >> (length - 1 - k)) & 1) }
        }
        set(0, 6, 8); set(8, 30, 2_111_234); set(40, 10, 1); set(50, 6, 31)
        set(56, 25, Int(8.5 * 60_000)); set(81, 24, Int(53.9 * 60_000))
        set(106, 5, 4); set(111, 5, 18); set(116, 6, 30)
        set(122, 7, 12); set(129, 7, 20); set(136, 9, 250); set(145, 9, 360)
        set(154, 11, -35); set(165, 7, 88); set(172, 10, 501); set(182, 9, 214)
        set(194, 8, 45); set(202, 12, 1120); set(216, 8, 255); set(224, 9, 360)
        set(277, 8, 255); set(285, 6, 63); set(327, 10, 82)
        let m = try #require(AISMessage.decode(AISBits(bits: bits)))
        let w = try #require(m.weather)
        #expect(abs((m.latitude ?? 0) - 53.9) < 1e-4 && abs((m.longitude ?? 0) - 8.5) < 1e-4)
        #expect(w.windKnots == 12 && w.gustKnots == 20 && w.windFrom == 250)
        #expect(w.airTemperature == -3.5 && w.humidity == 88 && w.dewPoint == nil)
        #expect(w.pressure == 1013)
        #expect(w.visibilityNM == 4.5)
        #expect(abs((w.waterLevel ?? 0) - 1.2) < 1e-9)
        #expect(w.currentKnots == nil && w.waveHeight == nil && w.waterTemperature == 8.2)
        #expect(w.time == "04. 18:30 UTC")
        var tracker = AISTracker()
        tracker.ingest(m, channel: "A")
        let station = try #require(tracker.vessels[2_111_234])
        #expect(station.kindText == "Wetterstation")
        #expect(MapShip(station, now: Date()).symbol == .weather)
    }

    @Test("Typ 14 und 12: Sicherheitsmeldungen, Wiederholung nur einmal")
    func safetyMessages() throws {
        let broadcast = AISBits(bits: field(14, 6) + field(0, 2) + field(351_809_000, 30) + field(0, 2) + sixBit("RCVD YR TEST MSG"))
        let m = try #require(AISMessage.decode(broadcast))
        #expect(m.safetyText == "RCVD YR TEST MSG")
        #expect(m.safetyDestination == nil)
        let addressed = AISBits(bits: field(12, 6) + field(0, 2) + field(244_000_001, 30) + field(0, 2)
                                + field(211_000_002, 30) + field(0, 2) + sixBit("ICE WARNING"))
        let a = try #require(AISMessage.decode(addressed))
        #expect(a.safetyText == "ICE WARNING")
        #expect(a.safetyDestination == 211_000_002)
        var tracker = AISTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        tracker.ingest(m, channel: "A", at: t0)
        tracker.ingest(m, channel: "B", at: t0.addingTimeInterval(5))
        tracker.ingest(a, channel: "A", at: t0.addingTimeInterval(6))
        tracker.ingest(m, channel: "A", at: t0.addingTimeInterval(700))
        #expect(tracker.safetyMessages.map(\.text) == ["RCVD YR TEST MSG", "ICE WARNING", "RCVD YR TEST MSG"])
        #expect(tracker.vessels[351_809_000]?.safetyText == "RCVD YR TEST MSG")
    }

    @Test("Notsender: SART/MOB/EPIRB nach MMSI, aktiv nur bei Status 14 oder „ACTIVE“")
    func beacons() throws {
        #expect(AISBeacon(mmsi: 970_123_456) == .sart)
        #expect(AISBeacon(mmsi: 972_000_001) == .manOverboard)
        #expect(AISBeacon(mmsi: 974_000_001) == .epirb)
        #expect(AISBeacon(mmsi: 211_000_001) == nil)
        var tracker = AISTracker()
        let test = AISBits(bits: field(14, 6) + field(0, 2) + field(970_123_456, 30) + field(0, 2) + sixBit("SART TEST"))
        tracker.ingest(try #require(AISMessage.decode(test)), channel: "A")
        let sart = try #require(tracker.vessels[970_123_456])
        #expect(sart.kindText == "Notsender (AIS-SART)")
        #expect(!sart.beaconActive)
        #expect(MapShip(sart, now: Date()).symbol == .sos)
        let active = AISBits(bits: field(14, 6) + field(0, 2) + field(970_123_456, 30) + field(0, 2) + sixBit("SART ACTIVE"))
        tracker.ingest(try #require(AISMessage.decode(active)), channel: "A")
        #expect(tracker.vessels[970_123_456]?.beaconActive == true)
        #expect(AISMessage.statusText(14) == "Notsender aktiv")
    }

    @Test("Schiffsliste führt Stamm- und Positionsdaten zusammen")
    func tracker() throws {
        var tracker = AISTracker()
        var position = try #require(AISNMEA.bits(from: static5).flatMap(AISMessage.decode))
        tracker.ingest(position, channel: "A")
        position = AISMessage(type: 1, mmsi: 351_759_000, speedKnots: 12, courseDegrees: 90, latitude: 53.5, longitude: 9.9)
        tracker.ingest(position, channel: "B")
        let v = try #require(tracker.sorted.first)
        #expect(v.name == "EVER DIADEM" && v.speedKnots == 12 && v.latitude == 53.5 && v.messages == 2)
    }

    @Test("Drehrate: ±127 heißt „> 5°/30 s“ ohne Zahlenwert, −128 nicht verfügbar (Review 05.11.2026)")
    func rateOfTurnLimits() throws {
        func message(rot: Int) throws -> AISMessage {
            var bits = field(1, 6) + field(0, 2) + field(265_547_250, 30) + field(0, 4) + field(rot & 0xFF, 8)
            bits += [UInt8](repeating: 0, count: 168 - bits.count)
            return try #require(AISMessage.decode(AISBits(bits: bits)))
        }
        let starboard = try message(rot: 127)
        #expect(starboard.rateOfTurn == nil && starboard.rateOfTurnOverRange == 1)
        #expect(starboard.rateOfTurnText == "> 5°/30 s nach Steuerbord")
        let port = try message(rot: -127)
        #expect(port.rateOfTurn == nil && port.rateOfTurnOverRange == -1)
        #expect(port.rateOfTurnText == "> 5°/30 s nach Backbord")
        let unavailable = try message(rot: -128)
        #expect(unavailable.rateOfTurn == nil && unavailable.rateOfTurnOverRange == nil && unavailable.rateOfTurnText == nil)
        let turning = try message(rot: -10)
        #expect(abs((turning.rateOfTurn ?? 0) + 4.464) < 0.01 && turning.rateOfTurnOverRange == nil)
        #expect(turning.rateOfTurnText == "-4.5°/min")
    }
}
