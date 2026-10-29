import Foundation

/// Ein elementarer Strom aus der PMT.
struct TSStream: Sendable, Equatable, Hashable {
    enum Kind: String, Sendable {
        case hevc = "HEVC", h264 = "H.264", mpeg2Video = "MPEG-2"
        case mpegAudio = "MPEG-Audio", aacADTS = "AAC", aacLATM = "HE-AAC (LATM)", ac3 = "AC-3", eac3 = "E-AC-3"
        case teletext = "Videotext", subtitles = "Untertitel", other = "Daten"

        var isVideo: Bool { self == .hevc || self == .h264 || self == .mpeg2Video }
        var isAudio: Bool { [.mpegAudio, .aacADTS, .aacLATM, .ac3, .eac3].contains(self) }
    }

    var pid: Int
    var streamType: Int
    var kind: Kind
    var language: String?
}

/// Ein Programm (Dienst) aus PAT, PMT und SDT.
struct TSService: Sendable, Equatable, Identifiable {
    var id: Int                 // program_number = service_id
    var pmtPID: Int
    var name: String = ""
    var provider: String = ""
    var serviceType = 0
    var streams: [TSStream] = []
    var scrambled = false

    var video: TSStream? { streams.first { $0.kind.isVideo } }
    var audio: [TSStream] { streams.filter { $0.kind.isAudio } }
    var isRadio: Bool { serviceType == 0x02 || serviceType == 0x0A || (video == nil && !audio.isEmpty) }
    var typeName: String {
        switch serviceType {
        case 0x01: "TV (SD)"
        case 0x02, 0x0A: "Radio"
        case 0x11, 0x19: "TV (HD)"
        case 0x1F: "TV (HEVC)"
        case 0x0C: String(localized: "Daten")
        default: serviceType == 0 ? "" : String(localized: "Typ \(String(format: "0x%02X", serviceType))")
        }
    }
}

/// Ein vollständiges PES-Paket.
struct PESPacket: Sendable {
    var pid: Int
    var pts: Int64?
    var dts: Int64?
    var payload: Data
}

/// Zerlegt einen Transportstrom: PSI/SI-Tabellen und PES der gewählten PIDs.
final class TSDemuxer: @unchecked Sendable {
    private(set) var services: [Int: TSService] = [:]
    private(set) var networkName = ""
    private(set) var transportStreamID: Int?
    private(set) var packets = 0
    private(set) var continuityErrors = 0
    /// Neue oder geänderte Dienste.
    var servicesChanged: (([TSService]) -> Void)?
    /// Fertige PES-Pakete der in `pesPIDs` gewählten Ströme.
    var pesHandler: ((PESPacket) -> Void)?
    var pesPIDs: Set<Int> = [] {
        didSet { pes = pes.filter { pesPIDs.contains($0.key) } }
    }

    private var sections: [Int: [UInt8]] = [:]
    private var pmtPIDs: [Int: Int] = [:]          // PID → program_number
    private var continuity: [Int: UInt8] = [:]
    private var pes: [Int: (data: [UInt8], header: Bool)] = [:]
    private var sdtVersion: Int?
    /// PIDs mit Videoströmen (größerer PES-Puffer).
    private var videoPIDs: Set<Int> = []

    /// Obergrenzen je PES-Paket: ohne Paketanfang (PUSI) wüchse der Puffer
    /// sonst unbegrenzt – ein Strom aus der Luft genügt.
    static let maxAudioPES = 256 * 1024
    static let maxVideoPES = 4 * 1024 * 1024

    func reset() {
        services = [:]; sections = [:]; pmtPIDs = [:]; continuity = [:]; pes = [:]; videoPIDs = []
        networkName = ""; transportStreamID = nil; sdtVersion = nil
    }

    func process(_ packet: [UInt8]) {
        guard packet.count == 188, packet[0] == 0x47 else { return }
        packets += 1
        if packet[1] & 0x80 != 0 { return }                    // transport_error_indicator
        let pid = Int(packet[1] & 0x1F) << 8 | Int(packet[2])
        let start = packet[1] & 0x40 != 0
        let adaptation = (packet[3] >> 4) & 3
        let counter = packet[3] & 0x0F
        guard adaptation & 1 == 1 else { return }               // keine Nutzdaten
        var offset = 4
        if adaptation & 2 != 0 { offset += 1 + Int(packet[4]) }
        guard offset < 188 else { return }
        if let last = continuity[pid], (last + 1) & 0x0F != counter, last != counter {
            continuityErrors += 1
            pes[pid] = nil
            if !start { sections[pid] = nil }
        }
        continuity[pid] = counter
        let payload = packet[offset...]

        if pid == 0 || pid == 0x11 || pid == 0x10 || pmtPIDs[pid] != nil {
            section(pid: pid, start: start, payload: Array(payload))
        }
        if pesPIDs.contains(pid) {
            if start {
                flushPES(pid)
                pes[pid] = (Array(payload), true)
            } else if pes[pid] != nil {
                let limit = videoPIDs.contains(pid) ? Self.maxVideoPES : Self.maxAudioPES
                if pes[pid]!.data.count + payload.count > limit { pes[pid] = nil } else { pes[pid]!.data += payload }
            }
        }
    }

    // MARK: - PSI-Abschnitte

    private func section(pid: Int, start: Bool, payload: [UInt8]) {
        var data = payload
        if start {
            let pointer = Int(data[0])
            // Rest des vorigen Abschnitts abschließen.
            if var pending = sections[pid], pointer > 0, 1 + pointer <= data.count {
                pending += data[1..<(1 + pointer)]
                parseSections(pid: pid, pending)
            }
            guard 1 + pointer <= data.count else { return }
            data = Array(data[(1 + pointer)...])
            sections[pid] = data
        } else if sections[pid] != nil {
            sections[pid]! += data
        } else {
            return
        }
        // Vollständige Abschnitte am Stück auswerten.
        while var buffer = sections[pid], buffer.count >= 3 {
            if buffer[0] == 0xFF { sections[pid] = nil; return }
            let length = 3 + (Int(buffer[1] & 0x0F) << 8 | Int(buffer[2]))
            guard buffer.count >= length else { return }
            parseSections(pid: pid, Array(buffer[0..<length]))
            buffer.removeFirst(length)
            sections[pid] = buffer.isEmpty ? nil : buffer
        }
    }

    private func parseSections(pid: Int, _ s: [UInt8]) {
        guard s.count >= 8 else { return }
        let length = 3 + (Int(s[1] & 0x0F) << 8 | Int(s[2]))
        guard length <= s.count, length >= 12, Self.crc32(s[0..<length]) == 0 else { return }
        let table = s[0]
        let body = Array(s[8..<(length - 4)])
        switch (pid, table) {
        case (0, 0x00): parsePAT(s, body)
        case (0x11, 0x42): parseSDT(s, body)
        case (0x10, 0x40): parseNIT(body)
        case (_, 0x02): if let program = pmtPIDs[pid] { parsePMT(program: program, pid: pid, body) }
        default: break
        }
    }

    private func parsePAT(_ s: [UInt8], _ body: [UInt8]) {
        transportStreamID = Int(s[3]) << 8 | Int(s[4])
        var i = 0
        var changed = false
        while i + 4 <= body.count {
            let program = Int(body[i]) << 8 | Int(body[i + 1])
            let pid = Int(body[i + 2] & 0x1F) << 8 | Int(body[i + 3])
            i += 4
            guard program != 0 else { continue }
            if pmtPIDs[pid] != program {
                pmtPIDs[pid] = program
                changed = true
            }
            if services[program] == nil {
                services[program] = TSService(id: program, pmtPID: pid)
                changed = true
            }
        }
        if changed { servicesChanged?(sortedServices) }
    }

    private func parsePMT(program: Int, pid: Int, _ body: [UInt8]) {
        guard body.count >= 4 else { return }
        let infoLength = Int(body[2] & 0x0F) << 8 | Int(body[3])
        var i = 4 + infoLength
        var streams: [TSStream] = []
        var scrambled = false
        if Self.descriptors(Array(body[4..<min(body.count, 4 + infoLength)])).contains(where: { $0.tag == 0x09 }) { scrambled = true }
        while i + 5 <= body.count {
            let type = Int(body[i])
            let esPID = Int(body[i + 1] & 0x1F) << 8 | Int(body[i + 2])
            let esInfo = Int(body[i + 3] & 0x0F) << 8 | Int(body[i + 4])
            let descriptors = Self.descriptors(Array(body[(i + 5)..<min(body.count, i + 5 + esInfo)]))
            i += 5 + esInfo
            var kind: TSStream.Kind
            switch type {
            case 0x24: kind = .hevc
            case 0x1B: kind = .h264
            case 0x01, 0x02: kind = .mpeg2Video
            case 0x03, 0x04: kind = .mpegAudio
            case 0x0F: kind = .aacADTS
            case 0x11: kind = .aacLATM
            case 0x81: kind = .ac3
            case 0x87: kind = .eac3
            default: kind = .other
            }
            var language: String?
            for d in descriptors {
                switch d.tag {
                case 0x6A where type == 0x06: kind = .ac3
                case 0x7A where type == 0x06: kind = .eac3
                case 0x7C where type == 0x06: kind = .aacLATM
                case 0x56 where type == 0x06: kind = .teletext
                case 0x59 where type == 0x06: kind = .subtitles
                case 0x09: scrambled = true
                case 0x0A where d.data.count >= 3:
                    language = String(bytes: d.data[0..<3], encoding: .isoLatin1)
                default: break
                }
            }
            streams.append(TSStream(pid: esPID, streamType: type, kind: kind, language: language))
            if kind.isVideo { videoPIDs.insert(esPID) }
        }
        var service = services[program] ?? TSService(id: program, pmtPID: pid)
        if service.streams != streams || service.scrambled != scrambled {
            service.streams = streams
            service.scrambled = scrambled
            services[program] = service
            servicesChanged?(sortedServices)
        }
    }

    private func parseSDT(_ s: [UInt8], _ body: [UInt8]) {
        let version = Int(s[5] >> 1) & 0x1F
        var i = 3   // original_network_id (2), reserved (1)
        var changed = false
        while i + 5 <= body.count {
            let serviceID = Int(body[i]) << 8 | Int(body[i + 1])
            let free = (body[i + 3] >> 4) & 1 == 0
            let loop = Int(body[i + 3] & 0x0F) << 8 | Int(body[i + 4])
            let descriptors = Self.descriptors(Array(body[(i + 5)..<min(body.count, i + 5 + loop)]))
            i += 5 + loop
            var service = services[serviceID] ?? TSService(id: serviceID, pmtPID: -1)
            for d in descriptors where d.tag == 0x48 && d.data.count >= 2 {
                service.serviceType = Int(d.data[0])
                let providerLength = Int(d.data[1])
                guard 2 + providerLength < d.data.count else { continue }
                service.provider = DVBText.decode(d.data[2..<(2 + providerLength)])
                let nameLength = Int(d.data[2 + providerLength])
                let nameStart = 3 + providerLength
                service.name = DVBText.decode(d.data[nameStart..<min(d.data.count, nameStart + nameLength)])
            }
            if !free { service.scrambled = true }
            if services[serviceID] != service {
                services[serviceID] = service
                changed = true
            }
        }
        if changed || sdtVersion != version {
            sdtVersion = version
            servicesChanged?(sortedServices)
        }
    }

    private func parseNIT(_ body: [UInt8]) {
        guard body.count >= 2 else { return }
        let length = Int(body[0] & 0x0F) << 8 | Int(body[1])
        for d in Self.descriptors(Array(body[2..<min(body.count, 2 + length)])) where d.tag == 0x40 {
            networkName = DVBText.decode(d.data[...])
        }
    }

    var sortedServices: [TSService] {
        services.values.sorted { ($0.name.isEmpty ? "\($0.id)" : $0.name).localizedStandardCompare($1.name.isEmpty ? "\($1.id)" : $1.name) == .orderedAscending }
    }

    // MARK: - PES

    private func flushPES(_ pid: Int) {
        guard let current = pes[pid], current.header else { return }
        let d = current.data
        guard d.count >= 9, d[0] == 0, d[1] == 0, d[2] == 1 else { return }
        let headerLength = Int(d[8])
        guard 9 + headerLength <= d.count else { return }
        let flags = d[7] >> 6
        func timestamp(_ i: Int) -> Int64 {
            Int64(d[i] >> 1 & 0x07) << 30 | Int64(d[i + 1]) << 22 | Int64(d[i + 2] >> 1) << 15 | Int64(d[i + 3]) << 7 | Int64(d[i + 4] >> 1)
        }
        let pts: Int64? = flags & 2 != 0 && headerLength >= 5 ? timestamp(9) : nil
        let dts: Int64? = flags == 3 && headerLength >= 10 ? timestamp(14) : nil
        var payload = Data(d[(9 + headerLength)...])
        let declared = Int(d[4]) << 8 | Int(d[5])
        if declared > 0, declared + 6 < d.count {
            // Angegebene Länge kürzer als der Kopf: Paket verwerfen (Funkdaten – sonst Absturz).
            guard declared + 6 >= 9 + headerLength else { return }
            payload = Data(d[(9 + headerLength)..<(declared + 6)])
        }
        pesHandler?(PESPacket(pid: pid, pts: pts, dts: dts, payload: payload))
    }

    // MARK: - Hilfsfunktionen

    static func descriptors(_ data: [UInt8]) -> [(tag: UInt8, data: [UInt8])] {
        var out: [(UInt8, [UInt8])] = []
        var i = 0
        while i + 2 <= data.count {
            let length = Int(data[i + 1])
            guard i + 2 + length <= data.count else { break }
            out.append((data[i], Array(data[(i + 2)..<(i + 2 + length)])))
            i += 2 + length
        }
        return out
    }

    /// CRC-32/MPEG-2 über den Abschnitt samt CRC: 0, wenn unversehrt.
    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }
}

/// DVB-Zeichenketten (ETSI EN 300 468, Anhang A).
enum DVBText {
    static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        guard let first = bytes.first else { return "" }
        var data = Array(bytes)
        var encoding: String.Encoding?
        switch first {
        case 0x01...0x0B:
            // ISO/IEC 8859-5 … 8859-15
            encoding = isoEncoding(Int(first) + 4)
            data.removeFirst()
        case 0x10 where data.count >= 3:
            encoding = isoEncoding(Int(data[1]) << 8 | Int(data[2]))
            data.removeFirst(3)
        case 0x15:
            encoding = .utf8
            data.removeFirst()
        case 0x11:
            encoding = .utf16BigEndian
            data.removeFirst()
        case 0x00..<0x20:
            data.removeFirst()
        default:
            break
        }
        // Steuerzeichen 0x80–0x9F (Hervorhebung, Zeilenumbruch) entfernen.
        if encoding != .utf8 && encoding != .utf16BigEndian {
            data = data.filter { !(0x80...0x9F).contains($0) }
        }
        if let encoding { return (String(bytes: data, encoding: encoding) ?? "").trimmingCharacters(in: .whitespaces) }
        return iso6937(data).trimmingCharacters(in: .whitespaces)
    }

    /// ISO/IEC 8859-n: Core Foundation zählt diese Kodierungen ab 0x0201 durch.
    private static func isoEncoding(_ part: Int) -> String.Encoding? {
        guard (1...16).contains(part) else { return .isoLatin1 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0200 + part)))
    }

    /// ISO/IEC 6937 (Standard ohne Kennbyte): Akzente als vorangestelltes Zeichen 0xC1–0xCF.
    static func iso6937(_ data: [UInt8]) -> String {
        let accents: [UInt8: Character] = [0xC1: "\u{300}", 0xC2: "\u{301}", 0xC3: "\u{302}", 0xC4: "\u{303}",
                                           0xC5: "\u{304}", 0xC6: "\u{306}", 0xC7: "\u{307}", 0xC8: "\u{308}",
                                           0xCA: "\u{30A}", 0xCB: "\u{327}", 0xCD: "\u{30B}", 0xCE: "\u{328}", 0xCF: "\u{30C}"]
        let specials: [UInt8: Character] = [0xA4: "$", 0xA6: "#", 0xA9: "‘", 0xAA: "“", 0xAB: "«", 0xB4: "×", 0xB8: "÷",
                                            0xB9: "’", 0xBA: "”", 0xBB: "»", 0xD0: "―", 0xE1: "Æ", 0xE9: "Ł", 0xEA: "Ø",
                                            0xEC: "Þ", 0xF1: "æ", 0xF9: "ł", 0xFA: "ø", 0xFB: "ß", 0xFC: "þ", 0xA0: " "]
        var out = ""
        var i = 0
        while i < data.count {
            let b = data[i]
            if let accent = accents[b], i + 1 < data.count {
                out.append(contentsOf: String([Character(UnicodeScalar(data[i + 1])), accent]).precomposedStringWithCanonicalMapping)
                i += 2
                continue
            }
            if let special = specials[b] { out.append(special) } else if b >= 0x20 && b < 0x7F { out.append(Character(UnicodeScalar(b))) }
            i += 1
        }
        return out
    }
}
