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
}
