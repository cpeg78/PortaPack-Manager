import Foundation

/// APS-Sicherheit (Zigbee 4.4): mit ihr wird der Netzwerkschlüssel beim
/// Anlernen übertragen (Transport-Key-Befehl). Er ist mit dem
/// Trust-Center-Link-Key verschlüsselt – standardmäßig „ZigBeeAlliance09“.
/// Wer beim Beitritt mithört, kann den Netzwerkschlüssel daraus gewinnen;
/// genau das macht auch Wireshark. Übernommen wird ein Schlüssel nur, wenn
/// die CCM*-Prüfsumme (MIC) aufgeht – ein falscher Link-Key liefert nichts.
enum ZigbeeAPSSecurity {
    /// Standard-Trust-Center-Link-Key (Klartext „ZigBeeAlliance09“).
    static let defaultTrustCenterLinkKey = Array("ZigBeeAlliance09".utf8)

    /// AES-MMO-Hash (Matyas-Meyer-Oseas) nach Zigbee B.6: H₀ = 0,
    /// Hᵢ = E(Hᵢ₋₁, Mᵢ) ⊕ Mᵢ, mit Längenauffüllung (0x80, dann Bitlänge).
    static func aesMMO(_ message: [UInt8]) -> [UInt8] {
        var padded = message
        let bitLength = message.count * 8
        padded.append(0x80)
        while padded.count % 16 != 14 { padded.append(0) }
        padded.append(UInt8(bitLength >> 8 & 0xFF))
        padded.append(UInt8(bitLength & 0xFF))
        var hash = [UInt8](repeating: 0, count: 16)
        for start in stride(from: 0, to: padded.count, by: 16) {
            let block = Array(padded[start..<(start + 16)])
            let encrypted = CCMStar.aes(hash, block)   // Schlüssel = aktueller Hashzustand
            for k in 0..<16 { hash[k] = encrypted[k] ^ block[k] }
        }
        return hash
    }

    /// Zigbee-Schlüssel-Hashfunktion (B.1.4): HMAC mit dem AES-MMO-Hash,
    /// Blockgröße 16. `input` ist ein einzelnes Byte (0x00 Key-Transport,
    /// 0x02 Key-Load).
    static func keyedHash(key: [UInt8], input: UInt8) -> [UInt8] {
        var ipad = [UInt8](repeating: 0x36, count: 16)
        var opad = [UInt8](repeating: 0x5C, count: 16)
        for k in 0..<min(16, key.count) { ipad[k] ^= key[k]; opad[k] ^= key[k] }
        let inner = aesMMO(ipad + [input])
        return aesMMO(opad + inner)
    }

    static func keyTransportKey(_ linkKey: [UInt8]) -> [UInt8] { keyedHash(key: linkKey, input: 0x00) }
    static func keyLoadKey(_ linkKey: [UInt8]) -> [UInt8] { keyedHash(key: linkKey, input: 0x02) }

    /// Ergebnis einer gelesenen APS-Nutzlast.
    struct Decrypted: Sendable, Equatable {
        var payload: [UInt8]
        /// Welcher Schlüssel passte: Verwendung aus dem Zusatzkopf.
        var keyIdentifier: Int
    }

    /// Entschlüsselt eine gesicherte APS-Nutzlast. `raw` ist der komplette
    /// APS-Rahmen (Kopf + Zusatzkopf + Chiffrat + MIC), `headerLength` die
    /// Länge des APS-Kopfs vor dem Zusatzkopf, `security` dessen Werte.
    /// `source` ist die erweiterte Quelladresse (für den Nonce).
    /// Für den Transport-Key-Befehl wird aus jedem Link-Key der
    /// Key-Transport-Key abgeleitet; die Verwendung (Bits 3–4) wählt die Ableitung.
    static func decrypt(raw: [UInt8], headerLength: Int, security: NWKSecurityHeader, source: UInt64,
                        linkKeys: [[UInt8]]) -> Decrypted? {
        let auxEnd = headerLength + security.length
        guard raw.count >= auxEnd + 4 else { return nil }
        var authenticated = Array(raw[..<auxEnd])
        let controlOffset = headerLength
        authenticated[controlOffset] = (authenticated[controlOffset] & ~7) | ZigbeeSecurity.level
        let nonce = ZigbeeSecurity.nonce(source: source, counter: security.frameCounter, control: authenticated[controlOffset])
        let body = Array(raw[auxEnd...])
        let ciphertext = Array(body.dropLast(4)), mic = Array(body.suffix(4))
        let keyIdentifier = security.keyIdentifier
        for linkKey in linkKeys {
            // Verwendung laut Zusatzkopf: 2 Key-Transport, 3 Key-Load, sonst
            // der Link-Key selbst (Daten). Unbekanntes probiert Transport.
            let candidates: [[UInt8]]
            switch keyIdentifier {
            case 2: candidates = [keyTransportKey(linkKey)]
            case 3: candidates = [keyLoadKey(linkKey)]
            case 0: candidates = [linkKey]
            default: candidates = [keyTransportKey(linkKey), linkKey]
            }
            for key in candidates {
                if let clear = CCMStar.decrypt(key: key, nonce: nonce, authenticated: authenticated,
                                               ciphertext: ciphertext, mic: mic) {
                    return Decrypted(payload: clear, keyIdentifier: keyIdentifier)
                }
            }
        }
        return nil
    }

    /// Netzwerkschlüssel aus einem entschlüsselten Transport-Key-Befehl
    /// (Befehl 0x05, Schlüsseltyp 0x01 Standard-Netzwerkschlüssel):
    /// danach 16 Byte Schlüssel, Folgenummer, Ziel-IEEE, Quell-IEEE.
    static func networkKey(fromTransportKey payload: [UInt8]) -> (key: [UInt8], sequence: UInt8)? {
        guard payload.count >= 1 + 1 + 16 + 1, payload[0] == 0x05 else { return nil }
        let keyType = payload[1]
        guard keyType == 0x01 || keyType == 0x05 else { return nil }   // Standard- oder High-Security-Netzwerkschlüssel
        return (Array(payload[2..<18]), payload[18])
    }
}
