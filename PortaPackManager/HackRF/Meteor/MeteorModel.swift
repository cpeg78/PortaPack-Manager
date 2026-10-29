import CoreGraphics
import Foundation
import Observation

/// Wettersatelliten-Empfang (METEOR-M LRPT) im HackRF-Modus, live oder aus
/// einer IQ-Aufnahme.
@MainActor
@Observable
final class MeteorModel {
    var frequency: Double = MeteorReceiver.frequencies[0]
    var signal: MeteorSignal = .oqpsk72
    var composite: MeteorComposite = .rgb221
    var lnaGain = GainProfile.preset(.meteor).lna
    var vgaGain = GainProfile.preset(.meteor).vga
    var amplifier = GainProfile.preset(.meteor).amplifier
    var antennaPower = false

    private(set) var running = false
    private(set) var playing = false
    private(set) var progress = 0.0
    private(set) var snapshot = MeteorReceiver.Snapshot()
    private(set) var image: CGImage?
    private(set) var channels: [Int] = []
    private(set) var savedFiles: [URL] = []
    private(set) var error: String?
    private(set) var recordings: [IQRecording] = []
    /// Beim nächsten Live-Start die Rohdaten in den Aufnahmeordner schreiben.
    var recordIQ = false
    private var iqRecorder: IQRecorder?
    private var iqRecording: IQRecording?

    private let shared = Shared()
    private var updateTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var imageVersion = -1
    private var renderedComposite: MeteorComposite?
    private var lastRender = Date.distantPast
    private var pendingForce = false

    private final class Shared: @unchecked Sendable {
        let receiver = MeteorReceiver(offset: MeteorReceiver.frequencies[0] - Double(MeteorReceiver.centerFrequency),
                                      signal: .oqpsk72)
        let player = IQPlayer()
    }

    init() { refreshRecordings() }

    var busy: Bool { running || playing }

    // MARK: Live

    func start(on device: HackRFDevice) {
        guard !busy else { return }
        do {
            shared.receiver.configure(inputRate: Double(MeteorReceiver.sampleRate),
                                      offset: frequency - Double(MeteorReceiver.centerFrequency), signal: signal)
            try device.setSampleRate(MeteorReceiver.sampleRate)
            try device.setBasebandFilter(HackRFDevice.basebandFilter(for: 1_750_000))
            try device.setFrequency(MeteorReceiver.centerFrequency)
            try applyGains(to: device)
            let receiver = shared.receiver
            var recorder: IQRecorder?
            if recordIQ {
                let name = Self.filePrefix()
                let new = IQRecorder()
                try new.start(url: IQStore.dataURL(for: name))
                recorder = new
                iqRecorder = new
                iqRecording = IQRecording(name: name, centerHz: MeteorReceiver.centerFrequency,
                                          sampleRate: MeteorReceiver.sampleRate, date: Date(), byteCount: 0)
            }
            let writer = recorder
            try device.startReceiving(owner: self) { block in
                writer?.write(block)
                receiver.process(block)
            }
            running = true
            error = nil
            startUpdates()
        } catch {
            self.error = error.localizedDescription
            // Angefangene Rohdatenaufnahme nicht offen liegen lassen (`stop` kehrt
            // ohne `running` sofort zurück).
            if let recorder = iqRecorder, let meta = iqRecording {
                _ = recorder.stop()
                try? FileManager.default.removeItem(at: IQStore.dataURL(for: meta.name))
            }
            iqRecorder = nil
            iqRecording = nil
        }
    }

    func stop(on device: HackRFDevice?) {
        guard running else { return }
        device?.stopReceiving(owner: self)
        running = false
        if let recorder = iqRecorder, var meta = iqRecording {
            meta.byteCount = recorder.stop()
            IQStore.save(meta)
            refreshRecordings()
        }
        iqRecorder = nil
        iqRecording = nil
        stopUpdates()
        autoSave()
    }

    /// Frequenz oder Betriebsart während des Empfangs wechseln.
    func retune() {
        guard running else { return }
        shared.receiver.configure(inputRate: Double(MeteorReceiver.sampleRate),
                                  offset: frequency - Double(MeteorReceiver.centerFrequency), signal: signal)
    }

    func applyGains(to device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    // MARK: Offline

    func refreshRecordings() {
        recordings = IQStore.list().filter { Self.covers($0) != nil }
    }

    /// Welche LRPT-Frequenz eine Aufnahme enthält (Kanal ganz im Band).
    static func covers(_ rec: IQRecording) -> Double? {
        let halfBand = Double(rec.sampleRate) / 2 - 80_000
        return MeteorReceiver.frequencies.first { abs($0 - Double(rec.centerHz)) < halfBand }
    }

    func play(_ rec: IQRecording) {
        guard !busy else { return }
        let target = Self.covers(rec) ?? frequency
        frequency = target
        shared.receiver.configure(inputRate: Double(rec.sampleRate), offset: target - Double(rec.centerHz), signal: signal)
        shared.receiver.clearImage()
        playing = true
        progress = 0
        error = nil
        startUpdates()
        let url = IQStore.dataURL(for: rec)
        let shared = shared
        playTask = Task.detached { [weak self] in
            shared.player.play(url: url, handler: { shared.receiver.process($0) }, progress: { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }, isCancelled: { Task.isCancelled })
            await MainActor.run { [weak self] in self?.finishPlayback() }
        }
    }

    func stopPlayback() {
        playTask?.cancel()
    }

    private func finishPlayback() {
        playTask = nil
        playing = false
        progress = 1
        stopUpdates()
        autoSave()
    }

    // MARK: Bild

    func clear() {
        shared.receiver.clearImage()
        image = nil
        channels = []
        savedFiles = []
        imageVersion = -1
    }

    func save() {
        let assembler = shared.receiver.currentImage
        guard !assembler.isEmpty else { return }
        do {
            savedFiles = try MeteorPNG.saveAll(assembler, prefix: Self.filePrefix())
            error = nil
        } catch {
            self.error = String(localized: "Speichern fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    private func autoSave() {
        refreshImage(force: true)
        if snapshot.lines >= 16 { save() }
    }

    func compositeChanged() {
        refreshImage(force: true)
    }

    private func startUpdates() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.snapshot = self.shared.receiver.snapshot
                self.refreshImage(force: false)
            }
        }
    }

    private func stopUpdates() {
        updateTask?.cancel()
        updateTask = nil
        snapshot = shared.receiver.snapshot
    }

    /// Bild höchstens alle zwei Sekunden neu zusammensetzen (abseits des Main Actors).
    private func refreshImage(force: Bool) {
        if renderTask != nil {
            if force { pendingForce = true }
            return
        }
        guard force || Date().timeIntervalSince(lastRender) > 2 else { return }
        // −2 kommt als Version nie vor: erzwingt eine Kopie des aktuellen Stands.
        guard let (newVersion, assembler) = shared.receiver.image(after: force ? -2 : imageVersion) else { return }
        lastRender = Date()
        let available = assembler.channelNumbers
        let chosen = composite.available(in: available)
            ? composite : (MeteorComposite.allCases.first { $0.available(in: available) } ?? composite)
        renderTask = Task { [weak self] in
            let rendered = await Task.detached { MeteorRenderedImage(chosen.render(assembler)) }.value
            guard let self else { return }
            self.image = rendered.image
            self.channels = available
            if self.composite != chosen, !self.composite.available(in: available) { self.composite = chosen }
            self.imageVersion = newVersion
            self.renderTask = nil
            if self.pendingForce {
                self.pendingForce = false
                self.refreshImage(force: true)
            }
        }
    }

    private static func filePrefix() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "METEOR_" + f.string(from: Date())
    }
}

/// Hülle, um ein `CGImage` aus der Hintergrundaufgabe zu reichen.
struct MeteorRenderedImage: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}
