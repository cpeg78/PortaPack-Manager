import CommonCrypto
import Foundation

// Thread (OpenThread, Matter über Thread) auf derselben 802.15.4-Bitübertragung:
// 6LoWPAN statt Zigbee-NWK, MAC-Sicherheit mit Schlüsseln aus dem
// Netzwerkschlüssel (Thread Specification 7.1.4), MLE-Nachrichten mit
// eigener Sicherung (4.9). Erkannt wird Thread an MAC-Sicherheit oder am
// 6LoWPAN-Dispatch; gelesen mit dem Netzwerkschlüssel (OpenThread
// `networkkey`, Matter-„Thread Operational Dataset“ Feld 0x0005).

/// Schlüsselableitung: HMAC-SHA256(Netzwerkschlüssel, Folge (32 Bit BE) ‖ "Thread")
/// → erste 16 Byte MLE-Schlüssel, letzte 16 Byte MAC-Schlüssel.
enum ThreadKeys {
    struct Derived: Sendable, Equatable {
        var sequence: UInt32
        var mle: [UInt8]
        var mac: [UInt8]
    }

    static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, message, message.count, &out)
        return out
    }

    static func derive(networkKey: [UInt8], sequence: UInt32) -> Derived {
        let message = (0..<4).map { UInt8(sequence >> UInt32(24 - 8 * $0) & 0xFF) } + Array("Thread".utf8)
        let digest = hmacSHA256(key: networkKey, message: message)
        return Derived(sequence: sequence, mle: Array(digest[0..<16]), mac: Array(digest[16..<32]))
    }

    /// Schlüsselindex im MAC-Zusatzkopf = (Folge mod 127) + 1; die Folge ist
    /// also nur modulo 127 bekannt – die ersten paar Umläufe werden probiert.
    static func sequences(keyIndex: UInt8) -> [UInt32] {
        guard keyIndex >= 1 else { return [] }
        return (0..<4).map { UInt32(keyIndex - 1) + 127 * UInt32($0) }
    }
}

/// Thread-Netzwerkschlüssel im Schlüsselbund, getrennt von den Zigbee-Schlüsseln.
enum ThreadKeyStore {
    private static let service = "de.christiangolz.portapackmanager.thread"
    private static let account = "network-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> [[UInt8]] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list.compactMap { ZigbeeSecurity.parseKey($0) }
    }

    @discardableResult
    static func save(_ keys: [[UInt8]]) -> OSStatus {
        guard !keys.isEmpty else { SecItemDelete(query as CFDictionary); return errSecSuccess }
        let list = keys.map { $0.map { String(format: "%02X", $0) }.joined() }
        guard let data = try? JSONEncoder().encode(list) else { return errSecParam }
        return KeychainBlob.save(data, query: query)
    }
}

/// MAC-Sicherheit nach 802.15.4 (anders als Zigbee-NWK: Adresse **und**
/// Zähler big-endian im Nonce, authentisiert wird der ganze MAC-Kopf).
enum ThreadMAC {
    static func nonce(source: UInt64, counter: UInt32, level: Int) -> [UInt8] {
        (0..<8).map { UInt8(source >> UInt64(56 - 8 * $0) & 0xFF) }
            + (0..<4).map { UInt8(counter >> UInt32(24 - 8 * $0) & 0xFF) }
            + [UInt8(level)]
    }

    /// Entschlüsselt die MAC-Nutzdaten; `mpdu` ohne FCS. Liefert Klartext und
    /// die verwendete Schlüsselfolge.
    static func decrypt(mpdu: [UInt8], mac: MACFrame, source: UInt64, networkKeys: [[UInt8]]) -> (payload: [UInt8], sequence: UInt32, keyIndex: Int)? {
        guard let security = mac.securityHeader, security.encrypted, let index = security.keyIndex,
              mac.payload.count >= security.micLength else { return nil }
        let authenticated = Array(mpdu[..<mac.headerLength])
        let ciphertext = Array(mac.payload.dropLast(security.micLength))
        let mic = Array(mac.payload.suffix(security.micLength))
        let nonce = self.nonce(source: source, counter: security.frameCounter, level: security.level)
        for (k, key) in networkKeys.enumerated() {
            for sequence in ThreadKeys.sequences(keyIndex: index) {
                let derived = ThreadKeys.derive(networkKey: key, sequence: sequence)
                if let clear = CCMStar.decrypt(key: derived.mac, nonce: nonce, authenticated: authenticated,
                                               ciphertext: ciphertext, mic: mic) {
                    return (clear, sequence, k)
                }
            }
        }
        return nil
    }

    static func encrypt(mpduHeader: [UInt8], payload: [UInt8], source: UInt64, counter: UInt32, level: Int, macKey: [UInt8]) -> [UInt8] {
        let nonce = self.nonce(source: source, counter: counter, level: level)
        let micLength = [0, 4, 8, 16][level & 3]
        let (cipher, mic) = CCMStar.encrypt(key: macKey, nonce: nonce, authenticated: mpduHeader, plaintext: payload, micLength: micLength)
        return mpduHeader + cipher + mic
    }
}

/// 6LoWPAN (RFC 6282) so weit, wie Thread es braucht: IPHC mit vollständig
/// aus den MAC-Adressen abgeleiteten Link-Local-Adressen, Kontext 0 für
/// Mesh-Local (Präfix unbekannt → nur Kennung), UDP-NHC mit Portkürzung.
struct LoWPANPacket: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case iphc, ipv6, mesh, fragment, other }

    var kind: Kind
    var sourceIPv6: [UInt8]?
    var destinationIPv6: [UInt8]?
    var nextHeader: UInt8?
    var hopLimit: Int?
    var udpSource: UInt16?
    var udpDestination: UInt16?
    /// Nutzdaten nach den Kopfdaten (bei UDP: nach dem UDP-Kopf).
    var payload: [UInt8]

    static let mlePort: UInt16 = 19788
    static let coapPort: UInt16 = 61631
    static let coapDefault: UInt16 = 5683

    var summary: String {
        switch kind {
        case .iphc, .ipv6:
            if let udpDestination {
                switch udpDestination {
                case Self.mlePort: return "MLE"
                case Self.coapPort: return String(localized: "CoAP (Thread-Verwaltung)")
                case Self.coapDefault, 5684: return "CoAP"
                case 53: return "DNS"
                default: return String(localized: "UDP → Port \(Int(udpDestination))")
                }
            }
            switch nextHeader {
            case 58?: return "ICMPv6"
            case 6?: return "TCP"
            case 17?: return "UDP"
            default: return "IPv6"
            }
        case .mesh: return String(localized: "6LoWPAN Mesh-Kopf")
        case .fragment: return String(localized: "6LoWPAN-Fragment")
        case .other: return "6LoWPAN"
        }
    }

    /// Erkennt 6LoWPAN am ersten Byte: 01xxxxxx IPHC (011), 01000001 IPv6,
    /// 10xxxxxx Mesh, 11000xxx/11100xxx Fragmente.
    static func looksLikeLoWPAN(_ b: [UInt8]) -> Bool {
        guard let first = b.first else { return false }
        return first & 0xE0 == 0x60 || first == 0x41 || first & 0xC0 == 0x80 || first & 0xD8 == 0xC0
    }

    static func parse(_ b: [UInt8], mac: MACFrame) -> LoWPANPacket? {
        guard let first = b.first else { return nil }
        if first & 0xC0 == 0x80 { return LoWPANPacket(kind: .mesh, payload: b) }
        if first & 0xD8 == 0xC0 {
            // Erstes Fragment (11000): Größe(11 Bit), Tag, dann IPHC.
            if first & 0xF8 == 0xC0, b.count > 4, let inner = parse(Array(b[4...]), mac: mac) {
                var packet = inner
                packet.kind = .fragment
                return packet
            }
            return LoWPANPacket(kind: .fragment, payload: b)
        }
        if first == 0x41 {
            guard b.count >= 41 else { return nil }
            var packet = LoWPANPacket(kind: .ipv6, payload: Array(b[41...]))
            packet.nextHeader = b[7]
            packet.hopLimit = Int(b[8])
            packet.sourceIPv6 = Array(b[9..<25])
            packet.destinationIPv6 = Array(b[25..<41])
            if b[7] == 17, b.count >= 49 {
                packet.udpSource = UInt16(b[41]) << 8 | UInt16(b[42])
                packet.udpDestination = UInt16(b[43]) << 8 | UInt16(b[44])
                packet.payload = Array(b[49...])
            }
            return packet
        }
        guard first & 0xE0 == 0x60, b.count >= 2 else { return LoWPANPacket(kind: .other, payload: b) }
        // IPHC: 011 TF(2) NH(1) HLIM(2) | CID(1) SAC(1) SAM(2) M(1) DAC(1) DAM(2)
        let tf = Int(first >> 3 & 3), nhc = first & 0x04 != 0, hlim = Int(first & 3)
        let second = b[1]
        let cid = second & 0x80 != 0, sac = second & 0x40 != 0, sam = Int(second >> 4 & 3)
        let m = second & 0x08 != 0, dac = second & 0x04 != 0, dam = Int(second & 3)
        var i = 2
        if cid { i += 1 }
        i += [4, 3, 1, 0][tf]
        var packet = LoWPANPacket(kind: .iphc, payload: [])
        if !nhc { guard i < b.count else { return nil }; packet.nextHeader = b[i]; i += 1 }
        switch hlim {
        case 0: guard i < b.count else { return nil }; packet.hopLimit = Int(b[i]); i += 1
        case 1: packet.hopLimit = 1
        case 2: packet.hopLimit = 64
        default: packet.hopLimit = 255
        }
        func address(mode: Int, contextBased: Bool, macAddress: MACAddress?, multicast: Bool) -> [UInt8]? {
            let prefix: [UInt8] = contextBased ? [UInt8](repeating: 0, count: 8) : [0xFE, 0x80, 0, 0, 0, 0, 0, 0]
            if multicast {
                switch mode {
                case 0: guard i + 16 <= b.count else { return nil }; defer { i += 16 }; return Array(b[i..<(i + 16)])
                case 1: guard i + 6 <= b.count else { return nil }; defer { i += 6 }
                    return [0xFF, b[i], 0, 0, 0, 0, 0, 0, 0, 0, 0] + Array(b[(i + 1)..<(i + 6)])
                case 2: guard i + 4 <= b.count else { return nil }; defer { i += 4 }
                    return [0xFF, b[i], 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + Array(b[(i + 1)..<(i + 4)])
                default: guard i + 1 <= b.count else { return nil }; defer { i += 1 }
                    return [0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, b[i]]
                }
            }
            switch mode {
            case 0:
                if contextBased { return [UInt8](repeating: 0, count: 16) }       // unspezifiziert
                guard i + 16 <= b.count else { return nil }; defer { i += 16 }; return Array(b[i..<(i + 16)])
            case 1: guard i + 8 <= b.count else { return nil }; defer { i += 8 }; return prefix + Array(b[i..<(i + 8)])
            case 2: guard i + 2 <= b.count else { return nil }; defer { i += 2 }
                return prefix + [0, 0, 0, 0xFF, 0xFE, 0, b[i], b[i + 1]]
            default:
                // Vollständig aus der MAC-Adresse: erweitert mit gekipptem U/L-Bit, kurz als 0000:00ff:fe00:XXXX.
                switch macAddress {
                case let .extended(e)?:
                    var iid = (0..<8).map { UInt8(e >> UInt64(56 - 8 * $0) & 0xFF) }
                    iid[0] ^= 0x02
                    return prefix + iid
                case let .short(s)?:
                    return prefix + [0, 0, 0, 0xFF, 0xFE, 0, UInt8(s >> 8), UInt8(s & 0xFF)]
                default: return nil
                }
            }
        }
        packet.sourceIPv6 = address(mode: sam, contextBased: sac, macAddress: mac.source, multicast: false)
        packet.destinationIPv6 = address(mode: dam, contextBased: dac, macAddress: mac.destination, multicast: m)
        if nhc {
            guard i < b.count else { return nil }
            let header = b[i]
            if header & 0xF8 == 0xF0 {                       // UDP-NHC: 11110 C P(2)
                packet.nextHeader = 17
                i += 1
                let ports = Int(header & 3)
                switch ports {
                case 0: guard i + 4 <= b.count else { return nil }
                    packet.udpSource = UInt16(b[i]) << 8 | UInt16(b[i + 1]); packet.udpDestination = UInt16(b[i + 2]) << 8 | UInt16(b[i + 3]); i += 4
                case 1: guard i + 3 <= b.count else { return nil }
                    packet.udpSource = UInt16(b[i]) << 8 | UInt16(b[i + 1]); packet.udpDestination = 0xF000 | UInt16(b[i + 2]); i += 3
                case 2: guard i + 3 <= b.count else { return nil }
                    packet.udpSource = 0xF000 | UInt16(b[i]); packet.udpDestination = UInt16(b[i + 1]) << 8 | UInt16(b[i + 2]); i += 3
                default: guard i + 1 <= b.count else { return nil }
                    packet.udpSource = 0xF0B0 | UInt16(b[i] >> 4); packet.udpDestination = 0xF0B0 | UInt16(b[i] & 0x0F); i += 1
                }
                if header & 0x04 == 0 { i += 2 }                // Prüfsumme übertragen
            } else {
                packet.nextHeader = header & 0x0E == 0x0E ? 0 : nil   // andere NHC (IPv6-Erweiterungen) nicht weiter zerlegt
            }
        }
        guard i <= b.count else { return nil }
        packet.payload = Array(b[i...])
        return packet
    }
}

/// MLE (Mesh Link Establishment): Sicherheitssuite 0 = AES-CCM mit dem
/// MLE-Schlüssel, Nonce wie 802.15.4 (Quelladresse BE, Zähler BE, Stufe 5),
/// authentisiert werden Quell- und Ziel-IPv6-Adresse und der Zusatzkopf.
struct MLEMessage: Sendable, Equatable {
    struct TLV: Sendable, Equatable { var type: UInt8; var value: [UInt8] }

    var command: UInt8
    var tlvs: [TLV]
    var sequence: UInt32?

    static let commandNames: [UInt8: String] = [
        0: "Link Request", 1: "Link Accept", 2: "Link Accept and Request", 3: "Link Reject", 4: "Advertisement",
        5: "Update", 6: "Update Request", 7: "Data Request", 8: "Data Response", 9: "Parent Request",
        10: "Parent Response", 11: "Child ID Request", 12: "Child ID Response", 13: "Child Update Request",
        14: "Child Update Response", 15: "Announce", 16: "Discovery Request", 17: "Discovery Response",
        18: "Link Metrics Management Request", 19: "Link Metrics Management Response", 20: "Link Probe",
    ]

    var commandName: String { Self.commandNames[command] ?? String(localized: "MLE-Befehl \(Int(command))") }

    /// RLOC16 aus dem Source-Address-TLV (0) bzw. Address16-TLV (10).
    var sourceAddress16: UInt16? { tlv(0).flatMap { $0.count == 2 ? UInt16($0[0]) << 8 | UInt16($0[1]) : nil } }
    var address16: UInt16? { tlv(10).flatMap { $0.count == 2 ? UInt16($0[0]) << 8 | UInt16($0[1]) : nil } }

    func tlv(_ type: UInt8) -> [UInt8]? { tlvs.first { $0.type == type }?.value }

    /// Kurzfassung: Befehl, RLOC16, Partition/Rolle aus Leader Data (11), Modus (1).
    var summary: String {
        var parts = [commandName]
        if let rloc = sourceAddress16 { parts.append(String(format: "RLOC 0x%04X", rloc)) }
        if let leader = tlv(11), leader.count >= 8 {
            let partition = UInt32(leader[0]) << 24 | UInt32(leader[1]) << 16 | UInt32(leader[2]) << 8 | UInt32(leader[3])
            parts.append(String(format: "Partition %08X, Router %d", partition, leader[7]))
        }
        if let mode = tlv(1)?.first {
            var flags: [String] = []
            if mode & 0x08 != 0 { flags.append(String(localized: "Empfänger an")) }
            if mode & 0x02 != 0 { flags.append(String(localized: "vollwertig (FTD)")) }
            if mode & 0x01 != 0 { flags.append(String(localized: "volle Netzdaten")) }
            if !flags.isEmpty { parts.append(flags.joined(separator: ", ")) }
        }
        if let timeout = tlv(2), timeout.count == 4 {
            let seconds = Int(UInt32(timeout[0]) << 24 | UInt32(timeout[1]) << 16 | UInt32(timeout[2]) << 8 | UInt32(timeout[3]))
            parts.append(String(localized: "Timeout \(seconds) s"))
        }
        if let route = tlv(9), route.count >= 1 { parts.append(String(localized: "Route64 Folge \(Int(route[0]))")) }
        return parts.joined(separator: " · ")
    }

    static func parseTLVs(_ b: [UInt8]) -> [TLV] {
        var out: [TLV] = []
        var i = 0
        while i + 2 <= b.count {
            let type = b[i]
            var length = Int(b[i + 1])
            i += 2
            if length == 255 {                               // erweiterte Länge
                guard i + 2 <= b.count else { break }
                length = Int(b[i]) << 8 | Int(b[i + 1])
                i += 2
            }
            guard i + length <= b.count else { break }
            out.append(TLV(type: type, value: Array(b[i..<(i + length)])))
            i += length
        }
        return out
    }

    /// Entschlüsselt eine MLE-Nachricht (UDP-Nutzdaten) mit den Schlüsseln
    /// aus `networkKeys`; `source` ist die erweiterte Adresse des Senders.
    static func decrypt(_ udpPayload: [UInt8], source: UInt64, sourceIPv6: [UInt8], destinationIPv6: [UInt8],
                        networkKeys: [[UInt8]]) -> MLEMessage? {
        guard udpPayload.count >= 1 + 5 + 4 else { return nil }
        if udpPayload[0] == 255 {                            // ungesichert (Discovery)
            let body = Array(udpPayload.dropFirst())
            guard let command = body.first else { return nil }
            return MLEMessage(command: command, tlvs: parseTLVs(Array(body.dropFirst())), sequence: nil)
        }
        guard udpPayload[0] == 0, let aux = MACSecurityHeader.parse(udpPayload, at: 1), aux.level == 5 else { return nil }
        let headerEnd = 1 + aux.length
        guard udpPayload.count >= headerEnd + 4 else { return nil }
        let authenticated = sourceIPv6 + destinationIPv6 + Array(udpPayload[1..<headerEnd])
        let ciphertext = Array(udpPayload[headerEnd..<(udpPayload.count - 4)])
        let mic = Array(udpPayload.suffix(4))
        let nonce = ThreadMAC.nonce(source: source, counter: aux.frameCounter, level: 5)
        // Schlüsselkennungsmodus 2: Quelle = Schlüsselfolge (32 Bit BE), Index = (Folge mod 127) + 1.
        var sequences: [UInt32] = []
        if aux.keyIdentifierMode == 2, aux.keySource.count == 4 {
            sequences = [UInt32(aux.keySource[0]) << 24 | UInt32(aux.keySource[1]) << 16 | UInt32(aux.keySource[2]) << 8 | UInt32(aux.keySource[3])]
        } else if let index = aux.keyIndex {
            sequences = ThreadKeys.sequences(keyIndex: index)
        }
        for key in networkKeys {
            for sequence in sequences {
                let derived = ThreadKeys.derive(networkKey: key, sequence: sequence)
                guard let clear = CCMStar.decrypt(key: derived.mle, nonce: nonce, authenticated: authenticated,
                                                  ciphertext: ciphertext, mic: mic), let command = clear.first else { continue }
                return MLEMessage(command: command, tlvs: parseTLVs(Array(clear.dropFirst())), sequence: sequence)
            }
        }
        return nil
    }

    /// Gegenstück für Tests: verschlüsselte MLE-Nachricht (Modus 2, Stufe 5).
    static func encrypt(command: UInt8, tlvs: [TLV], source: UInt64, sourceIPv6: [UInt8], destinationIPv6: [UInt8],
                        networkKey: [UInt8], sequence: UInt32, counter: UInt32) -> [UInt8] {
        var aux: [UInt8] = [0x15]                                        // Stufe 5, Modus 2
        aux += (0..<4).map { UInt8(counter >> UInt32(8 * $0) & 0xFF) }
        aux += (0..<4).map { UInt8(sequence >> UInt32(24 - 8 * $0) & 0xFF) }
        aux += [UInt8(sequence % 127) + 1]
        var clear: [UInt8] = [command]
        for tlv in tlvs { clear += [tlv.type, UInt8(tlv.value.count)] + tlv.value }
        let derived = ThreadKeys.derive(networkKey: networkKey, sequence: sequence)
        let nonce = ThreadMAC.nonce(source: source, counter: counter, level: 5)
        let (cipher, mic) = CCMStar.encrypt(key: derived.mle, nonce: nonce, authenticated: sourceIPv6 + destinationIPv6 + aux,
                                            plaintext: clear, micLength: 4)
        return [0] + aux + cipher + mic
    }
}

/// Auswertung eines Thread-Rahmens: MAC-Entschlüsselung (falls nötig),
/// 6LoWPAN, MLE – mit Lernen der Kurz-↔Langadressen aus MLE-Quelladressen.
struct ThreadFrame: Sendable, Equatable {
    var decrypted: Bool
    var lowpan: LoWPANPacket?
    var mle: MLEMessage?
    var summary: String
    /// Kurz-/Langadresse des Senders, falls beides bekannt wurde.
    var learned: (short: UInt16, extended: UInt64)?

    static func == (a: ThreadFrame, b: ThreadFrame) -> Bool { a.summary == b.summary && a.decrypted == b.decrypted }

    /// `addresses`: bekannte Kurz- → Langadressen (für MAC-Nonce bei kurzer Quelle).
    static func interpret(mpdu: [UInt8], mac: MACFrame, networkKeys: [[UInt8]], addresses: [UInt16: UInt64]) -> ThreadFrame? {
        var payload = mac.payload
        var decrypted = false
        var extendedSource: UInt64?
        switch mac.source {
        case let .extended(e)?: extendedSource = e
        case let .short(s)?: extendedSource = addresses[s]
        default: break
        }
        if let security = mac.securityHeader, security.encrypted {
            guard !networkKeys.isEmpty else {
                return ThreadFrame(decrypted: false, lowpan: nil, mle: nil, summary: String(localized: "Thread/802.15.4 (MAC-verschlüsselt, Schlüsselindex \(Int(security.keyIndex ?? 0)))"))
            }
            guard let source = extendedSource else {
                return ThreadFrame(decrypted: false, lowpan: nil, mle: nil, summary: String(localized: "Thread (MAC-verschlüsselt, Langadresse des Senders noch unbekannt)"))
            }
            guard let result = ThreadMAC.decrypt(mpdu: mpdu, mac: mac, source: source, networkKeys: networkKeys) else {
                return ThreadFrame(decrypted: false, lowpan: nil, mle: nil, summary: String(localized: "Thread (MAC-verschlüsselt, Schlüssel passt nicht)"))
            }
            payload = result.payload
            decrypted = true
        } else if mac.security {
            payload = Array(mac.payload.dropLast(mac.securityHeader?.micLength ?? 0))   // nur authentisiert
        }
        guard LoWPANPacket.looksLikeLoWPAN(payload) else {
            return mac.security ? ThreadFrame(decrypted: decrypted, lowpan: nil, mle: nil, summary: String(localized: "802.15.4 (gesichert, kein 6LoWPAN)")) : nil
        }
        guard let lowpan = LoWPANPacket.parse(payload, mac: mac) else {
            return ThreadFrame(decrypted: decrypted, lowpan: nil, mle: nil, summary: String(localized: "Thread: 6LoWPAN (unvollständig)"))
        }
        var frame = ThreadFrame(decrypted: decrypted, lowpan: lowpan, mle: nil, summary: "Thread: " + lowpan.summary)
        if lowpan.udpDestination == LoWPANPacket.mlePort, let source = extendedSource,
           let src = lowpan.sourceIPv6, let dst = lowpan.destinationIPv6 {
            if let mle = MLEMessage.decrypt(lowpan.payload, source: source, sourceIPv6: src, destinationIPv6: dst, networkKeys: networkKeys) {
                frame.mle = mle
                frame.summary = "Thread MLE: " + mle.summary
                if let rloc = mle.sourceAddress16 { frame.learned = (rloc, source) }
            } else if networkKeys.isEmpty {
                frame.summary = String(localized: "Thread: MLE (verschlüsselt)")
            } else {
                frame.summary = String(localized: "Thread: MLE (Schlüssel passt nicht)")
            }
        } else if lowpan.udpDestination == LoWPANPacket.mlePort {
            frame.summary = String(localized: "Thread: MLE (Langadresse des Senders unbekannt)")
        }
        return frame
    }
}
