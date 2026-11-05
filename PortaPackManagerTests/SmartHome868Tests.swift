import Foundation
import Testing
@testable import PortaPackManager

/// Bausteine für Testrahmen der Smart-Home-Funkarten.
enum SmartHomeTestFrames {
    /// Z-Wave R1/R2-Rahmen (Einzelruf, Quittung erbeten) mit XOR-Prüfsumme.
    static func zwave(home: UInt32, source: UInt8, destination: UInt8, payload: [UInt8], sequence: UInt8 = 3) -> [UInt8] {
        let length = UInt8(4 + 1 + 2 + 1 + 1 + payload.count + 1)
        var frame = [UInt8(home >> 24), UInt8(home >> 16 & 0xFF), UInt8(home >> 8 & 0xFF), UInt8(home & 0xFF),
                     source, 0x41, sequence & 0x0F, length, destination] + payload
        frame.append(ZWave.checksum(frame))
        return frame
    }

    /// Z-Wave R3-Rahmen mit Folgenummer und CRC-16.
    static func zwaveR3(home: UInt32, source: UInt8, destination: UInt8, payload: [UInt8], sequence: UInt8 = 0x42) -> [UInt8] {
        let length = UInt8(4 + 1 + 2 + 1 + 1 + 1 + payload.count + 2)
        var frame = [UInt8(home >> 24), UInt8(home >> 16 & 0xFF), UInt8(home >> 8 & 0xFF), UInt8(home & 0xFF),
                     source, 0x81, 0x00, length, sequence, destination] + payload
        let crc = ZWave.crc16(frame)
        frame += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        return frame
    }

    /// Homematic-Nachricht (entwürfelt): Länge wird gesetzt.
    static func homematic(counter: UInt8, flags: UInt8, type: UInt8, source: [UInt8], target: [UInt8], payload: [UInt8]) -> [UInt8] {
        let body = [counter, flags, type] + source + target + payload
        return [UInt8(body.count)] + body
    }

    /// EnOcean-Telegramm mit CRC-8.
    static func enocean(rorg: UInt8, data: [UInt8], sender: UInt32, status: UInt8) -> [UInt8] {
        var t = [rorg] + data + [UInt8(sender >> 24), UInt8(sender >> 16 & 0xFF), UInt8(sender >> 8 & 0xFF), UInt8(sender & 0xFF), status]
        t.append(EnOcean.crc8(t))
        return t
    }

    /// wM-Bus Format A: L korrigieren, Blöcke mit CRC.
    static func wmbusFormatA(_ data: [UInt8]) -> [UInt8] {
        var data = data
        data[0] = UInt8(data.count - 1)
        var out: [UInt8] = []
        var pos = 0
        var size = 10
        while pos < data.count {
            let block = Array(data[pos..<min(pos + size, data.count)])
            let crc = WMBus.crc16(block)
            out += block + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            pos += block.count
            size = 16
        }
        return out
    }

    /// wM-Bus Format B (bis 126 Byte): L zählt den CRC mit.
    static func wmbusFormatB(_ data: [UInt8]) -> [UInt8] {
        var data = data
        data[0] = UInt8(data.count + 2 - 1)
        let crc = WMBus.crc16(data)
        return data + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
    }

    /// OMS-Beispiel (OMS Vol. 2, Anhang N): Elster-Gaszähler 12345678, Modus 5,
    /// Schlüssel 0102…0F11. Ohne CRCs, ab L.
    static let omsExample = SmartHomeHex.parse("2E4493157856341233037A2A0020255923C95AAA26D1B2E7493B013EC4A6F6D3529B520EDFF0EA6DEFC99D6D69EBF3")!
    static let omsKey = SmartHomeHex.parse("0102030405060708090A0B0C0D0E0F11")!

    /// Unverschlüsselter Wasserzähler (Sensus iPERL, aus den wmbusmeters-Tests): 7,704 m³.
    static let iperl = SmartHomeHex.parse("1E44AE4C9956341268077A360010002F2F0413181E0000023B00000000")!
}

@Suite("Smart Home 868: Protokolle")
struct SmartHome868ProtocolTests {
    // MARK: - Prüfsummen

    @Test("CRC-Prüfwerte über „123456789“ (Katalogwerte)")
    func crcCheckValues() {
        let check = Array("123456789".utf8)
        #expect(WMBus.crc16(check) == 0xC2B7)        // CRC-16/EN-13757
        #expect(Homematic.crc16(check) == 0xAEE7)    // CRC-16/CMS (CC1101)
        #expect(ZWave.crc16(check) == 0xE5CC)        // CRC-16/SPI-FUJITSU (Start 0x1D0F)
        #expect(EnOcean.crc8(check) == 0xF4)         // CRC-8/SMBUS
    }

    @Test("PN9-Weißfolge wie im CC1101-Datenblatt")
    func pn9() {
        #expect(Homematic.whitening(count: 8) == [0xFF, 0xE1, 0x1D, 0x9A, 0xED, 0x85, 0x33, 0x24])
    }

    // MARK: - Wireless M-Bus

    @Test("OMS-Normbeispiel Modus 5 wird mit dem Schlüssel entschlüsselt")
    func omsMode5() throws {
        let keys = ["12345678": SmartHomeTestFrames.omsKey]
        let frame = try #require(WMBus.parse(SmartHomeTestFrames.omsExample, mode: "T1", keys: keys))
        #expect(frame.address == "ELS 12345678")
        #expect(frame.deviceType.contains("Gas"))
        #expect(!frame.encrypted)
        let volume = try #require(frame.values.first { $0.name == "Volumen" })
        #expect(abs(volume.value - 28504.27) < 0.001)
        #expect(volume.unit == "m³")
        #expect(frame.fields.contains { $0.name == "Zeitpunkt" && $0.value == "31.05.2008 23:50" })
        #expect(frame.values.contains { $0.name == "Fehlerflags" && $0.value == 0 })
    }

    @Test("Ohne oder mit falschem Schlüssel bleibt der Inhalt „verschlüsselt“")
    func omsWithoutKey() throws {
        let none = try #require(WMBus.parse(SmartHomeTestFrames.omsExample, mode: "T1", keys: [:]))
        #expect(none.encrypted)
        #expect(none.values.isEmpty)
        var wrongKey = SmartHomeTestFrames.omsKey
        wrongKey[0] ^= 0xFF
        let wrong = try #require(WMBus.parse(SmartHomeTestFrames.omsExample, mode: "T1", keys: ["12345678": wrongKey]))
        #expect(wrong.encrypted)
        #expect(wrong.summary.contains("passt nicht"))
    }

    @Test("Unverschlüsselter Wasserzähler: Hersteller, Ident, Zählerstand")
    func iperl() throws {
        let frame = try #require(WMBus.parse(SmartHomeTestFrames.iperl, mode: "T1", keys: [:]))
        #expect(frame.address == "SEN 12345699")
        #expect(frame.deviceType.contains("Wasser"))
        let volume = try #require(frame.values.first { $0.name == "Volumen" })
        #expect(abs(volume.value - 7.704) < 1e-9)
        #expect(frame.values.contains { $0.name == "Durchfluss" && $0.value == 0 })
    }

    @Test("Techem-Heizkostenverteiler: Einheiten, Perioden, Temperaturen (wmbusmeters-Vektoren und eigener Rahmen)")
    func techemHeatCostAllocator() throws {
        // wmbusmeters `fhkvdataiii`: Version 0x69 mit Kennbyte 0x11.
        let v69 = SmartHomeHex.parse("34446850226677116980A0119F27020480048300C408F709143C003D341A2B0B2A0707000000000000062D114457563D71A1850000")!
        var frame = try #require(WMBus.parse(v69, mode: "T1", keys: [:]))
        #expect(frame.address == "TCH 11776622")
        #expect(frame.deviceType == "Techem · Heizkostenverteiler")
        #expect(frame.values.first { $0.name == "Heizkosten-Einheiten" }?.value == 131)
        #expect(frame.values.first { $0.name == "Raumtemperatur" }?.value == 22.44)
        #expect(frame.values.first { $0.name == "Heizkörpertemperatur" }?.value == 25.51)
        #expect(frame.fields.first { $0.name == "Verbrauch Vorperiode" }?.value == "1026")
        #expect(frame.fields.first { $0.name == "Vorperiode bis" }?.value.contains("2019") == true)
        #expect(frame.fields.first { $0.name == "Stand vom" }?.value.contains("2020") == true)
        #expect(frame.encrypted == false)
        // Version 0x94, CI 0xA2, Kennbyte 0x0F mit Zwischenbyte vor den Temperaturen.
        let v94 = SmartHomeHex.parse("33446850341211119480A20F9F292D005024040011BD08380904000000070000000000000000000000000001000000000003140E")!
        frame = try #require(WMBus.parse(v94, mode: "T1", keys: [:]))
        #expect(frame.values.first { $0.name == "Heizkosten-Einheiten" }?.value == 4)
        #expect(frame.values.first { $0.name == "Raumtemperatur" }?.value == 22.37)
        #expect(frame.values.first { $0.name == "Heizkörpertemperatur" }?.value == 23.6)
        #expect(frame.fields.first { $0.name == "Verbrauch Vorperiode" }?.value == "45")
        // Am 03.11.2026 empfangen (Techem 84822684): Vorperiode bis 31.12.2025, Stand 3.11.
        let own = SmartHomeHex.parse("32446850842682846980A0119F33CA0A3016B90709096B091B7C017C1A000000000000000200020A3D1E494D74A464B0B24D4894")!
        frame = try #require(WMBus.parse(own, mode: "T1", keys: [:]))
        #expect(frame.values.first { $0.name == "Heizkosten-Einheiten" }?.value == 1977)
        #expect(frame.fields.first { $0.name == "Verbrauch Vorperiode" }?.value == "2762")
        #expect(frame.fields.first { $0.name == "Vorperiode bis" }?.value.contains("2025") == true)
        #expect(frame.fields.first { $0.name == "Stand vom" }?.value.contains("2026") == true)
        #expect(frame.values.first { $0.name == "Raumtemperatur" }?.value == 23.13)
        #expect(frame.values.first { $0.name == "Heizkörpertemperatur" }?.value == 24.11)
        // Unbekanntes Kennbyte: bleibt „herstellerspezifisch“ mit Rohbytes.
        var other = v69
        other[11] = 0x33
        frame = try #require(WMBus.parse(other, mode: "T1", keys: [:]))
        #expect(frame.values.isEmpty)
        #expect(frame.summary.contains("herstellerspezifisch"))
    }

    @Test("Sicherheitsmodus 7 mit AFL: Schlüsselableitung, Entschlüsselung und MAC (wmbusmeters-Vektor)")
    func securityMode7() throws {
        // Engelmann Sensostar, Format B mit CRCs (wmbusmeters tests/test_frame_b_trim.sh):
        // erwartet 9341 kWh und 1348,631 m³.
        let raw = SmartHomeHex.parse("C244C5140443054300048C200E900F002C25895E02003B0877D31DA840B17A0E009007100F8FAD4C4E61400DA4F3B1F7E273CC4C5C07F93CD20B237345DB39F9A98F8415E1C4B7A25C86E4C22D05C3352FA7E2E5627031F14643063F1DC8FE2C32459B6F02E4234B447B18E4BFDA8C4DA9B1EDE6CF29D0B2122A3E8B9DEEBEE3E6DBE6617B4E709EC6B595179CB01C2C0BDE6723A345B708652880C114A58DA07C73AD9EB8ACB17FA0A88F19BC84CB1FC56672DE8A9603FD0C05010002FD0B2111F60B")!
        let stripped = try #require(WMBus.stripFormatB(raw))
        #expect(stripped.crcOK)
        let key = SmartHomeHex.parse("622b9656991ff0c1574c0950cf9278d1")!
        let frame = try #require(WMBus.parse(stripped.data, mode: "C1", keys: ["43054304": key]))
        #expect(frame.address == "EFE 43054304")
        #expect(frame.encrypted == false)
        #expect(frame.fields.first { $0.name == "Nachrichtenzähler" }?.value == "\(0x00025E89)")
        #expect(frame.fields.first { $0.name == "Entschlüsselt" }?.value.contains("MAC geprüft") == true)
        let energy = try #require(frame.values.first { $0.name == "Energie" })
        #expect(energy.value == 9341 && energy.unit == "kWh")
        let volume = try #require(frame.values.first { $0.name == "Volumen" })
        #expect(abs(volume.value - 1348.631) < 1e-9)
        // Falscher Schlüssel: Inhalt beginnt nicht mit 2F 2F.
        var wrongKey = key
        wrongKey[0] ^= 0x01
        let wrong = try #require(WMBus.parse(stripped.data, mode: "C1", keys: ["43054304": wrongKey]))
        #expect(wrong.encrypted && wrong.summary.contains("passt nicht"))
        // Diehl-Wasserzähler, am 03.11.2026 empfangen, ohne Schlüssel: AFL wird
        // trotzdem gelesen (Zähler 0x00F1EE90), der Rest bleibt verschlüsselt.
        let diehl = SmartHomeHex.parse("6344A5115061826570078C007A900F002C2590EEF10032361B3B9FD39F0A7A90004007102C202E456122DA31090AC2D6157505238" + "09A6BBE131DFB58B8A01BA1FA846705B2C067A3D412CBCE1B5A9A0FA7AF873B45B51062C6C2E7875D89FE2895629C7C")!
        let none = try #require(WMBus.parse(diehl, mode: "T1", keys: [:]))
        #expect(none.address == "DME 65826150")
        #expect(none.encrypted && none.summary.contains("Modus 7") && none.summary.contains("fehlt"))
        #expect(none.fields.first { $0.name == "Nachrichtenzähler" }?.value == "15855248")
        #expect(none.fields.first { $0.name == "MAC" }?.value == "32 36 1B 3B 9F D3 9F 0A")
    }

    @Test("Herstellerkürzel aus dem M-Feld")
    func manufacturerCodes() {
        #expect(WMBus.manufacturer(0x1593) == "ELS")
        #expect(WMBus.manufacturer(0x4CAE) == "SEN")
        #expect(WMBus.manufacturer(0x2C2D) == "KAM")
    }

    @Test("3-aus-6-Kodierung hin und zurück, ungültige Kodes werden abgewiesen")
    func threeOfSix() {
        let bytes: [UInt8] = Array(0...255)
        let bits = WMBus.encode3of6(bytes)
        #expect(bits.count == 256 * 12)
        #expect(WMBus.decode3of6(bits, from: 0, count: 256) == bytes)
        var broken = bits
        broken[0] ^= 1
        #expect(WMBus.decode3of6(broken, from: 0, count: 1) == nil)
    }

    @Test("Format A und B: CRCs prüfen und entfernen")
    func formats() throws {
        let data = SmartHomeTestFrames.omsExample
        let a = SmartHomeTestFrames.wmbusFormatA(data)
        #expect(a.count == WMBus.formatALength(Int(data[0])))
        let strippedA = try #require(WMBus.stripFormatA(a))
        #expect(strippedA.crcOK)
        #expect(strippedA.data == data)
        var brokenA = a
        brokenA[20] ^= 0x01
        #expect(WMBus.stripFormatA(brokenA)?.crcOK == false)

        let b = SmartHomeTestFrames.wmbusFormatB(data)
        let strippedB = try #require(WMBus.stripFormatB(b))
        #expect(strippedB.crcOK)
        #expect(Array(strippedB.data.dropFirst()) == Array(data.dropFirst()))
    }

    @Test("T1-Bitstrom mit Sync wird gefunden und entschlüsselt")
    func t1Bits() throws {
        let raw = SmartHomeTestFrames.wmbusFormatA(SmartHomeTestFrames.omsExample)
        let bits = SmartHomeDemod.bits(of: [0x55, 0x55, 0x54, 0x3D]) + WMBus.encode3of6(raw) + [0, 1, 0, 1]
        let frames = WMBus.frames(inBits: bits, keys: ["12345678": SmartHomeTestFrames.omsKey])
        let frame = try #require(frames.first)
        #expect(frame.mode == "T1")
        #expect(frame.values.contains { $0.name == "Volumen" })
        // invertiert (andere FSK-Polarität) genauso
        #expect(WMBus.frames(inBits: SmartHomeDemod.inverted(bits), keys: [:]).count == 1)
    }

    @Test("C1 Format A und B im Bitstrom")
    func c1Bits() throws {
        let data = SmartHomeTestFrames.iperl
        let bitsA = SmartHomeDemod.bits(of: [0x55, 0x55, 0x54, 0x3D, 0x54, 0xCD] + SmartHomeTestFrames.wmbusFormatA(data) + [0x55])
        #expect(WMBus.frames(inBits: bitsA, keys: [:]).first?.mode == "C1 · Format A")
        let bitsB = SmartHomeDemod.bits(of: [0x55, 0x55, 0x54, 0x3D, 0x54, 0x3D] + SmartHomeTestFrames.wmbusFormatB(data) + [0x55])
        let frameB = try #require(WMBus.frames(inBits: bitsB, keys: [:]).first)
        #expect(frameB.mode == "C1 · Format B")
        #expect(frameB.values.contains { $0.name == "Volumen" && abs($0.value - 7.704) < 1e-9 })
    }

    @Test("ELL mit AES-CTR (Kamstrup-Art) hin und zurück")
    func ellCTR() throws {
        let key: [UInt8] = Array(0x10...0x1F)
        // Kopf: L C M(KAM) A(ID 76348799, Version 1B, Wasser 16)
        let header: [UInt8] = [0x00, 0x44, 0x2D, 0x2C, 0x99, 0x87, 0x34, 0x76, 0x1B, 0x16]
        let inner: [UInt8] = [0x78, 0x04, 0x13, 0x2A, 0x00, 0x00, 0x00]      // 0,042 m³
        let crc = WMBus.crc16(inner)
        let plain = [UInt8(crc & 0xFF), UInt8(crc >> 8)] + inner
        let cc: UInt8 = 0x20, sn: [UInt8] = [0x91, 0xD3, 0x7C, 0x2C]       // ENC-Bits ≠ 0
        let iv = [0x2D, 0x2C, 0x99, 0x87, 0x34, 0x76, 0x1B, 0x16, cc] + sn + [0, 0, 0]
        let encrypted = WMBus.aesCTR(key: key, iv: iv, plain)
        let data = header + [0x8D, cc, 0x00] + sn + encrypted
        let frame = try #require(WMBus.parse(data, mode: "C1 · Format A", keys: ["76348799": key]))
        #expect(frame.address == "KAM 76348799")
        #expect(frame.values.contains { $0.name == "Volumen" && abs($0.value - 0.042) < 1e-9 })
        let locked = try #require(WMBus.parse(data, mode: "C1 · Format A", keys: [:]))
        #expect(locked.encrypted)
    }

    @Test("DIF/VIF: BCD, Vorzeichen, Speicher, Energie in kWh")
    func records() {
        // 0C 06 BCD8 Energie kWh (VIF 06 = Wh·10³) · 4C 13 Volumen Speicher 1 · 02 5A Vorlauf 0,1 °C (−12,3)
        let payload: [UInt8] = [0x0C, 0x06, 0x56, 0x34, 0x12, 0x00,
                                0x4C, 0x13, 0x00, 0x05, 0x00, 0x00,
                                0x02, 0x5A, 0x85, 0xFF]
        let records = WMBus.parseRecords(payload)
        #expect(records.count == 3)
        #expect(records[0].name == "Energie" && records[0].unit == "kWh" && records[0].value == 123_456)
        #expect(records[1].storage == 1 && records[1].value == 0.5)
        #expect(records[2].name == "Vorlauftemperatur" && records[2].value == -12.3)
    }

    // MARK: - Z-Wave

    @Test("Z-Wave: Messsensor-Bericht (Temperatur) mit Home-ID, Knoten, Prüfsumme")
    func zwaveSensor() throws {
        // 31 05: Typ 01 Temperatur, Präzision 1, Skala 0, Größe 2 → 0x00D7 = 21,5 °C
        let bytes = SmartHomeTestFrames.zwave(home: 0xC0FFEE42, source: 7, destination: 1, payload: [0x31, 0x05, 0x01, 0x22, 0x00, 0xD7])
        let frame = try #require(ZWave.parse(bytes, rate: .r2))
        #expect(frame.checksumOK)
        #expect(frame.address == "C0FFEE42:7")
        #expect(frame.destination == "Knoten 1")
        #expect(frame.values == [SmartHomeValue(name: "Temperatur", unit: "°C", value: 21.5)])
        #expect(frame.fields.contains { $0.name == "Folgenummer" && $0.value == "3" })
        var broken = bytes
        broken[10] ^= 0x01
        #expect(ZWave.parse(broken, rate: .r2)?.checksumOK == false)
    }

    @Test("Z-Wave: Zähler, Batterie, Schalter, S2-verschlüsselt")
    func zwaveCommands() throws {
        // Zähler Strom kWh, Präzision 2, Größe 4: 0x000004D2 = 12,34 kWh
        let meter = ZWave.describe([0x32, 0x02, 0x21, 0x44, 0x00, 0x00, 0x04, 0xD2])
        #expect(meter.values == [SmartHomeValue(name: "Energie", unit: "kWh", value: 12.34)])
        #expect(ZWave.describe([0x80, 0x03, 0x55]).values == [SmartHomeValue(name: "Batterie", unit: "%", value: 85)])
        #expect(ZWave.describe([0x25, 0x03, 0xFF]).summary == "Schalter: ein")
        let s2 = ZWave.describe([0x9F, 0x03, 0x12, 0x00, 0xAA, 0xBB, 0xCC])
        #expect(s2.encrypted)
        #expect(s2.summary.contains("verschlüsselt"))
        #expect(ZWave.describe([0x98, 0x81, 0x01, 0x02]).encrypted)
        // Mehrkanal-Hülle um einen Schalterbericht
        let multi = ZWave.describe([0x60, 0x0D, 0x02, 0x00, 0x25, 0x03, 0x00])
        #expect(multi.summary == "Kanal 2: Schalter: aus")
        #expect(ZWave.describe([0x84, 0x07]).summary == "Aufgewacht")
    }

    @Test("Z-Wave R3: Folgenummer und CRC-16")
    func zwaveR3() throws {
        let bytes = SmartHomeTestFrames.zwaveR3(home: 0x01020304, source: 5, destination: 1, payload: [0x20, 0x03, 0x63])
        let frame = try #require(ZWave.parse(bytes, rate: .r3))
        #expect(frame.checksumOK)
        #expect(frame.fields.contains { $0.name == "Folgenummer" && $0.value == "66" })
        #expect(frame.summary == "Basic: Zustand ein")
    }

    @Test("Z-Wave R1: Manchester-Chips → Rahmen")
    func zwaveManchester() {
        let bytes = SmartHomeTestFrames.zwave(home: 0xDEADBEEF, source: 2, destination: 1, payload: [0x80, 0x03, 0x40])
        let bits = SmartHomeDemod.bits(of: [UInt8](repeating: 0x55, count: 10) + [0xF0] + bytes)
        let chips: [UInt8] = [1, 0, 1] + bits.flatMap { $0 == 1 ? [UInt8(1), 0] : [UInt8(0), 1] }
        let frames = ZWave.frames(inBits: chips, rate: .r1)
        #expect(frames.count == 1)
        #expect(frames.first?.values.first?.value == 64)
    }

    // MARK: - Homematic

    @Test("Homematic: Verwürfelung hin und zurück")
    func homematicScramble() {
        let message = SmartHomeTestFrames.homematic(counter: 0x2A, flags: 0x86, type: 0x70,
                                                   source: [0x1A, 0x2B, 0x3C], target: [0, 0, 0], payload: [0x00, 0xD7, 0x37])
        #expect(Homematic.descramble(Homematic.scramble(message)) == message)
        #expect(Homematic.scramble(message) != message)
    }

    @Test("Homematic: Wetterdaten aus dem Bitstrom (PN9, CRC, BidCoS)")
    func homematicWeather() throws {
        let message = SmartHomeTestFrames.homematic(counter: 0x2A, flags: 0x86, type: 0x70,
                                                   source: [0x1A, 0x2B, 0x3C], target: [0, 0, 0], payload: [0x00, 0xD7, 0x37])
        let air = Homematic.airBytes(message: message)
        let bits = SmartHomeDemod.bits(of: [0xAA, 0xAA, 0xAA, 0xAA, 0xE9, 0xCA, 0xE9, 0xCA] + air + [0xAA])
        let frame = try #require(Homematic.frames(inBits: bits).first)
        #expect(frame.address == "1A2B3C")
        #expect(frame.destination == "alle")
        #expect(frame.values.contains(SmartHomeValue(name: "Temperatur", unit: "°C", value: 21.5)))
        #expect(frame.values.contains(SmartHomeValue(name: "Luftfeuchte", unit: "%", value: 55)))
        // ein gekipptes Bit → CRC falsch → nichts
        var broken = bits
        broken[100] ^= 1
        #expect(Homematic.frames(inBits: broken).isEmpty)
    }

    @Test("Homematic: Fensterkontakt, Schaltstatus, Minustemperatur")
    func homematicMessages() throws {
        let contact = try #require(Homematic.parse(enc: Homematic.scramble(SmartHomeTestFrames.homematic(
            counter: 1, flags: 0xA4, type: 0x41, source: [0x11, 0x22, 0x33], target: [0x44, 0x55, 0x66], payload: [0x01, 0x05, 0xC8]))))
        #expect(contact.summary == "Kanal 1: offen")
        #expect(contact.deviceType == "Fensterkontakt")
        let status = try #require(Homematic.parse(enc: Homematic.scramble(SmartHomeTestFrames.homematic(
            counter: 2, flags: 0xA0, type: 0x10, source: [0x11, 0x22, 0x33], target: [0x44, 0x55, 0x66], payload: [0x06, 0x01, 0xC8, 0x00]))))
        #expect(status.summary == "Status Kanal 1: ein")
        // Heizkörperthermostat, am 03.11.2026 empfangen: 20,1 °C, Soll 17 °C, 3,0 V, Ventil zu, manuell.
        let thermostat = try #require(Homematic.parse(enc: Homematic.scramble(SmartHomeTestFrames.homematic(
            counter: 0xFE, flags: 0x86, type: 0x10, source: [0x24, 0xB5, 0x8B], target: [0, 0, 0],
            payload: [0x0A, 0x88, 0xC9, 0x0F, 0x00, 0x58]))))
        #expect(thermostat.summary == "20.1 °C, Soll 17.0 °C, Ventil 0 %, manuell")
        #expect(thermostat.deviceType == "Heizkörperthermostat")
        #expect(thermostat.values.contains(SmartHomeValue(name: "Temperatur", unit: "°C", value: 20.1)))
        #expect(thermostat.values.contains(SmartHomeValue(name: "Sollwert", unit: "°C", value: 17)))
        #expect(thermostat.values.contains(SmartHomeValue(name: "Batterie", unit: "V", value: 3.0)))
        #expect(thermostat.values.contains(SmartHomeValue(name: "Ventil", unit: "%", value: 0)))
        #expect(thermostat.fields.contains { $0.name == "Betriebsart" && $0.value == "manuell" })
        // −5,0 °C: 14-Bit-Zweierkomplement
        let raw = UInt16(bitPattern: Int16(-50)) & 0x7FFF
        let cold = try #require(Homematic.parse(enc: Homematic.scramble(SmartHomeTestFrames.homematic(
            counter: 3, flags: 0x86, type: 0x70, source: [1, 2, 3], target: [0, 0, 0], payload: [UInt8(raw >> 8), UInt8(raw & 0xFF), 80]))))
        #expect(cold.values.first == SmartHomeValue(name: "Temperatur", unit: "°C", value: -5))
    }

    @Test("EnOcean: Universal Teach-in (UTE) und VLD D2-01/D2-05")
    func enoceanUTEAndVLD() throws {
        // UTE: Anlernen für D2-01-12, Hersteller 0x046.
        let ute = SmartHomeTestFrames.enocean(rorg: 0xD4, data: [0xA0, 0x02, 0x46, 0x00, 0x12, 0x01, 0xD2], sender: 0x0500_1234, status: 0)
        let teach = try #require(EnOcean.parse(ute))
        #expect(teach.fields.contains { $0.name == "EEP" && $0.value == "D2-01-12" })
        #expect(teach.deviceTypeFromInfo && EnOcean.isSupported("D2-01-12"))
        // D2-01 Zustand: Kanal 0 auf 100 % → „ein“; Messwert 1234 W.
        let state = SmartHomeTestFrames.enocean(rorg: 0xD2, data: [0x04, 0x60, 0x64], sender: 0x0500_1234, status: 0)
        #expect(try #require(EnOcean.parse(state, eep: "D2-01-12")).summary == "Kanal 0: ein")
        let power = SmartHomeTestFrames.enocean(rorg: 0xD2, data: [0x07, 0x60, 0x00, 0x00, 0x04, 0xD2], sender: 0x0500_1234, status: 0)
        #expect(try #require(EnOcean.parse(power, eep: "D2-01-12")).values == [SmartHomeValue(name: "Leistung", unit: "W", value: 1234)])
        // D2-05 Rollladen: 40 % zu, Lamellen 20 %.
        let blind = SmartHomeTestFrames.enocean(rorg: 0xD2, data: [40, 20, 0x00, 0x04], sender: 0x0500_1235, status: 0)
        #expect(try #require(EnOcean.parse(blind, eep: "D2-05-00")).summary == "40 % geschlossen, Lamellen 20 %")
        // Ohne Profil nur Rohdaten.
        #expect(try #require(EnOcean.parse(state)).summary.contains("Profil unbekannt"))
    }

    @Test("wM-Bus: Kompaktrahmen (CI 0x79) mit dem Satzkopf eines vollständigen Rahmens")
    func wmbusCompact() {
        // Volumen 0x04 0x13 (l, 4 Byte) = 12 345 l, Temperatur 0x02 0x5A (0,1 °C, 2 Byte) = 21,5 °C, Füllbyte.
        let full: [UInt8] = [0x2F, 0x04, 0x13, 0x39, 0x30, 0x00, 0x00, 0x02, 0x5A, 0xD7, 0x00]
        let headers = WMBus.formatHeaders(full)
        #expect(headers == [0x04, 0x13, 0x02, 0x5A])
        let signature = WMBus.crc16(headers ?? [])
        let compactData: [UInt8] = [UInt8(signature & 0xFF), UInt8(signature >> 8), 0x00, 0x00,
                                    0x40, 0xE2, 0x01, 0x00, 0xE1, 0x00]   // 123 456 l, 22,5 °C
        var known = SmartHomeFrame(radio: .wmbus, mode: "T1", address: "x", kind: "", summary: "", checksumOK: true, bytes: [])
        WMBus.compact(compactData, formats: [signature: headers!], into: &known)
        #expect(known.values.contains { $0.unit == "m³" && abs($0.value - 123.456) < 1e-9 } || known.values.contains { $0.value == 123_456 })
        #expect(known.values.contains { $0.unit == "°C" && abs($0.value - 22.5) < 1e-9 })
        var unknown = SmartHomeFrame(radio: .wmbus, mode: "T1", address: "x", kind: "", summary: "", checksumOK: true, bytes: [])
        WMBus.compact(compactData, formats: [:], into: &unknown)
        #expect(unknown.values.isEmpty && unknown.summary.contains("Kompaktrahmen"))
        // Text variabler Länge (LVAR): kein fester Aufbau.
        #expect(WMBus.formatHeaders([0x0D, 0x78, 0x03, 0x41, 0x42, 0x43]) == nil)
    }

    @Test("EnOcean: weitere 4BS-Profile und Fenstergriff F6-10-00")
    func enoceanProfilesMore() throws {
        func values(_ eep: String, _ d: [UInt8]) -> [SmartHomeValue] { EnOcean.fourBS(d, eep: eep) }
        // A5-12-01: 1234,5 kWh (Stand 12345, Teiler 10), dann aktuell 850 W.
        #expect(values("A5-12-01", [0x00, 0x30, 0x39, 0x09]) == [SmartHomeValue(name: "Energie", unit: "kWh", value: 1234.5)])
        #expect(values("A5-12-01", [0x00, 0x03, 0x52, 0x0C]) == [SmartHomeValue(name: "Leistung", unit: "W", value: 850)])
        #expect(values("A5-09-04", [100, 64, 128, 0x0E]).contains(SmartHomeValue(name: "CO₂", unit: "ppm", value: 640)))
        #expect(values("A5-07-01", [0, 0, 200, 0x08]) == [SmartHomeValue(name: "Bewegung", unit: "", value: 1)])
        #expect(values("A5-14-01", [200, 0, 0, 0x09]).first == SmartHomeValue(name: "Kontakt offen", unit: "", value: 0))
        #expect(values("A5-10-03", [0, 128, 0, 0x08]).first == SmartHomeValue(name: "Temperatur", unit: "°C", value: 40))
        #expect(values("A5-20-01", [35, 0x10, 128, 0x08]).contains(SmartHomeValue(name: "Batterie schwach", unit: "", value: 1)))
        #expect(values("A5-06-01", [255, 0, 255, 0x08]).first == SmartHomeValue(name: "Helligkeit", unit: "lx", value: 60_000))
        // Fenstergriff: gekippt (D0), T21 = 1, NU = 0 – mit Profil sicher, ohne vermutet.
        let tilted = SmartHomeTestFrames.enocean(rorg: 0xF6, data: [0xD0], sender: 0x0100_ABCD, status: 0x20)
        let known = try #require(EnOcean.parse(tilted, eep: "F6-10-00"))
        #expect(known.summary == "Fenstergriff: gekippt")
        #expect(!known.deviceTypeGuessed)
        let guessed = try #require(EnOcean.parse(tilted))
        #expect(guessed.summary == "Fenstergriff: gekippt" && guessed.deviceTypeGuessed)
        // Wippe (NU = 1) bleibt Taster.
        let rocker = SmartHomeTestFrames.enocean(rorg: 0xF6, data: [0x30], sender: 0x0100_ABCD, status: 0x30)
        #expect(try #require(EnOcean.parse(rocker)).deviceType == "Taster (F6-02)")
    }

    @Test("Z-Wave: Türschloss, Thermostat, Benutzercode, Einstellung, Alarm, Klassenliste")
    func zwaveClasses() {
        #expect(ZWave.describe([0x62, 0x03, 0xFF, 0x00, 0x01]).summary == "Türschloss: verriegelt, Tür zu")
        #expect(ZWave.describe([0x62, 0x03, 0x00, 0x00, 0x00]).values == [SmartHomeValue(name: "Verriegelt", unit: "", value: 0)])
        #expect(ZWave.describe([0x42, 0x03, 0x01]).summary == "Thermostat: heizt")
        // Benutzercode: der Code (hier 1234) taucht nirgends auf.
        let code = ZWave.describe([0x63, 0x03, 0x05, 0x01, 0x31, 0x32, 0x33, 0x34])
        #expect(code.summary == "Benutzercode 5: belegt")
        #expect(!code.summary.contains("1234"))
        #expect(ZWave.describe([0x70, 0x06, 0x0D, 0x02, 0xFF, 0x38]).summary == "Einstellung 13 = -200")
        #expect(ZWave.describe([0x9C, 0x02, 0x00, 0x01, 0xFF]).summary == "Rauchmelder: Alarm!")
        // Sensortyp 0xFF: vorher `UInt8 + 1` → Absturz per Funk (Review 05.11.2026).
        #expect(ZWave.describe([0x9C, 0x02, 0x00, 0xFF, 0x01]).summary == "Alarm: Alarm!")
        #expect(ZWave.describe([0x30, 0x03, 0xFF, 0x0C]).summary == "Bewegungsmelder: ausgelöst")
        #expect(ZWave.describe([0x35, 0x05, 0x00, 0x01, 0x00, 0x00]).values.first?.value == 65_536)
        #expect(ZWave.describe([0x85, 0x03, 0x01, 0x05, 0x00, 0x01, 0x0F]).summary == "Zuordnung Gruppe 1: Knoten 1, 15")
        let info = ZWave.describe([0x01, 0x01, 0xD3, 0x9C, 0x01, 0x04, 0x10, 0x01, 0x5E, 0x25, 0x86, 0xEF, 0x20])
        #expect(info.fields.contains { $0.name == "Klassen" && $0.value == "Z-Wave Plus, Binärschalter, Version" })
    }

    @Test("Homematic: Wandthermostat „10 0B“, Thermostat-Gruppe, Batteriebit der Bestätigung")
    func homematicWallThermostat() throws {
        func frame(_ type: UInt8, _ payload: [UInt8]) throws -> SmartHomeFrame {
            try #require(Homematic.parse(enc: Homematic.scramble(SmartHomeTestFrames.homematic(
                counter: 9, flags: 0x86, type: type, source: [0x33, 0x44, 0x55], target: [0, 0, 0], payload: payload))))
        }
        // Soll 21 °C (42 << 10), Ist 21,5 °C (215), 2,9 V (14) + schwach, Boost 10 min.
        let word = 42 << 10 | 215
        let wall = try frame(0x10, [0x0B, UInt8(word >> 8), UInt8(word & 0xFF), 0x80 | 14, 0xC0 | 10])
        #expect(wall.summary == "21.5 °C, Soll 21.0 °C, Boost (10 min), Batterie schwach")
        #expect(wall.values.contains(SmartHomeValue(name: "Batterie", unit: "V", value: 2.9)))
        #expect(wall.deviceType == "Wandthermostat")
        // −3,2 °C: Vorzeichen in Bit 9.
        let cold = 34 << 10 | 0x200 | 32
        #expect(try frame(0x10, [0x0B, UInt8(cold >> 8), UInt8(cold & 0xFF), 14, 0x40]).values.first?.value == -3.2)
        #expect(try frame(0x59, [168 | 1]).summary == "Gruppe: Soll 21.0 °C, manuell")
        #expect(try frame(0x02, [0x01, 0x01, 0xC8, 0x80]).summary == "Bestätigung, Kanal 1: ein, Batterie schwach")
    }

    @Test("Homematic: Sensorereignis je nach gelerntem Modell (Rauch, Wasser, Bewegung)")
    func homematicSensorKinds() throws {
        func event(_ payload: [UInt8], models: [String: UInt16] = [:]) throws -> SmartHomeFrame {
            try #require(Homematic.parse(enc: Homematic.scramble(SmartHomeTestFrames.homematic(
                counter: 7, flags: 0x84, type: 0x41, source: [0x11, 0x22, 0x33], target: [0, 0, 0], payload: payload)),
                models: models))
        }
        // Geräteinfo des Rauchmelders HM-Sec-SD → Modell lernbar.
        let info = try #require(Homematic.parse(enc: Homematic.scramble(SmartHomeTestFrames.homematic(
            counter: 1, flags: 0x84, type: 0x00, source: [0x11, 0x22, 0x33], target: [0, 0, 0],
            payload: [0x10, 0x00, 0x42] + Array("KEQ0123456".utf8) + [0x20, 0x01, 0x00]))))
        #expect(info.deviceType == "HM-Sec-SD")
        #expect(Homematic.model(in: info) == 0x0042)
        let smoke = try event([0x01, 0x05, 0xC8], models: ["112233": 0x0042])
        #expect(smoke.summary == "Rauchalarm!")
        #expect(smoke.values == [SmartHomeValue(name: "Rauch", unit: "", value: 1)])
        #expect(try event([0x01, 0x06, 0x01], models: ["112233": 0x0042]).summary == "Kein Rauch")
        #expect(try event([0x01, 0x06, 0xC7], models: ["112233": 0x0042]).summary == "Alarmton aus")
        let water = try event([0x01, 0x05, 0x64], models: ["112233": 0x0045])
        #expect(water.summary == "Kanal 1: feucht")
        #expect(water.deviceType == "Wassermelder")
        #expect(!water.deviceTypeGuessed)
        // Ohne Modell: drei Bytes = vermutlich Fensterkontakt, vier = Bewegungsmelder.
        let contact = try event([0x81, 0x05, 0x00])
        #expect(contact.summary == "Kanal 1: geschlossen, Batterie schwach")
        #expect(contact.deviceTypeGuessed)
        let motion = try event([0x01, 0x2A, 0x37, 0x40])
        #expect(motion.summary == "Bewegung (Nr. 42), Helligkeit 55, nächste Meldung frühestens in 15 s")
        #expect(motion.deviceType == "Bewegungsmelder")
        #expect(motion.values.contains(SmartHomeValue(name: "Helligkeit", unit: "", value: 55)))
        // Kein Geräteinfo-Rahmen → kein Modell.
        #expect(Homematic.model(in: smoke) == nil)
    }

    // MARK: - EnOcean

    @Test("EnOcean: 8-aus-12-Kodierung hin und zurück")
    func enocean8of12() {
        let telegram = SmartHomeTestFrames.enocean(rorg: 0xF6, data: [0x30], sender: 0x0029ABCD, status: 0x30)
        let bits = EnOcean.encode8of12(telegram)
        #expect(EnOcean.decode8of12(bits, from: EnOcean.syncBits.count) == telegram)
    }

    @Test("EnOcean: Taster, Kontakt, Temperatur, Feuchte, Anlernen")
    func enoceanProfiles() throws {
        let rocker = try #require(EnOcean.parse(SmartHomeTestFrames.enocean(rorg: 0xF6, data: [0x30], sender: 0x0029ABCD, status: 0x30)))
        #expect(rocker.address == "0029ABCD")
        #expect(rocker.summary == "Taste A0 gedrückt")
        let contact = try #require(EnOcean.parse(SmartHomeTestFrames.enocean(rorg: 0xD5, data: [0x08], sender: 1, status: 0)))
        #expect(contact.summary == "Kontakt offen")
        // A5-02-05: 0 … 40 °C, DB1 = 255 − T·255/40; DB1 = 0x80 → 19,9 °C
        let temp = try #require(EnOcean.parse(SmartHomeTestFrames.enocean(rorg: 0xA5, data: [0, 0, 0x80, 0x08], sender: 2, status: 0)))
        #expect(temp.values == [SmartHomeValue(name: "Temperatur", unit: "°C", value: 19.9)])
        // A5-04-01: DB2 Feuchte 0 … 250 → 0 … 100 %, DB1 Temperatur 0 … 250 → 0 … 40 °C
        let humid = try #require(EnOcean.parse(SmartHomeTestFrames.enocean(rorg: 0xA5, data: [0, 125, 125, 0x0A], sender: 3, status: 0), eep: "A5-04-01"))
        #expect(humid.values == [SmartHomeValue(name: "Temperatur", unit: "°C", value: 20),
                                 SmartHomeValue(name: "Luftfeuchte", unit: "%", value: 50)])
        // Anlernen A5-02-05, Hersteller 0x00B
        let teach = try #require(EnOcean.parse(SmartHomeTestFrames.enocean(rorg: 0xA5, data: [0x08, 0x28, 0x0B, 0x80], sender: 4, status: 0)))
        #expect(teach.fields.contains { $0.name == "EEP" && $0.value == "A5-02-05" })
    }

    @Test("EnOcean im invertierten Bitstrom mit CRC-Prüfung")
    func enoceanBits() {
        let telegram = SmartHomeTestFrames.enocean(rorg: 0xA5, data: [0, 0, 0x40, 0x08], sender: 0x01A2B3C4, status: 0)
        let logical = [1, 1, 1] + EnOcean.encode8of12(telegram) + [1, 1]
        let air = logical.map { UInt8($0) ^ 1 }       // Träger an = 0
        let frames = EnOcean.frames(inBits: air)
        #expect(frames.count == 1)
        #expect(frames.first?.address == "01A2B3C4")
        var broken = telegram
        broken[3] ^= 0x01
        #expect(EnOcean.frames(inBits: EnOcean.encode8of12(broken).map { $0 ^ 1 }).isEmpty)
    }

    // MARK: - Robustheit

    @Test("Zufällige Bytes bringen keinen Parser zum Absturz")
    func fuzz() {
        var rng = ParserFuzzTests.FuzzRNG(seed: 868)
        for _ in 0..<3000 {
            let n = Int.random(in: 0...300, using: &rng)
            let bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = ZWave.parse(bytes, rate: .r2)
            _ = ZWave.parse(bytes, rate: .r3)
            _ = ZWave.describe(bytes)
            _ = Homematic.parse(enc: bytes)
            _ = EnOcean.parse(bytes)
            _ = WMBus.parse(bytes, mode: "T1", keys: ["12345678": SmartHomeTestFrames.omsKey])
            _ = WMBus.parseRecords(bytes)
            _ = WMBus.stripFormatA(bytes)
            _ = WMBus.stripFormatB(bytes)
        }
        // Mutierte gültige Rahmen
        for _ in 0..<2000 {
            var oms = SmartHomeTestFrames.omsExample
            oms[Int.random(in: 10..<oms.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            _ = WMBus.parse(oms, mode: "T1", keys: ["12345678": SmartHomeTestFrames.omsKey])
        }
    }
}
