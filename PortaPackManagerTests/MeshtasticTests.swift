import Foundation
import Testing
@testable import PortaPackManager

@Suite("Meshtastic")
struct MeshtasticTests {
    private func hex(_ text: String) -> [UInt8] {
        let clean = text.filter(\.isHexDigit)
        return stride(from: 0, to: clean.count, by: 2).map {
            let start = clean.index(clean.startIndex, offsetBy: $0)
            return UInt8(clean[start..<clean.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    // MARK: - Funkparameter

    @Test("Frequenzen der EU-868-Voreinstellungen aus dem Kanal-Hash")
    func frequenzen() {
        let eu = MeshtasticRegion.eu868
        #expect(eu.slotCount(bandwidthKHz: 250) == 1)
        #expect(abs(eu.frequencyMHz(preset: .longFast, channelName: "LongFast") - 869.525) < 1e-9)
        #expect(abs(eu.frequencyMHz(preset: .mediumFast, channelName: "MediumFast") - 869.525) < 1e-9)
        // 125 kHz: zwei Plätze, djb2("LongSlow") gerade, djb2("LongMod") ungerade.
        #expect(abs(eu.frequencyMHz(preset: .longSlow, channelName: "LongSlow") - 869.4625) < 1e-9)
        #expect(abs(eu.frequencyMHz(preset: .longModerate, channelName: "LongMod") - 869.5875) < 1e-9)
        #expect(Meshtastic.djb2("LongFast") == 130_429_955)
    }

    @Test("LongFast: SF11, 250 kHz, 4/5, Sync-Wort 0x2B")
    func longFastParameter() {
        let p = MeshtasticPreset.longFast.parameters
        #expect(p.spreadingFactor == 11)
        #expect(p.bandwidth == 250_000)
        #expect(MeshtasticPreset.longFast.codingRateDenominator == 5)
        #expect(p.syncWord == 0x2B)
        #expect(p.syncSymbols == (16, 88))
    }

    // MARK: - Schlüssel und Verschlüsselung

    @Test("Kurzschlüssel AQ== wird zum Standardschlüssel")
    func standardSchluessel() throws {
        let channel = try #require(MeshtasticChannel(name: "LongFast", pskBase64: "AQ=="))
        #expect(channel.key == hex("d4f1bb3a20290759f0bcffabcf4e6901"))
        // Kanal-Hash des Standardkanals ist öffentlich bekannt: 8.
        #expect(channel.hash == 0x08)
        #expect(MeshtasticChannel(name: "x", pskBase64: "Ag==")?.key.last == 0x02)
        #expect(MeshtasticChannel(name: "x", pskBase64: "AA==")?.key.isEmpty == true)
        #expect(MeshtasticChannel(name: "x", pskBase64: "kein base64!") == nil)
    }

    @Test("AES-128-CTR nach NIST SP 800-38A F.5.1")
    func aesCTR() throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let counter = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plain = hex("""
            6bc1bee22e409f96e93d7e117393172a ae2d8a571e03ac9c9eb76fac45af8e51
            30c81c46a35ce411e5fbc1191a0a52ef f69f2445df4f9b17ad2b417be66c3710
            """)
        let cipher = hex("""
            874d6191b620e3261bef6864990db6ce 9806f66b7970fdff8617187bb9fffdff
            5ae4df3edbd5d35e5b4f09020db03eab 1e031dda2fbe03d1792170a0f3009cee
            """)
        #expect(Meshtastic.aesCTR(key: key, counter: counter, data: plain) == cipher)
        #expect(Meshtastic.aesCTR(key: key, counter: counter, data: cipher) == plain)
        // Angefangener letzter Block.
        #expect(Meshtastic.aesCTR(key: key, counter: counter, data: Array(plain.prefix(20))) == Array(cipher.prefix(20)))
    }

    @Test("Nonce: Paket-ID 64 Bit LE, Absender 32 Bit LE, Rest 0")
    func nonce() {
        #expect(Meshtastic.nonce(packetID: 0x13B2_D662, from: 0x0929)
                == hex("62d6b2130000000029090000 00000000"))
    }

    // MARK: - Paket

    /// Funkpaket aus dem Firmware-Test `test_crypto` (PKI-Direktnachricht).
    @Test("Kopf eines echten Funkpakets aus dem Firmware-Test")
    func kopfAusFirmwareTest() throws {
        let radio = hex("8c646d7a2909000062d6b2136b00000040df24abfcc30a17a3d9046726099e796a1c036a792b")
        let header = try #require(MeshtasticHeader(radio))
        #expect(header.to == 0x7A6D_648C)
        #expect(header.from == 0x0929)
        #expect(header.id == 0x13B2_D662)
        #expect(header.hopLimit == 3)
        #expect(header.wantAck)
        #expect(!header.viaMQTT)
        #expect(header.hopStart == 3)
        #expect(header.hopsTaken == 0)
        #expect(header.channelHash == 0)   // 0 = mit öffentlichem Schlüssel verschlüsselt
        // Mit dem Standardkanal nicht zu öffnen – nur der Kopf bleibt.
        let packet = try #require(Meshtastic.decode(radio, channels: [MeshtasticChannel(name: "LongFast", psk: [1])]))
        #expect(packet.data == nil)
        #expect(packet.encrypted.count == 22)
        // Der Klartext aus demselben Test: Text „test“, bitfield 0.
        let data = try #require(MeshtasticData(hex("08011204746573744800")))
        #expect(data.portnum == 1)
        #expect(data.content == .text("test"))
        #expect(data.bitfield == 0)
    }

    /// Baut ein Funkpaket wie die Firmware: Kopf + AES-CTR(Data).
    static func radioPacket(from: UInt32, id: UInt32, to: UInt32 = MeshtasticHeader.broadcast, portnum: Int,
                            payload: [UInt8], channel: MeshtasticChannel) -> [UInt8] {
        var data: [UInt8] = [0x08, UInt8(portnum)]
        data += [0x12] + varint(UInt64(payload.count)) + payload
        let encrypted = Meshtastic.aesCTR(key: channel.key, counter: Meshtastic.nonce(packetID: id, from: from), data: data)!
        func le(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> UInt32(8 * $0) & 0xFF) } }
        let flags: UInt8 = 3 << 5 | 3   // hop_start 3, hop_limit 3
        return le(to) + le(from) + le(id) + [flags, channel.hash, 0, UInt8(from & 0xFF)] + encrypted
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    @Test("Textnachricht auf dem Standardkanal ver- und entschlüsseln")
    func textRundweg() throws {
        let channel = MeshtasticChannel(name: "LongFast", psk: [1])
        let text = "Grüße aus dem Mesh 📡"
        let radio = Self.radioPacket(from: 0xA1B2_C3D4, id: 0x1234_5678, portnum: 1, payload: Array(text.utf8), channel: channel)
        let packet = try #require(Meshtastic.decode(radio, channels: [channel]))
        #expect(packet.channel == "LongFast")
        #expect(packet.data?.content == .text(text))
        #expect(packet.header.from == 0xA1B2_C3D4)
        // Verfälschter Inhalt bei passendem Hash: keine plausible Nachricht.
        let damaged = Array(radio.prefix(16)) + radio.dropFirst(16).map { $0 ^ 0x5A }
        #expect(Meshtastic.decode(damaged, channels: [channel])?.data == nil)
        // Kanal mit anderem Hash wird gar nicht erst versucht.
        #expect(Meshtastic.decode(radio, channels: [MeshtasticChannel(name: "Privat", psk: [2])])?.data == nil)
    }

    // MARK: - Protobuf

    @Test("Position von Hand kodiert")
    func position() {
        var bytes: [UInt8] = [0x0D] + withUnsafeBytes(of: Int32(525_200_000).littleEndian, Array.init)
        bytes += [0x15] + withUnsafeBytes(of: Int32(-1_340_500).littleEndian, Array.init)
        bytes += [0x18] + Self.varint(UInt64(bitPattern: Int64(-12)))   // Höhe −12 m (10-Byte-Varint)
        bytes += [0x25] + withUnsafeBytes(of: UInt32(1_760_000_000).littleEndian, Array.init)
        bytes += [0x98, 0x01, 9]                                         // sats_in_view = 9 (Feld 19)
        bytes += [0xB8, 0x01, 32]                                        // precision_bits = 32 (Feld 23)
        let p = MeshtasticPosition(bytes)
        #expect(abs((p.latitude ?? 0) - 52.52) < 1e-9)
        #expect(abs((p.longitude ?? 0) + 0.13405) < 1e-9)
        #expect(p.altitude == -12)
        #expect(p.time == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(p.satellites == 9)
        #expect(p.precisionBits == 32)
        #expect(MeshtasticContent(portnum: 3, payload: bytes).summary == "52.52000, -0.13405 · -12 m · 9 Satelliten")
    }

    @Test("Knoteninfo und Telemetrie von Hand kodiert")
    func knotenUndTelemetrie() {
        func string(_ field: UInt8, _ text: String) -> [UInt8] {
            [field << 3 | 2] + Self.varint(UInt64(text.utf8.count)) + Array(text.utf8)
        }
        let user = string(1, "!a1b2c3d4") + string(2, "Bergstation Süd") + string(3, "BSü") + [0x28, 43] + [0x38, 2]
        let u = MeshtasticUser(user)
        #expect(u.id == "!a1b2c3d4")
        #expect(u.longName == "Bergstation Süd")
        #expect(u.shortName == "BSü")
        #expect(u.hardwareName == "Heltec V3")
        #expect(u.roleName == "Router")

        let device: [UInt8] = [0x08, 87] + [0x15] + withUnsafeBytes(of: Float(4.05).bitPattern.littleEndian, Array.init)
            + [0x28] + Self.varint(90_061)
        let telemetry: [UInt8] = [0x0D, 0, 0, 0, 0] + [0x12] + Self.varint(UInt64(device.count)) + device
        let t = MeshtasticTelemetry(telemetry)
        #expect(t.kind == "Gerät")
        #expect(t.batteryLevel == 87)
        #expect(abs((t.voltage ?? 0) - 4.05) < 1e-6)
        #expect(t.uptime == 90_061)
        #expect(t.readings.contains("Akku 87 %"))

        let environment: [UInt8] = [0x0D] + withUnsafeBytes(of: Float(21.5).bitPattern.littleEndian, Array.init)
            + [0x15] + withUnsafeBytes(of: Float(48).bitPattern.littleEndian, Array.init)
        let e = MeshtasticTelemetry([0x1A] + Self.varint(UInt64(environment.count)) + environment)
        #expect(e.kind == "Umwelt")
        #expect(e.temperature == 21.5)
        #expect(e.readings == ["21.5 °C", "48 % rF"])
    }

    @Test("Abgeschnittenes Protobuf wird abgelehnt")
    func protobufKaputt() {
        #expect(ProtobufMessage([0x12, 0x05, 0x41]) == nil)
        #expect(ProtobufMessage([0x08]) == nil)
        #expect(MeshtasticData([0x08, 0x00]) == nil)   // Port 0 gibt es nicht
    }

    // MARK: - Ganzer Weg

    @Test("Meshtastic-Paket über LoRa moduliert, empfangen und entschlüsselt")
    func ganzerWeg() throws {
        let preset = MeshtasticPreset.longFast
        let channel = MeshtasticChannel(name: preset.displayName, psk: [1])
        let text = "Hallo vom HackRF"
        let radio = Self.radioPacket(from: 0xDEAD_BEEF, id: 0x0BAD_CAFE, portnum: 1, payload: Array(text.utf8), channel: channel)
        let parameters = preset.parameters
        let symbols = LoRaCoding.encode(radio, sf: parameters.spreadingFactor, codingRate: preset.codingRateDenominator - 4)
        let os = LoRaDemodulator.oversampling
        let tx = LoRaTestTransmitter(parameters: parameters)
        var (re, im) = tx.waveform(symbols: symbols, sampleRate: parameters.bandwidth * Double(os), cfoHz: -11_500,
                                   startDelay: 77_777.3, tail: 30_000)
        var noise = TestNoise(state: 3)
        for k in re.indices {
            re[k] += 0.5 * noise.gaussian()
            im[k] += 0.5 * noise.gaussian()
        }
        let demod = LoRaDemodulator(parameters: parameters, centerFrequency: 869_525_000)
        let frames = demod.process(re: re.map(Float.init), im: im.map(Float.init))
        let frame = try #require(frames.first)
        #expect(frame.crcValid == true)
        let packet = try #require(Meshtastic.decode(frame.payload, channels: [channel]))
        #expect(packet.header.id == 0x0BAD_CAFE)
        #expect(packet.data?.content == .text(text))
    }
}
