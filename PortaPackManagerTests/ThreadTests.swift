import Foundation
import Testing
@testable import PortaPackManager

@Suite("Thread (6LoWPAN, MLE)")
struct ThreadTests {
    static let networkKey: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
    static let router: UInt64 = 0x1A2B_3C4D_5E6F_7081
    static let rloc: UInt16 = 0x5C00

    @Test("HMAC-SHA256 nach RFC 4231 (Fall 2), Schlüsselfolgen aus dem Index")
    func hmac() {
        let digest = ThreadKeys.hmacSHA256(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))
        let expected = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        #expect(digest.map { String(format: "%02x", $0) }.joined() == expected)
        let derived = ThreadKeys.derive(networkKey: Self.networkKey, sequence: 3)
        #expect(derived.mle.count == 16 && derived.mac.count == 16 && derived.mle != derived.mac)
        #expect(ThreadKeys.sequences(keyIndex: 1) == [0, 127, 254, 381])
        #expect(ThreadKeys.sequences(keyIndex: 4).first == 3)
    }

    /// Link-local-Adresse aus der Langadresse (U/L-Bit gekippt).
    static func linkLocal(_ extended: UInt64) -> [UInt8] {
        var iid = (0..<8).map { UInt8(extended >> UInt64(56 - 8 * $0) & 0xFF) }
        iid[0] ^= 0x02
        return [0xFE, 0x80, 0, 0, 0, 0, 0, 0] + iid
    }

    static let allNodes: [UInt8] = [0xFF, 0x02] + [UInt8](repeating: 0, count: 13) + [0x01]

    /// MLE Advertisement ohne MAC-Sicherheit: Langadresse als Quelle, an ff02::1.
    static func advertisement(counter: UInt32 = 7) -> [UInt8] {
        let fcf: UInt16 = 0x0001 | 0x0040 | 2 << 10 | 1 << 12 | 3 << 14
        var mpdu: [UInt8] = [UInt8(fcf & 0xFF), UInt8(fcf >> 8), 0x21, 0xCE, 0xFA, 0xFF, 0xFF]
        mpdu += (0..<8).map { UInt8(router >> UInt64(8 * $0) & 0xFF) }
        let leader: [UInt8] = [0x12, 0x34, 0x56, 0x78, 64, 1, 2, 0x17]
        let mle = MLEMessage.encrypt(command: 4, tlvs: [.init(type: 0, value: [UInt8(rloc >> 8), UInt8(rloc & 0xFF)]),
                                                         .init(type: 11, value: leader), .init(type: 1, value: [0x0F])],
                                     source: router, sourceIPv6: linkLocal(router), destinationIPv6: allNodes,
                                     networkKey: networkKey, sequence: 0, counter: counter)
        // IPHC: TF=11, NH=1, HLIM=11; SAM=11 (aus MAC), M=1, DAM=11 (ff02::XX); UDP-NHC volle Ports, Prüfsumme elidiert.
        mpdu += [0x7F, 0x3B, 0x01, 0xF4, 0x4D, 0x4C, 0x4D, 0x4C] + mle
        return mpdu
    }

    @Test("MLE Advertisement: 6LoWPAN-Adressen, Entschlüsselung, RLOC gelernt")
    func advertisement() throws {
        let mpdu = Self.advertisement()
        let mac = try #require(MACFrame.parse(mpdu))
        #expect(!mac.security)
        let frame = try #require(ThreadFrame.interpret(mpdu: mpdu, mac: mac, networkKeys: [Self.networkKey], addresses: [:]))
        #expect(frame.lowpan?.sourceIPv6 == Self.linkLocal(Self.router))
        #expect(frame.lowpan?.destinationIPv6 == Self.allNodes)
        #expect(frame.lowpan?.udpDestination == 19788)
        let mle = try #require(frame.mle)
        #expect(mle.command == 4 && mle.sourceAddress16 == Self.rloc)
        #expect(frame.learned?.short == Self.rloc && frame.learned?.extended == Self.router)
        #expect(frame.summary.hasPrefix("Thread MLE: Advertisement · RLOC 0x5C00 · Partition 12345678, Router 23"))
        // Ohne Schlüssel: erkannt, aber verschlüsselt.
        let locked = try #require(ThreadFrame.interpret(mpdu: mpdu, mac: mac, networkKeys: [], addresses: [:]))
        #expect(locked.mle == nil && locked.summary == "Thread: MLE (verschlüsselt)")
        // Falscher Schlüssel.
        var wrong = Self.networkKey; wrong[15] ^= 1
        #expect(ThreadFrame.interpret(mpdu: mpdu, mac: mac, networkKeys: [wrong], addresses: [:])?.mle == nil)
    }

    @Test("MAC-gesicherter Datenrahmen mit Kurzadresse: Schlüssel aus Index, Langadresse aus Tabelle")
    func macSecured() throws {
        let fcf: UInt16 = 0x0001 | 0x0008 | 0x0040 | 2 << 10 | 1 << 12 | 2 << 14
        var header: [UInt8] = [UInt8(fcf & 0xFF), UInt8(fcf >> 8), 0x22, 0xCE, 0xFA, 0x01, 0x04, 0x00, 0x5C]
        header += [0x0D, 9, 0, 0, 0, 1]                                  // Stufe 5, Modus 1, Zähler 9, Index 1 → Folge 0
        // IPHC: SAM=11, DAM=11 (beide aus MAC), UDP an 61631 (CoAP Thread-Verwaltung) mit CoAP-Kopf.
        let payload: [UInt8] = [0x7F, 0x33, 0xF4, 0xF0, 0xBF, 0xF0, 0xBF, 0x42, 0x02, 0x12, 0x34, 0xB1, 0x61]
        let macKey = ThreadKeys.derive(networkKey: Self.networkKey, sequence: 0).mac
        let mpdu = ThreadMAC.encrypt(mpduHeader: header, payload: payload, source: Self.router, counter: 9, level: 5, macKey: macKey)
        let mac = try #require(MACFrame.parse(mpdu))
        #expect(mac.securityHeader?.level == 5 && mac.securityHeader?.keyIndex == 1 && mac.headerLength == header.count)
        // Ohne Langadresse geht es nicht …
        let unknown = try #require(ThreadFrame.interpret(mpdu: mpdu, mac: mac, networkKeys: [Self.networkKey], addresses: [:]))
        #expect(!unknown.decrypted)
        // … mit gelernter Zuordnung schon.
        let frame = try #require(ThreadFrame.interpret(mpdu: mpdu, mac: mac, networkKeys: [Self.networkKey], addresses: [Self.rloc: Self.router]))
        #expect(frame.decrypted)
        #expect(frame.lowpan?.udpDestination == 61631 && frame.lowpan?.udpSource == 61631)
        #expect(frame.lowpan?.sourceIPv6 == [0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFE, 0, 0x5C, 0x00])
        #expect(frame.summary == "Thread: CoAP (Thread-Verwaltung)")
        #expect(frame.lowpan?.payload == [0x42, 0x02, 0x12, 0x34, 0xB1, 0x61])
    }

    @Test("Zigbee-Auswertung erkennt Thread und lernt Adressen über mehrere Rahmen")
    func interpretation() {
        let radio = ZigbeeRadioFrame(channel: 15, mpdu: Self.advertisement(), rssiDB: -50, offsetKHz: 0, date: Date())
        let packet = ZigbeePacket.interpret(radio, id: 1, keys: [], threadKeys: [Self.networkKey])
        #expect(packet.thread?.mle?.command == 4)
        #expect(packet.nwk == nil && !packet.encrypted)
        #expect(packet.summary.hasPrefix("Thread MLE"))
        let plain = ZigbeePacket.interpret(radio, id: 2, keys: [])
        #expect(plain.encrypted && plain.thread != nil)
    }

    @Test("Offline-Vorlage: Zigbee-Kanal aus der Aufnahmemitte")
    func preset() {
        #expect(IQPreset.zigbeeChannel(center: IQPreset.zigbeeCenter(channel: 15)) == 15)
        #expect(IQPreset.zigbeeCenter(channel: 11) == 2_403_000_000)
        #expect(IQPreset.zigbeeChannel(center: 2_400_000_000) == nil)
    }
}
