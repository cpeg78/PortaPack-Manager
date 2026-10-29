import Foundation

// Offline-Auswertung von IQ-Aufnahmen mit den Empfängern der Live-Seiten.
// Die Aufnahme muss mit Rate und Mitte des jeweiligen Modells entstanden sein
// (Vorlagen „DVB-T2-Kanal“ und „DAB-Block“ auf der Aufnahmeseite).

/// Aufnahmevorgaben, genau wie `TVModel.start` bzw. `DABModel.start` den HackRF einstellen.
enum IQPreset {
    /// DVB-T2: 2·64/7 MS/s, HackRF fs/4 über der Kanalmitte, Basisbandfilter 20 MHz.
    static let tvSampleRate = UInt32(T2FrontEnd.inputRate.rounded())
    static let tvBasebandFilter: UInt32 = 20_000_000
    static func tvCenter(_ channel: TVChannel) -> UInt64 { channel.frequency + UInt64(T2FrontEnd.tuningOffset) }

    /// Fernsehkanal zu einer Aufnahmemitte (nil, wenn keiner passt).
    static func tvChannel(center: UInt64, tolerance: Double = 100_000) -> TVChannel? {
        TVChannel.uhf.first { abs(Double(tvCenter($0)) - Double(center)) <= tolerance }
    }

    /// DAB: 8,192 MS/s, HackRF auf der Blockmitte.
    static let dabSampleRate = DABFrontEnd.inputRate
    static func dabChannel(center: UInt64, tolerance: Double = 20_000) -> DABChannel? {
        DABChannel.bandIII.first { abs(Double($0.frequency) - Double(center)) <= tolerance }
    }

    /// Zigbee/Thread: 8 MS/s, HackRF 2 MHz unter dem Kanal (wie `ZigbeeModel`).
    static let zigbeeSampleRate = UInt32(ZigbeeDemodulator.inputRate)
    static func zigbeeCenter(channel: Int) -> UInt64 {
        UInt64(IEEE802154.frequencyMHz(channel: channel) * 1_000_000 - ZigbeeDemodulator.offset)
    }
    static func zigbeeChannel(center: UInt64, tolerance: Double = 20_000) -> Int? {
        IEEE802154.channels.first { abs(Double(zigbeeCenter(channel: $0)) - Double(center)) <= tolerance }
    }
}

/// Ergebnis einer offline ausgewerteten Zigbee-/Thread-Aufnahme.
struct ZigbeeOfflineResult: Sendable, Equatable {
    struct Line: Identifiable, Sendable, Equatable {
        let id: Int
        let time: Double
        let from: String
        let to: String
        let encrypted: Bool
        let summary: String
    }

    var channel: Int?
    var frames = 0
    var crcErrors = 0
    var decrypted = 0
    var threadFrames = 0
    var nodes: [ZigbeeNode] = []
    var lines: [Line] = []

    static func == (a: ZigbeeOfflineResult, b: ZigbeeOfflineResult) -> Bool {
        a.frames == b.frames && a.decrypted == b.decrypted && a.lines.count == b.lines.count
    }
}

/// Zigbee-/Thread-Dekoder für Aufnahmen – derselbe Demodulator und dieselben
/// Schlüssel (Schlüsselbund) wie die Live-Seite, Zeit aus der Abtastposition.
final class ZigbeeOfflineDecoder: @unchecked Sendable {
    private let demod = ZigbeeDemodulator()
    private let keys = ZigbeeKeyStore.load()
    private let threadKeys = ThreadKeyStore.load()
    private var threadAddresses: [UInt16: UInt64] = [:]
    private let channel: Int
    private var samples = 0
    private var count = 0
    private var decrypted = 0
    private var thread = 0
    private var nodes: [ZigbeeNode.Key: ZigbeeNode] = [:]
    private var lines: [ZigbeeOfflineResult.Line] = []

    init(channel: Int?) { self.channel = channel ?? 11 }

    func process(_ block: Data) {
        let frames = demod.process(block, channel: channel)
        let blockStart = samples
        samples += block.count / 2
        for frame in frames {
            count += 1
            let packet = ZigbeePacket.interpret(frame, id: count, keys: keys, threadKeys: threadKeys, threadAddresses: threadAddresses)
            if let learned = packet.thread?.learned { threadAddresses[learned.short] = learned.extended }
            if packet.thread != nil { thread += 1 }
            if packet.decrypted != nil { decrypted += 1 }
            if let mac = packet.mac, let pan = mac.pan, case let .short(address)? = mac.source {
                let key = ZigbeeNode.Key(pan: pan, address: address)
                var node = nodes[key] ?? ZigbeeNode(key: key, channel: channel, lastSeen: frame.date)
                node.heard += 1
                node.thread = node.thread || packet.thread != nil
                node.rssiDB = node.rssiDB.map { 0.7 * $0 + 0.3 * frame.rssiDB } ?? frame.rssiDB
                node.lastSummary = packet.summary
                if let zcl = packet.zcl, let cluster = packet.aps?.cluster, !zcl.readings.isEmpty {
                    node.apply(readings: zcl.readings, cluster: cluster)
                }
                node.ieee = packet.nwk?.sourceIEEE ?? packet.nwk?.securityHeader?.source ?? node.ieee
                nodes[key] = node
            }
            if lines.count < 2000 {
                lines.append(.init(id: count, time: Double(blockStart) / ZigbeeDemodulator.inputRate,
                                   from: Self.address(packet.nwk?.source, mac: packet.mac?.source),
                                   to: Self.address(packet.nwk?.destination, mac: packet.mac?.destination),
                                   encrypted: packet.encrypted, summary: packet.summary))
            }
        }
    }

    func result() -> ZigbeeOfflineResult {
        ZigbeeOfflineResult(channel: channel, frames: count, crcErrors: demod.crcErrors, decrypted: decrypted,
                            threadFrames: thread, nodes: nodes.values.sorted { $0.heard > $1.heard }, lines: lines)
    }

    private static func address(_ nwk: UInt16?, mac: MACAddress?) -> String {
        if let nwk { return nwk >= 0xFFF8 ? String(localized: "alle", comment: "Rundruf an alle Geräte") : String(format: "0x%04X", nwk) }
        return mac.map { $0 == .short(0xFFFF) ? String(localized: "alle", comment: "Rundruf an alle Geräte") : $0.description } ?? "–"
    }
}

/// Ergebnis einer offline dekodierten DVB-T2-Aufnahme.
struct TVOfflineResult: Sendable, Equatable {
    var channel: TVChannel?
    var status: T2Receiver.Status
    var services: [TSService]
    var networkName: String

    /// Betriebsart wie in der Senderliste („16K erw. · 19/128 · PP2“).
    var modeDescription: String {
        var parts: [String] = []
        if let fft = status.fft { parts.append(status.extended ? String(localized: "\(fft.name) erw.") : fft.name) }
        if let gi = status.guardInterval { parts.append(gi.name) }
        if let pp = status.pattern { parts.append(pp.name) }
        return parts.joined(separator: " · ")
    }

    var plp: T2PLP? { status.post?.plps.first { $0.id == status.plpID } }

    var plpDescription: String? {
        guard let plp else { return nil }
        let fec = plp.fec.map { $0.normal ? "64K" : "16K" } ?? "?"
        return "PLP \(plp.id): \(plp.constellation?.name ?? "?") \(T2CodeRate(rawValue: plp.codeRate)?.name ?? "?") · \(fec)-LDPC · " + String(localized: "\(plp.blocks) Blöcke je Rahmen")
    }

    var requiredSNR: Double? { plp.flatMap { T2Threshold.requiredSNR(modulation: $0.modulation, codeRate: $0.codeRate) } }
}

/// DVB-T2-Empfänger plus Transportstrom-Demultiplexer für Aufnahmen.
final class TVOfflineDecoder: @unchecked Sendable {
    private let receiver = T2Receiver()
    private let demux = TSDemuxer()

    init() {
        receiver.packetHandler = { [demux] packet in demux.process(packet) }
    }

    func process(_ block: Data) { receiver.process(block) }

    func result(channel: TVChannel?) -> TVOfflineResult {
        TVOfflineResult(channel: channel, status: receiver.currentStatus(),
                        services: demux.services.values.sorted { $0.id < $1.id }, networkName: demux.networkName)
    }
}

/// Ergebnis einer offline dekodierten DAB-Aufnahme.
struct DABOfflineResult: Sendable, Equatable {
    var channel: DABChannel?
    var status: DABReceiver.Status
    var services: [DABStoredEnsemble.Service]
}

/// DAB-Empfänger für Aufnahmen: liest nur das Ensemble (kein Ton).
final class DABOfflineDecoder: @unchecked Sendable {
    private let receiver = DABReceiver()

    init() { receiver.select(serviceID: nil) }

    func process(_ block: Data) { receiver.process(block) }
    /// Bereits dezimierte Abtastwerte (2,048 MS/s) – für Tests.
    func process(re: [Float], im: [Float]) { receiver.process(re: re, im: im) }

    func result(channel: DABChannel?) -> DABOfflineResult {
        let status = receiver.status()
        let services = DABStoredEnsemble(channel: channel?.name ?? "", ensemble: status.ensemble, snr: status.snr).services
        return DABOfflineResult(channel: channel, status: status, services: services)
    }
}
