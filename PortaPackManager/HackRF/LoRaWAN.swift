import CommonCrypto
import Foundation

/// LoRaWAN-MAC-Schicht über dem LoRa-PHY (`LoRaDemodulator`): Rahmen zerlegen,
/// mit den Sitzungsschlüsseln entschlüsseln (nur eigene Geräte) und die MIC
/// prüfen. PHY: expliziter Kopf, CR 4/5, Sync-Wort 0x34, CRC an – alles
/// bereits im Demodulator. Krypto nach LoRaWAN 1.0.x: AES-128, CMAC für die
/// MIC, zählergestützte Verschlüsselung der Nutzlast. Sitzungsschlüssel
/// trägt der Nutzer ein (ABP, oder nach einem OTAA-Join aus dem Netzserver
/// abgelesen). Den Join-Accept selbst kann die App nicht mitlesen: Er kommt
/// wie jeder Downlink mit invertiertem IQ, den `LoRaDemodulator` nicht
/// empfängt – daraus ließen sich sonst die Schlüssel mit dem AppKey ableiten.
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
    /// Voller 32-Bit-Zähler, mit dem die MIC aufging (obere 16 Bit aus dem
    /// letzten gültigen Rahmen desselben Geräts fortgeführt).
    var fullFCnt: UInt32?
    var fPort: UInt8?
    var adr: Bool
    var ack: Bool
    var framePending: Bool
    /// Entschlüsselte Anwendungsnutzlast – nur bei gültiger MIC (sonst wäre es
    /// bei gefälschten Rahmen oder falschem Zähler Müll).
    var decrypted: [UInt8]?
    var micValid: Bool?
    var fOpts: [UInt8]
    /// Join-Request: AppEUI, DevEUI, DevNonce.
    var joinEUI: UInt64?
    var devEUI: UInt64?
    var devNonce: UInt16?

    /// MAC-Befehle: in FOpts (unverschlüsselt in 1.0.x) bzw. als Nutzlast auf Port 0.
    var macCommands: [LoRaWANMAC.Command] {
        var bytes = fOpts
        if fPort == 0, let decrypted { bytes += decrypted }
        return LoRaWANMAC.parse(bytes, uplink: mType.isUplink)
    }

    /// Nutzlast als Cayenne LPP, wenn sie vollständig in dieses Format passt.
    var cayenne: [String]? {
        guard let decrypted, let fPort, fPort != 0 else { return nil }
        return CayenneLPP.decode(decrypted)
    }

    var summary: String {
        var parts = [mType.name]
        if let devAddr { parts.append(String(format: "DevAddr %08X", devAddr)) }
        if let devEUI { parts.append(String(format: "DevEUI %016llX", devEUI)) }
        if let fCnt { parts.append("FCnt \(fullFCnt ?? UInt32(fCnt))") }
        if let fPort { parts.append("Port \(fPort)") }
        if adr { parts.append("ADR") }
        if ack { parts.append(String(localized: "bestätigt")) }
        if framePending { parts.append(String(localized: "mehr Daten folgen")) }
        let commands = macCommands
        if !commands.isEmpty { parts.append(commands.map(\.text).joined(separator: ", ")) }
        if let values = cayenne { parts.append(values.joined(separator: ", ")) }
        else if let decrypted, fPort != 0 { parts.append("\(decrypted.count) B: " + decrypted.map { String(format: "%02X", $0) }.joined()) }
        else if mType == .unconfirmedUp || mType == .confirmedUp || mType == .unconfirmedDown || mType == .confirmedDown {
            parts.append(String(localized: "verschlüsselt"))
        }
        if micValid == false { parts.append(String(localized: "Prüfcode (MIC) falsch")) }
        return parts.joined(separator: " · ")
    }
}

/// MAC-Befehle nach LoRaWAN 1.0.x (Tabelle 4): Kennung (CID) und feste Länge
/// je Richtung. Ab der ersten unbekannten Kennung ist der Rest nicht lesbar.
enum LoRaWANMAC {
    struct Command: Sendable, Equatable {
        var cid: UInt8
        var text: String
        /// DevStatusAns: Batterie (0 Netz, 1–254 Stand, 255 unbekannt) und Linkreserve (dB).
        var battery: Int?
        var margin: Int?
    }

    static func parse(_ bytes: [UInt8], uplink: Bool) -> [Command] {
        var out: [Command] = []
        var i = 0
        while i < bytes.count {
            let cid = bytes[i]
            let lengths: [UInt8: Int] = uplink
                ? [0x02: 0, 0x03: 1, 0x04: 0, 0x05: 1, 0x06: 2, 0x07: 1, 0x08: 0, 0x09: 0, 0x0A: 1, 0x0D: 0]
                : [0x02: 2, 0x03: 4, 0x04: 1, 0x05: 4, 0x06: 0, 0x07: 5, 0x08: 1, 0x09: 1, 0x0A: 4, 0x0D: 5]
            guard let length = lengths[cid], i + 1 + length <= bytes.count else {
                out.append(Command(cid: cid, text: String(format: String(localized: "MAC 0x%02X …"), cid)))
                break
            }
            let p = Array(bytes[(i + 1)..<(i + 1 + length)])
            out.append(describe(cid, p, uplink: uplink))
            i += 1 + length
        }
        return out
    }

    private static func describe(_ cid: UInt8, _ p: [UInt8], uplink: Bool) -> Command {
        var c = Command(cid: cid, text: "")
        switch (uplink, cid) {
        case (true, 0x02): c.text = String(localized: "fragt Empfang ab (LinkCheck)")
        case (true, 0x03): c.text = String(localized: "Datenrate übernommen") + (p[0] & 0x07 == 0x07 ? "" : String(localized: " (teilweise)"))
        case (true, 0x06):
            c.battery = Int(p[0])
            var margin = Int(p[1] & 0x3F)
            if margin >= 32 { margin -= 64 }
            c.margin = margin
            let battery = p[0] == 0 ? String(localized: "Netzbetrieb") : p[0] == 255 ? String(localized: "Batterie unbekannt")
                : String(format: String(localized: "Batterie %.0f %%"), Double(p[0] - 1) / 253 * 100)
            c.text = String(localized: "Gerätestatus: \(battery), Reserve \(margin) dB")
        case (true, 0x0D): c.text = String(localized: "fragt Uhrzeit ab")
        case (false, 0x02): c.text = String(localized: "Empfang: Reserve \(Int(p[0])) dB, \(Int(p[1])) Gateways")
        case (false, 0x03): c.text = String(localized: "neue Datenrate DR\(Int(p[0] >> 4)), Leistung \(Int(p[0] & 0x0F))")
        case (false, 0x06): c.text = String(localized: "fragt Gerätestatus ab")
        default: c.text = String(format: String(localized: "MAC 0x%02X"), cid)
        }
        return c
    }
}

/// Cayenne LPP (myDevices): Kanal · Typ · Wert fester Länge, beliebig oft
/// hintereinander. Nur, wenn die ganze Nutzlast aufgeht – sonst ist es kein LPP.
enum CayenneLPP {
    static func decode(_ p: [UInt8]) -> [String]? {
        var out: [String] = []
        var i = 0
        func signed(_ start: Int, _ length: Int) -> Int {
            var v = 0
            for k in 0..<length { v = v << 8 | Int(p[start + k]) }
            return v >= 1 << (8 * length - 1) ? v - (1 << (8 * length)) : v
        }
        func unsigned(_ start: Int, _ length: Int) -> Int { (0..<length).reduce(0) { $0 << 8 | Int(p[start + $1]) } }
        while i + 2 <= p.count {
            let channel = Int(p[i]), type = p[i + 1]
            let sizes: [UInt8: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 101: 2, 102: 1, 103: 2, 104: 1, 113: 6, 115: 2, 134: 6, 136: 9]
            guard let size = sizes[type], i + 2 + size <= p.count else { return nil }
            let d = i + 2
            let value: String
            switch type {
            case 0, 1: value = String(localized: "Schalter \(Int(p[d]))")
            case 2, 3: value = String(format: "%.2f", Double(signed(d, 2)) / 100)
            case 101: value = "\(unsigned(d, 2)) lx"
            case 102: value = p[d] != 0 ? String(localized: "anwesend") : String(localized: "niemand")
            case 103: value = String(format: "%.1f °C", Double(signed(d, 2)) / 10)
            case 104: value = String(format: "%.1f %%", Double(p[d]) / 2)
            case 113: value = String(format: "%.3f / %.3f / %.3f g", Double(signed(d, 2)) / 1000, Double(signed(d + 2, 2)) / 1000, Double(signed(d + 4, 2)) / 1000)
            case 115: value = String(format: "%.1f hPa", Double(unsigned(d, 2)) / 10)
            case 134: value = String(format: "%.2f / %.2f / %.2f °/s", Double(signed(d, 2)) / 100, Double(signed(d + 2, 2)) / 100, Double(signed(d + 4, 2)) / 100)
            default: value = String(format: "%.4f, %.4f, %.1f m", Double(signed(d, 3)) / 10_000, Double(signed(d + 3, 3)) / 10_000, Double(signed(d + 6, 3)) / 100)
            }
            out.append(String(localized: "K\(channel): \(value)"))
            i = d + size
        }
        return i == p.count && !out.isEmpty ? out : nil
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
    /// Schlüssel für `counters`: Gerät und Richtung (Auf- und Abwärtszähler sind getrennt).
    static func counterKey(devAddr: UInt32, uplink: Bool) -> UInt64 {
        UInt64(devAddr) << 1 | (uplink ? 0 : 1)
    }

    /// Kandidaten für den vollen Zähler aus den unteren 16 Bit der Luft und dem
    /// letzten gültigen vollen Zähler: zuerst fortgeführt (bei Überlauf der
    /// unteren 16 Bit eine Stufe höher), dann dieselbe Stufe (Wiederholung,
    /// vertauschte Reihenfolge), zuletzt nur 16 Bit (Gerät neu gestartet).
    static func counterCandidates(low: UInt16, last: UInt32?) -> [UInt32] {
        let plain = UInt32(low)
        guard let last else { return [plain] }
        let same = last & 0xFFFF_0000 | plain
        var result: [UInt32] = []
        if same < last, last < 0xFFFF_0000 { result.append(same + 0x1_0000) }
        result.append(same)
        if !result.contains(plain) { result.append(plain) }
        return result
    }

    /// Zerlegt einen PHYPayload und entschlüsselt ihn mit passenden Sitzungen.
    /// `counters`: letzter gültiger voller Zähler je Gerät und Richtung
    /// (`counterKey`) – über die Luft kommen nur die unteren 16 Bit, ab
    /// FCnt 65 536 ginge die MIC sonst nie mehr auf (Review 01.11.2026).
    static func parse(_ phy: [UInt8], sessions: [UInt32: LoRaWANSession],
                      counters: [UInt64: UInt32] = [:]) -> LoRaWANFrame? {
        // Höchstens 255 Byte: der B0-Block der MIC trägt die Länge in einem Byte
        // (`UInt8(msg.count)` trappte sonst – Review 05.11.2026).
        guard phy.count >= 5, phy.count <= 255, let mType = LoRaWANFrame.MType(rawValue: Int(phy[0] >> 5)) else { return nil }
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
            let message = Array(phy[..<micStart]), received = Array(phy[micStart...])
            let last = counters[counterKey(devAddr: devAddr, uplink: mType.isUplink)]
            let fullCnt = counterCandidates(low: fCnt, last: last).first { candidate in
                LoRaWANCrypto.dataMIC(nwkSKey: session.nwkSKey, devAddr: devAddr, fCnt: candidate, dir: dir,
                                      msg: message) == received
            }
            frame.micValid = fullCnt != nil
            frame.fullFCnt = fullCnt
            // Nur mit gültiger MIC entschlüsseln: Gefälschte Rahmen oder ein
            // falsch geratener Zähler ergäben sonst Müll als „letzte Nutzlast“.
            if let fullCnt, let fPort, !frmPayload.isEmpty {
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
