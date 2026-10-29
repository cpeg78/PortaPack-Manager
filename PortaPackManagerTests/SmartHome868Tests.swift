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
        // −5,0 °C: 14-Bit-Zweierkomplement
        let raw = UInt16(bitPattern: Int16(-50)) & 0x7FFF
        let cold = try #require(Homematic.parse(enc: Homematic.scramble(SmartHomeTestFrames.homematic(
            counter: 3, flags: 0x86, type: 0x70, source: [1, 2, 3], target: [0, 0, 0], payload: [UInt8(raw >> 8), UInt8(raw & 0xFF), 80]))))
        #expect(cold.values.first == SmartHomeValue(name: "Temperatur", unit: "°C", value: -5))
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
