import Foundation

/// Betriebsart des LRPT-Senders.
enum MeteorSignal: String, CaseIterable, Identifiable, Sendable {
    /// METEOR-M2-3 und M2-4 (Stand 2026): OQPSK 72 kSym/s, NRZ-M.
    case oqpsk72
    /// Alte METEOR-M2 (LRPT seit Ende 2022 aus): QPSK 72 kSym/s.
    case qpsk72

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oqpsk72: "M2-3/M2-4 (OQPSK 72k)"
        case .qpsk72: String(localized: "Alt: M2 (QPSK 72k)")
        }
    }

    var modulation: MeteorDemodulator.Modulation { self == .qpsk72 ? .qpsk : .oqpsk }
    var symbolRate: Double { 72_000 }
}

/// Die ganze Kette vom IQ-Block bis zum Bild. Wird vom Empfangsthread
/// gefüttert; die Oberfläche holt Schnappschüsse ab (alles unter `lock`).
final class MeteorReceiver: @unchecked Sendable {
    /// HackRF-Einstellung: Mitte zwischen beiden Frequenzen, beide im Band.
    static let sampleRate: UInt32 = 2_880_000
    static let centerFrequency: UInt64 = 137_500_000
    static let frequencies: [Double] = [137_900_000, 137_100_000]

    struct Snapshot: Sendable {
        var locked = false
        var lockQuality: Float = 0
        var frequencyOffset: Double = 0
        var levelDB: Float = -100
        var constellation: [(Float, Float)] = []
        var frame = MeteorFrameDecoder.Statistics()
        var packets = 0
        var lostFrames = 0
        var segments: [Int: Int] = [:]
        var lines = 0
        var spacecraftID: Int?
        var symbols = 0
    }

    private let lock = NSLock()
    private var demodulator: MeteorDemodulator
    private let decoder = MeteorFrameDecoder()
    private let demux = MeteorPacketDemux()
    private var assembler = MeteorImageAssembler()
    private var spacecraftID: Int?
    private var symbols = 0
    private var imageVersion = 0

    init(inputRate: Double = Double(MeteorReceiver.sampleRate), offset: Double, signal: MeteorSignal) {
        demodulator = MeteorDemodulator(inputRate: inputRate, offset: offset,
                                        symbolRate: signal.symbolRate, modulation: signal.modulation)
    }

    /// Neu einstellen (Frequenz, Betriebsart, Abtastrate); das Bild bleibt.
    func configure(inputRate: Double, offset: Double, signal: MeteorSignal) {
        lock.withLock {
            demodulator = MeteorDemodulator(inputRate: inputRate, offset: offset,
                                            symbolRate: signal.symbolRate, modulation: signal.modulation)
            decoder.reset()
            demux.reset()
        }
    }

    func clearImage() {
        lock.withLock {
            assembler = MeteorImageAssembler()
            imageVersion += 1
        }
    }

    func process(_ block: Data) {
        lock.withLock {
            let soft = demodulator.process(block)
            ingest(soft)
        }
    }

    /// Weiche Symbole direkt (Tests, `.s`-Dateien).
    func processSoft(_ soft: [Int8]) {
        lock.withLock { ingest(soft) }
    }

    /// Fertige VCDUs (Tests, `.cadu`-Dateien nach dem RS).
    func processVCDU(_ vcdu: [UInt8]) {
        lock.withLock { handle(vcdu) }
    }

    private func ingest(_ soft: [Int8]) {
        symbols += soft.count / 2
        for vcdu in decoder.process(soft) { handle(vcdu) }
    }

    private func handle(_ vcdu: [UInt8]) {
        if let header = MeteorVCDU(vcdu), header.virtualChannel == MeteorPacketDemux.imageChannel {
            spacecraftID = header.spacecraftID
        }
        let packets = demux.process(vcdu)
        for packet in packets { assembler.add(packet) }
        if packets.contains(where: { MeteorImageAssembler.apids.contains($0.apid) }) { imageVersion += 1 }
    }

    var snapshot: Snapshot {
        lock.withLock {
            var s = Snapshot()
            s.locked = demodulator.locked
            s.lockQuality = demodulator.lockQuality
            s.frequencyOffset = demodulator.frequencyOffset
            s.levelDB = demodulator.levelDB
            s.constellation = demodulator.constellation
            s.frame = decoder.statistics
            s.packets = demux.packetCount
            s.lostFrames = demux.lostFrames
            for c in assembler.channelNumbers { s.segments[c] = assembler.segmentCount(channel: c) }
            s.lines = assembler.lineCount
            s.spacecraftID = spacecraftID
            s.symbols = symbols
            return s
        }
    }

    /// Bild nur bei Änderungen: (Version, Kopie des Sammlers).
    func image(after version: Int) -> (Int, MeteorImageAssembler)? {
        lock.withLock {
            guard imageVersion != version else { return nil }
            return (imageVersion, assembler)
        }
    }

    var currentImage: MeteorImageAssembler { lock.withLock { assembler } }
}
