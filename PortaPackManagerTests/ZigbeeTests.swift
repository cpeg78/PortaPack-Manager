import Foundation
import Testing
@testable import PortaPackManager

@Suite("Zigbee")
struct ZigbeeTests {
    private func bits(_ s: String) -> [UInt8] { s.map { $0 == "1" ? 1 : 0 } }
    private func hex(_ s: String) -> [UInt8] {
        s.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    @Test("Chipfolgen nach IEEE 802.15.4 Tabelle 24")
    func chipTable() {
        #expect(IEEE802154.chips[0] == bits("11011001110000110101001000101110"))
        #expect(IEEE802154.chips[1] == bits("11101101100111000011010100100010"))
        #expect(IEEE802154.chips[8] == bits("10001100100101100000011101111011"))
        #expect(IEEE802154.chips[15] == bits("11001001011000000111011110111000"))
        // Symbol s + 8 ist in MSK-Sicht das Negativ von s.
        for s in 0..<8 {
            #expect(IEEE802154.frequencySigns[s + 8] == IEEE802154.frequencySigns[s].map { -$0 })
        }
    }

    @Test("FCS ist CRC-16/KERMIT")
    func fcs() {
        #expect(IEEE802154.crc(Array("123456789".utf8)) == 0x2189)
    }

    @Test("AES-CCM: Prüfvektor 1 aus RFC 3610")
    func ccmVector() throws {
        let key = hex("C0 C1 C2 C3 C4 C5 C6 C7 C8 C9 CA CB CC CD CE CF")
        let nonce = hex("00 00 00 03 02 01 00 A0 A1 A2 A3 A4 A5")
        let aad = Array(UInt8(0)...7)
        let plain = Array(UInt8(8)...0x1E)
        let (cipher, mic) = CCMStar.encrypt(key: key, nonce: nonce, authenticated: aad, plaintext: plain, micLength: 8)
        #expect(cipher == hex("58 8C 97 9A 61 C6 63 D2 F0 66 D0 C2 C0 F9 89 80 6D 5F 6B 61 DA C3 84"))
        #expect(mic == hex("17 E8 D1 2C FD F9 26 E0"))
        #expect(CCMStar.decrypt(key: key, nonce: nonce, authenticated: aad, ciphertext: cipher, mic: mic) == plain)
        var broken = cipher
        broken[3] ^= 1
        #expect(CCMStar.decrypt(key: key, nonce: nonce, authenticated: aad, ciphertext: broken, mic: mic) == nil)
    }

    @Test("Schlüssel aus Zigbee2MQTT und als Hex")
    func keyFormats() {
        let expected: [UInt8] = [1, 3, 5, 7, 9, 11, 13, 15, 0, 2, 4, 6, 8, 10, 12, 13]
        #expect(ZigbeeSecurity.parseKey("[1, 3, 5, 7, 9, 11, 13, 15, 0, 2, 4, 6, 8, 10, 12, 13]") == expected)
        #expect(ZigbeeSecurity.parseKey("01030507090B0D0F00020406080A0C0D") == expected)
        #expect(ZigbeeSecurity.parseKey("01:03:05:07:09:0B:0D:0F:00:02:04:06:08:0A:0C:0D") == expected)
        #expect(ZigbeeSecurity.parseKey("zu kurz") == nil)
        // YAML-Block, wie er in der configuration.yaml steht (auch samt Schlüsselname).
        let yaml = "network_key:\n" + expected.map { "    - \($0)" }.joined(separator: "\n")
        #expect(ZigbeeSecurity.parseKey(yaml) == expected)
        #expect(ZigbeeSecurity.parseKey(expected.map { "- \($0)" }.joined(separator: "\n")) == expected)
        #expect(ZigbeeSecurity.parseKey((0..<16).map { _ in "- 300" }.joined(separator: "\n")) == nil)
        #expect(ZigbeeSecurity.parseKey((0..<15).map { "- \($0)" }.joined(separator: "\n")) == nil)
        // Ausschnitt aus der configuration.yaml mit weiteren Einstellungen nach dem Schlüssel.
        #expect(ZigbeeSecurity.parseKey("advanced:\n  " + yaml.replacingOccurrences(of: "\n", with: "\n  ")
                                        + "\n  pan_id: 6754\n  channel: 11") == expected)
        #expect(ZigbeeSecurity.parseKey("network_key: GENERATE") == nil)
        #expect(ZigbeeSecurity.parseKey("[1, 3, 5, 7, 9, 11, 13, 15, 0, 2, 4, 6, 8, 10, 12, 13, 99]") == nil)
    }

    @Test("ZDO: Gerätemeldung, Endpunktbeschreibung, Nachbartabelle")
    func zdo() throws {
        // Device_annce: Seq, Kurzadresse, IEEE, Fähigkeiten (Router, Netz, Empfänger an).
        let ieee: [UInt8] = [0x4D, 0x3C, 0x2B, 0x1A, 0x00, 0x4B, 0x12, 0x00]
        let announce = try #require(ZDOMessage.parse(cluster: 0x0013, [0x11, 0x34, 0x12] + ieee + [0x8E]))
        #expect(announce.announce?.nwk == 0x1234)
        #expect(announce.announce?.ieee == 0x00124B00_1A2B3C4D)
        #expect(announce.announce?.router == true && announce.announce?.mainsPowered == true)
        #expect(announce.summary.contains("Router, Netz"))

        // Simple_Desc_rsp: Endpunkt 1, HA-Profil, Temperatursensor, Eingangs-Cluster Basis + Temperatur.
        let simple = try #require(ZDOMessage.parse(cluster: 0x8004, [0x12, 0x00, 0x34, 0x12, 0x0C, 0x01, 0x04, 0x01, 0x02, 0x03, 0x01,
                                                                     0x02, 0x00, 0x00, 0x02, 0x04, 0x00]))
        #expect(simple.simpleDescriptor?.deviceName == "Temperatursensor")
        #expect(simple.simpleDescriptor?.inputClusters == [0x0000, 0x0402])
        #expect(simple.summary.hasPrefix("Endpunkt 1 von 0x1234: Temperatursensor"))

        // Fehlerstatus wird benannt, Inhalt nicht gelesen.
        let failed = try #require(ZDOMessage.parse(cluster: 0x8004, [0x12, 0x81]))
        #expect(failed.summary == "Endpunktbeschreibung: Gerät nicht gefunden")

        // Mgmt_Lqi_rsp mit einem Nachbarn (Router, Kind, LQI 200).
        var lqi: [UInt8] = [0x13, 0x00, 0x03, 0x00, 0x01]
        lqi += [UInt8](repeating: 0xAA, count: 8) + ieee + [0x01, 0x00, 0b0001_0101, 0x02, 0x01, 200]
        let table = try #require(ZDOMessage.parse(cluster: 0x8031, lqi))
        #expect(table.neighbors.count == 1)
        #expect(table.neighbors.first?.nwk == 0x0001 && table.neighbors.first?.lqi == 200)
        #expect(table.neighbors.first?.relationship == 1 && table.neighbors.first?.deviceType == 1)
    }

    @Test("Zigbee2MQTT-Dateien: configuration.yaml und database.db")
    func zigbee2mqttImport() throws {
        let yaml = """
        homeassistant: true
        advanced:
          pan_id: 6754
          channel: 25
          network_key:
            - 1
            - 3
            - 5
            - 7
            - 9
            - 11
            - 13
            - 15
            - 0
            - 2
            - 4
            - 6
            - 8
            - 10
            - 12
            - 13
          last_seen: ISO_8601
        devices:
          '0x00158d0001a2b3c4':
            friendly_name: Wohnzimmer Sensor
            retain: false
          '0x00124b001a2b3c4d':
            friendly_name: 'Flur Lampe'
        """
        let parsed = ZigbeeDirectory.parse(yaml)
        #expect(parsed.panID == 0x1A62)
        #expect(parsed.channel == 25)
        #expect(parsed.networkKeyText.flatMap(ZigbeeSecurity.parseKey) == [1, 3, 5, 7, 9, 11, 13, 15, 0, 2, 4, 6, 8, 10, 12, 13])
        #expect(parsed.devices[0x00158d0001a2b3c4]?.name == "Wohnzimmer Sensor")
        #expect(parsed.devices[0x00124b001a2b3c4d]?.name == "Flur Lampe")

        let db = """
        {"id":1,"type":"Coordinator","ieeeAddr":"0x00124b0021aabbcc","nwkAddr":0,"interviewCompleted":false}
        {"id":2,"type":"EndDevice","ieeeAddr":"0x00158d0001a2b3c4","nwkAddr":4660,"manufId":4151,"manufName":"LUMI","modelId":"lumi.weather","interviewCompleted":true}
        """
        let devices = ZigbeeDirectory.parse(db)
        #expect(devices.devices[0x00158d0001a2b3c4]?.model == "lumi.weather")
        #expect(devices.devices[0x00158d0001a2b3c4]?.manufacturer == "LUMI")
        #expect(devices.devices[0x00124b0021aabbcc]?.type == "Koordinator")
        #expect(devices.panID == nil && devices.networkKeyText == nil)
    }

    @Test("PCAP: Kopf mit Linktyp 195, Rahmen mit FCS")
    func pcap() {
        let mpdu: [UInt8] = [0x61, 0x88, 0x2A, 0x62, 0x1A, 0x00, 0x00, 0x34, 0x12, 0x08]
        let frame = ZigbeeRadioFrame(channel: 11, mpdu: mpdu, rssiDB: -50, offsetKHz: 0, date: Date(timeIntervalSince1970: 1_700_000_000.5))
        let data = [UInt8](ZigbeePCAP.data([frame]))
        #expect(Array(data.prefix(4)) == [0xD4, 0xC3, 0xB2, 0xA1])
        #expect(Array(data[20..<24]) == [195, 0, 0, 0])
        #expect(Array(data[24..<28]) == [0x00, 0xF1, 0x53, 0x65])      // 1 700 000 000 = 0x6553F100, little-endian
        #expect(Array(data[32..<36]) == [12, 0, 0, 0])
        #expect(Array(data.suffix(12)) == IEEE802154.withFCS(mpdu))
    }

    @Test("ZCL: Tuya-Datenpunkte und Xiaomi-Herstellerattribut")
    func vendorClusters() throws {
        // Tuya 0xEF00, Befehl 0x02: Folge, DP1 Wert 210 (21,0 °C), DP16 Bool ein, DP4 Batterie 87 %.
        let tuya: [UInt8] = [0x00, 0x07, 1, 2, 0, 4, 0, 0, 0, 210, 16, 1, 0, 1, 1, 4, 2, 0, 4, 0, 0, 0, 87]
        let message = try #require(ZCLMessage.parse([0x09, 0x33, 0x02] + tuya, cluster: 0xEF00))
        #expect(message.summary == "Tuya: Datenpunkte")
        #expect(message.readings == ["DP1 21.0 °C", "DP16 ein", "DP4 Batterie 87 %"])
        // Xiaomi 0xFF01 im Basis-Cluster: Tag 1 (uint16) 2916 mV, Tag 3 (int8) 25 °C, Tag 100 (int16) 2150.
        let xiaomi: [UInt8] = [0x01, 0x21, 0x64, 0x0B, 0x03, 0x28, 0x19, 0x64, 0x29, 0x66, 0x08]
        #expect(ZCL.describe(cluster: 0x0000, (0xFF01, .raw(xiaomi))) == "Batterie 2.92 V, Gerät 25 °C, 21.50 °C")
        // Als Attributbericht mit Typ 0x42 (Zeichenkette mit Binärinhalt) → Rohdaten.
        let report: [UInt8] = [0x1C, 0x5F, 0x11, 0x01, 0x0A, 0x01, 0xFF, 0x42, UInt8(xiaomi.count)] + xiaomi
        let parsed = try #require(ZCLMessage.parse(report, cluster: 0x0000))
        #expect(parsed.manufacturer == 0x115F)
        #expect(parsed.readings == ["Batterie 2.92 V, Gerät 25 °C, 21.50 °C"])
        // Ungültige Messwerte (0x8000) verschwinden, Farbtemperatur in Kelvin.
        #expect(ZCL.describe(cluster: 0x0402, (0, .int(-32768))) == nil)
        #expect(ZCL.describe(cluster: 0x0300, (0x0007, .int(370))) == "2703 K Farbtemperatur")
        #expect(ZCL.clusterCommand(cluster: 0x0300, command: 0x0A, payload: [0x9A, 0x01, 0x0A, 0x00]) == "Farbtemperatur 2439 K")
        #expect(ZCL.clusterCommand(cluster: 0x0102, command: 0x05, payload: [40]) == "Rollladen auf 40 % zu")
    }

    @Test("Netzwerkschlüssel aus dem Transport-Key gewinnen (Beitritt)")
    func recoverNetworkKey() throws {
        let tclk = ZigbeeAPSSecurity.defaultTrustCenterLinkKey
        #expect(tclk == [0x5A, 0x69, 0x67, 0x42, 0x65, 0x65, 0x41, 0x6C, 0x6C, 0x69, 0x61, 0x6E, 0x63, 0x65, 0x30, 0x39])
        // AES-MMO und keyed hash sind deterministisch und 16 Byte lang.
        let transportKeyKey = ZigbeeAPSSecurity.keyTransportKey(tclk)
        #expect(transportKeyKey.count == 16 && transportKeyKey != ZigbeeAPSSecurity.keyLoadKey(tclk))
        #expect(ZigbeeAPSSecurity.aesMMO([]).count == 16)

        let networkKey: [UInt8] = Array(0x20...0x2F)
        let trustCenter: UInt64 = 0x00124B00_AABBCCDD
        // Transport-Key-Befehl: 0x05, Typ 0x01, Schlüssel, Folge, Ziel-IEEE, Quell-IEEE.
        let command: [UInt8] = [0x05, 0x01] + networkKey + [0x00] + Array(repeating: 0, count: 8) + Array(repeating: 0xAA, count: 8)
        // APS-Kopf: Befehlsrahmen (0x01) mit Sicherheit (0x20) + Zähler.
        let apsHeader: [UInt8] = [0x21, 0x42]
        // Zusatzkopf: Steuerbyte (Key-Transport 0x10 + erweiterter Nonce 0x20), Zähler LE, Quelle LE.
        let auxControlSent: UInt8 = 0x30
        var aux: [UInt8] = [auxControlSent]
        let apsCounter: UInt32 = 0x01020304
        aux += (0..<4).map { UInt8(apsCounter >> UInt32(8 * $0) & 0xFF) }
        aux += (0..<8).map { UInt8(trustCenter >> UInt64(8 * $0) & 0xFF) }
        let authenticated = apsHeader + [auxControlSent | ZigbeeSecurity.level] + Array(aux.dropFirst())
        let nonce = ZigbeeSecurity.nonce(source: trustCenter, counter: apsCounter, control: auxControlSent | ZigbeeSecurity.level)
        let (cipher, mic) = CCMStar.encrypt(key: transportKeyKey, nonce: nonce, authenticated: authenticated, plaintext: command, micLength: 4)
        let apsFrame = apsHeader + aux + cipher + mic

        // NWK-Datenrahmen ohne Sicherheit (das beitretende Gerät hat den Schlüssel noch nicht).
        let nwk: [UInt8] = [0x08, 0x00, 0x34, 0x12, 0x00, 0x00, 30, 9] + apsFrame
        // MAC-Datenrahmen.
        let mac: [UInt8] = [0x61, 0x88, 0x2A, 0x62, 0x1A, 0x34, 0x12, 0x00, 0x00] + nwk
        let radio = ZigbeeRadioFrame(channel: 15, mpdu: mac, rssiDB: -40, offsetKHz: 0, date: Date())
        let packet = ZigbeePacket.interpret(radio, id: 1, keys: [])
        #expect(packet.recoveredKey == networkKey)
        #expect(packet.summary.contains("Transport-Key"))

        // Falscher Link-Key: kein Fund (MIC schlägt fehl).
        var wrong = tclk; wrong[0] ^= 1
        #expect(ZigbeePacket.interpret(radio, id: 2, keys: [], linkKeys: [wrong]).recoveredKey == nil)
    }

    @Test("Nonce: Adresse und Zähler little-endian, Steuerbyte zuletzt")
    func nonce() {
        let nonce = ZigbeeSecurity.nonce(source: 0xACDE_4800_0000_0001, counter: 5, control: 0x2D)
        #expect(nonce == [0x01, 0, 0, 0, 0, 0x48, 0xDE, 0xAC, 5, 0, 0, 0, 0x2D])
        #expect(ZigbeeSecurity.nonce(source: 0xACDE_4800_0000_0001, counter: 5, control: 0x2D, bigEndianAddress: true).prefix(8)
                == [0xAC, 0xDE, 0x48, 0, 0, 0, 0, 0x01])
    }

    static let key: [UInt8] = Array(0x10...0x1F)
    static let sensor: UInt64 = 0x00124B00_1A2B3C4D

    /// MAC-Datenrahmen mit verschlüsseltem NWK-Rahmen: Temperaturbericht 21,50 °C.
    static func temperatureFrame(counter: UInt32 = 0x0102_0304) -> [UInt8] {
        var mac: [UInt8] = [0x61, 0x88, 0x2A, 0x62, 0x1A, 0x00, 0x00, 0x34, 0x12]
        let ieee = (0..<8).map { UInt8(sensor >> UInt64(8 * $0) & 0xFF) }
        var nwk: [UInt8] = [0x08, 0x12, 0x00, 0x00, 0x34, 0x12, 30, 7] + ieee
        let control: UInt8 = 0x28
        nwk += [control] + (0..<4).map { UInt8(counter >> UInt32(8 * $0) & 0xFF) } + ieee + [0]
        let aps: [UInt8] = [0x40, 0x01, 0x02, 0x04, 0x04, 0x01, 0x01, 0x05]
        let zcl: [UInt8] = [0x18, 0x01, 0x0A, 0x00, 0x00, 0x29, 0x66, 0x08]
        var authenticated = nwk
        authenticated[nwk.count - 14] = control | ZigbeeSecurity.level
        let nonce = ZigbeeSecurity.nonce(source: sensor, counter: counter, control: control | ZigbeeSecurity.level)
        let (cipher, mic) = CCMStar.encrypt(key: key, nonce: nonce, authenticated: authenticated,
                                            plaintext: aps + zcl, micLength: 4)
        mac += nwk + cipher + mic
        return mac
    }

    @Test("Rahmenauswertung mit Schlüssel: NWK, APS, ZCL-Temperatur")
    func interpretation() throws {
        let radio = ZigbeeRadioFrame(channel: 15, mpdu: Self.temperatureFrame(), rssiDB: -40, offsetKHz: 0, date: Date())
        let clear = ZigbeePacket.interpret(radio, id: 1, key: Self.key)
        #expect(clear.mac?.pan == 0x1A62)
        #expect(clear.nwk?.source == 0x1234)
        #expect(clear.nwk?.securityHeader?.source == Self.sensor)
        #expect(clear.aps?.cluster == 0x0402)
        #expect(clear.zcl?.readings == ["21.50 °C"])
        let locked = ZigbeePacket.interpret(radio, id: 2, key: nil)
        #expect(locked.encrypted && locked.zcl == nil)
        var wrongKey = Self.key
        wrongKey[0] ^= 1
        #expect(ZigbeePacket.interpret(radio, id: 3, key: wrongKey).decrypted == nil)
        // Mehrere Netze: der passende Schlüssel darf an beliebiger Stelle stehen.
        let second = ZigbeePacket.interpret(radio, id: 4, keys: [wrongKey, Self.key])
        #expect(second.decrypted != nil && second.keyIndex == 1)
        #expect(ZigbeePacket.interpret(radio, id: 5, keys: [wrongKey, wrongKey]).keyIndex == nil)
    }

    /// Basisband bei 8 MS/s (4 Werte je Chip) mit Ablage und Rauschen.
    private func signal(_ psdu: [UInt8], offsetHz: Double, noise: Float, invert: Bool = false, lead: Int = 3000) -> ([Float], [Float]) {
        let (re, im) = IEEE802154.modulate(symbols: IEEE802154.symbols(psdu: psdu), samplesPerChip: 4)
        var rng = TestSignals.Noise(state: 9)
        let total = lead + re.count + 3000
        var outRe = [Float](repeating: 0, count: total), outIm = [Float](repeating: 0, count: total)
        for n in 0..<total {
            var i: Float = 0, q: Float = 0
            let k = n - lead
            if k >= 0, k < re.count {
                let phase = 2 * Double.pi * offsetHz * Double(n) / ZigbeeDemodulator.inputRate
                let c = Float(cos(phase)), s = Float(sin(phase))
                let qq = invert ? -im[k] : im[k]
                i = 0.3 * (re[k] * c - qq * s)
                q = 0.3 * (re[k] * s + qq * c)
            }
            outRe[n] = i + noise * Float(rng.gaussian())
            outIm[n] = q + noise * Float(rng.gaussian())
        }
        return (outRe, outIm)
    }

    private func receive(_ re: [Float], _ im: [Float]) -> [ZigbeeRadioFrame] {
        let demod = ZigbeeDemodulator()
        var frames: [ZigbeeRadioFrame] = []
        for start in stride(from: 0, to: re.count, by: 50_000) {
            let end = min(start + 50_000, re.count)
            frames += demod.processBaseband(re: Array(re[start..<end]), im: Array(im[start..<end]), channel: 15)
        }
        return frames
    }

    @Test("Funk: O-QPSK mit 60 kHz Ablage und Rauschen", arguments: [false, true])
    func overTheAir(invert: Bool) throws {
        let psdu = IEEE802154.withFCS(Self.temperatureFrame())
        let (re, im) = signal(psdu, offsetHz: 60_000, noise: 0.04, invert: invert)
        let frames = receive(re, im)
        #expect(frames.count == 1)
        let frame = try #require(frames.first)
        #expect(frame.mpdu == Self.temperatureFrame())
        #expect(abs(frame.offsetKHz - 60) < 15)
        #expect(ZigbeePacket.interpret(frame, id: 1, key: Self.key).zcl?.readings == ["21.50 °C"])
    }

    @Test("Mehrere Rahmen hintereinander, kurze Quittung dazwischen")
    func sequence() {
        let ack = IEEE802154.withFCS([0x02, 0x00, 0x2A])
        let data = IEEE802154.withFCS(Self.temperatureFrame())
        let (r1, i1) = signal(data, offsetHz: -30_000, noise: 0.03)
        let (r2, i2) = signal(ack, offsetHz: 20_000, noise: 0.03, lead: 500)
        let (r3, i3) = signal(IEEE802154.withFCS(Self.temperatureFrame(counter: 9)), offsetHz: 0, noise: 0.03, lead: 500)
        let frames = receive(r1 + r2 + r3, i1 + i2 + i3)
        #expect(frames.map(\.mpdu.count) == [Self.temperatureFrame().count, 3, Self.temperatureFrame().count])
    }

    @Test("Rauschen allein ergibt keine Rahmen")
    func noiseOnly() {
        var rng = TestSignals.Noise(state: 4)
        let n = 400_000
        let re = (0..<n).map { _ in Float(0.05 * rng.gaussian()) }
        let im = (0..<n).map { _ in Float(0.05 * rng.gaussian()) }
        #expect(receive(re, im).isEmpty)
    }
}
