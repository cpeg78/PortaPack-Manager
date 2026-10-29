import Foundation

/// Audioformat eines DAB+-Dienstes (Kopf des Superframes, TS 102 563 §5.2).
struct DABPlusFormat: Equatable, Sendable {
    /// 48 kHz statt 32 kHz Ausgaberate.
    var dacRate48: Bool
    /// SBR (HE-AAC).
    var sbr: Bool
    /// Stereo im AAC-Kern.
    var stereo: Bool
    /// Parametric Stereo (HE-AAC v2).
    var parametricStereo: Bool

    init(byte: UInt8) {
        dacRate48 = byte & 0x40 != 0
        sbr = byte & 0x20 != 0
        stereo = byte & 0x10 != 0
        parametricStereo = byte & 0x08 != 0
    }

    var accessUnits: Int { dacRate48 ? (sbr ? 3 : 6) : (sbr ? 2 : 4) }
    var firstAccessUnitStart: Int { dacRate48 ? (sbr ? 6 : 11) : (sbr ? 5 : 8) }
    /// Ausgaberate in Hz.
    var outputRate: Int { dacRate48 ? 48_000 : 32_000 }
    /// Abtastrate des AAC-Kerns.
    var coreRate: Int { sbr ? outputRate / 2 : outputRate }

    var codecName: String { sbr ? (parametricStereo ? "HE-AAC v2" : "HE-AAC") : "AAC-LC" }
    var channelName: String { stereo || parametricStereo ? "Stereo" : "Mono" }
}

/// Setzt fünf Logikrahmen zum Superframe zusammen, korrigiert mit
/// RS(120,110), prüft den Firecode und zerlegt in Access Units (AAC-Rahmen).
final class DABPlusSuperframeDecoder: @unchecked Sendable {
    struct AccessUnit: Sendable {
        var data: [UInt8]
    }

    private(set) var format: DABPlusFormat?
    private(set) var superframes = 0
    private(set) var accessUnitsGood = 0
    private(set) var accessUnitsBad = 0
    private(set) var rsCorrected = 0
    private(set) var rsFailed = 0
    private(set) var synchronized = false

    private var frames: [[UInt8]] = []

    func reset() {
        frames = []
        format = nil
        synchronized = false
    }

    /// Nimmt einen Logikrahmen; liefert die AUs, sobald ein Superframe fertig ist.
    func process(logicalFrame: [UInt8]) -> [AccessUnit] {
        if let first = frames.first, first.count != logicalFrame.count { frames = [] }
        frames.append(logicalFrame)
        if frames.count > 5 { frames.removeFirst() }
        guard frames.count == 5 else { return [] }

        var superframe = frames.flatMap { $0 }
        correct(&superframe)
        guard let units = split(superframe) else {
            // Nicht synchron: beim nächsten Rahmen um eins verschoben versuchen.
            synchronized = false
            return []
        }
        synchronized = true
        superframes += 1
        frames = []
        return units
    }

    /// RS-Korrektur, Codewörter verschränkt mit Abstand s = Länge / 120.
    private func correct(_ superframe: inout [UInt8]) {
        let s = superframe.count / DABReedSolomon.n
        for j in 0..<s {
            var codeword = (0..<DABReedSolomon.n).map { superframe[j + $0 * s] }
            if let count = DABReedSolomon.decode(&codeword) {
                if count > 0 {
                    rsCorrected += count
                    for k in 0..<DABReedSolomon.n { superframe[j + k * s] = codeword[k] }
                }
            } else {
                rsFailed += 1
            }
        }
    }

    /// Firecode prüfen und Access Units ausschneiden.
    func split(_ sf: [UInt8]) -> [AccessUnit]? {
        guard sf.count >= 120, !(sf[3] == 0 && sf[4] == 0) else { return nil }
        let stored = UInt16(sf[0]) << 8 | UInt16(sf[1])
        guard DABCRC.fire(sf[2..<11]) == stored else { return nil }

        let format = DABPlusFormat(byte: sf[2])
        let count = format.accessUnits
        var starts = [Int](repeating: 0, count: count + 1)
        starts[0] = format.firstAccessUnitStart
        starts[count] = sf.count / 120 * 110
        let a = sf.map(Int.init)
        if count >= 2 { starts[1] = a[3] << 4 | a[4] >> 4 }
        if count >= 3 { starts[2] = (a[4] & 0x0F) << 8 | a[5] }
        if count >= 4 { starts[3] = a[6] << 4 | a[7] >> 4 }
        if count == 6 {
            starts[4] = (a[7] & 0x0F) << 8 | a[8]
            starts[5] = a[9] << 4 | a[10] >> 4
        }
        for i in 0..<count where starts[i] >= starts[i + 1] { return nil }
        self.format = format

        var units: [AccessUnit] = []
        for i in 0..<count {
            let unit = sf[starts[i]..<starts[i + 1]]
            guard unit.count > 2 else { accessUnitsBad += 1; continue }
            let body = unit.dropLast(2)
            let crc = UInt16(unit[unit.endIndex - 2]) << 8 | UInt16(unit[unit.endIndex - 1])
            if DABCRC.ccitt(body) == crc {
                accessUnitsGood += 1
                units.append(AccessUnit(data: Array(body)))
            } else {
                accessUnitsBad += 1
            }
        }
        return units
    }

    func resetStatistics() {
        accessUnitsGood = 0
        accessUnitsBad = 0
        rsCorrected = 0
        rsFailed = 0
        superframes = 0
    }

    /// PAD aus einem Data Stream Element am AU-Anfang (falls vorhanden).
    static func pad(in unit: [UInt8]) -> [UInt8]? {
        guard unit.count >= 3, unit[0] >> 5 == 4 else { return nil }
        var start = 2
        var length = Int(unit[1])
        if length == 255 {
            length += Int(unit[2])
            start += 1
        }
        guard length >= 2, unit.count >= start + length else { return nil }
        return Array(unit[start..<(start + length)])
    }
}
