import AVFoundation
import Foundation

/// Dateiformat der Tonaufnahme (Radio, DAB+).
enum AudioFileFormat: String, CaseIterable, Identifiable, Sendable {
    /// AAC-LC in `.m4a` – klein (≈ 1 MB/min in Stereo).
    case aac
    /// WAV, 16 bit PCM – verlustfrei, ≈ 11 MB/min in Stereo.
    case wav

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aac: String(localized: "AAC (m4a, klein)")
        case .wav: String(localized: "WAV (16 bit, verlustfrei)")
        }
    }

    var fileExtension: String { self == .aac ? "m4a" : "wav" }
}

/// Stand einer laufenden Tonaufnahme für die Anzeige.
struct AudioRecordingInfo: Equatable, Sendable {
    var url: URL
    var started: Date
    var seconds: Double
    var bytes: Int64
}

/// Schreibt den hörbaren Ton (48 kHz, Float ±1) als WAV oder AAC. `append`
/// kommt vom Empfangsthread und kopiert nur in eine eigene serielle
/// Warteschlange – geschrieben wird dort, nie auf dem Main Actor und nie
/// unter dem Lock des Demodulators. Fehler beenden das Schreiben; `failure`
/// sagt dann, warum.
final class AudioFileRecorder: @unchecked Sendable {
    static let sampleRate = 48_000.0
    /// Größte Datenmenge einer WAV-Datei (32-Bit-Längenfelder).
    static let wavDataLimit = Int64(UInt32.max) - 36

    let url: URL
    let format: AudioFileFormat
    let channels: Int

    private let queue = DispatchQueue(label: "de.christiangolz.portapackmanager.tonaufnahme")
    private let lock = NSLock()
    private var frames: Int64 = 0
    private var bytes: Int64 = 0
    private var failureText: String?
    private var closed = false

    // Nur auf `queue` benutzt:
    private var handle: FileHandle?
    private var file: AVAudioFile?
    private var dataBytes: Int64 = 0
    private var opened = false
    private var framesSinceHeader = 0
    private let wavLimit: Int64

    /// `wavLimit` nur für Tests kleiner als die echte Grenze.
    init(url: URL, format: AudioFileFormat, channels: Int, wavLimit: Int64 = AudioFileRecorder.wavDataLimit) {
        self.url = url
        self.format = format
        self.channels = max(1, min(2, channels))
        self.wavLimit = wavLimit
        queue.async { self.open() }
    }

    /// Aufgenommene Dauer in Sekunden.
    var seconds: Double { lock.withLock { Double(frames) / Self.sampleRate } }
    /// Größe der Datei (WAV genau, AAC aus der Datei gelesen, etwa sekündlich).
    var bytesWritten: Int64 { lock.withLock { bytes } }
    /// Grund, warum das Schreiben vorzeitig endete (`nil`, solange alles läuft).
    var failure: String? { lock.withLock { failureText } }

    /// Neue Werte (links, rechts). Mono-Dateien bekommen den Mittelwert.
    func append(left: [Float], right: [Float]) {
        let count = min(left.count, right.count)
        guard count > 0, lock.withLock({ !closed && failureText == nil }) else { return }
        queue.async { self.write(left: left, right: right, count: count) }
    }

    /// Schließt die Datei (auf der Warteschlange) und ruft danach `completion`.
    func finish(completion: (@Sendable () -> Void)? = nil) {
        lock.withLock { closed = true }
        queue.async {
            self.close()
            completion?()
        }
    }

    /// Für Tests: schließen und warten, bis die Datei fertig ist.
    func finishAndWait() {
        lock.withLock { closed = true }
        queue.sync { close() }
    }

    // MARK: - Auf der Warteschlange

    private func open() {
        opened = true
        do {
            switch format {
            case .wav:
                guard FileManager.default.createFile(atPath: url.path, contents: Self.wavHeader(channels: channels, dataBytes: 0)) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
                handle = try FileHandle(forWritingTo: url)
                try handle?.seekToEnd()
            case .aac:
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate,
                                               AVNumberOfChannelsKey: channels,
                                               AVEncoderBitRateKey: channels == 2 ? 128_000 : 64_000]
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
        } catch {
            fail(String(localized: "Die Tonaufnahme ließ sich nicht anlegen: \(error.localizedDescription)"))
        }
    }

    private func write(left: [Float], right: [Float], count: Int) {
        guard opened, lock.withLock({ failureText == nil }) else { return }
        do {
            switch format {
            case .wav:
                guard let handle else { return }
                let data = Self.pcm16(left: left, right: right, count: count, channels: channels)
                guard dataBytes + Int64(data.count) <= wavLimit else {
                    fail(String(localized: "Die WAV-Datei hat ihre Höchstgröße (4 GB) erreicht – Aufnahme beendet."))
                    return
                }
                try handle.write(contentsOf: data)
                dataBytes += Int64(data.count)
                framesSinceHeader += count
                // Etwa alle 10 s die Längen nachtragen: Auch nach einem Absturz bleibt die Datei lesbar.
                if framesSinceHeader >= 480_000 { try patchWAVHeader(); framesSinceHeader = 0 }
                lock.withLock { frames += Int64(count); bytes = 44 + dataBytes }
            case .aac:
                guard let file,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                      let target = buffer.floatChannelData else { return }
                buffer.frameLength = AVAudioFrameCount(count)
                if channels == 2 {
                    left.withUnsafeBufferPointer { target[0].update(from: $0.baseAddress!, count: count) }
                    right.withUnsafeBufferPointer { target[1].update(from: $0.baseAddress!, count: count) }
                } else {
                    for n in 0..<count { target[0][n] = (left[n] + right[n]) / 2 }
                }
                try file.write(from: buffer)
                framesSinceHeader += count
                var size: Int64?
                if framesSinceHeader >= 48_000 {
                    framesSinceHeader = 0
                    size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                }
                lock.withLock {
                    frames += Int64(count)
                    if let size { bytes = size }
                }
            }
        } catch {
            fail(String(localized: "Schreibfehler bei der Tonaufnahme: \(error.localizedDescription)"))
        }
    }

    private func close() {
        if let handle {
            try? patchWAVHeader()
            try? handle.close()
            self.handle = nil
        }
        if file != nil {
            file = nil    // AVAudioFile schreibt beim Freigeben die letzten Rahmen und den Kopf
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            if let size { lock.withLock { bytes = size } }
        }
    }

    private func fail(_ text: String) {
        lock.withLock { if failureText == nil { failureText = text } }
        close()
    }

    private func patchWAVHeader() throws {
        guard let handle else { return }
        let header = Self.wavHeader(channels: channels, dataBytes: dataBytes)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        try handle.seekToEnd()
    }

    // MARK: - WAV

    /// 44-Byte-Kopf für 16 bit PCM, 48 kHz.
    static func wavHeader(channels: Int, dataBytes: Int64) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        let blockAlign = UInt16(channels * 2)
        let size = UInt32(clamping: dataBytes)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) &+ size)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(channels))
        append(rate); append(rate * UInt32(blockAlign)); append(blockAlign); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(size)
        return data
    }

    /// Float ±1 → 16 bit, verschachtelt (Stereo) bzw. Mittelwert (Mono); begrenzt statt Überlauf.
    static func pcm16(left: [Float], right: [Float], count: Int, channels: Int) -> Data {
        var samples = [Int16](repeating: 0, count: count * channels)
        func convert(_ x: Float) -> Int16 { Int16((max(-1, min(1, x)) * 32_767).rounded()) }
        for n in 0..<count {
            if channels == 2 {
                samples[2 * n] = convert(left[n])
                samples[2 * n + 1] = convert(right[n])
            } else {
                samples[n] = convert((left[n] + right[n]) / 2)
            }
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Eine abgelegte Tonaufnahme.
struct AudioRecordingFile: Identifiable, Hashable, Sendable {
    let url: URL
    let date: Date
    let bytes: Int64
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Ordner der Tonaufnahmen (Application Support/Tonaufnahmen, wie die IQ-Aufnahmen
/// unter „Aufnahmen“). Dateiname: Quelle, Zeit, Frequenz bzw. Sendername.
enum AudioRecordingStore {
    static let radioPrefix = "Radio"
    static let dabPrefix = "DAB+"

    static var folder: URL {
        let url = AppFiles.support.appendingPathComponent("Tonaufnahmen", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// „Radio 2026-10-29 14-03-12 144.30000 MHz USB.m4a“ – ohne Doppelpunkt und
    /// Schrägstrich (Finder bzw. Pfadtrenner), höchstens 120 Zeichen.
    static func fileName(source: String, detail: String, date: Date, format: AudioFileFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let cleaned = detail.unicodeScalars
            .map { CharacterSet(charactersIn: "/:\\\0").contains($0) || CharacterSet.controlCharacters.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        var base = "\(source) \(formatter.string(from: date))"
        if !cleaned.isEmpty { base += " " + cleaned }
        return String(base.prefix(120)) + "." + format.fileExtension
    }

    /// Neuer, noch nicht vorhandener Dateiname im Ordner.
    static func newURL(source: String, detail: String, format: AudioFileFormat, date: Date = Date(), in folder: URL = folder) -> URL {
        let first = folder.appendingPathComponent(fileName(source: source, detail: detail, date: date, format: format))
        let base = first.deletingPathExtension().lastPathComponent
        var url = first
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(index)).\(format.fileExtension)")
            index += 1
        }
        return url
    }

    /// Aufnahmen einer Quelle, neueste zuerst.
    static func list(source: String, in folder: URL = folder) -> [AudioRecordingFile] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.filter { ["m4a", "wav"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent.hasPrefix(source + " ") }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return AudioRecordingFile(url: url, date: values?.creationDate ?? .distantPast, bytes: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
    }

    static func delete(_ file: AudioRecordingFile) {
        try? FileManager.default.removeItem(at: file.url)
    }
}
