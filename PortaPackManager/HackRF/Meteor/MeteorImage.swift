import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sammelt dekodierte Bildpakete je MSU-MR-Kanal und setzt daraus Bilder
/// zusammen (1568 Pixel breit, je Zeilengruppe 8 Zeilen).
///
/// Zuordnung wie SatDump `lrpt_msumr_reader.cpp`: Der Paketzähler läuft über
/// alle Kanäle; eine Zeilengruppe besteht aus 14 Paketen je Kanal plus einem
/// Telemetriepaket (bei drei Kanälen 43 Pakete). Kanäle einer Zeilengruppe
/// folgen in APID-Reihenfolge.
struct MeteorImageAssembler: Sendable {
    /// MSU-MR-Kanal 1…6 (APID 64…69).
    static let apids = 64...69

    struct Channel: Sendable {
        /// Paketzähler des ersten Pakets einer Zeilengruppe → 14 Teilstücke.
        var groups: [Int: [[UInt8]?]] = [:]
        var segments = 0
        var lastKey: Int?
    }

    private(set) var channels: [Int: Channel] = [:]
    /// Zeilengruppen-Periode in Paketen (aus kleinstem Abstand geschätzt).
    private(set) var period = 43
    private var minimumGap: Int?
    private var lastSequence: Int?
    private var unwrapped = 0
    /// Bereich der bisherigen Schlüssel über alle Kanäle.
    private var keyRange: ClosedRange<Int>?

    /// Höchstens so viele Zeilengruppen (8 Zeilen) je Bild – ein Überflug hat
    /// etwa 800. Gestörte Paketzähler würden sonst Bildhöhen von GB anfordern.
    static let maxRowGroups = 2000
    /// Größte Schlüsselspanne (Pakete) bei der längsten Periode.
    static let maxKeySpan = maxRowGroups * 43

    var isEmpty: Bool { channels.isEmpty }
    var channelNumbers: [Int] { channels.keys.sorted().map { $0 - 63 } }
    func segmentCount(channel: Int) -> Int { channels[channel + 63]?.segments ?? 0 }

    mutating func add(_ packet: MeteorPacket) {
        guard Self.apids.contains(packet.apid),
              let segment = MeteorJPEG.decodeSegment(packet.payload) else { return }
        // Paketzähler (14 Bit) über alle APIDs entfalten.
        if let last = lastSequence {
            var delta = (packet.sequence - last) & 0x3FFF
            if delta >= 0x2000 { delta -= 0x4000 }
            unwrapped += delta
        }
        lastSequence = packet.sequence
        let index = segment.mcuNumber / MeteorJPEG.mcusPerSegment
        let key = unwrapped - index
        // Ausreißer (weit außerhalb des bisherigen Bereichs) verwerfen.
        if let range = keyRange {
            let merged = min(range.lowerBound, key)...max(range.upperBound, key)
            guard merged.upperBound - merged.lowerBound <= Self.maxKeySpan else { return }
            keyRange = merged
        } else {
            keyRange = key...key
        }
        var channel = channels[packet.apid] ?? Channel()
        if let last = channel.lastKey, key - last >= 15 {
            // Kleinster Abstand zweier Zeilengruppen = Periode (Lücken sind Vielfache).
            let gap = key - last
            minimumGap = min(minimumGap ?? gap, gap)
            period = minimumGap ?? 43
        }
        channel.lastKey = key
        var group = channel.groups[key] ?? [[UInt8]?](repeating: nil, count: MeteorJPEG.segmentsPerLine)
        group[index] = segment.pixels
        channel.groups[key] = group
        channel.segments += 1
        channels[packet.apid] = channel
    }

    /// Zeilengruppen-Nummer je (APID, Schlüssel), über alle Kanäle ausgerichtet.
    private func rows() -> [Int: [Int: Int]] {
        let present = channels.keys.sorted()
        guard let reference = present.first, let refKeys = channels[reference]?.groups.keys,
              let refKey = refKeys.min() else { return [:] }
        let p = period
        var result: [Int: [Int: Int]] = [:]
        for apid in present {
            guard let channel = channels[apid], let anyKey = channel.groups.keys.min() else { continue }
            // Versatz dieses Kanals innerhalb einer Zeilengruppe (nach dem Bezugskanal).
            let offset = ((anyKey - refKey) % p + p) % p
            var map: [Int: Int] = [:]
            for key in channel.groups.keys {
                map[key] = Int((Double(key - offset - refKey) / Double(p)).rounded(.down))
            }
            result[apid] = map
        }
        return result
    }

    /// Graustufenbild eines Kanals (1…6); fehlende Pakete bleiben schwarz.
    /// Alle Kanäle haben dieselbe Höhe, damit Komposite passen.
    func grayImage(channel: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        let rowMap = rows()
        let all = rowMap.values.flatMap { $0.values }
        guard let minRow = all.min(), let maxRow = all.max(),
              let channelData = channels[channel + 63], let map = rowMap[channel + 63] else { return nil }
        let width = MeteorJPEG.lineWidth
        let rowCount = min(maxRow - minRow + 1, Self.maxRowGroups)
        let height = rowCount * 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        for (key, group) in channelData.groups {
            guard let row = map[key], row - minRow < rowCount else { continue }
            let top = (row - minRow) * 8
            for (index, segment) in group.enumerated() {
                guard let segment else { continue }
                for line in 0..<8 {
                    let dst = (top + line) * width + index * MeteorJPEG.segmentWidth
                    let src = line * MeteorJPEG.segmentWidth
                    pixels.replaceSubrange(dst..<(dst + MeteorJPEG.segmentWidth),
                                           with: segment[src..<(src + MeteorJPEG.segmentWidth)])
                }
            }
        }
        return (pixels, width, height)
    }

    var lineCount: Int {
        let all = rows().values.flatMap { $0.values }
        guard let lo = all.min(), let hi = all.max() else { return 0 }
        return min(hi - lo + 1, Self.maxRowGroups) * 8
    }
}

/// Darstellung: einzelner Kanal oder RGB-Komposit (Rohwerte, unkalibriert).
enum MeteorComposite: String, CaseIterable, Identifiable, Sendable {
    case rgb221, rgb124, rgb321, channel1, channel2, channel3, channel4, channel5, channel6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rgb221: "RGB 2-2-1"
        case .rgb124: String(localized: "Falschfarben 1-2-4")
        case .rgb321: "RGB 3-2-1"
        default: String(localized: "Kanal \(singleChannel!)")
        }
    }

    var singleChannel: Int? {
        switch self {
        case .channel1: 1
        case .channel2: 2
        case .channel3: 3
        case .channel4: 4
        case .channel5: 5
        case .channel6: 6
        default: nil
        }
    }

    /// Benötigte Kanäle (R, G, B).
    var rgb: (Int, Int, Int)? {
        switch self {
        case .rgb221: (2, 2, 1)
        case .rgb124: (1, 2, 4)
        case .rgb321: (3, 2, 1)
        default: nil
        }
    }

    func available(in channels: [Int]) -> Bool {
        if let c = singleChannel { return channels.contains(c) }
        guard let (r, g, b) = rgb else { return false }
        return [r, g, b].allSatisfy(channels.contains)
    }

    /// Kontrast strecken (1.–99. Perzentil der vorhandenen Pixel auf 1…255),
    /// Infrarotkanäle (4–6) invertieren – kalte Wolken hell. Fehlende Pixel
    /// (0) bleiben schwarz.
    static func display(_ pixels: [UInt8], channel: Int) -> [UInt8] {
        var histogram = [Int](repeating: 0, count: 256)
        for v in pixels where v != 0 { histogram[Int(v)] += 1 }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return pixels }
        func percentile(_ p: Double) -> Int {
            let target = Int(Double(total) * p)
            var sum = 0
            for v in 1..<256 {
                sum += histogram[v]
                if sum > target { return v }
            }
            return 255
        }
        let lo = percentile(0.01), hi = max(percentile(0.99), lo + 1)
        let invert = channel >= 4
        var table = [UInt8](repeating: 0, count: 256)
        for v in 1..<256 {
            var x = Double(v - lo) / Double(hi - lo)
            x = max(0, min(1, x))
            if invert { x = 1 - x }
            table[v] = UInt8(1 + (x * 254).rounded())
        }
        return pixels.map { table[Int($0)] }
    }

    func render(_ assembler: MeteorImageAssembler) -> CGImage? {
        if let c = singleChannel {
            guard let gray = assembler.grayImage(channel: c) else { return nil }
            return MeteorPNG.grayImage(Self.display(gray.pixels, channel: c), width: gray.width, height: gray.height)
        }
        guard let (r, g, b) = rgb,
              let redRaw = assembler.grayImage(channel: r), let greenRaw = assembler.grayImage(channel: g),
              let blueRaw = assembler.grayImage(channel: b) else { return nil }
        let red = Self.display(redRaw.pixels, channel: r)
        let green = Self.display(greenRaw.pixels, channel: g)
        let blue = Self.display(blueRaw.pixels, channel: b)
        let count = redRaw.width * redRaw.height
        var rgba = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            rgba[4 * i] = red[i]
            rgba[4 * i + 1] = green[i]
            // 1-2-4 wie SatDump: blau = (1 − Kanal 4)/2 (Kanal 4 ist schon invertiert).
            rgba[4 * i + 2] = self == .rgb124 ? blue[i] / 2 : blue[i]
        }
        return MeteorPNG.rgbImage(rgba, width: redRaw.width, height: redRaw.height)
    }
}

/// Bilder erzeugen und als PNG ablegen.
enum MeteorPNG {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("de.christiangolz.portapackmanager/Wettersatellit", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func grayImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func rgbImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// Speichert alle Einzelkanäle und passende Komposite; liefert die Dateien.
    static func saveAll(_ assembler: MeteorImageAssembler, prefix: String) throws -> [URL] {
        var urls: [URL] = []
        let channels = assembler.channelNumbers
        for composite in MeteorComposite.allCases where composite.available(in: channels) {
            guard let image = composite.render(assembler) else { continue }
            let url = folder.appendingPathComponent("\(prefix)_\(composite.rawValue).png")
            try write(image, to: url)
            urls.append(url)
        }
        return urls
    }
}
