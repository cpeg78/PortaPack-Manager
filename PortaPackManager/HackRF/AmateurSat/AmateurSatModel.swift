import CoreGraphics
import Foundation
import Observation
import os

/// Ein empfangener AX.25-Rahmen eines Satelliten.
struct AmateurFrame: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let satellite: String
    let channel: String
    let source: String
    let destination: String
    let path: String
    /// Nutzdaten als Text (überwiegend druckbar) oder `nil`.
    let text: String?
    let hex: String
    let bytes: Int

    /// Liest Adressen, Pfad und Nutzdaten; Rahmen, die kein AX.25-UI-Rahmen
    /// sind, erscheinen nur als Hex.
    init(bytes: [UInt8], satellite: String, channel: String, date: Date = Date()) {
        self.date = date
        self.satellite = satellite
        self.channel = channel
        self.bytes = bytes.count
        if let frame = AX25Frame.parse(bytes) {
            source = frame.source.description
            destination = frame.destination.description
            path = frame.path
            text = Self.printable(frame.info)
            hex = Self.hex(frame.info)
        } else {
            source = "–"
            destination = "–"
            path = ""
            text = nil
            hex = Self.hex(bytes)
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Text, wenn mindestens 90 % der Bytes druckbares ASCII sind.
    static func printable(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else { return "" }
        let good = bytes.filter { (0x20...0x7E).contains($0) || $0 == 0x0D || $0 == 0x0A }.count
        guard Double(good) >= 0.9 * Double(bytes.count) else { return nil }
        return String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : 0x20 }, as: UTF8.self)
    }
}

/// Ablage der SSTV-Bilder (neben dem Ordner der Wettersatellitenbilder).
enum SSTVStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("de.christiangolz.portapackmanager/SSTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func cgImage(_ image: SSTVImage) -> CGImage? {
        MeteorPNG.rgbImage(image.rgba, width: image.width, height: image.height)
    }

    /// Speichert das Bild (nur die schon empfangenen Zeilen).
    static func save(_ image: SSTVImage) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "SSTV_\(formatter.string(from: image.started))_\(image.mode.title.replacingOccurrences(of: " ", with: ""))"
            + (image.complete ? "" : "_teilweise") + ".png"
        let rows = max(1, image.rows)
        let cropped = Array(image.rgba.prefix(rows * image.width * 4))
        guard let cg = MeteorPNG.rgbImage(cropped, width: image.width, height: rows) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = folder.appendingPathComponent(name)
        try MeteorPNG.write(cg, to: url)
        return url
    }

    /// PNGs der Galerie, neueste zuerst.
    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "png" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// Amateurfunksatelliten und ISS im HackRF-Modus: SSTV-Bilder und AX.25-
/// Telemetrie (1200 Bd AFSK, 9600 Bd G3RUH), Doppler-Korrektur aus der
/// Bahnrechnung. Gehört dem Empfangsplan (geplante Überflüge laufen auch
/// ohne offene Seite).
@MainActor
@Observable
final class AmateurSatModel {
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Amateursatelliten")

    /// Gewählter Satellit (Seite); ein geplanter Termin empfängt seinen eigenen.
    var satelliteID = UserDefaults.standard.object(forKey: "amateurSatellite") as? Int ?? AmateurSatellite.issID {
        didSet { UserDefaults.standard.set(satelliteID, forKey: "amateurSatellite") }
    }
    var lnaGain = GainProfile.preset(.aprs).lna
    var vgaGain = GainProfile.preset(.aprs).vga
    var amplifier = GainProfile.preset(.aprs).amplifier
    var antennaPower = false
    /// Doppler-Korrektur aus der Bahnrechnung (braucht Standort und Bahndaten).
    var dopplerCorrection = true

    private(set) var running = false
    /// Satellit des laufenden Empfangs.
    private(set) var receiving: AmateurSatellite?
    private(set) var liveImage: CGImage?
    private(set) var liveStatus = SSTVDecoder.Status()
    private(set) var liveClockPPM = 0.0
    private(set) var gallery: [URL] = []
    private(set) var frames: [AmateurFrame] = []
    private(set) var frameCount = 0
    private(set) var imageCount = 0
    private(set) var savedFiles: [URL] = []
    static let maxSavedFiles = 100
    private(set) var levels: [Float] = []
    private(set) var geometry: Doppler.Geometry?
    private(set) var error: String?

    var satellite: AmateurSatellite { AmateurSatellite.lookup(satelliteID) ?? AmateurSatellite.catalog[0] }

    private let shared = Shared()
    private var updateTask: Task<Void, Never>?
    private var lastRows = -1

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        /// Hält, wer gerade dekodiert (Empfangsfaden bzw. `stop`).
        let work = NSLock()
        var front: SatChannelizer?
        var decoders: [Decoder] = []
        var newFrames: [(bytes: [UInt8], channel: String)] = []
        var finished: [SSTVImage] = []
        var current: SSTVImage?
        var status = SSTVDecoder.Status()
        var levels: [Float] = []
    }

    private enum Decoder: Sendable {
        case sstv(SSTVDecoder)
        case afsk(AFSKDemodulator)
        case g3ruh(G3RUHDemodulator)
    }

    init() { refreshGallery() }

    // MARK: Empfang

    func start(on device: HackRFDevice, satellite override: AmateurSatellite? = nil) {
        guard !running else { return }
        let target = override ?? satellite
        guard !target.channels.isEmpty else {
            error = String(localized: "Für diesen Satelliten ist kein Kanal eingetragen.")
            return
        }
        let center = target.centerFrequency
        let front = SatChannelizer(channels: target.channels.map {
            SatChannelizer.Channel(offset: $0.frequency - center, frequency: $0.frequency, cutoff: $0.mode.channelCutoff)
        })
        let decoders: [Decoder] = target.channels.map {
            switch $0.mode {
            case .sstv: .sstv(SSTVDecoder())
            case .afsk1200: .afsk(AFSKDemodulator())
            case .g3ruh9600: .g3ruh(G3RUHDemodulator())
            }
        }
        let labels = target.channels.map { String(format: "%.3f MHz %@", $0.frequency / 1e6, $0.label) }
        let shared = shared
        shared.lock.withLock {
            shared.front = front
            shared.decoders = decoders
            shared.newFrames = []
            shared.finished = []
            shared.current = nil
            shared.status = SSTVDecoder.Status()
        }
        receiving = target
        updateDoppler()
        do {
            try device.setSampleRate(UInt32(SatChannelizer.inputRate))
            try device.setFrequency(UInt64(center - SatChannelizer.offset))
            try applyGains(to: device)
            try device.startReceiving(owner: self) { block in
                shared.work.lock()
                defer { shared.work.unlock() }
                let outputs = front.process(block)
                var frames: [(bytes: [UInt8], channel: String)] = []
                var finished: [SSTVImage] = []
                var current: SSTVImage?
                var status: SSTVDecoder.Status?
                for (index, decoder) in decoders.enumerated() where index < outputs.count {
                    switch decoder {
                    case .sstv(let sstv):
                        sstv.process(outputs[index])
                        finished += sstv.takeFinished()
                        current = sstv.currentImage
                        status = sstv.status
                    case .afsk(let afsk):
                        frames += afsk.process(outputs[index]).map { ($0, labels[index]) }
                    case .g3ruh(let g3ruh):
                        frames += g3ruh.process(outputs[index]).map { ($0, labels[index]) }
                    }
                }
                let levels = front.channelPowerDB
                shared.lock.withLock {
                    shared.newFrames += frames
                    shared.finished += finished
                    if let status { shared.status = status; shared.current = current }
                    shared.levels = levels
                }
            }
            running = true
            error = nil
            lastRows = -1
            startUpdates()
            Self.log.notice("Start: \(target.name, privacy: .public)")
        } catch {
            self.error = error.localizedDescription
            receiving = nil
        }
    }

    func stop(on device: HackRFDevice?) {
        guard running else { return }
        device?.stopReceiving(owner: self)
        running = false
        updateTask?.cancel()
        updateTask = nil
        // Ein angefangenes Bild nicht verlieren.
        let shared = shared
        shared.work.withLock {
            let decoders = shared.lock.withLock { shared.decoders }
            for decoder in decoders {
                if case .sstv(let sstv) = decoder {
                    sstv.flush()
                    let images = sstv.takeFinished()
                    shared.lock.withLock { shared.finished += images; shared.current = nil }
                }
            }
        }
        pull()
        receiving = nil
    }

    func applyGains(to device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    func clearFrames() {
        frames = []
    }

    func refreshGallery() {
        gallery = SSTVStore.list()
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshGallery()
    }

    // MARK: Aktualisierung

    private func startUpdates() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.pull()
                tick += 1
                if tick % 2 == 0 { self.updateDoppler() }
            }
        }
    }

    /// Bahnlage und Doppler-Faktor aus SGP4 (Standort und Bahndaten nötig).
    func updateDoppler() {
        let target = receiving ?? satellite
        guard let home = ReceptionPlanner.home, let tle = ReceptionPlanner.shared.amateurTLE(for: target.id) else {
            geometry = nil
            shared.lock.withLock { shared.front }?.setDoppler(factor: 0)
            return
        }
        geometry = Doppler.geometry(tle: tle, station: home, at: Date())
        let factor = dopplerCorrection ? (geometry?.factor ?? 0) : 0
        shared.lock.withLock { shared.front }?.setDoppler(factor: factor)
    }

    private func pull() {
        let (newFrames, finished, current, status, levels) = shared.lock.withLock {
            defer { shared.newFrames = []; shared.finished = [] }
            return (shared.newFrames, shared.finished, shared.current, shared.status, shared.levels)
        }
        self.levels = levels
        liveStatus = status
        let name = receiving?.name ?? satellite.name
        if !newFrames.isEmpty {
            let parsed = newFrames.map { AmateurFrame(bytes: $0.bytes, satellite: name, channel: $0.channel) }
            frames.insert(contentsOf: parsed.reversed(), at: 0)
            if frames.count > 500 { frames.removeLast(frames.count - 500) }
            frameCount += parsed.count
        }
        if let current, current.rows != lastRows {
            lastRows = current.rows
            liveImage = SSTVStore.cgImage(current)
            liveClockPPM = current.clockPPM
        }
        for image in finished {
            liveImage = SSTVStore.cgImage(image)
            liveClockPPM = image.clockPPM
            guard image.rows >= 16 else { continue }
            do {
                let url = try SSTVStore.save(image)
                savedFiles.append(url)
                // Nur die letzten Bilder merken – im Dauerbetrieb wüchse die Liste sonst ohne Ende.
                if savedFiles.count > Self.maxSavedFiles { savedFiles.removeFirst(savedFiles.count - Self.maxSavedFiles) }
                imageCount += 1
                Self.log.notice("SSTV-Bild gespeichert: \(url.lastPathComponent, privacy: .public), \(image.rows) Zeilen, Takt \(Int(image.clockPPM)) ppm")
            } catch {
                self.error = String(localized: "Speichern fehlgeschlagen: \(error.localizedDescription)")
            }
        }
        if !finished.isEmpty { refreshGallery() }
    }

    /// Zähler für den Plan (vor `stop` merken, danach Unterschied bilden).
    var counters: (images: Int, frames: Int) { (imageCount, frameCount) }

    /// Doppler-Verschiebung (Hz) auf dem ersten Kanal.
    var dopplerHz: Double? {
        guard let geometry, let f = (receiving ?? satellite).channels.first?.frequency else { return nil }
        return geometry.factor * f
    }
}

extension AmateurSatModel: GainTunable {
    var idleHint: String {
        String(localized: "Satelliten sind nur während eines Überflugs zu hören – die Zeiten stehen unter „Überflüge“. Bilder (SSTV) sendet die ISS nur an angekündigten Tagen.")
    }
    var activity: Int? { frameCount + imageCount }
    var quality: GainQuality? { nil }   // Pakete und Bilder kommen zu selten für einen Vergleich
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}
