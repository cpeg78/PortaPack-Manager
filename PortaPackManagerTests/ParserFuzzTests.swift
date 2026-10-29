import Foundation
import Testing
@testable import PortaPackManager

/// Fuzz-Tests für alle Funk-Parser: Zufällige und mutierte Bytefolgen dürfen
/// nie abstürzen (Bereichsfehler, Überlauf, `Int(NaN)`, doppelte Schlüssel).
/// Jeder Sender in Reichweite kann solche Rahmen erzeugen – ein Absturz
/// beendet auch Fernzugriff und Empfangsplan. Geprüft wird nur „kein Absturz“;
/// die Ergebnisse selbst sind egal. Deterministisch (fester Startwert).
@Suite("Parser-Fuzz")
struct ParserFuzzTests {

    // MARK: - Werkzeuge

    /// Für längere Suchläufe: `TEST_RUNNER_FUZZ_SCALE=20 TEST_RUNNER_FUZZ_SEED=7 xcodebuild test …`
    /// vervielfacht die Durchläufe bzw. wählt andere Startwerte. Standard: schnell (< 20 s).
    static let scale = max(1, Int(ProcessInfo.processInfo.environment["FUZZ_SCALE"] ?? "") ?? 1)
    static let seedOffset = UInt64(ProcessInfo.processInfo.environment["FUZZ_SEED"] ?? "") ?? 0
    static func rng(_ seed: UInt64) -> FuzzRNG { FuzzRNG(seed: seed &+ seedOffset &* 1000) }
    static func runs(_ n: Int) -> Int { n * scale }

    /// SplitMix64: schnell, reproduzierbar.
    struct FuzzRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
        mutating func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in byte() } }
        mutating func bytes(upTo max: Int) -> [UInt8] { bytes(Int.random(in: 0...max, using: &self)) }
        mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
        mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
        /// Häufige Grenzwerte statt reinem Zufall.
        mutating func interesting() -> UInt8 { [0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF, 0x03, 0x17, 0x83, 0x97][int(0...9)] }
    }

    /// Mutiert einen gültigen Vektor: Bits kippen, Bytes ersetzen/einfügen/löschen, kürzen.
    static func mutate(_ base: [UInt8], _ rng: inout FuzzRNG) -> [UInt8] {
        var out = base
        for _ in 0..<rng.int(1...6) {
            switch rng.int(0...5) {
            case 0 where !out.isEmpty:
                let i = rng.int(0...(out.count - 1))
                out[i] ^= 1 << UInt8(rng.int(0...7))
            case 1 where !out.isEmpty:
                out[rng.int(0...(out.count - 1))] = rng.interesting()
            case 2:
                out.insert(rng.byte(), at: rng.int(0...out.count))
            case 3 where !out.isEmpty:
                out.remove(at: rng.int(0...(out.count - 1)))
            case 4 where !out.isEmpty:
                out = Array(out.prefix(rng.int(0...out.count)))
            case 5:
                out += rng.bytes(upTo: 8)
            default:
                break
            }
        }
        return out
    }

    // MARK: - ACARS, VDL2, ATN, CPDLC

    @Test("ACARS: Blöcke beliebiger Länge und Deutung stürzen nicht ab")
    func acars() {
        var rng = Self.rng(1)
        var reassembler = ACARSReassembler()
        let labels: [[UInt8]] = [Array("H1".utf8), Array("SA".utf8), Array("Q0".utf8), Array("_d".utf8), Array("B6".utf8),
                                 Array("A6".utf8), Array("QA".utf8), Array("5Z".utf8), Array("80".utf8)]
        let prefixes = ["#M1BPOSN50123E008456", "#DFBREP001", "/EDDHXAX.ADS.D-AIZZ", "- #M1", "0EV205802V", "#T1B",
                        "AT1.ADS", "/BOGXCXA.AT1.D-ABCD", "CC1D-ABCD,261026,1200,EDDH,EDDF"]
        for n in 0..<Self.runs(6000) {
            var txt: [UInt8]
            if n % 3 == 0 {
                txt = rng.bytes(upTo: 40)
            } else {
                // Gerüst: Modus, Kennzeichen (7), ACK, Label, Block-ID, STX, Text, ETX/ETB
                txt = [rng.byte() & 0x7F] + (0..<7).map { _ in UInt8(rng.int(0x20...0x5A)) } + [0x15]
                txt += labels[rng.int(0...(labels.count - 1))]
                txt += [rng.chance(0.5) ? UInt8(rng.int(0x30...0x39)) : UInt8(rng.int(0x41...0x5A)), 0x02]
                if rng.chance(0.6) { txt += Array(prefixes[rng.int(0...(prefixes.count - 1))].utf8) }
                txt += (0..<rng.int(0...30)).map { _ in rng.chance(0.8) ? UInt8(rng.int(0x20...0x7E)) : rng.byte() }
                txt.append(rng.chance(0.5) ? 0x03 : 0x17)
                if rng.chance(0.3) { txt = Self.mutate(txt, &rng) }
            }
            _ = ACARSFrame.validate(txt, crc: rng.bytes(2))
            if let message = ACARSFrame.parse(txt) {
                _ = ACARSInterpreter.interpret(message)
                _ = reassembler.add(message)
                _ = message.isDownlink
            }
        }
        // K1: genau 13 Zeichen, Downlink (Block-ID Ziffer), Text vorhanden.
        let thirteen: [UInt8] = Array("2.D-ABCD!H11".utf8) + [0x02]
        _ = ACARSFrame.parse(thirteen)
    }

    @Test("ADS-C: zufällige Hex-Texte stürzen nicht ab")
    func adsc() {
        var rng = Self.rng(2)
        let heads = ["/EDDHXAX.ADS.D-AIZZ", "/BOGXCXA.AT1.D-ABCD", "/EDDHXAX.CR1.D-ABCD", "/EDDHXAX.ADS", "/X.ADS.", "/"]
        for _ in 0..<Self.runs(3000) {
            let hex = rng.bytes(upTo: 40).map { String(format: "%02X", $0) }.joined()
            let text = heads[rng.int(0...(heads.count - 1))] + hex
            _ = ADSC.parse(text, isDownlink: rng.chance(0.5))
        }
    }

    /// AVLC-Rahmen mit korrekter FCS, damit die Auswertung erreicht wird.
    static func avlc(_ body: [UInt8]) -> [UInt8] {
        let fcs = VDL2Coding.crc16(body) ^ 0xFFFF
        return body + [UInt8(fcs & 0xFF), UInt8(fcs >> 8)]
    }

    @Test("VDL2: AVLC, X.25, XID und ACARS-Inhalt stürzen nicht ab")
    func vdl2() {
        var rng = Self.rng(3)
        for n in 0..<Self.runs(6000) {
            var body = rng.bytes(8)
            switch n % 4 {
            case 0: body += [rng.byte() & 0xFE, 0xFF, 0xFF, 0x01] + rng.bytes(upTo: 40)        // ACARS in I-Rahmen
            case 1: body += [rng.byte() & 0xFE, 0x10 | rng.byte() & 0x0F, rng.byte(), rng.byte()] + rng.bytes(upTo: 30)  // X.25
            case 2: body += [0xAF, 0x82] + [0xF0, 0, UInt8(rng.int(0...20))] + rng.bytes(upTo: 24)  // XID
            default: body += rng.bytes(upTo: 40)
            }
            if rng.chance(0.2) { body = Self.mutate(body, &rng) }
            _ = VDL2Coding.parseAVLC(Self.avlc(body))
            _ = VDL2Coding.parseX25(Array(body.dropFirst(9)))
            _ = VDL2Coding.describeX25(Array(body.dropFirst(9)))
            _ = VDL2Coding.parseXID(Array(body.dropFirst(9)))
            _ = VDL2Coding.parseACARS(Array(body.dropFirst(12)))
        }
        // K1 über VDL2: FF FF 01 + 13 Byte.
        let k1: [UInt8] = [0, 0, 0, 2, 0, 0, 0, 2, 0x00, 0xFF, 0xFF, 0x01] + Array("2.D-ABCD!H11".utf8) + [0x02]
        _ = VDL2Coding.parseAVLC(Self.avlc(k1))
    }

    @Test("ATN-Stapel: X.25-Daten über CLNP/COTP/ULCS stürzen nicht ab")
    func atnStack() {
        var rng = Self.rng(4)
        let decoder = ATNDecoder()
        let firstBytes: [UInt8] = [0x81, 0x82, 0xE0, 0x10, 0x30, 0x60, 0x70, 0x90, 0xA0, 0x00]
        for n in 0..<Self.runs(4000) {
            var data: [UInt8]
            switch n % 3 {
            case 0:
                // Komprimiertes CLNP + COTP DT + Sitzung
                data = [firstBytes[rng.int(3...9)], rng.byte(), rng.byte(), rng.byte() & 0x7F]
                if rng.chance(0.5) { data += rng.bytes(6) }
                data += [UInt8(rng.int(2...6)), 0xF0, rng.byte(), rng.byte(), 0x80 | rng.byte()]
                data += [rng.chance(0.5) ? 0xE8 : rng.byte(), 0x02] + rng.bytes(upTo: 40)
            case 1:
                data = [0x81, UInt8(rng.int(0...30))] + rng.bytes(upTo: 60)
            default:
                data = [firstBytes[rng.int(0...9)]] + rng.bytes(upTo: 60)
            }
            let key = "\(rng.int(0...600))"
            _ = decoder.handle(x25Data: data, more: rng.chance(0.3), key: key, fromAircraft: rng.chance(0.5))
        }
        // W14: wechselnde Schlüssel dürfen den Puffer nicht unbegrenzt füllen.
        for k in 0..<2000 { _ = decoder.handle(x25Data: rng.bytes(16), more: true, key: "k\(k)", fromAircraft: true) }
        #expect(decoder.pendingFragments <= 2 * ATNFragmentStore.maxKeys)
    }

    @Test("PER-Dekoder: ATN- und FANS-Typen mit Zufallsbits stürzen nicht ab")
    func perDecoder() throws {
        var rng = Self.rng(5)
        let atn = try #require(ASN1Schema.atn)
        let fans = try #require(ASN1Schema.fans)
        let atnTypes = ["ACSE_apdu", "CMAircraftMessage", "CMGroundMessage", "ATCDownlinkMessage", "ATCUplinkMessage",
                        "ProtectedAircraftPDUs", "ProtectedGroundPDUs", "Fully_encoded_data", "ATCUplinkMsgElementId",
                        "Level", "Time", "FreeText"]
        let fansTypes = ["FANSATCDownlinkMessage", "FANSATCUplinkMessage"]
        let seeds: [[UInt8]] = [[0x4A, 0x00], [0x0A, 0x25, 0x00], [0xB6, 0x40], [0x2B, 0xC0], [0x01, 0x91, 0x24]]
        for n in 0..<Self.runs(3000) {
            let bytes = n % 4 == 0 ? Self.mutate(seeds[rng.int(0...(seeds.count - 1))], &rng) : rng.bytes(upTo: 64)
            // Erweiterungsbits und große Normally-small-Werte gezielt anbieten.
            let data = rng.chance(0.3) ? [0xFF, 0xFF, 0xFF] + bytes : bytes
            let type = atnTypes[n % atnTypes.count]
            if let value = try? PERDecoder(schema: atn).decode(type, bytes: data) {
                _ = CPDLCFormatter.atn(value, uplink: type.contains("Uplink"), schema: atn)
                _ = CPDLCFormatter.format(value, type: type, schema: atn)
            }
            let fansType = fansTypes[n % 2]
            if let value = try? PERDecoder(schema: fans).decode(fansType, bytes: data) {
                _ = CPDLCFormatter.fans(value, uplink: fansType.contains("Uplink"), schema: fans)
            }
        }
        // K2: erweiterte CHOICE mit riesigem Normally-small-Index.
        let huge: [UInt8] = [0x80 | 0x40, 0xBF, 0xFF] + [UInt8](repeating: 0xFF, count: 40)
        for type in atnTypes { _ = try? PERDecoder(schema: atn).decode(type, bytes: huge) }
    }

    // MARK: - Zigbee, Thread

    @Test("Zigbee: MAC/NWK/APS/ZCL/ZDO und Gesamtauswertung stürzen nicht ab")
    func zigbee() {
        var rng = Self.rng(6)
        let key: [UInt8] = Array(0x10...0x1F)
        let zdoClusters: [UInt16] = [0x0000, 0x0001, 0x0002, 0x0004, 0x0005, 0x0006, 0x0013, 0x0021, 0x0022, 0x0034, 0x0036,
                                     0x8000, 0x8001, 0x8002, 0x8004, 0x8005, 0x8031, 0x8032]
        let zclClusters: [UInt16] = [0x0000, 0x0001, 0x0006, 0x0008, 0x0012, 0x0020, 0x0101, 0x0102, 0x0201, 0x0300, 0x0400,
                                     0x0402, 0x0403, 0x0405, 0x0406, 0x040D, 0x042A, 0x0500, 0x0702, 0x0B04, 0x0B05, 0xEF00]
        for n in 0..<Self.runs(6000) {
            let payload = rng.bytes(upTo: 48)
            let cluster = n % 2 == 0 ? zclClusters[rng.int(0...(zclClusters.count - 1))] : UInt16(truncatingIfNeeded: rng.next())
            _ = ZCLMessage.parse(payload, cluster: cluster)
            _ = ZCL.records(payload, withStatus: rng.chance(0.5)).compactMap { ZCL.describe(cluster: cluster, $0) }
            _ = ZDOMessage.parse(cluster: zdoClusters[rng.int(0...(zdoClusters.count - 1))], payload)
            _ = Tuya.dataPoints(payload)
            _ = Xiaomi.readings(payload)
            _ = NWKCommand.linkStatus([0x08] + payload)
            _ = ZigbeeBeacon.parse(payload)
            _ = APSFrame.parse(payload)
            _ = NWKFrame.parse(payload)
            if let mac = MACFrame.parse(payload) {
                _ = LoWPANPacket.parse(mac.payload, mac: mac)
                _ = ThreadFrame.interpret(mpdu: payload, mac: mac, networkKeys: [key], addresses: [:])
            }
            _ = MLEMessage.parseTLVs(payload)
        }
        // ZCL-Werte gezielt: Float NaN/∞ (Typ 0x39), int8 −1 beim Türschloss, Zonenstatus.
        let nan: [UInt8] = [0x00, 0x00, 0xC0, 0x7F], inf: [UInt8] = [0x00, 0x00, 0x80, 0x7F]
        for cluster: UInt16 in [0x0101, 0x0500, 0x0012, 0x0300, 0x0402] {
            for attribute: [UInt8] in [[0x00, 0x00], [0x02, 0x00], [0x55, 0x00], [0x07, 0x00]] {
                for value: [UInt8] in [[0x39] + nan, [0x39] + inf, [0x28, 0xFF], [0x20, 0xFF]] {
                    let report = [0x18, 0x01, 0x0A] + attribute + value
                    _ = ZCLMessage.parse(report, cluster: cluster)
                }
            }
        }
        // Ganze unverschlüsselte Rahmen: MAC-Daten → NWK → APS → ZCL/ZDO, auch Nachbartabellen mit Doppeln.
        for n in 0..<Self.runs(4000) {
            let profile: UInt16 = n % 2 == 0 ? 0x0000 : 0x0104
            let cluster = profile == 0 ? zdoClusters[rng.int(0...(zdoClusters.count - 1))] : zclClusters[rng.int(0...(zclClusters.count - 1))]
            let mac: [UInt8] = [0x41, 0x88, rng.byte(), 0x62, 0x1A, 0x00, 0x00, rng.byte(), rng.byte()]
            let nwk: [UInt8] = [0x08, 0x00, rng.byte(), rng.byte(), rng.byte(), rng.byte(), 30, rng.byte()]
            let aps: [UInt8] = [0x40, 0x01, UInt8(cluster & 0xFF), UInt8(cluster >> 8), UInt8(profile & 0xFF), UInt8(profile >> 8), 0x01, rng.byte()]
            var body = rng.bytes(upTo: 40)
            if cluster == 0x8031, rng.chance(0.5) {
                // Mgmt_Lqi_rsp mit zweimal derselben Nachbaradresse (K7).
                let entry = rng.bytes(16) + [0x34, 0x12] + rng.bytes(4)
                body = [rng.byte(), 0x00, 2, 0, 2] + entry + entry
            }
            var mpdu = mac + nwk + aps + body
            if rng.chance(0.2) { mpdu = Self.mutate(mpdu, &rng) }
            let radio = ZigbeeRadioFrame(channel: 15, mpdu: mpdu, rssiDB: -40, offsetKHz: 0, date: Date(timeIntervalSince1970: 1_700_000_000))
            _ = ZigbeePacket.interpret(radio, id: n, keys: [key], threadKeys: [key], threadAddresses: [:])
        }
        // Verschlüsselter Testrahmen, mutiert.
        let valid = ZigbeeTests.temperatureFrame()
        for n in 0..<Self.runs(1500) {
            let radio = ZigbeeRadioFrame(channel: 15, mpdu: Self.mutate(valid, &rng), rssiDB: -40, offsetKHz: 0, date: Date())
            _ = ZigbeePacket.interpret(radio, id: n, keys: [ZigbeeTests.key])
        }
        for text in ["Wert", "-", "1.2.3", "Cluster 0x0402 = 99", "„123“", "--5", "x 1e400"] { _ = ZigbeeReading.parse(text) }
    }

    // MARK: - Meshtastic, LoRaWAN

    @Test("Meshtastic: Kopf, Protobuf und Inhalte stürzen nicht ab")
    func meshtastic() {
        var rng = Self.rng(7)
        let channels = [MeshtasticChannel(name: "LongFast", psk: [1])]
        for n in 0..<Self.runs(6000) {
            let bytes = rng.bytes(upTo: 64)
            _ = ProtobufMessage(bytes)
            _ = MeshtasticData(bytes)
            _ = MeshtasticPosition(bytes)
            _ = MeshtasticUser(bytes)
            _ = MeshtasticTelemetry(bytes)
            _ = MeshtasticContent(portnum: [1, 3, 4, 67, 5, 70][n % 6], payload: bytes)
            _ = Meshtastic.decode(rng.bytes(16) + bytes, channels: channels)
        }
        // K8: Varints ≥ 2⁶³ in jedem Zahlenfeld.
        let big: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        for field in [1, 3, 5, 7, 15, 19, 23] {
            let message = [UInt8(field << 3)] + big
            _ = MeshtasticPosition(message)
            _ = MeshtasticUser(message)
            _ = MeshtasticTelemetry([0x12, UInt8(message.count)] + message)
        }
        _ = Meshtastic.duration(Int.max)
    }

    @Test("LoRaWAN: Rahmen mit und ohne Sitzungsschlüssel stürzen nicht ab")
    func lorawan() {
        var rng = Self.rng(8)
        let devAddr: UInt32 = 0x2601_1BDA
        let session = LoRaWANSession(devAddr: devAddr, nwkSKey: Array(0..<16), appSKey: Array(16..<32), label: nil)
        for n in 0..<Self.runs(5000) {
            var phy = [UInt8(rng.int(0...7) << 5)] + rng.bytes(upTo: 40)
            if n % 2 == 0, phy.count >= 5 {
                phy[1] = 0xDA; phy[2] = 0x1B; phy[3] = 0x01; phy[4] = 0x26
            }
            _ = LoRaWANParser.parse(phy, sessions: [devAddr: session])
            _ = LoRaCoding.parseHeader((0..<5).map { _ in rng.byte() & 0x0F })
        }
    }

    // MARK: - AIS, ADS-B, APRS, Sonden, Funkruf

    @Test("AIS: Bitfolgen aller Meldungstypen stürzen nicht ab")
    func ais() {
        var rng = Self.rng(9)
        var tracker = AISTracker()
        for n in 0..<Self.runs(6000) {
            var bytes = rng.bytes(upTo: 60)
            if !bytes.isEmpty { bytes[0] = UInt8(n % 28) << 2 | bytes[0] & 3 }
            let bits = AISBits(frameBytes: bytes)
            if let message = AISMessage.decode(bits) {
                tracker.ingest(message, channel: "A", at: Date(timeIntervalSince1970: Double(n)))
                _ = AISNMEA.sentences(for: bits, channel: "A", sequence: n)
            }
            _ = AISMessage.decode(AISBits(bits: (0..<rng.int(0...500)).map { _ in rng.byte() & 1 }))
        }
        #expect(tracker.vessels.count <= AISTracker.maxVessels)
    }

    @Test("DSC: Zeichenfolgen mit gültigem Prüfzeichen und zufällige Bits stürzen nicht ab")
    func dsc() {
        var rng = Self.rng(31)
        let formats: [UInt8] = [102, 112, 114, 116, 120, 123]
        var log = DSCCallLog()
        for n in 0..<Self.runs(20000) {
            // Formatkennzeichen, sonst Ziffern/Befehle in beliebiger Länge, EOS und passendes ECC.
            let format = rng.chance(0.9) ? formats[rng.int(0...5)] : rng.byte() & 0x7F
            var message: [UInt8] = [format, rng.chance(0.95) ? format : rng.byte() & 0x7F]
            for _ in 0..<rng.int(0...40) {
                message.append(rng.chance(0.7) ? UInt8(rng.int(0...99)) : UInt8(rng.int(100...127)))
            }
            message.append([117, 122, 127][rng.int(0...2)])
            var symbols = message + [DSCSymbol.ecc(message.dropFirst())]
            if rng.chance(0.1), !symbols.isEmpty { symbols[rng.int(0...(symbols.count - 1))] = rng.byte() }
            if let call = DSCCall.parse(symbols) {
                _ = (call.kindText, call.natureText, call.subsequentText, call.position?.text, call.area?.text, call.timeText)
                _ = MaritimeIdentity.country(call.sender)
                log.ingest(call, at: Date(timeIntervalSince1970: Double(n)))
            }
            _ = DSCCall.parse(rng.bytes(upTo: 60))
        }
        #expect(log.entries.count <= DSCCallLog.maxEntries)
        // Zufällige und halb gültige Bitströme in den Rahmenbauer.
        var assembler = DSCFrameAssembler()
        for _ in 0..<Self.runs(40) {
            var bits = (0..<rng.int(0...3000)).map { _ in rng.byte() & 1 }
            if rng.chance(0.5) {
                bits += DSCSymbol.transmission(message: [116, 116] + (0..<rng.int(0...50)).map { _ in rng.byte() & 0x7F } + [127])
                    .flatMap(DSCSymbol.bits).map { rng.chance(0.02) ? $0 ^ 1 : $0 }
            }
            for bit in bits { if let frame = assembler.push(bit) { _ = DSCCall.parse(frame.symbols) } }
        }
        for id in [0, 1, 999_999_999, 2_111_240, 970_000_000] { _ = MaritimeIdentity.classify(id) }
    }

    @Test("ADS-B: Rahmen mit gültiger Prüfsumme und Ortung stürzen nicht ab")
    func adsb() {
        var rng = Self.rng(10)
        var tracker = AircraftTracker()
        tracker.receiver = (53.5, 9.9)
        for n in 0..<Self.runs(6000) {
            var bytes = [UInt8(rng.chance(0.5) ? 17 << 3 : 18 << 3) | rng.byte() & 7] + rng.bytes(10) + [0, 0, 0]
            let crc = ADSBDemodulator.crc24(Array(bytes.prefix(11)) + [0, 0, 0])
            bytes[11] = UInt8(crc >> 16 & 0xFF); bytes[12] = UInt8(crc >> 8 & 0xFF); bytes[13] = UInt8(crc & 0xFF)
            if let message = ADSBDemodulator.decode(bytes, now: Date(timeIntervalSince1970: Double(n))) {
                tracker.ingest(message)
            }
        }
    }

    @Test("APRS und AX.25: Rahmen und TNC2-Zeilen stürzen nicht ab")
    func aprs() {
        var rng = Self.rng(11)
        let starts = ["!", "=", "/", "@", "`", "'", ";", ")", ":", ">", "}", "T#", "$GPRMC,"]
        for _ in 0..<Self.runs(5000) {
            let call: [UInt8] = Array("DL1ABC".utf8).map { $0 << 1 }
            let frame = call + [0x60] + call + [0x61, 0x03, 0xF0] + rng.bytes(upTo: 60)
            if let ax = AX25Frame.parse(rng.chance(0.2) ? Self.mutate(frame, &rng) : frame) { _ = APRSPacket.parse(ax) }
            let info = starts[rng.int(0...(starts.count - 1))]
                + String(decoding: (0..<rng.int(0...50)).map { _ in UInt8(rng.int(0x20...0x7E)) }, as: UTF8.self)
            _ = APRSPacket.parse(tnc2: "DL1ABC>APRS,WIDE1-1:" + info)
        }
    }

    @Test("Radiosonden RS41 und Funkruf: Zufallsrahmen stürzen nicht ab")
    func sondeAndPager() {
        var rng = Self.rng(12)
        var calibration: [String: RS41.Calibration] = [:]
        for _ in 0..<Self.runs(1500) {
            _ = RS41.parse(rng.bytes(upTo: 520), calibration: &calibration)
        }
        var framer = POCSAGFramer(bitRate: 1200)
        for _ in 0..<Self.runs(60_000) { _ = framer.push(rng.byte() & 1) }
        _ = framer.flush()
        for _ in 0..<Self.runs(500) { _ = DCF77Code.decode((0..<rng.int(0...70)).map { _ in rng.byte() & 1 }) }
    }

    // MARK: - BLE, WLAN, Remote ID

    @Test("BLE, WLAN und Remote ID: Zufallsrahmen stürzen nicht ab")
    func bleWlanRemoteID() {
        var rng = Self.rng(13)
        for n in 0..<Self.runs(6000) {
            let pdu = [rng.byte() & 0x4F, UInt8(rng.int(6...37))] + rng.bytes(upTo: 40)
            if let ad = BLEAdvertisement.parse(pdu) {
                _ = BLEInterpreter.interpret(ad)
                _ = RemoteID.parse(ad)
            }
            let message = [UInt8(rng.int(0...7) << 4 | 2)] + rng.bytes(24)
            _ = RemoteID.decodeSingle(message)
            _ = RemoteID.decode([0xF2, 0x19, UInt8(rng.int(0...12))] + rng.bytes(upTo: 200))
            _ = RemoteID.parseServiceData([RemoteID.appCode, rng.byte()] + rng.bytes(upTo: 60))
            _ = RemoteID.parseBeaconElements([0xDD, UInt8(rng.int(0...40)), 0xFA, 0x0B, 0xBC, 0x0D] + rng.bytes(upTo: 40))
            _ = RemoteID.parseNANServiceInfo(rng.bytes(upTo: 60))
            _ = FrenchDroneID.parse(elements: [0xDD, UInt8(rng.int(0...40)), 0x6A, 0x5C, 0x35, 0x01] + rng.bytes(upTo: 40))
            _ = FrenchDroneID.parse(tlv: rng.bytes(upTo: 40))
            let fc: [UInt8] = [[0x80, 0x00], [0x50, 0x00], [0x40, 0x00], [0xD0, 0x00], [0xD4, 0x00], [0x08, 0x01]][n % 6]
            if let frame = WLANFrame.parse(fc + rng.bytes(upTo: 80)) { _ = RemoteID.parse(frame) }
        }
    }

    // MARK: - DAB

    @Test("DAB: FIG, Unterkanäle, Superframe und PAD stürzen nicht ab")
    func dab() {
        var rng = Self.rng(14)
        var ensemble = DABEnsemble()
        for _ in 0..<Self.runs(6000) {
            var fib = [UInt8]()
            while fib.count < 30 {
                let length = rng.int(1...10)
                fib += [UInt8(rng.int(0...1) << 5 | length)] + [rng.byte() & 0x9F] + rng.bytes(length - 1)
            }
            ensemble.process(fib: Array(fib.prefix(30))[...])
        }
        // K9: jeder Unterkanal (auch 1–11 CU) und jede Stufe.
        for size in 0...60 {
            for level in 0...5 {
                for profileB in [false, true] {
                    let sub = DABSubchannel(id: 0, startCU: 0, sizeCU: size, protection: .eep(profileB: profileB, level: level))
                    _ = sub.bitrate
                    _ = sub.puncturing.map { ($0.motherBits, $0.transmittedBits, $0.dataBits) }
                    _ = DABSubchannelDecoder(subchannel: sub)
                    _ = sub.protection.description
                }
            }
        }
        for sub in ensemble.subchannels.values {
            _ = sub.puncturing
            _ = DABSubchannelDecoder(subchannel: sub)
        }
        for index in [-1, 0, 63, 64, 1000] { _ = DABSubchannel(id: 0, startCU: 0, sizeCU: 10, protection: .uep(tableIndex: index)).puncturing }

        let superframe = DABPlusSuperframeDecoder()
        for _ in 0..<Self.runs(2000) {
            var sf = rng.bytes(120 * rng.int(1...4))
            let fire = DABCRC.fire(sf[2..<11])
            sf[0] = UInt8(fire >> 8); sf[1] = UInt8(fire & 0xFF)
            _ = superframe.split(sf)
        }
        let pad = DABPADDecoder()
        for _ in 0..<Self.runs(8000) {
            let fpad: [UInt8] = [UInt8(rng.int(0...3) << 4), rng.chance(0.7) ? 0x02 : 0x00]
            _ = pad.process(pad: rng.bytes(upTo: 60) + fpad, exactLength: rng.chance(0.5))
        }
    }

    // MARK: - DVB-T2, Transportstrom, Fernsehton

    @Test("DVB-T2: L1-Signalisierung, BBHEADER und Layout stürzen nicht ab")
    func dvbt2() {
        var rng = Self.rng(15)
        for _ in 0..<Self.runs(3000) { _ = T2BBHeader(bytes: rng.bytes(upTo: 12)[...]) }
        let extractor = T2TransportStreamExtractor()
        for _ in 0..<Self.runs(200) {
            extractor.process(bits: (0..<(8 * rng.int(0...400))).map { _ in rng.byte() & 1 }, ok: rng.chance(0.9))
        }
        // K11/W12: Datensymbole aus dem L1-pre – 0, 1, 2 und riesig.
        for symbols in [0, 1, 2, 3, 100, 4095] {
            for fft in [T2FFTSize.k1, .k16, .k32] {
                _ = T2Layout(fft: fft, guardInterval: .g1_128, pattern: .pp2, extended: false, toneReservation: false, dataSymbols: symbols)
            }
        }
        // K10: L1-pre mit beliebiger L1-post-Größe gegen zu wenige Zellen.
        let cells: [[Float]] = [(0..<2000).map { _ in Float(rng.int(-100...100)) / 50 }]
        let weights: [[Float]] = [[Float](repeating: 1, count: 2000)]
        _ = T2L1Decoder.decodePre(re: [], im: [], weights: [])
        _ = T2L1Decoder.decodePre(re: cells, im: cells, weights: weights)
    }

    /// PSI-Abschnitt mit gültiger CRC-32 (MPEG-2, ohne Schluss-XOR).
    static func section(table: UInt8, body: [UInt8]) -> [UInt8] {
        let length = 5 + body.count + 4
        var s: [UInt8] = [table, 0xB0 | UInt8(length >> 8 & 0x0F), UInt8(length & 0xFF), 0x00, 0x01, 0xC1, 0x00, 0x00] + body
        let crc = TSDemuxer.crc32(s[...])
        s += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
        return s
    }

    static func tsPacket(pid: Int, start: Bool, counter: Int, payload: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x47, UInt8(start ? 0x40 : 0) | UInt8(pid >> 8 & 0x1F), UInt8(pid & 0xFF), 0x10 | UInt8(counter & 0x0F)]
        p += payload.prefix(184)
        while p.count < 188 { p.append(0xFF) }
        return p
    }

    @Test("Transportstrom: PAT/PMT/SDT/NIT und PES stürzen nicht ab")
    func transportStream() {
        var rng = Self.rng(16)
        let demux = TSDemuxer()
        demux.pesPIDs = [0x100, 0x101]
        demux.pesHandler = { _ in }
        var counters: [Int: Int] = [:]
        func send(_ pid: Int, _ start: Bool, _ payload: [UInt8]) {
            let c = counters[pid, default: 0]
            counters[pid] = c + 1
            demux.process(Self.tsPacket(pid: pid, start: start, counter: c, payload: payload))
        }
        // PAT mit PMT auf 0x20, PMT mit Video 0x100 und Audio 0x101.
        send(0, true, [0] + Self.section(table: 0x00, body: [0x00, 0x01, 0xE0, 0x20]))
        send(0x20, true, [0] + Self.section(table: 0x02, body: [0xE1, 0x00, 0xF0, 0x00, 0x24, 0xE1, 0x00, 0xF0, 0x00, 0x0F, 0xE1, 0x01, 0xF0, 0x00]))
        for n in 0..<Self.runs(6000) {
            switch n % 5 {
            case 0:
                let table: UInt8 = [0x00, 0x02, 0x42, 0x40][rng.int(0...3)]
                let pid = [0, 0x20, 0x11, 0x10][rng.int(0...3)]
                send(pid, true, [0] + Self.section(table: table, body: rng.bytes(upTo: 160)))
            case 1:
                // PES-Kopf mit beliebiger Kopf- und Paketlänge (K12).
                let header: [UInt8] = [0, 0, 1, 0xC0, rng.byte(), rng.byte(), 0x80, 0xC0, rng.byte()]
                send(0x101, true, header + rng.bytes(upTo: 170))
            case 2:
                send([0x100, 0x101][rng.int(0...1)], false, rng.bytes(184))       // W13: ohne Paketanfang
            default:
                demux.process([0x47] + rng.bytes(187))
            }
        }
    }

    @Test("Fernsehton: ADTS, LATM, MPEG und AC-3 aus Zufallsdaten stürzen nicht ab")
    func tvAudio() {
        var rng = Self.rng(17)
        for kind in [TSStream.Kind.aacADTS, .aacLATM, .mpegAudio, .ac3, .eac3] {
            let decoder = TVAudioDecoder(kind: kind)
            for _ in 0..<Self.runs(300) {
                var data = rng.bytes(upTo: 400)
                // Synchronwörter streuen, damit die Rahmenköpfe gelesen werden.
                for _ in 0..<rng.int(0...6) where data.count > 3 {
                    let i = rng.int(0...(data.count - 3))
                    switch kind {
                    case .aacADTS, .mpegAudio: data[i] = 0xFF; data[i + 1] = 0xF0 | rng.byte() & 0x0F
                    case .aacLATM: data[i] = 0x56; data[i + 1] = 0xE0 | rng.byte() & 0x1F
                    default: data[i] = 0x0B; data[i + 1] = 0x77
                    }
                }
                _ = decoder.decode(Data(data))
            }
            // W13: viele falsche Synchronwörter hintereinander (früher Rekursion je Wort).
            _ = decoder.decode(Data([UInt8](repeating: 0xFF, count: 200_000)))
        }
        // K13: LATM mit StreamMuxConfig v1 und riesiger ascLength.
        let latm = TVAudioDecoder(kind: .aacLATM)
        let element: [UInt8] = [0x60, 0x00, 0x00, 0x7F, 0xFF, 0xFF, 0xFF, 0xF0] + [UInt8](repeating: 0x55, count: 40)
        _ = latm.decode(Data([0x56, 0xE0, UInt8(element.count)] + element))
    }

    // MARK: - METEOR

    @Test("METEOR: VCDU, Bildsegmente und Bildaufbau stürzen nicht ab")
    func meteor() {
        var rng = Self.rng(18)
        let demux = MeteorPacketDemux()
        var assembler = MeteorImageAssembler()
        for n in 0..<Self.runs(400) {
            var vcdu = rng.bytes(892)
            vcdu[1] = vcdu[1] & 0xC0 | 5
            vcdu[2] = 0; vcdu[3] = UInt8(n >> 8 & 0xFF); vcdu[4] = UInt8(n & 0xFF)
            vcdu[8] = rng.chance(0.5) ? 0 : vcdu[8]
            for packet in demux.process(vcdu) { assembler.add(packet) }
        }
        for _ in 0..<Self.runs(3000) {
            var payload = rng.bytes(upTo: 300)
            if payload.count > 14 {
                payload[8] = UInt8(14 * rng.int(0...13)); payload[9] = 0; payload[10] = 0; payload[11] = 0xFF; payload[12] = 0xF0
            }
            _ = MeteorJPEG.decodeSegment(payload)
        }
        // W15: Paketzähler, die weit auseinanderliegen, dürfen keine Riesenbilder anfordern.
        var image = MeteorImageAssembler()
        var segment = [UInt8](repeating: 0, count: 60)
        segment[11] = 0xFF; segment[12] = 0xF0; segment[13] = 50
        for k in 0..<200 {
            image.add(MeteorPacket(apid: 64 + k % 3, sequence: rng.int(0...0x3FFF), payload: segment))
        }
        #expect(image.lineCount <= MeteorImageAssembler.maxRowGroups * 8)
        _ = image.grayImage(channel: 1)
    }

    // MARK: - FT8, WSPR (Review Y21)

    @Test("FT8: 77 Zufallsbits und mutierte Nachrichten mit und ohne Hash-Tabelle stürzen nicht ab")
    func ft8Unpack() {
        var rng = Self.rng(19)
        let hashes = FT8CallHashes()
        for call in ["DL1ABC", "PJ4/K1ABC", "W9XYZ", "K1ABC/P", "TX9/DL1XYZ", "3DA0XYZ"] { hashes.save(call) }
        let samples = ["CQ DL1ABC JO62", "W9XYZ <PJ4/K1ABC> RR73", "PJ4/K1ABC W9XYZ -07", "CQ PJ4/K1ABC",
                       "DL1ABC W9XYZ R-12", "123456789ABCDEF012", "TNX BOB 73 GL"]
        let packed = samples.compactMap { FT8Message.pack($0, hashes: hashes) }
        for n in 0..<Self.runs(20_000) {
            var bits: [UInt8]
            if n % 2 == 0 || packed.isEmpty {
                bits = (0..<rng.int(70...80)).map { _ in UInt8(rng.next() & 1) }
            } else {
                bits = packed[rng.int(0...(packed.count - 1))]
                for _ in 0..<rng.int(1...8) { bits[rng.int(0...(bits.count - 1))] ^= 1 }
            }
            // i3/n3 gezielt auf alle Typen setzen.
            if bits.count >= 77, rng.chance(0.5) {
                let i3 = rng.int(0...7), n3 = rng.int(0...7)
                for k in 0..<3 {
                    bits[74 + k] = UInt8((i3 >> (2 - k)) & 1)
                    bits[71 + k] = UInt8((n3 >> (2 - k)) & 1)
                }
            }
            if let m = FT8Message.unpack(bits, hashes: rng.chance(0.5) ? hashes : nil) {
                _ = m.text
                if let from = m.from { hashes.save(from) }
            }
        }
    }

    @Test("FT8: Hash-Tabelle bleibt bei vielen Rufzeichen begrenzt")
    func ft8HashCapacity() throws {
        let hashes = FT8CallHashes(capacity: 100)
        var rng = Self.rng(20)
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        for _ in 0..<5000 {
            hashes.save("D" + String((0..<5).map { _ in letters[rng.int(0...(letters.count - 1))] }))
        }
        #expect(hashes.count <= 100)
        hashes.save("DL1ABC")
        let h = try #require(FT8CallHashes.hash("DL1ABC", bits: 22))
        #expect(hashes.lookup22(h) == "DL1ABC")
    }

    @Test("WSPR: unpack mit Zufallsdaten und Fano mit Zufallssymbolen stürzen nicht ab")
    func wspr() {
        var rng = Self.rng(21)
        let hashes = WSPRCallHashes()
        hashes.save("DL1ABC")
        for _ in 0..<Self.runs(20_000) {
            _ = WSPRCodec.unpack(rng.bytes(11), hashes: rng.chance(0.5) ? hashes : nil)
        }
        // Fano mit begrenzter Laufzeit: wenige Zyklen je Bit.
        let start = Date()
        for n in 0..<Self.runs(60) {
            let symbols: [UInt8] = n % 3 == 0
                ? (0..<162).map { _ in rng.chance(0.5) ? 128 : rng.byte() }
                : rng.bytes(162)
            if let data = WSPRCodec.fano(symbols, maxCyclesPerBit: 200) { _ = WSPRCodec.unpack(data, hashes: hashes) }
        }
        #expect(Date().timeIntervalSince(start) < 30 * Double(Self.scale))
    }

    // MARK: - LTE (Review Y21)

    @Test("LTE: MIB, DCI und SIB1 mit Zufallsbits stürzen nicht ab")
    func lteParsers() {
        var rng = Self.rng(22)
        for _ in 0..<Self.runs(5000) {
            let bits = (0..<rng.int(0...40)).map { _ in UInt8(rng.next() & 1) }
            _ = LTEMIB.parse(bits, ports: rng.int(1...4), segment: rng.int(0...3))
        }
        for _ in 0..<Self.runs(5000) {
            let nRB = rng.chance(0.7) ? [6, 15, 25, 50, 75, 100][rng.int(0...5)] : rng.int(6...110)
            let bits = (0..<rng.int(0...40)).map { _ in UInt8(rng.next() & 1) }
            for format in [LTEDCI.Format.f1A, .f1C] {
                if let dci = LTEDCI.parse(bits, format: format, nRB: nRB) {
                    _ = LTEAllocation.prbs(for: dci, nRB: nRB)
                    _ = LTEAllocation.transportBlockSize(dci)
                }
            }
        }
        for _ in 0..<Self.runs(3000) {
            _ = LTESIB1.parse((0..<rng.int(0...600)).map { _ in UInt8(rng.next() & 1) })
        }
        // Gültige SIB1, mutiert und gekürzt.
        let base = LTESIB1(plmns: [.init(mcc: "262", mnc: "01"), .init(mcc: "262", mnc: "023")], tac: 0xB1A7,
                           cellIdentity: 0x1A2B3C4, cellBarred: false, intraFreqReselectionAllowed: true,
                           qRxLevMinDBm: -124, pMax: 23, freqBandIndicator: 20)
        let encoded = base.encode()
        for _ in 0..<Self.runs(3000) {
            var bits = encoded
            for _ in 0..<rng.int(1...6) { bits[rng.int(0...(bits.count - 1))] ^= 1 }
            if rng.chance(0.3) { bits = Array(bits.prefix(rng.int(0...bits.count))) }
            _ = LTESIB1.parse(bits)
        }
    }

    @Test("LTE: Zuteilung über alle Bandbreiten, RIV und MCS stürzt nicht ab")
    func lteAllocation() {
        var rng = Self.rng(23)
        for nRB in 6...110 {
            let standard = [6, 15, 25, 50, 75, 100].contains(nRB)
            for format in [LTEDCI.Format.f1A, .f1C] {
                let n = format == .f1A ? nRB
                    : LTEAllocation.vrbCount(nRB: nRB, gap2: false) / LTEAllocation.rbStep(nRB)
                let width = LTEDCI.rivBits(max(n, 1))
                let rivs: [Int] = standard ? Array(0..<(1 << width)) : (0..<300).map { _ in rng.int(0...((1 << width) - 1)) }
                for riv in rivs {
                    for distributed in [false, true] where format == .f1A || distributed {
                        for gap2 in [false, true] {
                            let dci = LTEDCI(format: format, distributed: distributed, gap2: gap2, riv: riv,
                                             mcs: rng.int(0...31), rv: format == .f1A ? rng.int(0...3) : nil,
                                             nPRB1A: rng.chance(0.5) ? 2 : 3)
                            if let prbs = LTEAllocation.prbs(for: dci, nRB: nRB) {
                                #expect(prbs.slot0.allSatisfy { (0..<nRB).contains($0) })
                            }
                        }
                    }
                }
            }
        }
        for mcs in 0...31 {
            for format in [LTEDCI.Format.f1A, .f1C] {
                for column in [2, 3] {
                    _ = LTEAllocation.transportBlockSize(LTEDCI(format: format, distributed: false, gap2: false, riv: 0,
                                                                mcs: mcs, rv: 0, nPRB1A: column))
                }
            }
        }
        for sfn in 0..<1024 { #expect((0...3).contains(LTEAllocation.sib1RV(sfn: sfn))) }
    }

    // MARK: - Funkfeuer, Morse (Review Y21)

    @Test("Funkfeuer-CSV: nan, inf, 1e400 und kaputte Zeilen stürzen nicht ab")
    func navaidCSV() {
        var rng = Self.rng(24)
        let header = "id,filename,ident,name,type,frequency_khz,latitude_deg,longitude_deg,iso_country,magnetic_variation_deg,slaved_variation_deg"
        let numbers = ["nan", "NaN", "inf", "-inf", "1e400", "-1e400", "113000", "113000.4", "0x1p20", "", "abc", "9e18",
                       "-9e18", "108000", "117950", "117950.6", "52.5", "-200", "1e-400"]
        var lines = [header]
        for _ in 0..<Self.runs(3000) {
            func number() -> String { numbers[rng.int(0...(numbers.count - 1))] }
            var fields = ["1", "x.csv", "ABC", "\"Name, mit Komma\"", rng.chance(0.8) ? "VOR-DME" : "NDB",
                          number(), number(), number(), "DE", number(), number()]
            if rng.chance(0.2) { fields = Array(fields.prefix(rng.int(0...fields.count))) }
            var line = fields.joined(separator: ",")
            if rng.chance(0.1) { line += "\"" }
            lines.append(line)
        }
        let navaids = NavaidCSV.parse(lines.joined(separator: rng.chance(0.5) ? "\n" : "\r\n"))
        for navaid in navaids {
            #expect((108_000...117_950).contains(navaid.frequencyKHz))
            #expect(navaid.latitude.isFinite && navaid.longitude.isFinite)
            #expect(navaid.declination?.isFinite ?? true)
        }
        // Gezielt: genau die Werte, die vor dem Fix abstürzten (Y2).
        for bad in ["nan", "inf", "-inf", "1e400"] {
            #expect(NavaidCSV.parse("\(header)\n1,x,ABC,N,VOR,\(bad),50,8,DE,,").isEmpty)
            #expect(NavaidCSV.parse("\(header)\n1,x,ABC,N,VOR,113000,\(bad),8,DE,,").isEmpty)
            #expect(NavaidCSV.parse("\(header)\n1,x,ABC,N,VOR,113000,50,\(bad),DE,,").isEmpty)
        }
        #expect(NavaidCSV.parse("\(header)\n1,x,ABC,N,VOR,113000,50,8,DE,,").count == 1)
        #expect(NavaidCSV.parse("\(header)\n1,x,ABC,N,VOR,113000,95,8,DE,,").isEmpty)
    }

    @Test("Morse: Zufallselemente (auch Dauer 0) und Zufallspegel stürzen nicht ab")
    func morse() {
        var rng = Self.rng(25)
        for _ in 0..<Self.runs(5000) {
            let elements = (0..<rng.int(0...40)).map { k in
                MorseDecoder.Element(on: k % 2 == 0 || rng.chance(0.2),
                                     seconds: rng.chance(0.2) ? 0 : (rng.chance(0.05) ? 1e-300 : Double(rng.int(0...3000)) / 1000))
            }
            _ = MorseDecoder.decode(elements)
        }
        let decoder = MorseDecoder(rate: 100)
        for _ in 0..<Self.runs(200) {
            let levels: [Float] = (0..<rng.int(0...400)).map { _ in
                switch rng.int(0...9) {
                case 0: .nan
                case 1: .infinity
                case 2: 0
                default: Float(rng.int(0...1000)) / 10
                }
            }
            decoder.feed(levels)
        }
        _ = decoder.confirmedIdent
    }

    // MARK: - Belegungsaufzeichnung (Review Y21, Y3)

    @Test("Belegungsaufzeichnung: Zufallskopf und NaN-Felder stürzen nicht ab")
    func occupancyRecording() {
        var rng = Self.rng(26)
        let plan = OccupancyPlan(startMHz: 433.05, endMHz: 434.79, binKHz: 25)
        var recording = OccupancyRecording(name: "Fuzz", plan: plan, sliceSeconds: 60, thresholdDB: 10)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        recording.slices = (0..<6).map { i in
            OccupancySlice(start: start.addingTimeInterval(Double(i) * 60), floorDB: -60, visits: 3,
                           mean: rng.bytes(plan.binCount), peak: rng.bytes(plan.binCount), occupancy: rng.bytes(plan.binCount))
        }
        let valid = recording.encoded()
        let specials: [UInt64] = [Double.nan.bitPattern, Double.infinity.bitPattern, (-Double.infinity).bitPattern,
                                  Double.greatestFiniteMagnitude.bitPattern, 0, (1e300).bitPattern, (-1.0).bitPattern]
        let floatSpecials: [UInt32] = [Float.nan.bitPattern, Float.infinity.bitPattern, 0x7F7F_FFFF, 0]
        for n in 0..<Self.runs(4000) {
            var data = valid
            switch n % 4 {
            case 0:
                // Kopffelder gezielt auf Sonderwerte
                for offset in [12, 20, 28] where rng.chance(0.5) {
                    data.putLE(specials[rng.int(0...(specials.count - 1))], at: offset)
                }
                if rng.chance(0.5) { data.putLE(floatSpecials[rng.int(0...(floatSpecials.count - 1))], at: 36) }
                if rng.chance(0.3) { data.putLE(UInt32(truncatingIfNeeded: rng.next()), at: 8) }
            case 1:
                // Zeit und Boden einer Scheibe
                let o = OccupancyRecording.headerSize + rng.int(0...5) * recording.recordSize
                data.putLE(specials[rng.int(0...(specials.count - 1))], at: o)
                if rng.chance(0.5) { data.putLE(floatSpecials[rng.int(0...(floatSpecials.count - 1))], at: o + 8) }
            case 2:
                // Zufälliger Kopf hinter Kennung und Version
                data.replaceSubrange(8..<OccupancyRecording.headerSize, with: rng.bytes(OccupancyRecording.headerSize - 8))
            default:
                for _ in 0..<rng.int(1...20) { data[rng.int(0...(data.count - 1))] = rng.byte() }
                if rng.chance(0.3) { data = data.prefix(rng.int(0...data.count)) }
            }
            guard let decoded = try? OccupancyRecording.decode(data) else { continue }
            #expect(decoded.sliceSeconds.isFinite && decoded.thresholdDB.isFinite)
            let timeline = OccupancyTimeline(slices: decoded.slices, sliceSeconds: decoded.sliceSeconds)
            #expect(timeline.count <= decoded.slices.count * 31)      // höchstens 30 Leerzeilen je Lücke
            let summary = OccupancyAnalysis.summary(decoded.slices, binCount: decoded.plan.binCount)
            _ = OccupancyAnalysis.mostActive(summary, slices: decoded.slices, plan: decoded.plan)
            _ = displayInt(decoded.thresholdDB)
            _ = displayInt(decoded.sliceSeconds)
        }
        // Zeitachse direkt mit unsinnigen Zeiten und Längen.
        let odd = [0, 1e300, -1e300, .nan, 60].map {
            OccupancySlice(start: Date(timeIntervalSince1970: $0), floorDB: 0, visits: 0, mean: [1], peak: [1], occupancy: [0])
        }
        for seconds in [Double.nan, .infinity, 0, -5, 60] {
            _ = OccupancyTimeline(slices: odd, sliceSeconds: seconds)
        }
        #expect(displayInt(Double.nan) == 0 && displayInt(Float.infinity) == 0)
        #expect(displayInt(1e300) == 1_000_000_000)
    }

    // MARK: - Amateurfunksatelliten, SSTV (Review Y21)

    @Test("Amateurfunk-Rahmen: Zufallsbytes und mutierte AX.25-Rahmen stürzen nicht ab")
    func amateurFrame() {
        var rng = Self.rng(27)
        let base = AX25Frame(destination: AX25Address("CQ"), source: AX25Address("RS0ISS"), info: Array("Hallo Welt".utf8)).encoded()
        for n in 0..<Self.runs(6000) {
            let bytes = n % 2 == 0 ? rng.bytes(upTo: 340) : Self.mutate(base, &rng)
            let frame = AmateurFrame(bytes: bytes, satellite: "X", channel: "Y")
            _ = frame.hex
            _ = frame.text
        }
    }

    @Test("SSTV: Zufalls- und NaN-Audio stürzt nicht ab, der Empfänger bleibt danach hörend")
    func sstv() {
        var rng = Self.rng(28)
        let decoder = SSTVDecoder()
        for _ in 0..<Self.runs(60) {
            let audio: [Float] = (0..<rng.int(0...4800)).map { _ in
                switch rng.int(0...19) {
                case 0: .nan
                case 1: .infinity
                case 2: -.infinity
                default: Float(Int(rng.next() % 2001) - 1000) / 100
                }
            }
            decoder.process(audio)
            _ = decoder.takeFinished()
        }
        decoder.flush()
        _ = decoder.takeFinished()
        // Gültiger Bildanfang, dann NaN mitten im Bild.
        let mode = SSTVMode.robot36
        let source = SSTVTestSignal.image(mode)
        var audio = SSTVTestSignal.discriminator(SSTVTestSignal.tones(mode, image: source, lines: 40))
        for k in stride(from: audio.count / 2, to: min(audio.count, audio.count / 2 + 2000), by: 7) { audio[k] = .nan }
        let (images, _) = SSTVTestSignal.decode(audio)
        for image in images { _ = SSTVStore.cgImage(image) }
        // Erst NaN, dann ein sauberes Bild: der Empfänger muss es noch erkennen.
        let clean = SSTVTestSignal.discriminator(SSTVTestSignal.tones(mode, image: source))
        let (after, _) = SSTVTestSignal.decode([Float](repeating: .nan, count: 4800) + clean)
        #expect(after.count == 1)
        #expect(SSTVMode.value(frequency: .nan) == 0)
        #expect(SSTVMode.rgb(y: .nan, cr: 128, cb: 128).0 == 0)
    }

    // MARK: - Smart Home 868 MHz mit Sync (Review Y21, K1)

    @Test("EnOcean, Homematic, Z-Wave und wM-Bus: Bitströme mit Sync und bis 300 Byte stürzen nicht ab")
    func smartHomeBits() {
        var rng = Self.rng(29)
        func bits(_ bytes: [UInt8]) -> [UInt8] { SmartHomeDemod.bits(of: bytes) }
        func randomBits(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(rng.next() & 1) } }
        let keys = ["12345678": SmartHomeTestFrames.omsKey]
        for n in 0..<Self.runs(1500) {
            let length = rng.int(0...300)
            let preamble = randomBits(rng.int(0...24))
            // wM-Bus C1 Format B: L-Feld gezielt um 0x80 (K1) und zufällig.
            let l = n % 3 == 0 ? UInt8(rng.int(0x7C...0x84)) : rng.byte()
            let wmbusB = preamble + WMBus.syncBits + bits([l] + rng.bytes(length))
            let wmbusA = preamble + WMBus.syncBits + bits([0x54, 0xCD, rng.byte()] + rng.bytes(length))
            let wmbusT = preamble + WMBus.encode3of6([rng.byte()] + rng.bytes(length))
            for stream in [wmbusB, wmbusA, wmbusT, randomBits(rng.int(0...2400))] {
                _ = WMBus.frames(inBits: stream, keys: keys)
                _ = WMBus.frames(inBits: SmartHomeDemod.inverted(stream), keys: keys)
            }
            _ = EnOcean.frames(inBits: preamble + EnOcean.syncBits + randomBits(rng.int(0...(length * 12))))
            _ = Homematic.frames(inBits: preamble + Homematic.syncBits + bits([rng.byte()] + rng.bytes(length)))
            let zwave = preamble + ZWave.syncBits + bits([rng.byte()] + rng.bytes(length))
            for rate in ZWave.Rate.allCases { _ = ZWave.frames(inBits: zwave, rate: rate) }
        }
        // K1 exakt: Sync, L = 0x80/0x81 (vorher Absturz), dahinter genug Bytes.
        for l: UInt8 in [0x80, 0x81, 0x82] {
            _ = WMBus.frames(inBits: WMBus.syncBits + bits([l] + rng.bytes(140)), keys: keys)
            let stripped = WMBus.stripFormatB([l] + rng.bytes(140))
            #expect((stripped == nil) == (l < 0x82))
        }
    }
}
