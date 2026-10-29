import CommonCrypto
import Foundation

/// LoRaWAN-MAC-Schicht über dem LoRa-PHY (`LoRaDemodulator`): Rahmen zerlegen,
/// mit den Sitzungsschlüsseln entschlüsseln (nur eigene Geräte) und die MIC
/// prüfen. PHY: expliziter Kopf, CR 4/5, Sync-Wort 0x34, CRC an – alles
/// bereits im Demodulator. Krypto nach LoRaWAN 1.0.x: AES-128, CMAC für die
/// MIC, zählergestützte Verschlüsselung der Nutzlast. Join-Accept (OTAA)
/// wird mit dem AppKey entschlüsselt und daraus die Sitzungsschlüssel abgeleitet.
enum LoRaWANCrypto {
    /// AES-128 ein Block (ECB), über `CCMStar.aes`.
    static func aes(_ key: [UInt8], _ block: [UInt8]) -> [UInt8] { CCMStar.aes(key, block) }

    /// AES-CMAC (NIST SP 800-38B). Unterschlüssel K1/K2 aus E(0), dann CBC-MAC
    /// mit XOR des letzten (ggf. aufgefüllten) Blocks.
    static func cmac(key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        let zero = [UInt8](repeating: 0, count: 16)
        let l = aes(key, zero)
        func shiftLeft(_ input: [UInt8]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 16)
            var carry: UInt8 = 0
            for i in stride(from: 15, through: 0, by: -1) {
                out[i] = input[i] << 1 | carry
                carry = input[i] >> 7
            }
            return out
        }
        var k1 = shiftLeft(l)
        if l[0] & 0x80 != 0 { k1[15] ^= 0x87 }
        var k2 = shiftLeft(k1)
        if k1[0] & 0x80 != 0 { k2[15] ^= 0x87 }

        let blockCount = (message.count + 15) / 16
        var lastBlock: [UInt8]
        let complete = message.count > 0 && message.count % 16 == 0
        if complete {
            lastBlock = Array(message[(16 * (blockCount - 1))...])
            for i in 0..<16 { lastBlock[i] ^= k1[i] }
        } else {
            let start = 16 * max(0, blockCount - 1)
            var padded = Array(message[start...])
            padded.append(0x80)
            while padded.count < 16 { padded.append(0) }
            for i in 0..<16 { padded[i] ^= k2[i] }
            lastBlock = padded
        }
        var x = zero
        let fullBlocks = complete ? blockCount - 1 : max(0, blockCount - 1)
        for b in 0..<fullBlocks {
            let block = Array(message[(16 * b)..<(16 * b + 16)])
            x = aes(key, zip(x, block).map(^))
        }
        return aes(key, zip(x, lastBlock).map(^))
    }

    /// Verschlüsselt/entschlüsselt FRMPayload (symmetrisch): Ai-Blöcke
    /// verschlüsseln und XOR. `dir` 0 = uplink, 1 = downlink.
    static func cryptPayload(key: [UInt8], devAddr: UInt32, fCnt: UInt32, dir: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: payload.count)
        var block = 0
        while block * 16 < payload.count {
            let i = UInt8(block + 1)
            let a: [UInt8] = [0x01, 0, 0, 0, 0, dir] + le32(devAddr) + le32(fCnt) + [0x00, i]
            let s = aes(key, a)
            for k in 0..<min(16, payload.count - block * 16) { out[block * 16 + k] = payload[block * 16 + k] ^ s[k] }
            block += 1
        }
        return out
    }

    /// MIC eines Datenrahmens: CMAC(NwkSKey, B0 ‖ msg)[0..<4]. `msg` ist der
    /// PHYPayload ohne die MIC (MHDR ‖ FHDR ‖ FPort ‖ FRMPayload).
    static func dataMIC(nwkSKey: [UInt8], devAddr: UInt32, fCnt: UInt32, dir: UInt8, msg: [UInt8]) -> [UInt8] {
        let b0: [UInt8] = [0x49, 0, 0, 0, 0, dir] + le32(devAddr) + le32(fCnt) + [0x00, UInt8(msg.count)]
        return Array(cmac(key: nwkSKey, b0 + msg).prefix(4))
    }

    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * UInt32($0)) & 0xFF) } }
}

/// Ein zerlegter LoRaWAN-Rahmen.
struct LoRaWANFrame: Sendable, Equatable {
    enum MType: Int, Sendable {
        case joinRequest = 0, joinAccept = 1, unconfirmedUp = 2, unconfirmedDown = 3,
             confirmedUp = 4, confirmedDown = 5, rejoinRequest = 6, proprietary = 7
        var name: String {
            switch self {
            case .joinRequest: "Join-Request"
            case .joinAccept: "Join-Accept"
            case .unconfirmedUp: String(localized: "Daten ↑")
            case .unconfirmedDown: String(localized: "Daten ↓")
            case .confirmedUp: String(localized: "Daten ↑ (bestätigt)")
            case .confirmedDown: String(localized: "Daten ↓ (bestätigt)")
            case .rejoinRequest: "Rejoin-Request"
            case .proprietary: String(localized: "herstellerspezifisch")
            }
        }
        var isUplink: Bool { self == .joinRequest || self == .unconfirmedUp || self == .confirmedUp || self == .rejoinRequest }
    }

    var mType: MType
    var devAddr: UInt32?
    var fCnt: UInt16?
    var fPort: UInt8?
    var adr: Bool
    var ack: Bool
    var framePending: Bool
    /// Entschlüsselte Anwendungsnutzlast, falls Schlüssel passten.
    var decrypted: [UInt8]?
    var micValid: Bool?
    var fOpts: [UInt8]
    /// Join-Request: AppEUI, DevEUI, DevNonce.
    var joinEUI: UInt64?
    var devEUI: UInt64?
    var devNonce: UInt16?

    var summary: String {
        var parts = [mType.name]
        if let devAddr { parts.append(String(format: "DevAddr %08X", devAddr)) }
        if let devEUI { parts.append(String(format: "DevEUI %016llX", devEUI)) }
        if let fCnt { parts.append("FCnt \(fCnt)") }
        if let fPort { parts.append("Port \(fPort)") }
        if let decrypted { parts.append("\(decrypted.count) B: " + decrypted.map { String(format: "%02X", $0) }.joined()) }
        else if mType == .unconfirmedUp || mType == .confirmedUp || mType == .unconfirmedDown || mType == .confirmedDown {
            parts.append(String(localized: "verschlüsselt"))
        }
        if micValid == false { parts.append(String(localized: "Prüfcode (MIC) falsch")) }
        return parts.joined(separator: " · ")
    }
}

/// Sitzungsschlüssel eines Geräts (ABP oder nach OTAA-Join).
struct LoRaWANSession: Codable, Sendable, Equatable {
    var devAddr: UInt32
    var nwkSKey: [UInt8]
    var appSKey: [UInt8]
    var label: String?
}

enum LoRaWANParser {
    /// Zerlegt einen PHYPayload und entschlüsselt ihn mit passenden Sitzungen.
    static func parse(_ phy: [UInt8], sessions: [UInt32: LoRaWANSession]) -> LoRaWANFrame? {
        guard phy.count >= 5, let mType = LoRaWANFrame.MType(rawValue: Int(phy[0] >> 5)) else { return nil }
        if mType == .joinRequest || mType == .rejoinRequest {
            guard phy.count >= 23 else { return nil }
            let joinEUI = le64(phy, 1), devEUI = le64(phy, 9)
            let devNonce = UInt16(phy[17]) | UInt16(phy[18]) << 8
            return LoRaWANFrame(mType: mType, adr: false, ack: false, framePending: false,
                                fOpts: [], joinEUI: joinEUI, devEUI: devEUI, devNonce: devNonce)
        }
        guard mType == .unconfirmedUp || mType == .confirmedUp || mType == .unconfirmedDown || mType == .confirmedDown,
              phy.count >= 12 else {
            return LoRaWANFrame(mType: mType, adr: false, ack: false, framePending: false, fOpts: [])
        }
        let devAddr = UInt32(phy[1]) | UInt32(phy[2]) << 8 | UInt32(phy[3]) << 16 | UInt32(phy[4]) << 24
        let fCtrl = phy[5]
        let fOptsLen = Int(fCtrl & 0x0F)
        let fCnt = UInt16(phy[6]) | UInt16(phy[7]) << 8
        guard phy.count >= 8 + fOptsLen + 4 else { return nil }
        let fOpts = Array(phy[8..<(8 + fOptsLen)])
        let afterFHDR = 8 + fOptsLen
        let dir: UInt8 = mType.isUplink ? 0 : 1
        var frame = LoRaWANFrame(mType: mType, devAddr: devAddr, fCnt: fCnt,
                                 adr: fCtrl & 0x80 != 0, ack: fCtrl & 0x20 != 0, framePending: fCtrl & 0x10 != 0,
                                 fOpts: fOpts)
        let micStart = phy.count - 4
        var fPort: UInt8?
        var frmPayload: [UInt8] = []
        if afterFHDR < micStart {
            fPort = phy[afterFHDR]
            frmPayload = Array(phy[(afterFHDR + 1)..<micStart])
        }
        frame.fPort = fPort
        if let session = sessions[devAddr] {
            let fullCnt = UInt32(fCnt)   // nur die unteren 16 Bit bekannt
            let mic = LoRaWANCrypto.dataMIC(nwkSKey: session.nwkSKey, devAddr: devAddr, fCnt: fullCnt, dir: dir,
                                            msg: Array(phy[..<micStart]))
            frame.micValid = mic == Array(phy[micStart...])
            if let fPort, !frmPayload.isEmpty {
                let key = fPort == 0 ? session.nwkSKey : session.appSKey
                frame.decrypted = LoRaWANCrypto.cryptPayload(key: key, devAddr: devAddr, fCnt: fullCnt, dir: dir, frmPayload)
            }
        }
        return frame
    }

    static func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[i + k]) << UInt64(8 * k) }
        return v
    }
}

/// Sitzungsschlüssel im Schlüsselbund (JSON).
enum LoRaWANKeyStore {
    private static let service = "de.christiangolz.portapackmanager.lorawan"
    private static let account = "sessions"

    static func load() -> [LoRaWANSession] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let list = try? JSONDecoder().decode([LoRaWANSession].self, from: data) else { return [] }
        return list
    }

    @discardableResult
    static func save(_ sessions: [LoRaWANSession]) -> OSStatus {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        guard !sessions.isEmpty else { SecItemDelete(base as CFDictionary); return errSecSuccess }
        guard let data = try? JSONEncoder().encode(sessions) else { return errSecParam }
        return KeychainBlob.save(data, query: base)
    }

    /// 32 Hex-Zeichen → 16 Byte Schlüssel; „0x“ und Trenner erlaubt.
    static func parseKey(_ text: String) -> [UInt8]? { ZigbeeSecurity.parseKey(text) }

    /// DevAddr als 8 Hex-Zeichen.
    static func parseDevAddr(_ text: String) -> UInt32? {
        let hex = text.lowercased().replacingOccurrences(of: "0x", with: "").filter { $0.isHexDigit }
        guard hex.count == 8 else { return nil }
        return UInt32(hex, radix: 16)
    }
}
