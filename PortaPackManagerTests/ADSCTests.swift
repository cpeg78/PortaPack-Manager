import Foundation
import Testing
@testable import PortaPackManager

@Suite("ADS-C und X.25")
struct ADSCTests {
    private struct BitWriter {
        var bits: [UInt8] = []
        mutating func write(_ value: Int, _ count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) { bits.append(UInt8((value >> i) & 1)) }
        }
        var bytes: [UInt8] {
            var padded = bits
            while padded.count % 8 != 0 { padded.append(0) }
            return stride(from: 0, to: padded.count, by: 8).map { s in padded[s..<(s + 8)].reduce(0) { $0 << 1 | $1 } }
        }
    }
    private func coord(_ deg: Double) -> Int {
        let v = Int((deg * 1_048_575 / (180 - 90 / 524_288)).rounded())
        return v & 0x1FFFFF
    }

    @Test("Positionsbericht: Position, Höhe, Zeit, Flugnummer, Kurs/Fahrt, Wetter")
    func basicReport() throws {
        var w = BitWriter()
        w.write(7, 8)
        w.write(coord(53.5), 21); w.write(coord(-9.9), 21); w.write(35000 / 4, 16); w.write(Int(1234.5 * 8), 15); w.write(0b0010110, 7)
        w.write(12, 8)
        for c in "DLH123  " { w.write(Int(c.asciiValue! & 0x3F), 6) }
        w.write(14, 8)
        w.write(0, 1); w.write(ADSC.signed(-100, bits: 12) & 0xFFF, 12); w.write(900, 13); w.write(ADSC.signed(-20, bits: 12) & 0xFFF, 12); w.write(0, 2)
        w.write(16, 8)
        w.write(60, 9); w.write(0, 1); w.write(ADSC.signed(-50, bits: 9) & 0x1FF, 9); w.write(ADSC.signed(-100, bits: 12) & 0xFFF, 12); w.write(0, 1)
        let hex = (w.bytes + [0xAB, 0xCD]).map { String(format: "%02X", $0) }.joined()
        let report = try #require(ADSC.parse("/EDDHXAX.ADS.D-AIZZ" + hex, isDownlink: true))
        #expect(report.registration == "D-AIZZ" && report.groundStation == "EDDHXAX")
        #expect(report.title == "ADS-C-Bericht: Positionsbericht, Flug DLH123")
        #expect(report.latitude.map { abs($0 - 53.5) < 1e-4 } == true)
        #expect(report.longitude.map { abs($0 + 9.9) < 1e-4 } == true)
        #expect(report.altitudeFt == 35000)
        #expect(report.rows.contains { $0.name == "Zeit" && $0.value.hasPrefix("20:34,500") })
        #expect(report.rows.contains { $0.name == "Flugnummer" && $0.value == "DLH123" })
        let ref = try #require(report.rows.first { $0.name == "Über Grund" }?.value)
        #expect(ref.contains("351°") && ref.contains("450 kn") && ref.contains("-320 ft/min"), "\(ref)")
        let wx = try #require(report.rows.first { $0.name == "Wetter" }?.value)
        #expect(wx.contains("325°") && wx.contains("30 kn") && wx.contains("-25.0 °C"), "\(wx)")

        // Über die Deutung: Label B6 landet beim ADS-C-Dekoder.
        let m = ACARSMessage(mode: "2", registration: "D-AIZZ", acknowledge: "!", label: "B6", blockID: "3",
                             messageNumber: "M12A", text: "/EDDHXAX.ADS.D-AIZZ" + hex, continued: false)
        #expect(m.interpretation.summary.hasPrefix("ADS-C-Bericht"))
        #expect(m.interpretation.latitude != nil)
        let cpdlc = ACARSMessage(mode: "2", registration: "D-AIZZ", acknowledge: "!", label: "BA", blockID: "3",
                                 messageNumber: "M12A", text: "/EDDHXAX.CR1.D-AIZZ0102030405", continued: false)
        #expect(cpdlc.interpretation.summary.contains("CPDLC"))
    }

    @Test("X.25: Verbindungsaufruf mit Adressen, Datenpaket mit CLNP")
    func x25() {
        let call = VDL2Coding.describeX25([0x10, 0x01, 0x0B, 0x24, 0x12, 0x34, 0x56, 0x00, 0x02, 0x81])
        #expect(call == "X.25 Verbindungsaufruf an 1234 von 56 (Kanal 1) – CM-Logon/CPDLC-Aufbau")
        let data = VDL2Coding.describeX25([0x10, 0x02, 0x22, 0x81, 1, 2, 3])
        #expect(data == "ATN-Daten Nr. 1 (Kanal 2): CLNP, 4 Byte – CPDLC/CM, nicht entschlüsselt")
        #expect(VDL2Coding.describeX25([0x10, 0x02, 0x01]) == "X.25 Empfangsbereit (Kanal 2)")
        #expect(VDL2Coding.describeX25([0x20, 0x02, 0x01]) == nil)
    }
}
