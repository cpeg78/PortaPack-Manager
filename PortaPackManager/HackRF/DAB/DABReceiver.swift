import Foundation

/// Die ganze DAB-Kette für einen Kanal: Eingangsstufe → OFDM → FIC
/// (Ensemble) → gewählter Unterkanal → DAB+-Superframe bzw. MP2-Rahmen →
/// Audio (48 kHz Stereo) und Lauftext.
///
/// Nicht threadsicher: alle Aufrufe aus derselben (seriellen) Warteschlange.
final class DABReceiver: @unchecked Sendable {
    struct Status: Sendable, Equatable {
        var synchronized = false
        var snr: Double = 0
        var frequencyOffset: Double = 0
        /// Anteil gültiger FIBs (0…1) seit dem letzten Abruf.
        var ficQuality: Double = 0
        var ensemble = DABEnsemble()
        var format: String = ""
        var accessUnitsGood = 0
        var accessUnitsBad = 0
        var dynamicLabel = ""
        var framesDecoded = 0
        var failedSearches = 0
        var audioErrors = 0
    }

    /// Bekommt die dekodierten Audiowerte (48 kHz, links/rechts).
    var audioHandler: (@Sendable ([Float], [Float]) -> Void)?

    private let frontEnd = DABFrontEnd()
    private let ofdm = DABOFDMDemodulator()
    private let fic = DABFICDecoder()
    private(set) var ensemble = DABEnsemble()

    private var selectedServiceID: UInt32?
    private var subchannelDecoder: DABSubchannelDecoder?
    private let superframe = DABPlusSuperframeDecoder()
    private var audioDecoder: DABAudioDecoder?
    private let pad = DABPADDecoder()
    private var mp2Buffer: [UInt8] = []
    private var mp2Errors = 0

    /// Neuer Kanal: alles vergessen (die Frequenzablage bleibt als Startwert).
    func reset() {
        frontEnd.reset()
        ofdm.reset()
        fic.resetStatistics()
        ensemble = DABEnsemble()
        stopService()
    }

    /// Wählt einen Dienst (oder `nil` für „nur Ensemble lesen“).
    func select(serviceID: UInt32?) {
        stopService()
        selectedServiceID = serviceID
        prepareService()
    }

    private func stopService() {
        subchannelDecoder = nil
        audioDecoder = nil
        superframe.reset()
        superframe.resetStatistics()
        pad.reset()
        mp2Buffer = []
        mp2Errors = 0
    }

    /// Richtet den Unterkanal-Dekoder ein, sobald das Ensemble ihn kennt.
    private func prepareService() {
        guard subchannelDecoder == nil, let id = selectedServiceID, let service = ensemble.services[id],
              let subchannel = ensemble.subchannel(for: service) else { return }
        subchannelDecoder = DABSubchannelDecoder(subchannel: subchannel)
    }

    // MARK: - Verarbeitung

    /// Verarbeitet einen IQ-Block vom HackRF (8,192 MS/s, int8).
    func process(_ iq: Data) {
        let (re, im) = frontEnd.process(iq)
        process(re: re, im: im)
    }

    /// Verarbeitet bereits dezimierte Abtastwerte (2,048 MS/s).
    func process(re: [Float], im: [Float]) {
        for frame in ofdm.process(re: re, im: im) {
            for fib in fic.decode(frame.fic) { ensemble.process(fib: fib) }
            prepareService()
            if let subchannelDecoder, let service = selectedServiceID.flatMap({ ensemble.services[$0] }) {
                // Unterkanal hat sich geändert (Rekonfiguration) → neu einrichten.
                if let current = ensemble.subchannel(for: service), current != subchannelDecoder.subchannel {
                    stopService()
                    prepareService()
                    continue
                }
                for logical in subchannelDecoder.process(msc: frame.msc) {
                    switch service.kind {
                    case .dabPlus: handleDABPlus(logical)
                    case .dab: handleMP2(logical)
                    case .data: break
                    }
                }
            }
        }
    }

    private func handleDABPlus(_ logical: [UInt8]) {
        let before = superframe.superframes
        let units = superframe.process(logicalFrame: logical)
        // Fehlerhafte AUs durch Stille gleicher Dauer ersetzen (ein Superframe
        // = 120 ms), damit die Wiedergabe nicht neu puffern muss.
        if superframe.superframes > before, let format = superframe.format, audioDecoder != nil {
            let missing = format.accessUnits - units.count
            if missing > 0 {
                let silence = [Float](repeating: 0, count: missing * 5760 / format.accessUnits)
                audioHandler?(silence, silence)
            }
        }
        for unit in units {
            if let format = superframe.format {
                if case let .aac(current)? = audioDecoder?.codec, current == format {} else {
                    audioDecoder = try? DABAudioDecoder(codec: .aac(format))
                }
            }
            if let bytes = DABPlusSuperframeDecoder.pad(in: unit.data) {
                pad.process(pad: bytes, exactLength: true)
            }
            if let audioDecoder {
                let (left, right) = audioDecoder.decode(unit.data)
                if !left.isEmpty { audioHandler?(left, right) }
            }
        }
    }

    // MARK: - DAB (MPEG-1/2 Layer II)

    struct MP2Header: Equatable, Sendable {
        var sampleRate: Int
        var bitrate: Int
        var channels: Int
        var mpeg1: Bool
        var frameLength: Int

        init?(_ b: ArraySlice<UInt8>) {
            guard b.count >= 4 else { return nil }
            let s = b.startIndex
            guard b[s] == 0xFF, b[s + 1] & 0xF0 == 0xF0, (b[s + 1] >> 1) & 0x03 == 0x02 else { return nil }
            mpeg1 = b[s + 1] & 0x08 != 0
            let bitrateIndex = Int(b[s + 2] >> 4)
            let rateIndex = Int(b[s + 2] >> 2 & 0x03)
            guard bitrateIndex > 0, bitrateIndex < 15, rateIndex < 3 else { return nil }
            let rates = mpeg1 ? [44_100, 48_000, 32_000] : [22_050, 24_000, 16_000]
            let bitrates = mpeg1
                ? [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
                : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
            sampleRate = rates[rateIndex]
            bitrate = bitrates[bitrateIndex]
            channels = b[s + 3] >> 6 == 3 ? 1 : 2
            let padding = Int(b[s + 2] >> 1 & 0x01)
            frameLength = 144_000 * bitrate / sampleRate + padding
        }
    }

    private func handleMP2(_ logical: [UInt8]) {
        mp2Buffer += logical
        while mp2Buffer.count >= 4 {
            guard let header = MP2Header(mp2Buffer[...]) else {
                // Neu aufsetzen: nächstes Synchronwort suchen.
                if let next = (1..<(mp2Buffer.count - 1)).first(where: { mp2Buffer[$0] == 0xFF && mp2Buffer[$0 + 1] & 0xF0 == 0xF0 }) {
                    mp2Buffer.removeFirst(next)
                } else {
                    mp2Buffer = []
                }
                continue
            }
            guard mp2Buffer.count >= header.frameLength else { return }
            let frame = Array(mp2Buffer.prefix(header.frameLength))
            mp2Buffer.removeFirst(header.frameLength)
            if case let .mp2(rate, channels)? = audioDecoder?.codec, rate == header.sampleRate, channels == header.channels {} else {
                audioDecoder = try? DABAudioDecoder(codec: .mp2(sampleRate: header.sampleRate, channels: header.channels))
            }
            // PAD am Rahmenende: … X-PAD | ScF-CRC | F-PAD (2 Bytes)
            let scfCRC = header.mpeg1 && header.bitrate < (header.channels == 1 ? 56 : 112) ? 2 : 4
            if frame.count > 2 + scfCRC + 4 {
                let xpadEnd = frame.count - 2 - scfCRC
                pad.process(pad: Array(frame[4..<xpadEnd]) + frame.suffix(2), exactLength: false)
            }
            if let audioDecoder {
                let (left, right) = audioDecoder.decode(frame)
                if left.isEmpty { mp2Errors += 1 } else { audioHandler?(left, right) }
            }
        }
    }

    // MARK: - Zustand

    /// Momentaufnahme für die Anzeige; setzt die FIC-Statistik zurück.
    func status() -> Status {
        var status = Status()
        status.synchronized = ofdm.state == .locked
        status.snr = ofdm.snr
        status.frequencyOffset = ofdm.frequencyOffset
        status.ficQuality = fic.fibsTotal > 0 ? Double(fic.fibsGood) / Double(fic.fibsTotal) : 0
        fic.resetStatistics()
        status.ensemble = ensemble
        if let format = superframe.format {
            status.format = "\(format.codecName) · \(format.channelName) · \(format.outputRate / 1000) kHz"
        } else if case let .mp2(rate, channels)? = audioDecoder?.codec {
            status.format = "MP2 · \(channels == 1 ? "Mono" : "Stereo") · \(rate / 1000) kHz"
        }
        status.accessUnitsGood = superframe.accessUnitsGood
        status.accessUnitsBad = superframe.accessUnitsBad
        status.dynamicLabel = pad.dynamicLabel
        status.framesDecoded = ofdm.framesDecoded
        status.failedSearches = ofdm.failedSearches
        status.audioErrors = (audioDecoder?.errors ?? 0) + mp2Errors
        return status
    }
}
