import Foundation

/// Graw DFM-09/DFM-17: FSK, Manchester mit 2500 Bd (5000 Halbbits/s).
/// Rahmen zu 280 Bit: Kopf 0x45CF, Konfiguration (7 Hamming-Wörter),
/// zwei Datenblöcke (je 13 Wörter), jeweils verschränkt. Aufbau nach
/// rs1729/RS (`dfm09mod.c`); ausgewertet werden Position, Geschwindigkeit,
/// Zeit und Seriennummer, keine Messwerte.
final class DFMDecoder {
    static let chipRate = 5000.0
    static let frameBits = 280
    static let headerBits = 16
    /// Kopf als Halbbits: „10“ = 0, „01“ = 1.
    static let rawHeader: [UInt8] = Array("10011010100110010101101001010101").map { $0 == "1" ? 1 : 0 }

    static let hammingH: [[UInt8]] = [
        [0, 1, 1, 1, 1, 0, 0, 0],
        [1, 0, 1, 1, 0, 1, 0, 0],
        [1, 1, 0, 1, 0, 0, 1, 0],
        [1, 1, 1, 0, 0, 0, 0, 1],
    ]
    static let hammingG: [[UInt8]] = [
        [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1],
        [0, 1, 1, 1], [1, 0, 1, 1], [1, 1, 0, 1], [1, 1, 1, 0],
    ]
    /// Spalten von H als Syndromwert – Lage eines einzelnen Bitfehlers.
    static let syndromeColumns: [Int] = [0x7, 0xB, 0xD, 0xE, 0x8, 0x4, 0x2, 0x1]

    private var history: [UInt8] = []
    private var collecting: [UInt8]?
    private var inverted = false

    // Zustand über mehrere Rahmen
    private var positionMode = 2
    private var serialHalves: [Int: Int] = [:]
    private var serialChannel = 0
    private(set) var serial: String?
    private var model = "DFM"
    private var latitude: Double?, longitude: Double?, altitude: Double?
    private var groundSpeed: Double?, heading: Double?, verticalSpeed: Double?
    private var frameNumber: Int?
    private var seconds: Double?
    private var dateParts: (year: Int, month: Int, day: Int, hour: Int, minute: Int)?
    private var satellites: Int?
    private var updated: Set<String> = []

    /// Nimmt harte Halbbits (0/1) auf und liefert fertige Meldungen.
    func process(chips: [UInt8]) -> [SondeReport] {
        var reports: [SondeReport] = []
        let header = Self.rawHeader
        let needed = (Self.frameBits - Self.headerBits) * 2
        for chip in chips {
            if collecting != nil {
                collecting!.append(inverted ? chip ^ 1 : chip)
                if collecting!.count == needed {
                    if let report = handleFrame(collecting!) { reports.append(report) }
                    collecting = nil
                }
                continue
            }
            history.append(chip)
            if history.count > header.count { history.removeFirst(history.count - header.count) }
            guard history.count == header.count else { continue }
            var errors = 0, invErrors = 0
            for i in 0..<header.count {
                if history[i] != header[i] { errors += 1 } else { invErrors += 1 }
            }
            if errors <= 2 || invErrors <= 2 {
                inverted = invErrors <= 2
                collecting = []
                collecting!.reserveCapacity(needed)
                history.removeAll(keepingCapacity: true)
            }
        }
        return reports
    }

    // MARK: Rahmen

    private func handleFrame(_ chips: [UInt8]) -> SondeReport? {
        // Manchester: Paar „10“ → 0, „01“ → 1; ungültige Paare nach dem ersten Halbbit.
        var bits = [UInt8](repeating: 0, count: chips.count / 2)
        for i in bits.indices { bits[i] = chips[2 * i] == 1 ? 0 : 1 }
        guard let conf = Self.decodeBlock(Array(bits[0..<56]), words: 7),
              let dat1 = Self.decodeBlock(Array(bits[56..<160]), words: 13),
              let dat2 = Self.decodeBlock(Array(bits[160..<264]), words: 13) else {
            return nil
        }
        handleConfiguration(conf)
        handleData(dat1)
        handleData(dat2)
        // Eine Meldung, sobald eine neue Position komplett ist.
        guard updated.contains("lat"), updated.contains("lon"), updated.contains("alt"),
              let latitude, let longitude, let altitude,
              abs(latitude) <= 90, abs(longitude) <= 180, altitude > -1000, altitude < 50_000 else { return nil }
        updated.removeAll()
        var report = SondeReport(kind: .dfm, serial: serial ?? "", model: model)
        report.frame = frameNumber
        report.latitude = latitude
        report.longitude = longitude
        report.altitude = altitude
        report.groundSpeed = groundSpeed
        report.heading = heading
        report.verticalSpeed = verticalSpeed
        report.satellites = satellites
        if let d = dateParts, let seconds, d.year > 2000 {
            var components = DateComponents(timeZone: TimeZone(identifier: "UTC"), year: d.year, month: d.month, day: d.day,
                                            hour: d.hour, minute: d.minute)
            components.nanosecond = 0
            report.gpsTime = Calendar(identifier: .gregorian).date(from: components)?.addingTimeInterval(seconds)
        }
        return report
    }

    /// Entschachtelt und prüft Hamming(8,4); liefert die Datenbits
    /// (4 je Wort) oder `nil` bei nicht korrigierbaren Wörtern.
    static func decodeBlock(_ bits: [UInt8], words: Int) -> [UInt8]? {
        var block = [UInt8](repeating: 0, count: bits.count)
        for j in 0..<8 {
            for i in 0..<words { block[8 * i + j] = bits[words * j + i] }
        }
        var data: [UInt8] = []
        data.reserveCapacity(words * 4)
        for i in 0..<words {
            var code = Array(block[(8 * i)..<(8 * i + 8)])
            var syndrome = 0
            for row in 0..<4 {
                var s: UInt8 = 0
                for j in 0..<8 { s ^= hammingH[row][j] & code[j] }
                syndrome = syndrome << 1 | Int(s)
            }
            if syndrome != 0 {
                guard let position = syndromeColumns.firstIndex(of: syndrome) else { return nil }
                code[position] ^= 1
            }
            data.append(contentsOf: code[0..<4])
        }
        return data
    }

    static func encodeBlock(_ data: [UInt8], words: Int) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: words * 8)
        for i in 0..<words {
            for row in 0..<8 {
                var bit: UInt8 = 0
                for k in 0..<4 { bit ^= hammingG[row][k] & data[4 * i + k] }
                block[8 * i + row] = bit
            }
        }
        var bits = [UInt8](repeating: 0, count: words * 8)
        for j in 0..<8 {
            for i in 0..<words { bits[words * j + i] = block[8 * i + j] }
        }
        return bits
    }

    static func value(_ bits: [UInt8], _ start: Int, _ length: Int) -> Int {
        var v = 0
        for i in 0..<length { v = v << 1 | Int(bits[start + i]) }
        return v
    }

    private func handleConfiguration(_ bits: [UInt8]) {
        let id = Self.value(bits, 0, 4)
        let kind = Self.value(bits, 4, 4)
        // Seriennummer in zwei Hälften: Kanal ≥ 6, zweites Nibble 0xC,
        // die letzten 4 Bit nennen die Hälfte (0/1).
        guard id >= 6, kind == 0xC else { return }
        let value = Self.value(bits, 8, 20)
        let half = value & 0xF
        guard half < 2 else { return }
        if id != serialChannel { serialHalves = [:]; serialChannel = id }
        serialHalves[half] = (value >> 4) & 0xFFFF
        if let high = serialHalves[0], let low = serialHalves[1] {
            serial = String(high << 16 | low)
            model = switch id {
            case 0xA: "DFM-09"
            case 0xB, 0xD: "DFM-17"
            default: "DFM-09/17"
            }
        }
    }

    private func handleData(_ bits: [UInt8]) {
        let id = Self.value(bits, 48, 4)
        func s16(_ start: Int) -> Int { Int(Int16(truncatingIfNeeded: Self.value(bits, start, 16))) }
        func s32(_ start: Int) -> Int { Int(Int32(truncatingIfNeeded: Self.value(bits, start, 32))) }
        if id == 0 {
            let mode = Self.value(bits, 16, 8)
            if (2...4).contains(mode) { positionMode = mode }
        }
        if id == 8 {
            dateParts = (Self.value(bits, 0, 12), Self.value(bits, 12, 4), Self.value(bits, 16, 5),
                         Self.value(bits, 21, 5), Self.value(bits, 26, 6))
            satellites = Self.value(bits, 32, 8)
            return
        }
        if positionMode <= 2 {
            switch id {
            case 0: frameNumber = Self.value(bits, 24, 8)
            case 1: seconds = Double(Self.value(bits, 32, 16)) / 1000
            case 2: latitude = Double(s32(0)) / 1e7; groundSpeed = Double(s16(32)) / 100; updated.insert("lat")
            case 3: longitude = Double(s32(0)) / 1e7; heading = Double(Self.value(bits, 32, 16)) / 100; updated.insert("lon")
            case 4: altitude = Double(s32(0)) / 100; verticalSpeed = Double(s16(32)) / 100; updated.insert("alt")
            default: break
            }
        } else {
            switch id {
            case 0: seconds = Double(Self.value(bits, 0, 16)) / 1000; groundSpeed = Double(s16(32)) / 100
            case 1: latitude = Double(s32(0)) / 1e7; heading = Double(Self.value(bits, 32, 16)) / 100; updated.insert("lat")
            case 2: longitude = Double(s32(0)) / 1e7; verticalSpeed = Double(s16(32)) / 100; updated.insert("lon")
            case 3: altitude = Double(s32(0)) / 100; updated.insert("alt")
            default: break
            }
        }
    }
}
