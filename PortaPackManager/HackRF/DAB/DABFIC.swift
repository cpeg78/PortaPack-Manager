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
    /// Erste Paketdaten-Komponente (FIG 0/2, TMId 3): Kennung SCId für FIG 0/3.
    var packetComponentID: Int?

    var programmeTypeName: String { DABProgrammeType.name(programmeType) }
}

/// Paketdaten-Komponente (FIG 0/3): Unterkanal, Paketadresse, Datendienstart.
struct DABPacketComponent: Sendable, Equatable {
    var id: Int
    var subchannelID: Int
    var address: Int
    /// DSCTy (60 = MOT).
    var serviceType: Int
    /// MSC-Datengruppen (DG-Flag 0) – für MOT nötig.
    var dataGroups: Bool
}

/// Laufende Durchsage (FIG 0/19): Arten, Unterkanal mit dem Ton, zuletzt gemeldet.
struct DABAnnouncement: Sendable, Equatable {
    var types: UInt16
    var subchannelID: Int
    var date: Date

    /// Klartext der Arten (EN 300 401 Tabelle 14, Bit 0 = Alarm …).
    static func names(_ flags: UInt16) -> [String] {
        let all = [String(localized: "Alarm"), String(localized: "Verkehrsfunk"), String(localized: "Verkehrsmeldung ÖPNV"),
                   String(localized: "Warnung"), String(localized: "pty.news", defaultValue: "Nachrichten"), String(localized: "Wetter"),
                   String(localized: "Veranstaltung"), String(localized: "Sonderereignis"), String(localized: "Programmhinweis"),
                   String(localized: "Sport"), String(localized: "Finanzen")]
        return all.indices.filter { flags & (1 << $0) != 0 }.map { all[$0] }
    }
}

/// Inhalt des FIC: Ensemble, Dienste, Unterkanäle.
struct DABEnsemble: Sendable, Equatable {
    var id: UInt16?
    var label: String = ""
    var services: [UInt32: DABService] = [:]
    var subchannels: [Int: DABSubchannel] = [:]
    /// Uhrzeit des Senders (UTC, FIG 0/10) und Ortszeitversatz in Minuten (FIG 0/9).
    var clock: Date?
    var localOffsetMinutes: Int?
    /// Unterstützte Durchsagearten je Dienst (FIG 0/18).
    var announcementSupport: [UInt32: UInt16] = [:]
    /// Laufende Durchsagen je Cluster (FIG 0/19).
    var announcements: [Int: DABAnnouncement] = [:]
    /// Frequenzen anderer Ensembles je EId in kHz (FIG 0/21, DAB).
    var ensembleFrequencies: [UInt16: Set<Int>] = [:]
    /// UKW-Frequenzen je RDS-PI in kHz (FIG 0/21, UKW mit und ohne RDS).
    var fmFrequencies: [UInt16: Set<Int>] = [:]
    /// Andere Ensembles (EIds), in denen ein Dienst ebenfalls läuft (FIG 0/24).
    var otherEnsembles: [UInt32: Set<UInt16>] = [:]
    /// Paketdaten-Komponenten je SCId (FIG 0/3).
    var packetComponents: [Int: DABPacketComponent] = [:]
    /// Dienste mit Programmführer (FIG 0/13, Anwendungstyp 7 = SPI).
    var spiServices: Set<UInt32> = []
    /// Höchstzahl je Liste – eine fehlerhafte Aussendung soll den Speicher nicht füllen.
    static let maxAlternatives = 32

    /// Durchsagen, die in den letzten 10 s gemeldet wurden (sie wiederholen sich laufend).
    func activeAnnouncements(now: Date = Date()) -> [DABAnnouncement] {
        announcements.values.filter { $0.types != 0 && now.timeIntervalSince($0.date) < 10 }
            .sorted { $0.subchannelID < $1.subchannelID }
    }

    /// Dienst, der auf einem Unterkanal läuft (Ton der Durchsage).
    func service(onSubchannel id: Int) -> DABService? {
        services.values.first { $0.subchannelID == id }
    }

    /// Hörbare Dienste mit Namen, alphabetisch.
    var audioServices: [DABService] {
        services.values
            .filter { $0.kind != .data && !$0.label.isEmpty && $0.subchannelID.map { subchannels[$0] != nil } == true }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Komponente, die den Programmführer (SPI, MOT im Paketmodus) trägt.
    /// Vorrang: Dienst mit SPI-Anwendung (FIG 0/13), sonst ein MOT-Datendienst
    /// mit „EPG“/„SPI“ im Namen.
    var programmeGuideComponent: DABPacketComponent? {
        func component(_ service: DABService) -> DABPacketComponent? {
            guard let id = service.packetComponentID, let c = packetComponents[id], c.dataGroups,
                  subchannels[c.subchannelID] != nil else { return nil }
            return c
        }
        let sorted = services.values.sorted { $0.id < $1.id }
        if let c = sorted.lazy.filter({ spiServices.contains($0.id) }).compactMap(component).first { return c }
        return sorted.lazy.filter { s in
            let label = s.label.uppercased()
            return label.contains("EPG") || label.contains("SPI")
        }.compactMap(component).first { $0.serviceType == 60 }
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
        // Frequenzlisten und Dienste anderer Ensembles gelten für beide OE-Werte.
        switch extensionID {
        case 21: parseFrequencyInformation(payload); return
        case 24: parseOtherEnsembleServices(payload, longID: longServiceID); return
        default: break
        }
        guard !otherEnsemble else { return }
        switch extensionID {
        case 0:
            if payload.count >= 2 { id = UInt16(payload[0]) << 8 | UInt16(payload[1]) }
        case 1: parseSubchannels(payload)
        case 2: parseServices(payload, longID: longServiceID)
        case 3: parsePacketComponents(payload)
        case 13: parseUserApplications(payload, longID: longServiceID)
        case 17: parseProgrammeTypes(payload)
        case 9 where payload.count >= 1:
            // Ortszeitversatz in halben Stunden mit Vorzeichen (Bit 5).
            let halfHours = Int(payload[0] & 0x1F)
            localOffsetMinutes = halfHours * 30 * (payload[0] & 0x20 != 0 ? -1 : 1)
        case 10: parseClock(payload)
        case 18: parseAnnouncementSupport(payload)
        case 19: parseAnnouncementSwitching(payload)
        default: break
        }
    }

    /// FIG 0/10: rfu (1) · MJD (17) · LSI · rfa · UTC-Flag · Stunde (5) · Minute (6)
    /// [· Sekunde (6) · Millisekunde (10)].
    private mutating func parseClock(_ p: [UInt8]) {
        guard p.count >= 4 else { return }
        let word = Int(p[0]) << 24 | Int(p[1]) << 16 | Int(p[2]) << 8 | Int(p[3])
        let mjd = (word >> 14) & 0x1FFFF
        let long = (word >> 11) & 1 == 1
        let hour = (word >> 6) & 0x1F, minute = word & 0x3F
        var seconds = Double(hour * 3600 + minute * 60)
        if long, p.count >= 6 { seconds += Double(p[4] >> 2) + Double(Int(p[4] & 0x03) << 8 | Int(p[5])) / 1000 }
        guard mjd > 50_000, hour < 24, minute < 60 else { return }
        clock = Date(timeIntervalSince1970: Double(mjd - 40_587) * 86_400 + seconds)   // MJD 40587 = 1970-01-01
    }

    /// FIG 0/18: SId (16) · Arten (16) · rfa (3) · Zahl der Cluster (5) · Cluster-IDs.
    private mutating func parseAnnouncementSupport(_ p: [UInt8]) {
        var i = 0
        while i + 5 <= p.count {
            let sid = UInt32(p[i]) << 8 | UInt32(p[i + 1])
            announcementSupport[sid] = UInt16(p[i + 2]) << 8 | UInt16(p[i + 3])
            i += 5 + Int(p[i + 4] & 0x1F)
        }
    }

    /// FIG 0/21 (EN 300 401 §8.1.8): Blöcke aus Rfa (11) · Länge (5) und einer
    /// FI-Liste; je Eintrag Kennung (16) · R&M (4) · Fortsetzung (1) · Länge (3)
    /// und die Frequenzen. R&M 0/1 = DAB-Ensemble (Steuerfeld 5 + Frequenz 19 Bit
    /// in 16 kHz), 8/9 = UKW mit/ohne RDS (1 Byte, 87,5 MHz + n · 100 kHz).
    /// AM, DRM und AMSS werden übersprungen.
    private mutating func parseFrequencyInformation(_ p: [UInt8]) {
        var i = 0
        while i + 2 <= p.count {
            let end = min(i + 2 + Int(p[i + 1] & 0x1F), p.count)
            i += 2
            while i + 3 <= end {
                let id = UInt16(p[i]) << 8 | UInt16(p[i + 1])
                let rm = Int(p[i + 2] >> 4)
                let listEnd = min(i + 3 + Int(p[i + 2] & 0x07), end)
                i += 3
                switch rm {
                case 0, 1:
                    var j = i
                    while j + 3 <= listEnd {
                        let units = Int(p[j] & 0x07) << 16 | Int(p[j + 1]) << 8 | Int(p[j + 2])
                        if units > 0 { Self.insert(units * 16, into: &ensembleFrequencies[id, default: []]) }
                        j += 3
                    }
                case 8, 9:
                    for code in p[i..<listEnd] where (1...204).contains(code) {
                        Self.insert(87_500 + Int(code) * 100, into: &fmFrequencies[id, default: []])
                    }
                default: break
                }
                i = listEnd
            }
            i = end
        }
    }

    /// FIG 0/24 (§8.1.10): SId (16 bzw. 32 Bit) · Rfa · CAId (3) · Anzahl (4) · EIds.
    private mutating func parseOtherEnsembleServices(_ p: [UInt8], longID: Bool) {
        let sidLength = longID ? 4 : 2
        var i = 0
        while i + sidLength + 1 <= p.count {
            let sid = p[i..<(i + sidLength)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let count = Int(p[i + sidLength] & 0x0F)
            i += sidLength + 1
            guard i + 2 * count <= p.count else { return }
            for k in 0..<count {
                let eid = UInt16(p[i + 2 * k]) << 8 | UInt16(p[i + 2 * k + 1])
                if eid != id { Self.insert(eid, into: &otherEnsembles[sid, default: []]) }
            }
            i += 2 * count
        }
    }

    private static func insert<T: Hashable>(_ value: T, into set: inout Set<T>) {
        if set.count < maxAlternatives || set.contains(value) { set.insert(value) }
    }

    /// FIG 0/3 (§6.3.2): SCId (12) · Rfa (3) · CAOrg (1) · DG (1) · Rfu (1) ·
    /// DSCTy (6) · SubChId (6) · Paketadresse (10) [· CAOrg (16)].
    private mutating func parsePacketComponents(_ p: [UInt8]) {
        var i = 0
        while i + 5 <= p.count {
            let id = Int(p[i]) << 4 | Int(p[i + 1] >> 4)
            let caOrg = p[i + 1] & 0x01 != 0
            packetComponents[id] = DABPacketComponent(
                id: id, subchannelID: Int(p[i + 3] >> 2), address: Int(p[i + 3] & 0x03) << 8 | Int(p[i + 4]),
                serviceType: Int(p[i + 2] & 0x3F), dataGroups: p[i + 2] & 0x80 == 0)
            i += caOrg ? 7 : 5
        }
    }

    /// FIG 0/13 (§8.1.20): SId · SCIdS (4) · Anzahl (4), je Anwendung Typ (11) · Länge (5) · Daten.
    private mutating func parseUserApplications(_ p: [UInt8], longID: Bool) {
        let sidLength = longID ? 4 : 2
        var i = 0
        while i + sidLength + 1 <= p.count {
            let sid = p[i..<(i + sidLength)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let count = Int(p[i + sidLength] & 0x0F)
            i += sidLength + 1
            for _ in 0..<count {
                guard i + 2 <= p.count else { return }
                let type = Int(p[i]) << 3 | Int(p[i + 1] >> 5)
                if type == 7 { spiServices.insert(sid) }
                i += 2 + Int(p[i + 1] & 0x1F)
            }
        }
    }

    /// FIG 0/19: Cluster (8) · Arten (16) · Neu · Region · Unterkanal (6) [· Region (8)].
    private mutating func parseAnnouncementSwitching(_ p: [UInt8]) {
        var i = 0
        while i + 4 <= p.count {
            let cluster = Int(p[i])
            let types = UInt16(p[i + 1]) << 8 | UInt16(p[i + 2])
            let region = p[i + 3] & 0x40 != 0
            announcements[cluster] = DABAnnouncement(types: types, subchannelID: Int(p[i + 3] & 0x3F), date: Date())
            i += region ? 5 : 4
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
                if tmID == 3, service.packetComponentID == nil {
                    service.packetComponentID = Int(p[i] & 0x3F) << 6 | Int(p[i + 1] >> 2)
                }
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
            String(localized: "pty.news", defaultValue: "Nachrichten"), String(localized: "Aktuelles"), String(localized: "Information"),
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
