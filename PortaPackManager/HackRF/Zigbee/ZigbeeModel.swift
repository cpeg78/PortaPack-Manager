import Foundation
import Observation
import Security

/// Ein ausgewerteter Zigbee-Rahmen für Protokoll und Geräteliste.
struct ZigbeePacket: Identifiable, Sendable {
    let id: Int
    let radio: ZigbeeRadioFrame
    let mac: MACFrame?
    let nwk: NWKFrame?
    /// Entschlüsselte NWK-Nutzdaten (nur mit passendem Netzwerkschlüssel).
    let decrypted: [UInt8]?
    /// Stelle des passenden Schlüssels in der Schlüsselliste.
    let keyIndex: Int?
    let aps: APSFrame?
    let zcl: ZCLMessage?
    let zdo: ZDOMessage?
    let beacon: ZigbeeBeacon?
    /// Thread/6LoWPAN statt Zigbee-NWK.
    let thread: ThreadFrame?
    /// Aus einem Transport-Key-Befehl gewonnener Netzwerkschlüssel (beim Beitritt).
    let recoveredKey: [UInt8]?
    let summary: String
    let links: [(neighbor: UInt16, incoming: Int, outgoing: Int)]

    var encrypted: Bool {
        if let thread {
            let macLocked = mac?.securityHeader?.encrypted == true && !thread.decrypted
            let mleLocked = thread.lowpan?.udpDestination == LoWPANPacket.mlePort && thread.mle == nil
            return macLocked || mleLocked
        }
        return nwk?.security == true && decrypted == nil
    }

    /// Wertet einen Funkrahmen aus; `key` ist der Netzwerkschlüssel, falls bekannt.
    static func interpret(_ radio: ZigbeeRadioFrame, id: Int, key: [UInt8]?) -> ZigbeePacket {
        interpret(radio, id: id, keys: key.map { [$0] } ?? [])
    }

    /// Wertet einen Funkrahmen aus; verschlüsselte Rahmen werden mit jedem
    /// Schlüssel aus `keys` probiert (mehrere Netze) – die MIC entscheidet.
    /// Thread-Rahmen (MAC-Sicherheit oder 6LoWPAN) gehen an `ThreadFrame`,
    /// `threadAddresses` liefert die Langadressen zu Kurzadressen.
    static func interpret(_ radio: ZigbeeRadioFrame, id: Int, keys: [[UInt8]], threadKeys: [[UInt8]] = [],
                          threadAddresses: [UInt16: UInt64] = [:], linkKeys: [[UInt8]] = [ZigbeeAPSSecurity.defaultTrustCenterLinkKey]) -> ZigbeePacket {
        let mac = MACFrame.parse(radio.mpdu)
        var nwk: NWKFrame?
        var decrypted: [UInt8]?
        var keyIndex: Int?
        var aps: APSFrame?
        var zcl: ZCLMessage?
        var zdo: ZDOMessage?
        var beacon: ZigbeeBeacon?
        var thread: ThreadFrame?
        var recoveredKey: [UInt8]?
        var links: [(UInt16, Int, Int)] = []
        var summary = mac?.kind.title ?? String(localized: "Unlesbarer MAC-Rahmen")
        if let mac, mac.kind == .data, mac.security || LoWPANPacket.looksLikeLoWPAN(mac.payload),
           let frame = ThreadFrame.interpret(mpdu: radio.mpdu, mac: mac, networkKeys: threadKeys, addresses: threadAddresses) {
            thread = frame
            summary = frame.summary
            if frame.decrypted { decrypted = frame.lowpan?.payload ?? [] }
        } else if let mac {
            switch mac.kind {
            case .beacon:
                beacon = ZigbeeBeacon.parse(mac.payload)
                if let beacon {
                    let pan = ZigbeeFormat.ieee(beacon.extendedPAN)
                    summary = beacon.permitJoining
                        ? String(localized: "Beacon · erweiterte PAN \(pan) · Beitritt offen")
                        : String(localized: "Beacon · erweiterte PAN \(pan)")
                }
            case .command:
                summary = mac.payload.first.flatMap { MACFrame.commandNames[$0] } ?? String(localized: "MAC-Befehl")
            case .ack:
                summary = String(localized: "Quittung #\(Int(mac.sequence))")
            case .data:
                nwk = NWKFrame.parse(mac.payload)
                guard let frame = nwk else { summary = String(localized: "Daten (kein Zigbee-NWK)"); break }
                var payload: [UInt8]? = frame.security ? nil : frame.payload
                if frame.security {
                    for (index, key) in keys.enumerated() {
                        guard let clear = ZigbeeSecurity.decrypt(nwk: mac.payload, header: frame, key: key) else { continue }
                        decrypted = clear
                        keyIndex = index
                        break
                    }
                    payload = decrypted
                }
                guard let payload else {
                    summary = frame.kind == .command ? String(localized: "NWK-Befehl (verschlüsselt)") : String(localized: "Daten (verschlüsselt)")
                    break
                }
                if frame.kind == .command {
                    let id = payload.first ?? 0
                    summary = NWKCommand.names[id] ?? String(format: String(localized: "NWK-Befehl 0x%02X"), id)
                    links = NWKCommand.linkStatus(payload)
                    if !links.isEmpty { summary = String(localized: "\(summary) · \(links.count) Nachbarn") }
                } else if let parsed = APSFrame.parse(payload) {
                    aps = parsed
                    // Gesicherte APS-Befehle (z. B. Transport-Key beim Beitritt) mit den Link-Keys lesen;
                    // nur ein Schlüssel mit gültiger MIC liefert ein Ergebnis.
                    if parsed.security, let security = parsed.securityHeader, !linkKeys.isEmpty,
                       let source = security.source ?? frame.sourceIEEE ?? frame.securityHeader?.source,
                       let apsClear = ZigbeeAPSSecurity.decrypt(raw: payload, headerLength: parsed.headerLength,
                                                                security: security, source: source, linkKeys: linkKeys) {
                        if parsed.kind == .command, let found = ZigbeeAPSSecurity.networkKey(fromTransportKey: apsClear.payload) {
                            recoveredKey = found.key
                            summary = String(localized: "Netzwerkschlüssel beim Beitritt mitgelesen (Transport-Key, Folge \(Int(found.sequence)))")
                        } else {
                            summary = parsed.kind == .command ? String(localized: "APS-Befehl (entschlüsselt)") : ZCL.clusterName(parsed.cluster ?? 0)
                        }
                    } else {
                    switch parsed.kind {
                    case .ack: summary = String(localized: "APS-Quittung")
                    case .command: summary = parsed.security ? String(localized: "APS-Befehl (verschlüsselt)") : String(localized: "APS-Befehl")
                    default:
                        let cluster = parsed.cluster ?? 0
                        if parsed.profile == 0x0000 {
                            zdo = ZDOMessage.parse(cluster: cluster, parsed.payload)
                            summary = zdo?.summary ?? String(format: String(localized: "Geräteverwaltung (ZDO) 0x%04X"), cluster)
                        } else if let message = ZCLMessage.parse(parsed.payload, cluster: cluster) {
                            zcl = message
                            summary = ZCL.clusterName(cluster) + ": " + message.summary
                                + (message.readings.isEmpty ? "" : " · " + message.readings.joined(separator: ", "))
                        } else {
                            summary = ZCL.clusterName(cluster)
                        }
                    }
                    }
                }
            }
        }
        return ZigbeePacket(id: id, radio: radio, mac: mac, nwk: nwk, decrypted: decrypted, keyIndex: keyIndex,
                            aps: aps, zcl: zcl, zdo: zdo, beacon: beacon, thread: thread, recoveredKey: recoveredKey, summary: summary, links: links)
    }
}

/// Ein Zigbee-Teilnehmer, zusammengefasst über seine Kurzadresse im PAN.
struct ZigbeeNode: Identifiable, Sendable, Equatable {
    struct Key: Hashable, Sendable { var pan: UInt16; var address: UInt16 }
    let key: Key
    var ieee: UInt64?
    var channel: Int
    /// Rahmen, die dieses Gerät selbst gefunkt hat (MAC-Quelle).
    var heard = 0
    /// Rahmen, die es ausgelöst hat (NWK-Quelle, auch über Router).
    var originated = 0
    var rssiDB: Double?
    var lastReadings: [String] = []
    var lastSummary = ""
    /// Nachbarn aus dem Verbindungsstatus (nur Router senden ihn).
    var neighbors: [UInt16: (incoming: Int, outgoing: Int)] = [:]
    /// Nachbartabelle (ZDO Mgmt_Lqi): Nachbar → LQI.
    var lqiNeighbors: [UInt16: Int] = [:]
    /// Gerätetyp aus Endpunkt- oder Knotenbeschreibung bzw. Gerätemeldung.
    var deviceType: String?
    var router: Bool?
    var mainsPowered: Bool?
    var endpoints: Set<UInt8> = []
    var manufacturer: String?
    var model: String?
    /// Letzter Wert je Cluster, z. B. „Temperatur“ → „21.50 °C“.
    var state: [String: String] = [:]
    /// Zahlenwert je Messgröße (für den Verlauf), z. B. „°C“ → 21.5.
    var metrics: [String: Double] = [:]
    /// Gerät spricht Thread (6LoWPAN) statt Zigbee.
    var thread = false
    var lastSeen: Date

    var id: Key { key }
    var role: String {
        if thread { return deviceType ?? String(localized: "Thread-Gerät") }
        if key.address == 0x0000 { return String(localized: "Koordinator") }
        if let deviceType { return deviceType }
        if let router { return router ? String(localized: "Router") : String(localized: "Endgerät") }
        return neighbors.isEmpty ? String(localized: "Endgerät/Router") : String(localized: "Router")
    }

    var power: String? {
        mainsPowered.map { $0 ? String(localized: "Netzstrom") : String(localized: "Batterie") }
    }

    /// Zustand als eine Zeile, stabil sortiert.
    var stateLine: String {
        state.keys.sorted().map { state[$0]! }.joined(separator: " · ")
    }

    /// Fügt Messwerte eines Clusters in den Zustand ein (Hersteller/Modell
    /// aus dem Basis-Cluster gesondert).
    mutating func apply(readings: [String], cluster: UInt16) {
        var values: [String] = []
        for reading in readings {
            if reading.hasPrefix("Modell ") { model = String(reading.dropFirst(7)) }
            else if reading.hasPrefix("Hersteller ") { manufacturer = String(reading.dropFirst(11)) }
            else { values.append(reading) }
        }
        // Cluster und Beschriftungen kommen aus der Luft – je Gerät begrenzen.
        let name = ZCL.clusterName(cluster)
        if !values.isEmpty, state[name] != nil || state.count < Self.maxStateEntries { state[name] = values.joined(separator: ", ") }
        for value in values {
            if let (label, number) = ZigbeeReading.parse(value), metrics[label] != nil || metrics.count < Self.maxMetrics {
                metrics[label] = number
            }
        }
    }

    static let maxStateEntries = 64
    static let maxMetrics = 32

    static func == (a: ZigbeeNode, b: ZigbeeNode) -> Bool {
        a.key == b.key && a.heard == b.heard && a.originated == b.originated && a.lastSeen == b.lastSeen
    }
}

/// Ein hinterlegter Netzwerkschlüssel samt dem, was er bisher entschlüsselt hat.
struct ZigbeeKeyEntry: Identifiable, Sendable, Equatable {
    let bytes: [UInt8]
    var decrypted = 0
    /// PANs, deren Rahmen mit diesem Schlüssel lesbar waren.
    var pans: Set<UInt16> = []

    var id: [UInt8] { bytes }
    var hex: String { bytes.map { String(format: "%02X", $0) }.joined() }
    /// Gekürzt für die Liste: erste und letzte zwei Bytes.
    var short: String {
        let h = bytes.map { String(format: "%02X", $0) }
        return h[0] + h[1] + "…" + h[14] + h[15]
    }
}

/// Zigbee im HackRF-Modus: ein Kanal 11–26 oder Kanalsuche über alle.
@MainActor
@Observable
final class ZigbeeModel {
    static let channelKey = "zigbeeChannel"
    var channel = UserDefaults.standard.object(forKey: channelKey) as? Int ?? 15
    var lnaGain = GainProfile.preset(.zigbee).lna
    var vgaGain = GainProfile.preset(.zigbee).vga
    var amplifier = GainProfile.preset(.zigbee).amplifier
    var antennaPower = false

    private(set) var running = false
    private(set) var scanning = false
    private(set) var nodes: [ZigbeeNode] = [] {
        didSet {
            shortNames = Dictionary(nodes.compactMap { node in name(of: node).map { (node.key.address, $0) } },
                                    uniquingKeysWith: { first, _ in first })
        }
    }
    /// Namen je Kurzadresse für die Rahmenliste (bei gleicher Adresse in zwei
    /// Netzen gilt das zuletzt gehörte Gerät).
    private(set) var shortNames: [UInt16: String] = [:]
    private(set) var log: [ZigbeePacket] = []
    private(set) var frameCount = 0
    private(set) var decryptedCount = 0
    private(set) var crcErrors = 0
    private(set) var noiseDB = -100.0
    /// Rahmen je Kanal aus der Kanalsuche.
    private(set) var channelActivity: [Int: Int] = [:]
    /// Netzwerkschlüssel (mehrere Netze), in der Reihenfolge der Eingabe.
    private(set) var keys = ZigbeeKeyStore.load().map { ZigbeeKeyEntry(bytes: $0) }
    var hasKey: Bool { !keys.isEmpty }
    /// Thread-Netzwerkschlüssel (OpenThread `networkkey`, Matter-Dataset 0x0005).
    private(set) var threadKeys = ThreadKeyStore.load().map { ZigbeeKeyEntry(bytes: $0) }
    private(set) var threadFrames = 0
    private(set) var threadDecrypted = 0
    /// Beim Beitritt mitgelesene Netzwerkschlüssel (noch nicht in der Liste).
    private(set) var recoveredKeys: [[UInt8]] = []
    /// Bekannte Geräte (Namen, Modelle) je IEEE-Adresse.
    private(set) var directory = ZigbeeDirectory.load()
    /// PAN des eigenen Netzes aus der Zigbee2MQTT-Konfiguration.
    var ownPAN: UInt16? = UserDefaults.standard.object(forKey: "zigbeeOwnPAN") as? UInt16 {
        didSet { UserDefaults.standard.set(ownPAN, forKey: "zigbeeOwnPAN") }
    }
    /// Rahmen je Sekunde, geglättet.
    private(set) var frameRate = 0.0
    private var lastPoll: (date: Date, count: Int)?
    private(set) var error: String?

    private let shared = Shared()
    private var pollTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Kennung der laufenden Kanalsuche – eine abgebrochene alte räumt den
    /// Zustand einer neuen nicht ab.
    private var scanRun: UUID?
    private weak var device: HackRFDevice?

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let demod = ZigbeeDemodulator()
        var channel = 15
        var keys: [ZigbeeKeyEntry] = ZigbeeKeyStore.load().map { ZigbeeKeyEntry(bytes: $0) }
        var threadKeys: [ZigbeeKeyEntry] = ThreadKeyStore.load().map { ZigbeeKeyEntry(bytes: $0) }
        /// Zusätzliche Link-Keys (Install-Codes); der Standard-TCLK ist immer dabei.
        var linkKeys: [[UInt8]] = [ZigbeeAPSSecurity.defaultTrustCenterLinkKey]
        /// Beim Beitritt mitgelesene Netzwerkschlüssel (noch nicht übernommen).
        var recovered: [[UInt8]] = []
        /// Thread: Kurzadresse (RLOC16) → Langadresse, aus MLE gelernt.
        var threadAddresses: [UInt16: UInt64] = [:]
        var threadFrames = 0
        var threadDecrypted = 0
        var nodes: [ZigbeeNode.Key: ZigbeeNode] = [:]
        /// Zeitreihe je Gerät: Pegel und Messwerte, gedrosselt.
        var history: [ZigbeeNode.Key: [ZigbeeHistorySample]] = [:]
        private var lastSample: [ZigbeeNode.Key: Date] = [:]

        /// Hält Pegel/Messwerte eines Geräts fest – höchstens alle 2 s, max. 600 Punkte.
        func record(_ node: ZigbeeNode, date: Date) {
            if let last = lastSample[node.key], date.timeIntervalSince(last) < 2 { return }
            lastSample[node.key] = date
            var series = history[node.key] ?? []
            series.append(ZigbeeHistorySample(date: date, rssiDB: node.rssiDB, metrics: node.metrics))
            if series.count > 600 { series.removeFirst(series.count - 600) }
            history[node.key] = series
        }
        static let maxRecoveredKeys = 8
        /// Höchstzahl geführter Geräte; Adressen kommen aus der Luft, zufällige
        /// blähten die Liste sonst unbegrenzt auf (wie bei ADS-B/BLE).
        static let maxNodes = 2000
        static let maxHistoryNodes = 300
        static let staleAge: TimeInterval = 3600
        private var lastPrune = Date.distantPast

        /// Lange nicht gehörte Geräte weg, wenn die Liste zu groß wird; der
        /// Verlauf nur für die zuletzt aktiven Geräte.
        func prune(now: Date) {
            guard now.timeIntervalSince(lastPrune) >= 10 || nodes.count > Self.maxNodes * 2 else { return }
            lastPrune = now
            if nodes.count > Self.maxNodes {
                nodes = nodes.filter { now.timeIntervalSince($0.value.lastSeen) < Self.staleAge }
                if nodes.count > Self.maxNodes {
                    let keep = nodes.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.maxNodes)
                    nodes = Dictionary(keep.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                }
            }
            history = history.filter { nodes[$0.key] != nil }
            lastSample = lastSample.filter { nodes[$0.key] != nil }
            if history.count > Self.maxHistoryNodes {
                let keep = history.sorted { ($0.value.last?.date ?? .distantPast) > ($1.value.last?.date ?? .distantPast) }
                    .prefix(Self.maxHistoryNodes)
                history = Dictionary(keep.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
                lastSample = lastSample.filter { history[$0.key] != nil }
            }
            if threadAddresses.count > Self.maxNodes { threadAddresses = [:] }
        }
        var log: [ZigbeePacket] = []
        var count = 0
        var decrypted = 0
        var perChannel: [Int: Int] = [:]
        var crcErrors = 0
        var noiseDB = -100.0

        func handle(_ block: Data) {
            let (channel, keys, threadKeys, linkKeys) = lock.withLock { (self.channel, self.keys.map(\.bytes), self.threadKeys.map(\.bytes), self.linkKeys) }
            let frames = demod.process(block, channel: channel)
            let errors = demod.crcErrors, noise = demod.noiseDB
            lock.withLock {
                crcErrors = errors
                noiseDB = noise
                for frame in frames {
                    count += 1
                    let packet = ZigbeePacket.interpret(frame, id: count, keys: keys, threadKeys: threadKeys,
                                                        threadAddresses: threadAddresses, linkKeys: linkKeys)
                    credit(packet)
                    perChannel[channel, default: 0] += 1
                    log.append(packet)
                    ingest(packet)
                }
                if log.count > 2000 { log.removeFirst(log.count - 2000) }
                if let last = frames.last { prune(now: last.date) }
            }
        }

        /// Zählt einen entschlüsselten Rahmen dem passenden Schlüssel zu.
        func credit(_ packet: ZigbeePacket) {
            if let thread = packet.thread {
                threadFrames += 1
                if thread.decrypted || thread.mle != nil { threadDecrypted += 1 }
                if let learned = thread.learned { threadAddresses[learned.short] = learned.extended }
                return
            }
            if let recoveredKey = packet.recoveredKey,
               !recovered.contains(recoveredKey), !keys.contains(where: { $0.bytes == recoveredKey }) {
                // Mit dem öffentlichen Standard-Link-Key kann jeder Transport-Key-
                // Befehle fälschen – nur die jüngsten paar Vorschläge behalten.
                recovered.append(recoveredKey)
                if recovered.count > Self.maxRecoveredKeys { recovered.removeFirst(recovered.count - Self.maxRecoveredKeys) }
            }
            guard packet.decrypted != nil else { return }
            decrypted += 1
            guard let index = packet.keyIndex, index < keys.count else { return }
            keys[index].decrypted += 1
            if let pan = packet.mac?.pan { keys[index].pans.insert(pan) }
        }

        private func ingest(_ packet: ZigbeePacket) {
            guard let mac = packet.mac, let pan = mac.pan else { return }
            let date = packet.radio.date
            // Thread: Sender über Kurz- oder Langadresse führen.
            if let thread = packet.thread {
                let address: UInt16
                switch mac.source {
                case let .short(s)?: address = s
                case let .extended(e)?: address = thread.mle?.sourceAddress16 ?? UInt16(truncatingIfNeeded: e)
                default: return
                }
                let key = ZigbeeNode.Key(pan: pan, address: address)
                var node = nodes[key] ?? ZigbeeNode(key: key, channel: packet.radio.channel, lastSeen: date)
                node.thread = true
                node.heard += 1
                node.channel = packet.radio.channel
                if case let .extended(e)? = mac.source { node.ieee = e } else { node.ieee = node.ieee ?? threadAddresses[address] }
                node.rssiDB = node.rssiDB.map { 0.7 * $0 + 0.3 * packet.radio.rssiDB } ?? packet.radio.rssiDB
                node.lastSummary = thread.summary
                if let mle = thread.mle {
                    node.state["MLE"] = mle.commandName
                    if let mode = mle.tlv(1)?.first {
                        node.router = mode & 0x02 != 0
                        node.deviceType = mode & 0x02 != 0 ? String(localized: "Thread (vollwertig)") : String(localized: "Thread (Endgerät)")
                        node.mainsPowered = mode & 0x08 != 0 ? true : node.mainsPowered
                    }
                    if mle.command == 4 { node.deviceType = String(localized: "Thread-Router") }
                }
                node.lastSeen = date
                nodes[key] = node
                return
            }
            // Letzter Funkabschnitt: MAC-Quelle mit Pegel.
            if case let .short(address)? = mac.source {
                var node = nodes[.init(pan: pan, address: address)]
                    ?? ZigbeeNode(key: .init(pan: pan, address: address), channel: packet.radio.channel, lastSeen: date)
                node.heard += 1
                node.channel = packet.radio.channel
                node.rssiDB = node.rssiDB.map { 0.7 * $0 + 0.3 * packet.radio.rssiDB } ?? packet.radio.rssiDB
                node.lastSeen = date
                if !packet.links.isEmpty {
                    // Doppelte Nachbaradressen aus der Luft – sonst Absturz.
                    node.neighbors = Dictionary(packet.links.map { ($0.neighbor, ($0.incoming, $0.outgoing)) },
                                                uniquingKeysWith: { _, new in new })
                }
                nodes[node.key] = node
                record(node, date: date)
            }
            // Urheber laut NWK (kann über Router weitergeleitet sein).
            if let nwk = packet.nwk {
                let key = ZigbeeNode.Key(pan: pan, address: nwk.source)
                var node = nodes[key] ?? ZigbeeNode(key: key, channel: packet.radio.channel, lastSeen: date)
                node.originated += 1
                node.ieee = nwk.sourceIEEE ?? nwk.securityHeader?.source ?? node.ieee
                node.lastSummary = packet.summary
                if let zcl = packet.zcl, let cluster = packet.aps?.cluster {
                    if !zcl.readings.isEmpty {
                        node.lastReadings = zcl.readings
                        node.apply(readings: zcl.readings, cluster: cluster)
                    }
                    // Zonenstatus meldet der Sensor selbst (Cluster-Befehl von der Quelle).
                    if zcl.clusterSpecific, cluster == 0x0500, zcl.command == 0 { node.state[ZCL.clusterName(cluster)] = zcl.summary }
                }
                if let endpoint = packet.aps?.sourceEndpoint, endpoint != 0 { node.endpoints.insert(endpoint) }
                if let zdo = packet.zdo, !zdo.neighbors.isEmpty {
                    node.lqiNeighbors = Dictionary(zdo.neighbors.map { ($0.nwk, $0.lqi) }, uniquingKeysWith: { _, new in new })
                }
                node.lastSeen = date
                nodes[key] = node
                record(node, date: date)
                // Steuerbefehle (Ein/Aus, Helligkeit, Farbe) beschreiben den Zustand des Ziels.
                if let zcl = packet.zcl, zcl.clusterSpecific, let cluster = packet.aps?.cluster,
                   [0x0006, 0x0008, 0x0102].contains(cluster), nwk.destination < 0xFFF8 {
                    let target = ZigbeeNode.Key(pan: pan, address: nwk.destination)
                    var targetNode = nodes[target] ?? ZigbeeNode(key: target, channel: packet.radio.channel, lastSeen: date)
                    targetNode.state[ZCL.clusterName(cluster)] = zcl.summary
                    if let endpoint = packet.aps?.destinationEndpoint, endpoint != 0 { targetNode.endpoints.insert(endpoint) }
                    nodes[target] = targetNode
                }
            }
            if let zdo = packet.zdo { ingest(zdo, pan: pan, channel: packet.radio.channel, date: date) }
        }

        /// ZDO-Inhalte beschreiben oft ein anderes Gerät als den Absender.
        private func ingest(_ zdo: ZDOMessage, pan: UInt16, channel: Int, date: Date) {
            func update(_ address: UInt16, _ body: (inout ZigbeeNode) -> Void) {
                let key = ZigbeeNode.Key(pan: pan, address: address)
                var node = nodes[key] ?? ZigbeeNode(key: key, channel: channel, lastSeen: date)
                body(&node)
                nodes[key] = node
            }
            if let announce = zdo.announce {
                update(announce.nwk) { node in
                    node.ieee = announce.ieee
                    node.router = announce.router
                    node.mainsPowered = announce.mainsPowered
                }
            }
            if let mapping = zdo.addressMapping {
                update(mapping.nwk) { $0.ieee = mapping.ieee }
            }
            if let descriptor = zdo.simpleDescriptor {
                update(descriptor.nwk) { node in
                    node.endpoints.insert(descriptor.endpoint)
                    // Der niedrigste Endpunkt benennt das Gerät; Green-Power-Endpunkt 242 nicht.
                    if descriptor.endpoint != 242, node.deviceType == nil || descriptor.endpoint <= (node.endpoints.filter { $0 != 242 }.min() ?? 255) {
                        node.deviceType = descriptor.deviceName
                    }
                }
            }
            if let descriptor = zdo.nodeDescriptor {
                update(descriptor.nwk) { node in
                    node.router = descriptor.logicalType <= 1
                    node.mainsPowered = descriptor.mainsPowered
                    if node.deviceType == nil, descriptor.logicalType == 0 { node.deviceType = String(localized: "Koordinator") }
                }
            }
            if let active = zdo.activeEndpoints {
                update(active.nwk) { $0.endpoints.formUnion(active.endpoints) }
            }
            for neighbor in zdo.neighbors where neighbor.ieee != 0 && neighbor.ieee != 0xFFFF_FFFF_FFFF_FFFF {
                update(neighbor.nwk) { node in
                    node.ieee = neighbor.ieee
                    if neighbor.deviceType < 3 { node.router = neighbor.deviceType <= 1 }
                }
            }
        }
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            try device.setSampleRate(UInt32(ZigbeeDemodulator.inputRate))
            try device.setBasebandFilter(ZigbeeDemodulator.basebandFilter)
            try tune(device, channel)
            try applyGains(to: device)
            shared.demod.reset()
            let shared = shared
            try device.startReceiving(owner: self) { shared.handle($0) }
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    // Jede Sekunde: bei 25 Rahmen/s baute SwiftUI sonst alle 400 ms
                    // Gerätetabelle, 500 Protokollzeilen und Karte neu – 70 % CPU (27.10.2026).
                    try? await Task.sleep(for: .seconds(1))
                    self?.poll()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop(on device: HackRFDevice?) {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
        pollTask?.cancel()
        pollTask = nil
        device?.stopReceiving(owner: self)
        running = false
    }

    private func tune(_ device: HackRFDevice, _ channel: Int) throws {
        shared.lock.withLock { shared.channel = channel }
        try device.setFrequency(UInt64(IEEE802154.frequencyMHz(channel: channel) * 1_000_000 - ZigbeeDemodulator.offset))
    }

    func setChannel(_ channel: Int) {
        self.channel = channel
        UserDefaults.standard.set(channel, forKey: Self.channelKey)
        guard running, let device, device.isReceiving(for: self) else { return }
        do { try tune(device, channel) } catch { self.error = error.localizedDescription }
    }

    /// Kanalsuche: jeden Kanal `seconds` lang abhören, Rahmen zählen,
    /// danach auf den aktivsten Kanal gehen.
    ///
    /// Vor jedem Umstimmen prüft die Suche den Besitz: Hat eine andere Seite,
    /// der Fernzugriff oder der Plan das Gerät übernommen, endet sie, statt
    /// deren Strom umzustimmen. Nur eine vollständige Suche wechselt auf den
    /// besten Kanal; abgebrochen kehrt sie zum Ausgangskanal zurück
    /// (Review 28.10.2026, Y9).
    func scanChannels(seconds: Double = 3) {
        guard running, let device, !scanning, device.isReceiving(for: self) else { return }
        scanning = true
        shared.lock.withLock { shared.perChannel = [:] }
        channelActivity = [:]
        let original = channel
        let run = UUID()
        scanRun = run
        scanTask = Task { [weak self] in
            guard let self else { return }
            var completed = true
            for candidate in IEEE802154.channels {
                guard !Task.isCancelled, device.isReceiving(for: self) else { completed = false; break }
                self.channel = candidate
                do { try self.tune(device, candidate) } catch { self.error = error.localizedDescription; completed = false; break }
                try? await Task.sleep(for: .seconds(seconds))
                self.channelActivity = self.shared.lock.withLock { self.shared.perChannel }
            }
            let stillOwner = !Task.isCancelled && device.isReceiving(for: self)
            if completed, stillOwner, let best = self.channelActivity.max(by: { $0.value < $1.value }), best.value > 0 {
                self.setChannel(best.key)
            } else {
                // Abgebrochen oder nichts gehört: zurück zum Ausgangskanal;
                // umgestimmt wird dabei nur der eigene Strom (`setChannel`).
                self.setChannel(original)
            }
            if self.scanRun == run {
                self.scanning = false
                self.scanRun = nil
            }
        }
    }

    func cancelScan() { scanTask?.cancel() }

    private func poll(force: Bool = false) {
        let (nodes, log, count, decrypted, keys, errors, noise, perChannel, thread, recovered) = shared.lock.withLock {
            (shared.nodes, shared.log, shared.count, shared.decrypted, shared.keys,
             shared.crcErrors, shared.noiseDB, shared.perChannel, (shared.threadFrames, shared.threadDecrypted), shared.recovered)
        }
        if force || count != frameCount {
            // Feste Reihenfolge (Adresse): nach „zuletzt gehört“ sortiert wechselten
            // die Zeilen bei jedem Rahmen den Platz, und die Tabelle zeichnete alles neu.
            let sorted = nodes.values.sorted { ($0.key.pan, $0.key.address) < ($1.key.pan, $1.key.address) }
            if sorted != self.nodes {
                reportToMQTT(sorted, previous: self.nodes)
                self.nodes = sorted
            }
            self.log = Array(log.suffix(500).reversed())
            frameCount = count
            if decrypted != decryptedCount { decryptedCount = decrypted }
            if keys != self.keys { self.keys = keys }
            if thread.0 != threadFrames { threadFrames = thread.0 }
            if thread.1 != threadDecrypted { threadDecrypted = thread.1 }
            if recovered != recoveredKeys { recoveredKeys = recovered }
        }
        let now = Date()
        if let last = lastPoll, now.timeIntervalSince(last.date) >= 1 {
            let rate = Double(count - last.count) / now.timeIntervalSince(last.date)
            let smoothed = frameRate == 0 ? rate : 0.7 * frameRate + 0.3 * rate
            if smoothed != frameRate { frameRate = smoothed }
            lastPoll = (now, count)
        } else if lastPoll == nil {
            lastPoll = (now, count)
        }
        // Nur bei Änderung setzen: @Observable meldet jede Zuweisung, auch
        // gleiche Werte – die Seite baute sonst jede Sekunde neu auf, selbst
        // ohne neuen Rahmen. Rauschen erst ab 0,5 dB Unterschied.
        if errors != crcErrors { crcErrors = errors }
        if abs(noise - noiseDB) >= 0.5 { noiseDB = noise }
        if scanning, perChannel != channelActivity { channelActivity = perChannel }
    }

    /// Neu gehörte Geräte an Home Assistant (nur wenn dort eingeschaltet).
    private func reportToMQTT(_ nodes: [ZigbeeNode], previous: [ZigbeeNode]) {
        let bridge = MQTTBridge.shared
        guard bridge.isEnabled(.zigbee) else { return }
        let before = Dictionary(previous.map { ($0.key, $0.lastSeen) }, uniquingKeysWith: { a, _ in a })
        for node in nodes where before[node.key] != node.lastSeen {
            bridge.report(source: .zigbee, deviceID: MQTTFeeds.deviceID(of: node),
                          name: MQTTFeeds.name(of: node, stored: name(of: node)),
                          model: node.model ?? info(of: node)?.model, manufacturer: node.manufacturer ?? info(of: node)?.manufacturer,
                          values: MQTTFeeds.values(of: node), seen: node.lastSeen)
        }
    }

    func applyGains(to device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    /// Netzwerkschlüssel hinzufügen (Schlüsselbund). Liefert eine
    /// Fehlermeldung, wenn der Text kein Schlüssel ist oder der Schlüsselbund
    /// ihn nicht annimmt (dann gilt er bis zum Beenden). Schon empfangene
    /// Rahmen werden mit der neuen Liste erneut ausgewertet.
    @discardableResult
    func addKey(_ text: String) -> String? {
        guard let key = ZigbeeSecurity.parseKey(text) else {
            return String(localized: "Kein gültiger Schlüssel. Erwartet werden 32 Hex-Zeichen, eine Liste „[1, 3, …]“ mit 16 Zahlen oder der Block aus Zigbee2MQTT.")
        }
        guard !keys.contains(where: { $0.bytes == key }) else { return Self.duplicateKeyMessage }
        return store(keys.map(\.bytes) + [key])
    }

    static var duplicateKeyMessage: String { String(localized: "Dieser Schlüssel ist schon hinterlegt.") }

    func removeKey(_ entry: ZigbeeKeyEntry) {
        store(keys.map(\.bytes).filter { $0 != entry.bytes })
    }

    @discardableResult
    private func store(_ list: [[UInt8]]) -> String? {
        var message: String?
        let status = ZigbeeKeyStore.save(list)
        if status != errSecSuccess {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "Fehler \(Int(status))")
            message = String(localized: "Schlüsselbund: \(reason). Die Schlüssel gelten nur, bis du die App beendest.")
        }
        shared.lock.withLock {
            shared.keys = list.map { ZigbeeKeyEntry(bytes: $0) }
            reinterpret()
        }
        poll(force: true)
        return message
    }

    /// Gepufferte Rahmen mit den aktuellen Schlüsseln neu auswerten (unter `shared.lock`).
    private func reinterpret() {
        let keys = shared.keys.map(\.bytes), threadKeys = shared.threadKeys.map(\.bytes), linkKeys = shared.linkKeys
        shared.decrypted = 0
        shared.threadFrames = 0
        shared.threadDecrypted = 0
        for index in shared.keys.indices { shared.keys[index].decrypted = 0; shared.keys[index].pans = [] }
        shared.log = shared.log.map { ZigbeePacket.interpret($0.radio, id: $0.id, keys: keys, threadKeys: threadKeys,
                                                              threadAddresses: shared.threadAddresses, linkKeys: linkKeys) }
        shared.log.forEach { shared.credit($0) }
    }

    // MARK: Thread

    /// Einen beim Beitritt gefundenen Schlüssel in die Liste übernehmen.
    func adoptRecoveredKey(_ key: [UInt8]) {
        shared.lock.withLock { shared.recovered.removeAll { $0 == key } }
        recoveredKeys.removeAll { $0 == key }
        _ = store(keys.map(\.bytes) + [key])
    }

    /// Zusätzlichen Trust-Center-Link-Key hinzufügen (z. B. aus einem
    /// Install-Code). Der Standard-TCLK „ZigBeeAlliance09“ ist immer aktiv.
    @discardableResult
    func addLinkKey(_ text: String) -> String? {
        guard let key = ZigbeeSecurity.parseKey(text) else {
            return String(localized: "Kein gültiger Link-Key. Erwartet werden 32 Hex-Zeichen oder eine Liste mit 16 Zahlen.")
        }
        shared.lock.withLock {
            if !shared.linkKeys.contains(key) { shared.linkKeys.append(key) }
            reinterpret()
        }
        poll(force: true)
        return nil
    }

    @discardableResult
    func addThreadKey(_ text: String) -> String? {
        guard let key = ZigbeeSecurity.parseKey(text) else {
            return String(localized: "Kein gültiger Schlüssel. Erwartet werden 32 Hex-Zeichen (OpenThread „networkkey“) oder eine Liste mit 16 Zahlen.")
        }
        guard !threadKeys.contains(where: { $0.bytes == key }) else { return Self.duplicateKeyMessage }
        return storeThread(threadKeys.map(\.bytes) + [key])
    }

    func removeThreadKey(_ entry: ZigbeeKeyEntry) {
        storeThread(threadKeys.map(\.bytes).filter { $0 != entry.bytes })
    }

    @discardableResult
    private func storeThread(_ list: [[UInt8]]) -> String? {
        var message: String?
        let status = ThreadKeyStore.save(list)
        if status != errSecSuccess {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "Fehler \(Int(status))")
            message = String(localized: "Schlüsselbund: \(reason). Die Schlüssel gelten nur, bis du die App beendest.")
        }
        threadKeys = list.map { ZigbeeKeyEntry(bytes: $0) }
        shared.lock.withLock {
            shared.threadKeys = list.map { ZigbeeKeyEntry(bytes: $0) }
            reinterpret()
        }
        poll(force: true)
        return message
    }

    func clear() {
        shared.lock.withLock {
            shared.nodes = [:]
            shared.log = []
            shared.history = [:]
        }
        nodes = []
        log = []
    }

    // MARK: Geräteverzeichnis

    /// Messwert- und Pegelverlauf eines Geräts.
    func history(for key: ZigbeeNode.Key) -> [ZigbeeHistorySample] {
        shared.lock.withLock { shared.history[key] ?? [] }
    }

    func name(of node: ZigbeeNode) -> String? {
        node.ieee.flatMap { directory[$0]?.name }
    }

    func info(of node: ZigbeeNode) -> ZigbeeDeviceInfo? {
        node.ieee.flatMap { directory[$0] }
    }

    func setName(_ name: String, for node: ZigbeeNode) {
        guard let ieee = node.ieee else { return }
        var info = directory[ieee] ?? ZigbeeDeviceInfo()
        info.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        directory[ieee] = info
        ZigbeeDirectory.save(directory)
    }

    /// Zigbee2MQTT-Datei einlesen: Namen/Modelle, PAN, Kanal und – falls
    /// enthalten – den Netzwerkschlüssel. Liefert eine Zusammenfassung.
    func importZigbee2MQTT(_ text: String) -> String {
        let parsed = ZigbeeDirectory.parse(text)
        var parts: [String] = []
        if !parsed.devices.isEmpty {
            for (ieee, info) in parsed.devices {
                var merged = directory[ieee] ?? ZigbeeDeviceInfo()
                merged.name = info.name ?? merged.name
                merged.model = info.model ?? merged.model
                merged.manufacturer = info.manufacturer ?? merged.manufacturer
                merged.type = info.type ?? merged.type
                directory[ieee] = merged
            }
            ZigbeeDirectory.save(directory)
            let named = parsed.devices.values.filter { $0.name != nil }.count
            parts.append(named > 0 ? String(localized: "\(parsed.devices.count) Geräte (\(named) mit Namen)") : String(localized: "\(parsed.devices.count) Geräte"))
        }
        if let pan = parsed.panID {
            ownPAN = pan
            parts.append(String(format: "PAN 0x%04X", pan))
        }
        if let channel = parsed.channel, IEEE802154.channels.contains(channel) {
            setChannel(channel)
            parts.append(String(localized: "Kanal \(channel)"))
        }
        if let keyText = parsed.networkKeyText {
            let message = addKey(keyText)
            if let message {
                parts.append(message == Self.duplicateKeyMessage ? String(localized: "Schlüssel schon bekannt") : String(localized: "Schlüssel: \(message)"))
            } else {
                parts.append(String(localized: "Netzwerkschlüssel übernommen"))
            }
        }
        return parts.isEmpty
            ? String(localized: "Nichts Verwertbares gefunden. Wähle configuration.yaml, devices.yaml oder database.db aus Zigbee2MQTT.")
            : String(localized: "Importiert: \(parts.joined(separator: ", "))")
    }

    /// PANs, die als eigenes Netz gelten: aus der Konfiguration und alle, die
    /// ein hinterlegter Schlüssel entschlüsselt hat.
    var ownPANs: Set<UInt16> {
        var pans = Set(keys.flatMap { $0.pans })
        if let ownPAN { pans.insert(ownPAN) }
        return pans
    }

    /// Alle gepufferten Rahmen (bis 2000) als PCAP, Linktyp 802.15.4 mit FCS.
    func pcap() -> Data {
        let frames = shared.lock.withLock { shared.log.map(\.radio) }
        return ZigbeePCAP.data(frames)
    }
}

/// Netzwerkschlüssel im Anmelde-Schlüsselbund (nicht in den Einstellungen):
/// JSON-Liste aus Hex-Strings; ein älterer Eintrag mit 16 Rohbytes wird gelesen.
enum ZigbeeKeyStore {
    private static let service = "de.christiangolz.portapackmanager.zigbee"
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
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            return list.compactMap { ZigbeeSecurity.parseKey($0) }
        }
        return data.count == 16 ? [[UInt8](data)] : []
    }

    @discardableResult
    static func save(_ keys: [[UInt8]]) -> OSStatus {
        guard !keys.isEmpty else { delete(); return errSecSuccess }
        let list = keys.map { $0.map { String(format: "%02X", $0) }.joined() }
        guard let data = try? JSONEncoder().encode(list) else { return errSecParam }
        return KeychainBlob.save(data, query: query)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
