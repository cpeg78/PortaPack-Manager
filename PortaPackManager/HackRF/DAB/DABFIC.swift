import Foundation

/// Schutz eines Unterkanals (FIG 0/1).
enum DABProtection: Hashable, Sendable, Codable {
    /// EEP-A oder EEP-B, Stufe 1…4.
    case eep(profileB: Bool, level: Int)
    /// UEP (Kurzform), Index in Tabelle 31.
    case uep(tableIndex: Int)

    var description: String {
        switch self {
        case let .eep(profileB, level): "EEP \(level)-\(profileB ? "B" : "A")"
        case let .uep(index): DABTables.uepSubchannels.indices.contains(index) ? "UEP \(DABTables.uepSubchannels[index].level)" : "UEP ?"
        }
    }
}

/// Unterkanal im MSC (FIG 0/1).
struct DABSubchannel: Hashable, Sendable, Codable {
    var id: Int
    var startCU: Int
    var sizeCU: Int
    var protection: DABProtection

    /// Bitrate in kbit/s.
    var bitrate: Int {
        switch protection {
        case let .uep(index): return DABTables.uepSubchannels.indices.contains(index) ? DABTables.uepSubchannels[index].bitrate : 0
        case let .eep(profileB, level):
            // Stufe kommt aus FIG 0/1 (1…4) bzw. aus gespeicherten Senderlisten – absichern.
            guard (1...4).contains(level) else { return 0 }
            if profileB { return sizeCU / [27, 21, 18, 15][level - 1] * 32 }
            return sizeCU / [12, 8, 6, 4][level - 1] * 8
        }
    }

    var puncturing: DABPuncturing? {
        switch protection {
        case let .eep(profileB, level): DABPuncturing.eep(profileB: profileB, level: level, bitrate: bitrate)
        case let .uep(index):
            DABTables.uepSubchannels.indices.contains(index)
                ? DABPuncturing.uep(bitrate: bitrate, level: DABTables.uepSubchannels[index].level) : nil
        }
    }
}

/// Art des Audiodienstes (ASCTy aus FIG 0/2).
enum DABAudioKind: String, Hashable, Sendable, Codable {
    case dabPlus = "DAB+"
    case dab = "DAB"
    case data = "Daten"

    /// Anzeigename (der Rohwert ist gespeichert und bleibt deutsch).
    var title: String {
        switch self {
        case .dabPlus: "DAB+"
        case .dab: "DAB (MP2)"
        case .data: String(localized: "Daten")
        }
    }
}

/// Ein Dienst (Programm) des Ensembles.
struct DABService: Identifiable, Hashable, Sendable, Codable {
    var id: UInt32
    var label: String = ""
    var subchannelID: Int?
    var kind: DABAudioKind = .data
    var programmeType: Int = 0

    var programmeTypeName: String { DABProgrammeType.name(programmeType) }
}

/// Inhalt des FIC: Ensemble, Dienste, Unterkanäle.
struct DABEnsemble: Sendable, Equatable {
    var id: UInt16?
    var label: String = ""
    var services: [UInt32: DABService] = [:]
    var subchannels: [Int: DABSubchannel] = [:]

    /// Hörbare Dienste mit Namen, alphabetisch.
    var audioServices: [DABService] {
        services.values
            .filter { $0.kind != .data && !$0.label.isEmpty && $0.subchannelID.map { subchannels[$0] != nil } == true }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    func subchannel(for service: DABService) -> DABSubchannel? {
        service.subchannelID.flatMap { subchannels[$0] }
    }

    // MARK: - FIG-Auswertung

    /// Wertet ein FIB (30 Nutzbytes) aus.
    mutating func process(fib: ArraySlice<UInt8>) {
        let bytes = Array(fib)
        var index = 0
        while index < bytes.count {
            let header = bytes[index]
            if header == 0xFF { break }
            let type = Int(header >> 5)
            let length = Int(header & 0x1F)
            guard length > 0, index + 1 + length <= bytes.count else { break }
            let data = Array(bytes[(index + 1)..<(index + 1 + length)])
            switch type {
            case 0: processFIG0(data)
            case 1: processFIG1(data)
            default: break
            }
            index += 1 + length
        }
    }

    private mutating func processFIG0(_ data: [UInt8]) {
        guard data.count >= 2 else { return }
        let otherEnsemble = data[0] & 0x40 != 0
        let longServiceID = data[0] & 0x20 != 0
        let extensionID = Int(data[0] & 0x1F)
        let payload = Array(data.dropFirst())
        guard !otherEnsemble else { return }
        switch extensionID {
        case 0:
            if payload.count >= 2 { id = UInt16(payload[0]) << 8 | UInt16(payload[1]) }
        case 1: parseSubchannels(payload)
        case 2: parseServices(payload, longID: longServiceID)
        case 17: parseProgrammeTypes(payload)
        default: break
        }
    }

    /// FIG 0/1: Unterkanal-Organisation.
    private mutating func parseSubchannels(_ p: [UInt8]) {
        var i = 0
        while i + 3 <= p.count {
            let subchannelID = Int(p[i] >> 2)
            let start = Int(p[i] & 0x03) << 8 | Int(p[i + 1])
            if p[i + 2] & 0x80 == 0 {
                // Kurzform: UEP-Tabelle
                let tableIndex = Int(p[i + 2] & 0x3F)
                if tableIndex < DABTables.uepSubchannels.count {
                    subchannels[subchannelID] = DABSubchannel(
                        id: subchannelID, startCU: start, sizeCU: DABTables.uepSubchannels[tableIndex].size,
                        protection: .uep(tableIndex: tableIndex))
                }
                i += 3
            } else {
                guard i + 4 <= p.count else { return }
                let option = Int(p[i + 2] >> 4 & 0x07)
                let level = Int(p[i + 2] >> 2 & 0x03) + 1
                let size = Int(p[i + 2] & 0x03) << 8 | Int(p[i + 3])
                if option <= 1, size > 0 {
                    subchannels[subchannelID] = DABSubchannel(
                        id: subchannelID, startCU: start, sizeCU: size,
                        protection: .eep(profileB: option == 1, level: level))
                }
                i += 4
            }
        }
    }

    /// FIG 0/2: Dienste und ihre Komponenten.
    private mutating func parseServices(_ p: [UInt8], longID: Bool) {
        var i = 0
        let idLength = longID ? 4 : 2
        while i + idLength + 1 <= p.count {
            var serviceID: UInt32 = 0
            for k in 0..<idLength { serviceID = serviceID << 8 | UInt32(p[i + k]) }
            i += idLength
            let count = Int(p[i] & 0x0F)
            i += 1
            var service = services[serviceID] ?? DABService(id: serviceID)
            for _ in 0..<count {
                guard i + 2 <= p.count else { break }
                let tmID = p[i] >> 6
                let primary = p[i + 1] & 0x02 != 0
                if tmID == 0 {
                    let ascTy = Int(p[i] & 0x3F)
                    let subchannelID = Int(p[i + 1] >> 2)
                    // Primärkomponente bevorzugen, sonst die erste.
                    if primary || service.subchannelID == nil {
                        service.subchannelID = subchannelID
                        service.kind = ascTy == 63 ? .dabPlus : (ascTy == 0 ? .dab : .data)
                    }
                }
                i += 2
            }
            services[serviceID] = service
        }
    }

    /// FIG 0/17: Programmart.
    private mutating func parseProgrammeTypes(_ p: [UInt8]) {
        var i = 0
        while i + 4 <= p.count {
            let serviceID = UInt32(p[i]) << 8 | UInt32(p[i + 1])
            let languagePresent = p[i + 2] & 0x20 != 0
            let complementary = p[i + 2] & 0x10 != 0
            var k = i + 3
            if languagePresent { k += 1 }
            guard k < p.count else { return }
            let type = Int(p[k] & 0x1F)
            if var service = services[serviceID] {
                service.programmeType = type
                services[serviceID] = service
            }
            i = k + 1 + (complementary ? 1 : 0)
        }
    }

    /// FIG 1: Namen.
    private mutating func processFIG1(_ data: [UInt8]) {
        guard data.count >= 1 else { return }
        let charset = Int(data[0] >> 4)
        let otherEnsemble = data[0] & 0x08 != 0
        let extensionID = Int(data[0] & 0x07)
        guard !otherEnsemble else { return }
        let payload = Array(data.dropFirst())
        switch extensionID {
        case 0:
            guard payload.count >= 18 else { return }
            label = DABCharset.decode(payload[2..<18], charset: charset)
        case 1:
            guard payload.count >= 18 else { return }
            let serviceID = UInt32(payload[0]) << 8 | UInt32(payload[1])
            var service = services[serviceID] ?? DABService(id: serviceID)
            service.label = DABCharset.decode(payload[2..<18], charset: charset)
            services[serviceID] = service
        case 5:
            guard payload.count >= 20 else { return }
            var serviceID: UInt32 = 0
            for k in 0..<4 { serviceID = serviceID << 8 | UInt32(payload[k]) }
            var service = services[serviceID] ?? DABService(id: serviceID)
            service.label = DABCharset.decode(payload[4..<20], charset: charset)
            services[serviceID] = service
        default: break
        }
    }
}

/// Dekodiert den FIC eines Rahmens (3 Symbole = 4 FIC-Blöcke = 12 FIBs).
final class DABFICDecoder: @unchecked Sendable {
    private let viterbi = DABViterbi()
    private let prbs = DABTables.prbs(count: 768)
    private(set) var fibsTotal = 0
    private(set) var fibsGood = 0

    /// Liefert die gültigen FIBs (je 30 Nutzbytes).
    func decode(_ soft: [Int16]) -> [ArraySlice<UInt8>] {
        var fibs: [ArraySlice<UInt8>] = []
        let blockLength = DABPuncturing.fic.transmittedBits   // 2304
        soft.withUnsafeBufferPointer { all in
            for block in 0..<(all.count / blockLength) {
                let input = UnsafeBufferPointer(rebasing: all[(block * blockLength)..<((block + 1) * blockLength)])
                let mother = DABPuncturing.fic.depuncture(input)
                var bits = viterbi.decode(mother, bits: 768)
                for i in 0..<768 { bits[i] ^= prbs[i] }
                let bytes = DABBits.pack(bits)
                for f in 0..<3 {
                    let fib = bytes[(f * 32)..<(f * 32 + 32)]
                    fibsTotal += 1
                    let stored = UInt16(fib[fib.startIndex + 30]) << 8 | UInt16(fib[fib.startIndex + 31])
                    if DABCRC.ccitt(fib.prefix(30)) == stored {
                        fibsGood += 1
                        fibs.append(fib.prefix(30))
                    }
                }
            }
        }
        return fibs
    }

    func resetStatistics() {
        fibsTotal = 0
        fibsGood = 0
    }
}

/// Programmarten (EN 300 401 / TS 101 756, europäische Liste).
enum DABProgrammeType {
    static func name(_ code: Int) -> String {
        let names = [
            "",
            String(localized: "Nachrichten"), String(localized: "Aktuelles"), String(localized: "Information"),
            String(localized: "Sport"), String(localized: "Bildung"), String(localized: "Hörspiel"),
            String(localized: "Kultur"), String(localized: "Wissenschaft"), String(localized: "Unterhaltung"),
            String(localized: "Pop"), String(localized: "Rock"), String(localized: "Leichte Musik"),
            String(localized: "Leichte Klassik"), String(localized: "Klassik"), String(localized: "Andere Musik"),
            String(localized: "Wetter"), String(localized: "Wirtschaft"), String(localized: "Kinder"),
            String(localized: "Soziales"), String(localized: "Religion"), String(localized: "Hörertelefon"),
            String(localized: "Reise"), String(localized: "Freizeit"), String(localized: "Jazz"),
            String(localized: "Country"), String(localized: "Landesmusik"), String(localized: "Oldies"),
            String(localized: "Folk"), String(localized: "Dokumentation"),
        ]
        return code < names.count ? names[code] : ""
    }
}
