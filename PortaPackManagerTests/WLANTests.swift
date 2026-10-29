import Foundation
import Testing
@testable import PortaPackManager

/// Sender für 802.11 (DSSS und OFDM) bei 20 MS/s – nur zum Prüfen der Empfänger.
enum WLANTestTransmitter {
    static let sampleRate = 20_000_000.0

    // MARK: Rahmen

    static func beacon(source: [UInt8], elements: [UInt8], sequence: Int = 7) -> [UInt8] {
        var mpdu: [UInt8] = [0x80, 0x00, 0x00, 0x00]
        mpdu += [UInt8](repeating: 0xFF, count: 6) + source + source
        mpdu += [UInt8(sequence << 4 & 0xFF), UInt8(sequence >> 4)]
        mpdu += [UInt8](repeating: 0, count: 8) + [0x64, 0x00] + [0x21, 0x04]
        mpdu += elements
        return mpdu + WLANCRC32.fcs(mpdu)
    }

    static func nanServiceDiscovery(source: [UInt8], serviceID: [UInt8], info: [UInt8]) -> [UInt8] {
        var mpdu: [UInt8] = [0xD0, 0x00, 0x00, 0x00]
        mpdu += WLANFrame.nanCluster + source + WLANFrame.nanCluster
        mpdu += [0x10, 0x00]
        var attribute: [UInt8] = serviceID + [0x01, 0x00, 0x10, UInt8(info.count)] + info
        attribute = [0x03, UInt8(attribute.count & 0xFF), UInt8(attribute.count >> 8)] + attribute
        mpdu += [0x04, 0x09] + WLANFrame.wfaOUI + [0x13] + attribute
        return mpdu + WLANCRC32.fcs(mpdu)
    }

    static func remoteIDElement(counter: UInt8, messages: [[UInt8]]) -> [UInt8] {
        let body: [UInt8] = [0xFA, 0x0B, 0xBC, RemoteID.appCode, counter] + RemoteIDEncoder.pack(messages)
        return [0xDD, UInt8(body.count)] + body
    }

    // MARK: OFDM

    /// Vollständiger 802.11a/g-Rahmen im Zeitbereich (Kurz-/Langpräambel, SIGNAL, Daten).
    static func ofdm(mpdu: [UInt8], mbps: Int, seed: UInt8 = 0x5D) -> (re: [Float], im: [Float]) {
        let rate = WLANOFDM.rate(mbps: mbps)!
        var re: [Float] = [], im: [Float] = []
        // Kurzpräambel: 160 Werte, periodisch mit 16.
        let stf = WLANOFDM.shortTrainingTime
        for n in 0..<160 { re.append(stf.re[n % 64]); im.append(stf.im[n % 64]) }
        // Langpräambel: Schutzintervall 32 + zwei Symbole.
        let ltf = WLANOFDM.longTrainingTime
        for n in 0..<160 { let k = (n + 32) % 64; re.append(ltf.re[k]); im.append(ltf.im[k]) }

        // SIGNAL: RATE, R, LENGTH, Parität, Tail – BPSK 1/2, ohne Verwürfelung.
        var signal = [UInt8](repeating: 0, count: 24)
        for i in 0..<4 { signal[i] = rate.code >> i & 1 }
        for i in 0..<12 { signal[5 + i] = UInt8(mpdu.count >> i & 1) }
        signal[17] = signal[0..<17].reduce(0, ^)
        appendSymbol(&re, &im, coded: encode(signal, rate: WLANOFDM.rate(mbps: 6)!), rate: WLANOFDM.rate(mbps: 6)!, pilotIndex: 0)

        // Daten: SERVICE (16 × 0), PSDU, Tail (6), Auffüllen; verwürfeln, Tail nullen.
        let symbols = WLANOFDM.symbolCount(length: mpdu.count, rate: rate)
        var data = [UInt8](repeating: 0, count: symbols * rate.dataBitsPerSymbol)
        for (i, byte) in mpdu.enumerated() { for bit in 0..<8 { data[16 + 8 * i + bit] = byte >> bit & 1 } }
        let scramble = WLANOFDM.scrambler(seed: seed, count: data.count)
        for i in 0..<data.count { data[i] ^= scramble[i] }
        for i in 0..<6 { data[16 + 8 * mpdu.count + i] = 0 }
        // Der Faltungskodierer läuft über das ganze Datenfeld durch.
        let coded = encode(data, rate: rate)
        for s in 0..<symbols {
            let slice = Array(coded[(s * rate.codedBitsPerSymbol)..<((s + 1) * rate.codedBitsPerSymbol)])
            appendSymbol(&re, &im, coded: slice, rate: rate, pilotIndex: (s + 1) % 127)
        }
        return (re, im)
    }

    /// Faltungscode (A = 133, B = 171) und Punktierung.
    private static func encode(_ bits: [UInt8], rate: WLANOFDM.Rate) -> [UInt8] {
        // Der Meteor-Kodierer liefert (171, 133) = (B, A) → tauschen.
        let encoded = MeteorConvolutionalCode.encode(bits)
        var coded: [UInt8] = []
        coded.reserveCapacity(encoded.count)
        var i = 0
        while i + 1 < encoded.count { coded.append(encoded[i + 1]); coded.append(encoded[i]); i += 2 }
        var punctured: [UInt8] = []
        switch rate.puncturing {
        case .r12: punctured = coded
        case .r23:
            var j = 0
            while j + 3 < coded.count + 1 { punctured += [coded[j], coded[j + 1], coded[j + 2]]; j += 4 }
        case .r34:
            var j = 0
            while j + 5 < coded.count + 1 { punctured += [coded[j], coded[j + 1], coded[j + 2], coded[j + 5]]; j += 6 }
        }
        return punctured
    }

    /// Verschachtelt und moduliert ein Symbol; hängt es mit Schutzintervall an.
    private static func appendSymbol(_ re: inout [Float], _ im: inout [Float], coded punctured: [UInt8], rate: WLANOFDM.Rate, pilotIndex: Int) {
        precondition(punctured.count == rate.codedBitsPerSymbol, "Kodierte Bits \(punctured.count)")
        let map = WLANOFDM.interleaverMap(rate)
        var interleaved = [UInt8](repeating: 0, count: rate.codedBitsPerSymbol)
        for k in 0..<rate.codedBitsPerSymbol { interleaved[map[k]] = punctured[k] }

        var spectrum: [Int: (re: Float, im: Float)] = [:]
        let scale = 1 / WLANOFDM.constellationScale(rate.bitsPerSubcarrier)
        var index = 0
        func level(_ bits: ArraySlice<UInt8>) -> Float {
            switch Array(bits) {
            case [0]: return -1
            case [1]: return 1
            case [0, 0]: return -3
            case [0, 1]: return -1
            case [1, 1]: return 1
            case [1, 0]: return 3
            case [0, 0, 0]: return -7
            case [0, 0, 1]: return -5
            case [0, 1, 1]: return -3
            case [0, 1, 0]: return -1
            case [1, 1, 0]: return 1
            case [1, 1, 1]: return 3
            case [1, 0, 1]: return 5
            default: return 7
            }
        }
        let half = max(rate.bitsPerSubcarrier / 2, 1)
        for k in WLANOFDM.dataSubcarriers {
            let group = interleaved[index..<(index + rate.bitsPerSubcarrier)]
            index += rate.bitsPerSubcarrier
            if rate.bitsPerSubcarrier == 1 {
                spectrum[k] = (level(group) * scale, 0)
            } else {
                spectrum[k] = (level(group.prefix(half)) * scale, level(group.suffix(half)) * scale)
            }
        }
        let polarity = WLANOFDM.pilotPolarity[pilotIndex]
        for (j, k) in WLANOFDM.pilotSubcarriers.enumerated() { spectrum[k] = (WLANOFDM.pilotValues[j] * polarity, 0) }
        let symbol = WLANOFDM.timeSymbol(spectrum)
        for n in 0..<80 { let k = (n + 48) % 64; re.append(symbol.re[k]); im.append(symbol.im[k]) }
    }

    // MARK: DSSS

    /// 802.11b-Rahmen: lange (1 Mbit/s) oder kurze Präambel (Kopf 2 Mbit/s), PSDU mit `mbps`.
    static func dsss(mpdu: [UInt8], mbps: Int, shortPreamble: Bool = false) -> (re: [Float], im: [Float]) {
        var bits: [UInt8] = []
        bits += [UInt8](repeating: shortPreamble ? 0 : 1, count: shortPreamble ? 56 : 128)
        bits += shortPreamble ? WLANDSSSDemodulator.shortSFD : WLANDSSSDemodulator.longSFD
        let lengthMicroseconds = mpdu.count * 8 / mbps
        var header: [UInt8] = []
        let signal: UInt8 = mbps == 1 ? 0x0A : 0x14
        header += (0..<8).map { signal >> $0 & 1 }
        header += [UInt8](repeating: 0, count: 8)
        header += (0..<16).map { UInt8(lengthMicroseconds >> $0 & 1) }
        header += WLANDSSSDemodulator.headerCRC(header)
        let headerStart = bits.count
        bits += header
        let dataStart = bits.count
        for byte in mpdu { for bit in 0..<8 { bits.append(byte >> bit & 1) } }
        // Selbstsynchronisierender Verwürfler: s = d ⊕ s[−4] ⊕ s[−7].
        var register: UInt8 = shortPreamble ? 0x6C : 0x1B
        var scrambled: [UInt8] = []
        for bit in bits {
            let s = bit ^ (register >> 3 & 1) ^ (register >> 6 & 1)
            register = (register << 1 | s) & 0x7F
            scrambled.append(s)
        }
        // Differenzmodulation: Kopf bei kurzer Präambel und PSDU bei 2 Mbit/s DQPSK.
        var phases: [Float] = []
        var phase: Float = 0
        var i = 0
        while i < scrambled.count {
            let qpsk = (i >= headerStart && shortPreamble) || (i >= dataStart && mbps == 2)
            if qpsk {
                let d0 = scrambled[i], d1 = scrambled[i + 1]
                switch (d0, d1) {
                case (0, 0): break
                case (0, 1): phase += .pi / 2
                case (1, 1): phase += .pi
                default: phase -= .pi / 2
                }
                i += 2
            } else {
                if scrambled[i] == 1 { phase += .pi }
                i += 1
            }
            phases.append(phase)
        }
        let barker = WLANDSSSDemodulator.barker
        let samples = phases.count * 20
        var re = [Float](repeating: 0, count: samples), im = [Float](repeating: 0, count: samples)
        for n in 0..<samples {
            let t = Double(n) / sampleRate * 1e6       // µs
            let symbol = Int(t)
            let chip = Int((t - Double(symbol)) * 11)
            let amplitude = barker[min(chip, 10)]
            re[n] = amplitude * cos(phases[symbol])
            im[n] = amplitude * sin(phases[symbol])
        }
        return (re, im)
    }

    // MARK: Kanal

    /// Stille, Rahmen mit Pegel/Ablage/Rauschen, Stille – als HackRF-Block (int8).
    static func channel(_ frame: (re: [Float], im: [Float]), amplitude: Float = 40, offsetHz: Double = 0,
                        noise: Float = 1.5, lead: Int = 3000, trail: Int = 3000, seed: UInt64 = 1) -> Data {
        var rng = SplitMix(seed: seed)
        let total = lead + frame.re.count + trail
        var data = Data(count: total * 2)
        var rms: Float = 0
        for n in 0..<frame.re.count { rms += frame.re[n] * frame.re[n] + frame.im[n] * frame.im[n] }
        rms = (rms / Float(frame.re.count)).squareRoot()
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<total {
                var i: Float = 0, q: Float = 0
                if n >= lead, n < lead + frame.re.count {
                    let k = n - lead
                    let phase = Float(2 * Double.pi * offsetHz * Double(n) / sampleRate)
                    let a = frame.re[k] / rms * amplitude, b = frame.im[k] / rms * amplitude
                    i = a * cos(phase) - b * sin(phase)
                    q = a * sin(phase) + b * cos(phase)
                }
                i += rng.gaussian() * noise + 3     // Gleichanteil wie beim HackRF
                q += rng.gaussian() * noise - 2
                p[2 * n] = Int8(max(-127, min(127, i.rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, q.rounded())))
            }
        }
        return data
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }
        mutating func gaussian() -> Float {
            let u = max(uniform(), 1e-7), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }
}

@Suite("WLAN (802.11) über den HackRF")
struct WLANTests {
    static let source: [UInt8] = [0x60, 0x60, 0x1F, 0x12, 0x34, 0x56]

    static var remoteIDMessages: [[UInt8]] {
        [RemoteIDEncoder.basicID(idType: 1, uaType: 2, id: "1596F123456789ABCDEF"),
         RemoteIDEncoder.location(status: 2, direction: 90, speed: 12, verticalSpeed: 0.5, latitude: 52.52,
                                  longitude: 13.405, altitudeBaro: 120, altitudeGeo: 160, heightOverGround: false,
                                  height: 80, timestamp: 1234)]
    }

    @Test("CRC-32 (FCS): Prüfwert von „123456789“ ist 0xCBF43926")
    func fcs() {
        let bytes = Array("123456789".utf8)
        #expect(WLANCRC32.checksum(bytes[...]) == 0xCBF4_3926)
        #expect(WLANCRC32.verify(bytes + WLANCRC32.fcs(bytes)))
        #expect(!WLANCRC32.verify(bytes + [0, 0, 0, 0]))
    }

    @Test("Beacon: Kopf, SSID und Remote-ID-Element")
    func beaconFrame() throws {
        let elements: [UInt8] = [0x00, 0x05] + Array("Drone".utf8)
            + WLANTestTransmitter.remoteIDElement(counter: 9, messages: Self.remoteIDMessages)
        let mpdu = WLANTestTransmitter.beacon(source: Self.source, elements: elements)
        #expect(WLANCRC32.verify(mpdu))
        let frame = try #require(WLANFrame.parse(Array(mpdu.dropLast(4))))
        #expect(frame.kind == .beacon)
        #expect(frame.address2 == Self.source)
        #expect(frame.sequence == 7)
        #expect(frame.ssid == "Drone")
        let parsed = try #require(RemoteID.parse(frame))
        #expect(parsed.transport == .beacon)
        #expect(parsed.frame.counter == 9)
        #expect(parsed.frame.messages.count == 2)
    }

    @Test("Schutz aus RSN/WPA/Privacy, Steuerrahmen, Probe-Anfrage")
    func securityAndControl() throws {
        func beacon(_ elements: [UInt8], privacy: Bool = false) -> WLANFrame {
            var mpdu = WLANTestTransmitter.beacon(source: Self.source, elements: elements)
            if privacy { mpdu[24 + 10] |= 0x10 }
            return WLANFrame.parse(Array(mpdu.dropLast(4)))!
        }
        let ssid: [UInt8] = [0x00, 0x04] + Array("Test".utf8)
        let rsnWPA2: [UInt8] = [48, 20, 1, 0, 0, 0x0F, 0xAC, 4, 1, 0, 0, 0x0F, 0xAC, 4, 1, 0, 0, 0x0F, 0xAC, 2, 0, 0]
        #expect(beacon(ssid + rsnWPA2, privacy: true).security == "WPA2")
        let rsnMixed: [UInt8] = [48, 24, 1, 0, 0, 0x0F, 0xAC, 4, 1, 0, 0, 0x0F, 0xAC, 4, 2, 0, 0, 0x0F, 0xAC, 2, 0, 0x0F, 0xAC, 8, 0, 0]
        #expect(beacon(ssid + rsnMixed, privacy: true).security == "WPA2/WPA3")
        let wpa: [UInt8] = [0xDD, 6, 0x00, 0x50, 0xF2, 0x01, 1, 0]
        #expect(beacon(ssid + wpa, privacy: true).security == "WPA")
        #expect(beacon(ssid, privacy: true).security == "WEP")
        #expect(beacon(ssid + [3, 1, 6]).security == "offen")
        #expect(beacon(ssid + [3, 1, 6]).dsChannel == 6)
        // ACK: 14 Byte samt FCS – nur Empfängeradresse.
        let ack: [UInt8] = [0xD4, 0x00, 0x00, 0x00] + Self.source
        let control = try #require(WLANFrame.parse(ack))
        #expect(control.kind == .control && control.subtype == 13 && control.address1 == Self.source)
        // Probe-Anfrage: Elemente ohne feste Felder.
        var probe: [UInt8] = [0x40, 0x00, 0x00, 0x00] + [UInt8](repeating: 0xFF, count: 6) + Self.source + [UInt8](repeating: 0xFF, count: 6) + [0x10, 0x00]
        probe += ssid
        let request = try #require(WLANFrame.parse(probe))
        #expect(request.kind == .probeRequest && request.ssid == "Test")
    }

    @Test("NAN-Service-Discovery: Dienstbeschreibung mit Remote-ID-Service-ID")
    func nanFrame() throws {
        let info: [UInt8] = [3] + RemoteIDEncoder.pack(Self.remoteIDMessages)
        let mpdu = WLANTestTransmitter.nanServiceDiscovery(source: Self.source, serviceID: RemoteID.nanServiceID, info: info)
        let frame = try #require(WLANFrame.parse(Array(mpdu.dropLast(4))))
        #expect(frame.kind == .action)
        #expect(frame.address1 == WLANFrame.nanCluster)
        #expect(frame.nanServices.count == 1)
        let parsed = try #require(RemoteID.parse(frame))
        #expect(parsed.transport == .nan)
        #expect(parsed.frame.counter == 3)
        #expect(parsed.frame.messages.count == 2)
        // Fremder Dienst wird nicht als Remote ID gelesen.
        let other = WLANTestTransmitter.nanServiceDiscovery(source: Self.source, serviceID: [1, 2, 3, 4, 5, 6], info: info)
        #expect(RemoteID.parse(WLANFrame.parse(Array(other.dropLast(4)))!) == nil)
        // Variante mit App-Code voran.
        #expect(RemoteID.parseNANServiceInfo([RemoteID.appCode, 5] + RemoteIDEncoder.pack(Self.remoteIDMessages))?.counter == 5)
    }

    @Test("Französische Kennung: TLVs big-endian, Übersetzung in Remote-ID-Nachrichten")
    func frenchBeacon() throws {
        var tlv: [UInt8] = [1, 1, 1]
        let id = Array("ABCDEF123456789012345678901234".utf8)
        tlv += [2, UInt8(id.count)] + id
        func be32(_ v: Int32) -> [UInt8] { (0..<4).map { UInt8(UInt32(bitPattern: v) >> (24 - 8 * UInt32($0)) & 0xFF) } }
        func be16(_ v: Int16) -> [UInt8] { [UInt8(UInt16(bitPattern: v) >> 8), UInt8(UInt16(bitPattern: v) & 0xFF)] }
        tlv += [4, 4] + be32(4_852_000) + [5, 4] + be32(235_200)
        tlv += [6, 2] + be16(150) + [7, 2] + be16(60)
        tlv += [8, 4] + be32(4_851_900) + [9, 4] + be32(235_100)
        tlv += [10, 1, 7] + [11, 2] + be16(270)
        let body: [UInt8] = FrenchDroneID.oui + [0x01] + tlv
        let elements: [UInt8] = [0x00, 0x00, 0xDD, UInt8(body.count)] + body
        let parsed = try #require(FrenchDroneID.parse(elements: elements))
        #expect(parsed.latitude == 48.52)
        #expect(parsed.longitude == 2.352)
        #expect(parsed.height == 60)
        #expect(parsed.heading == 270)
        #expect(parsed.speed == 7)
        let frame = parsed.frame
        #expect(frame.messages.count == 3)
        guard case let .basicID(basic)? = frame.messages.first else { Issue.record("Basic ID fehlt"); return }
        #expect(basic.uasID == "ABCDEF123456789012345678901234")
        guard case let .system(system)? = frame.messages.last else { Issue.record("System fehlt"); return }
        #expect(system.operatorLatitude == 48.519)
        let beacon = WLANTestTransmitter.beacon(source: Self.source, elements: elements)
        #expect(RemoteID.parse(WLANFrame.parse(Array(beacon.dropLast(4)))!)?.transport == .frenchBeacon)
    }

    @Test("OFDM-Tabellen: Pilotpolarität, Verschachtelung ist eine Permutation")
    func tables() {
        let expected: [Float] = [1, 1, 1, 1, -1, -1, -1, 1, -1, -1, -1, -1, 1, 1, -1, 1]
        #expect(Array(WLANOFDM.pilotPolarity.prefix(16)) == expected)
        #expect(WLANOFDM.pilotPolarity.count == 127)
        for rate in WLANOFDM.rates {
            let map = WLANOFDM.interleaverMap(rate)
            #expect(Set(map).count == rate.codedBitsPerSymbol)
        }
        #expect(WLANOFDM.dataSubcarriers.count == 48)
        #expect(WLANOFDM.rate(code: 0b1011)?.mbps == 6)
        #expect(WLANOFDM.rate(code: 0b1100)?.mbps == 54)
    }

    @Test("OFDM: Beacon mit 6, 24 und 54 Mbit/s, Ablage und Rauschen", arguments: [6, 24, 54])
    func ofdm(mbps: Int) throws {
        let elements: [UInt8] = [0x00, 0x05] + Array("Drone".utf8)
            + WLANTestTransmitter.remoteIDElement(counter: 9, messages: Self.remoteIDMessages)
        let mpdu = WLANTestTransmitter.beacon(source: Self.source, elements: elements)
        let frame = WLANTestTransmitter.ofdm(mpdu: mpdu, mbps: mbps)
        let noise: Float = mbps == 54 ? 0.8 : 2
        let data = WLANTestTransmitter.channel(frame, amplitude: 40, offsetHz: 30_000, noise: noise)
        let receiver = WLANReceiver()
        var packets = receiver.process(data)
        packets += receiver.process(Data(count: 2 * 8192))
        try #require(packets.count == 1)
        #expect(packets[0].modulation == .ofdm)
        #expect(packets[0].rateMbps == Double(mbps))
        #expect(packets[0].mpdu == Array(mpdu.dropLast(4)))
        #expect(abs(packets[0].offsetKHz - 30) < 5)
    }

    @Test("OFDM: NAN-Rahmen über eine Blockgrenze hinweg")
    func ofdmSplit() throws {
        let info: [UInt8] = [3] + RemoteIDEncoder.pack(Self.remoteIDMessages)
        let mpdu = WLANTestTransmitter.nanServiceDiscovery(source: Self.source, serviceID: RemoteID.nanServiceID, info: info)
        let data = WLANTestTransmitter.channel(WLANTestTransmitter.ofdm(mpdu: mpdu, mbps: 6), lead: 8000, trail: 8000)
        let receiver = WLANReceiver()
        let cut = 2 * 8400     // mitten im Rahmen
        var packets = receiver.process(data.prefix(cut))
        packets += receiver.process(data.suffix(from: cut))
        packets += receiver.process(Data(count: 2 * 8192))
        try #require(packets.count == 1)
        #expect(packets[0].mpdu == Array(mpdu.dropLast(4)))
        let parsed = try #require(RemoteID.parse(WLANFrame.parse(packets[0].mpdu)!))
        #expect(parsed.transport == .nan)
    }

    @Test("DSSS: 1 Mbit/s lang, 2 Mbit/s lang und kurz", arguments: [(1, false), (2, false), (2, true)])
    func dsss(mbps: Int, shortPreamble: Bool) throws {
        let elements: [UInt8] = [0x00, 0x05] + Array("Drone".utf8)
            + WLANTestTransmitter.remoteIDElement(counter: 9, messages: Self.remoteIDMessages)
        let mpdu = WLANTestTransmitter.beacon(source: Self.source, elements: elements)
        let frame = WLANTestTransmitter.dsss(mpdu: mpdu, mbps: mbps, shortPreamble: shortPreamble)
        // Genug Stille, damit der Rauschboden (unteres Drittel) nicht im Rahmen liegt.
        let data = WLANTestTransmitter.channel(frame, amplitude: 30, offsetHz: 40_000, noise: 4, lead: 40_000, trail: 40_000)
        let receiver = WLANReceiver()
        var packets = receiver.process(data)
        packets += receiver.process(Data(count: 2 * 8192))
        try #require(packets.count == 1)
        #expect(packets[0].modulation == .dsss)
        #expect(packets[0].rateMbps == Double(mbps))
        #expect(packets[0].mpdu == Array(mpdu.dropLast(4)))
        #expect(abs(packets[0].offsetKHz - 40) < 5)
    }

    @Test("Laufzeit: ein HackRF-Block (131 072 Werte = 6,6 ms) deutlich unter Echtzeit")
    func performance() {
        // Rauschen plus ein Rahmen je Block, wie bei dichtem WLAN-Verkehr.
        let frame = WLANTestTransmitter.ofdm(mpdu: WLANTestTransmitter.beacon(source: Self.source, elements: [0, 0]), mbps: 6)
        let block = WLANTestTransmitter.channel(frame, amplitude: 40, noise: 3, lead: 60_000, trail: 131_072 - 60_000 - frame.re.count)
        let receiver = WLANReceiver()
        _ = receiver.process(block)
        let start = Date()
        let runs = 20
        for _ in 0..<runs { _ = receiver.process(block) }
        let perBlock = Date().timeIntervalSince(start) / Double(runs)
        print("WLAN-Empfänger: \(String(format: "%.2f", perBlock * 1000)) ms je 6,55-ms-Block")
        // Gemessen 24.10.2026 (M4 Pro): Release 1,6 ms, Debug 18,6 ms.
        #if DEBUG
        #expect(perBlock < 0.040)
        #else
        #expect(perBlock < 0.0066)
        #endif
    }

    @Test("Rauschen allein liefert keine Rahmen")
    func noiseOnly() {
        let data = WLANTestTransmitter.channel((re: [], im: []), noise: 6, lead: 200_000, trail: 0)
        let receiver = WLANReceiver()
        #expect(receiver.process(data).isEmpty)
        #expect(receiver.process(data).isEmpty)
    }
}
