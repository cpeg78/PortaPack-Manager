import Foundation
import Testing
@testable import PortaPackManager

@Suite("LoRaWAN")
struct LoRaWANTests {
    static func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { i in
            let start = s.index(s.startIndex, offsetBy: i)
            return UInt8(s[start..<s.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    @Test("AES-CMAC gegen die NIST-Vektoren (SP 800-38B)")
    func cmac() {
        let key = Self.hex("2b7e151628aed2a6abf7158809cf4f3c")
        #expect(LoRaWANCrypto.cmac(key: key, []) == Self.hex("bb1d6929e95937287fa37d129b756746"))
        let m16 = Self.hex("6bc1bee22e409f96e93d7e117393172a")
        #expect(LoRaWANCrypto.cmac(key: key, m16) == Self.hex("070a16b46b4d4144f79bdd9dd04a287c"))
        let m40 = Self.hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411")
        #expect(LoRaWANCrypto.cmac(key: key, m40) == Self.hex("dfa66747de9ae63030ca32611497c827"))
    }

    @Test("Datenrahmen: Nutzlast entschlüsseln und MIC prüfen (Roundtrip)")
    func dataFrame() throws {
        let nwkSKey = Self.hex("00112233445566778899aabbccddeeff")
        let appSKey = Self.hex("0f0e0d0c0b0a09080706050403020100")
        let devAddr: UInt32 = 0x26011BDA
        let fCnt: UInt32 = 42
        let app: [UInt8] = Array("Hallo LoRa".utf8)
        // Uplink bauen: MHDR (unconfirmed up = 0x40), FHDR, FPort 1, verschlüsselte Nutzlast, MIC.
        let fhdr: [UInt8] = [0x40] + LoRaWANCrypto.le32(devAddr) + [0x00, UInt8(fCnt & 0xFF), UInt8(fCnt >> 8)]
        let encrypted = LoRaWANCrypto.cryptPayload(key: appSKey, devAddr: devAddr, fCnt: fCnt, dir: 0, app)
        let msg = fhdr + [0x01] + encrypted
        let mic = LoRaWANCrypto.dataMIC(nwkSKey: nwkSKey, devAddr: devAddr, fCnt: fCnt, dir: 0, msg: msg)
        let phy = msg + mic

        let session = LoRaWANSession(devAddr: devAddr, nwkSKey: nwkSKey, appSKey: appSKey, label: "Sensor")
        let frame = try #require(LoRaWANParser.parse(phy, sessions: [devAddr: session]))
        #expect(frame.mType == .unconfirmedUp)
        #expect(frame.devAddr == devAddr && frame.fCnt == UInt16(fCnt) && frame.fPort == 1)
        #expect(frame.micValid == true)
        #expect(frame.decrypted == app)
        // Ohne Schlüssel: Kopf lesbar, Nutzlast verschlüsselt.
        let locked = try #require(LoRaWANParser.parse(phy, sessions: [:]))
        #expect(locked.decrypted == nil && locked.micValid == nil && locked.devAddr == devAddr)
        // Falscher NwkSKey: MIC schlägt fehl.
        var wrong = session; wrong.nwkSKey[0] ^= 1
        #expect(LoRaWANParser.parse(phy, sessions: [devAddr: wrong])?.micValid == false)
        // … und dann wird auch nichts „entschlüsselt“ (wäre Müll).
        #expect(LoRaWANParser.parse(phy, sessions: [devAddr: wrong])?.decrypted == nil)
    }

    @Test("Zähler über 65 535: obere 16 Bit je Gerät fortgeführt, MIC und Nutzlast stimmen")
    func fullFrameCounter() throws {
        let nwkSKey = Self.hex("00112233445566778899aabbccddeeff")
        let appSKey = Self.hex("0f0e0d0c0b0a09080706050403020100")
        let devAddr: UInt32 = 0x26011BDA
        let app: [UInt8] = Array("Zähler".utf8)
        func uplink(_ fCnt: UInt32) -> [UInt8] {
            let fhdr: [UInt8] = [0x40] + LoRaWANCrypto.le32(devAddr) + [0x00, UInt8(fCnt & 0xFF), UInt8((fCnt >> 8) & 0xFF)]
            let msg = fhdr + [0x01] + LoRaWANCrypto.cryptPayload(key: appSKey, devAddr: devAddr, fCnt: fCnt, dir: 0, app)
            return msg + LoRaWANCrypto.dataMIC(nwkSKey: nwkSKey, devAddr: devAddr, fCnt: fCnt, dir: 0, msg: msg)
        }
        let sessions = [devAddr: LoRaWANSession(devAddr: devAddr, nwkSKey: nwkSKey, appSKey: appSKey)]
        let key = LoRaWANParser.counterKey(devAddr: devAddr, uplink: true)
        // Ohne Vorgeschichte geht ein Rahmen mit FCnt 65 540 nicht auf – und liefert keine Nutzlast.
        let unknown = try #require(LoRaWANParser.parse(uplink(65_540), sessions: sessions))
        #expect(unknown.micValid == false && unknown.decrypted == nil)
        // Mit dem letzten vollen Zähler (gleiche Stufe) und über den 16-Bit-Überlauf hinweg.
        let same = try #require(LoRaWANParser.parse(uplink(65_540), sessions: sessions, counters: [key: 65_537]))
        #expect(same.micValid == true && same.fullFCnt == 65_540 && same.decrypted == app)
        let wrapped = try #require(LoRaWANParser.parse(uplink(131_073), sessions: sessions, counters: [key: 131_070]))
        #expect(wrapped.fullFCnt == 131_073 && wrapped.decrypted == app)
        let crossed = try #require(LoRaWANParser.parse(uplink(131_074), sessions: sessions, counters: [key: 131_000 - 66_000]))
        #expect(crossed.micValid == false)   // zu weit gesprungen – nicht geraten
        let overflow = try #require(LoRaWANParser.parse(uplink(0x2_0001), sessions: sessions, counters: [key: 0x1_FFF0]))
        #expect(overflow.fullFCnt == 0x2_0001 && overflow.decrypted == app)
        // Gerät neu gestartet: Zähler beginnt wieder bei 0.
        let restarted = try #require(LoRaWANParser.parse(uplink(3), sessions: sessions, counters: [key: 70_000]))
        #expect(restarted.fullFCnt == 3)
    }

    @Test("MAC-Befehle (DevStatusAns, LinkCheckReq), Flags, Cayenne LPP")
    func macAndCayenne() {
        // Aufwärts: DevStatusAns Batterie 128, Reserve −5 dB (6 Bit), dann LinkCheckReq.
        let commands = LoRaWANMAC.parse([0x06, 128, 0x3B, 0x02], uplink: true)
        #expect(commands.count == 2)
        #expect(commands[0].battery == 128 && commands[0].margin == -5)
        #expect(commands[1].cid == 0x02)
        #expect(LoRaWANMAC.parse([0x06, 0, 0x0A], uplink: true)[0].text == "Gerätestatus: Netzbetrieb, Reserve 10 dB")
        // Unbekannte Kennung bricht ab, statt Unsinn zu lesen.
        #expect(LoRaWANMAC.parse([0x7F, 1, 2], uplink: true).map(\.cid) == [0x7F])
        // Cayenne: Kanal 1 Temperatur 27,2 °C, Kanal 2 Feuchte 50 %, Kanal 3 Luftdruck 1013,2 hPa.
        #expect(CayenneLPP.decode([0x01, 103, 0x01, 0x10, 0x02, 104, 100, 0x03, 115, 0x27, 0x94])
                == ["K1: 27.2 °C", "K2: 50.0 %", "K3: 1013.2 hPa"])
        #expect(CayenneLPP.decode([0x01, 103, 0x01]) == nil)              // abgeschnitten
        #expect(CayenneLPP.decode([0x01, 0xEE, 0x00, 0x00]) == nil)       // unbekannter Typ
    }

    @Test("Join-Request: EUIs und DevNonce")
    func joinRequest() throws {
        let joinEUI: UInt64 = 0x70B3D57ED0012345
        let devEUI: UInt64 = 0x0004A30B001C0530
        var phy: [UInt8] = [0x00]
        phy += (0..<8).map { UInt8(joinEUI >> UInt64(8 * $0) & 0xFF) }
        phy += (0..<8).map { UInt8(devEUI >> UInt64(8 * $0) & 0xFF) }
        phy += [0x34, 0x12]                     // DevNonce
        phy += [0, 0, 0, 0]                      // MIC (hier nicht geprüft)
        let frame = try #require(LoRaWANParser.parse(phy, sessions: [:]))
        #expect(frame.mType == .joinRequest)
        #expect(frame.joinEUI == joinEUI && frame.devEUI == devEUI && frame.devNonce == 0x1234)
    }

    @Test("Rahmen über 255 Byte werden abgelehnt, statt in der MIC-Länge zu trappen (Review 05.11.2026)")
    func oversizedFrame() {
        let devAddr: UInt32 = 0x2601_1BDA
        let session = LoRaWANSession(devAddr: devAddr, nwkSKey: Array(0..<16), appSKey: Array(16..<32), label: nil)
        let phy: [UInt8] = [0x40, 0xDA, 0x1B, 0x01, 0x26, 0x00, 0x01, 0x00, 0x01] + [UInt8](repeating: 0, count: 300)
        #expect(LoRaWANParser.parse(phy, sessions: [devAddr: session]) == nil)
        #expect(LoRaWANParser.parse(Array(phy.prefix(255)), sessions: [devAddr: session]) != nil)
    }
}
