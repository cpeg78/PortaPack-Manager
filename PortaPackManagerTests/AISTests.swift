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
}
