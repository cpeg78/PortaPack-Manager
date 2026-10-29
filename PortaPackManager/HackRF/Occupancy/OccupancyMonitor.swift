import Foundation
import Observation
import os

/// Belegungsmonitor: beobachtet ein Band über Stunden oder Tage.
///
/// **Gerätebesitz:** Der Monitor ist ein gemeinsames Objekt und läuft weiter,
/// wenn man die Seite verlässt – eine Langzeitbeobachtung soll nicht enden,
/// weil man kurz in die Hilfe oder die Übersicht schaut. Übernimmt aber eine
/// andere Seite, der Fernzugriff oder der Empfangsplan den HackRF, **pausiert**
/// der Monitor mit Hinweis („Fortsetzen“), statt sich das Gerät zurückzuholen
/// (Regel aus der CLAUDE.md). Vor jedem Umstimmen prüft er `isReceiving(for:)`.
/// Die Aufzeichnung liegt auf der Platte und übersteht Pausen und Neustarts.
@MainActor
@Observable
final class OccupancyMonitor {
    static let shared = OccupancyMonitor()
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Belegung")

    // MARK: Einstellungen (gemerkt)

    var startMHz: Double { didSet { save() } }
    var endMHz: Double { didSet { save() } }
    var binKHz: Double { didSet { save() } }
    var sliceSeconds: Double { didSet { save() } }
    var thresholdDB: Double { didSet { save() } }
    var maxMB: Double { didSet { save() } }
    /// Kennung (`OccupancyPreset.id`) der gewählten Vorlage, nil = eigener Bereich.
    var presetName: String? { didSet { save() } }
    /// Anzeigename der gewählten Vorlage.
    var presetTitle: String? { OccupancyPreset.with(id: presetName)?.name ?? presetName }

    var lnaGain = GainProfile.preset(.spectrum).lna
    var vgaGain = GainProfile.preset(.spectrum).vga
    var amplifier = GainProfile.preset(.spectrum).amplifier
    var antennaPower = false

    // MARK: Zustand

    private(set) var running = false
    /// Gesetzt, wenn der Monitor ohne „Stopp“ angehalten wurde (Gerät übernommen …).
    private(set) var pausedReason: String?
    private(set) var error: String?
    private(set) var rounds = 0
    private(set) var visits = 0
    private(set) var currentWindowMHz: Double?
    private(set) var startedAt: Date?

    private(set) var recording: OccupancyRecording?
    private(set) var recordingURL: URL?
    private(set) var entries: [OccupancyStore.Entry] = []
    /// Zählt neue Scheiben – Ansichten rechnen daran neu.
    private(set) var revision = 0
    private(set) var summary: OccupancyAnalysis.Summary?
    private(set) var active: [OccupancyAnalysis.ActiveFrequency] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var collector: OccupancyCollector?
    @ObservationIgnored private var slicer: OccupancySlicer?
    @ObservationIgnored private weak var device: HackRFDevice?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    let store: OccupancyStore
    /// Ablage der Einstellungen – Tests geben eigene `UserDefaults(suiteName:)`
    /// mit, damit sie nicht die der App überschreiben (Testwirt teilt sie).
    private let defaults: UserDefaults

    var plan: OccupancyPlan { OccupancyPlan(startMHz: startMHz, endMHz: endMHz, binKHz: binKHz) }

    init(store: OccupancyStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        startMHz = defaults.object(forKey: "occupancyStartMHz") as? Double ?? 433.05
        endMHz = defaults.object(forKey: "occupancyEndMHz") as? Double ?? 434.79
        binKHz = defaults.object(forKey: "occupancyBinKHz") as? Double ?? 10
        sliceSeconds = defaults.object(forKey: "occupancySliceSeconds") as? Double ?? 60
        thresholdDB = defaults.object(forKey: "occupancyThresholdDB") as? Double ?? 10
        maxMB = defaults.object(forKey: "occupancyMaxMB") as? Double ?? 200
        presetName = defaults.string(forKey: "occupancyPreset") ?? "433 MHz ISM"
        refreshEntries()
        if let path = defaults.string(forKey: "occupancyRecording"),
           FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        }
    }

    private func save() {
        let d = defaults
        d.set(startMHz, forKey: "occupancyStartMHz")
        d.set(endMHz, forKey: "occupancyEndMHz")
        d.set(binKHz, forKey: "occupancyBinKHz")
        d.set(sliceSeconds, forKey: "occupancySliceSeconds")
        d.set(thresholdDB, forKey: "occupancyThresholdDB")
        d.set(maxMB, forKey: "occupancyMaxMB")
        d.set(presetName, forKey: "occupancyPreset")
    }

    func apply(_ preset: OccupancyPreset) {
        presetName = preset.id
        startMHz = preset.startMHz
        endMHz = preset.endMHz
        binKHz = preset.binKHz
    }

    /// Betriebsart fürs Radio an dieser Frequenz.
    func radioMode(for mhz: Double) -> RadioMode {
        OccupancyPreset.all.first { $0.id == presetName && ($0.startMHz...$0.endMHz).contains(mhz) }?.mode
            ?? OccupancyPreset.radioMode(for: mhz)
    }

    // MARK: Aufzeichnungen

    func refreshEntries() { entries = store.list() }

    func open(_ url: URL) {
        guard !running else { return }
        do {
            let rec = try store.load(url)
            recording = rec
            recordingURL = url
            defaults.set(url.path, forKey: "occupancyRecording")
            error = nil
            recomputeAnalysis()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Die Einstellungen der geöffneten Aufzeichnung übernehmen.
    func adoptSettingsOfRecording() {
        guard let recording else { return }
        startMHz = recording.plan.startMHz
        endMHz = recording.plan.endMHz
        binKHz = recording.plan.binKHz
        sliceSeconds = recording.sliceSeconds
        thresholdDB = Double(recording.thresholdDB)
        presetName = OccupancyPreset.all.first { abs($0.startMHz - startMHz) < 1e-6 && abs($0.endMHz - endMHz) < 0.01 }?.id
    }

    func closeRecording() {
        guard !running else { return }
        recording = nil
        recordingURL = nil
        summary = nil
        active = []
        revision += 1
        defaults.removeObject(forKey: "occupancyRecording")
    }

    func delete(_ entry: OccupancyStore.Entry) {
        guard !(running && entry.url == recordingURL) else { return }
        if entry.url == recordingURL { closeRecording() }
        store.delete(entry.url)
        refreshEntries()
    }

    /// Passt die geöffnete Aufzeichnung zu den Einstellungen (Fortsetzen möglich)?
    var canContinue: Bool {
        recording?.matches(plan: plan, sliceSeconds: sliceSeconds) == true
    }

    // MARK: Empfang

    /// Startet (bzw. setzt fort). `fresh`: immer eine neue Aufzeichnung.
    func start(on device: HackRFDevice, fresh: Bool = false) {
        guard !running else { return }
        let plan = plan
        if fresh || !canContinue {
            let name = presetTitle ?? String(format: "%.3f–%.3f MHz", plan.startMHz, plan.endMHz)
            recording = OccupancyRecording(name: name, plan: plan, sliceSeconds: sliceSeconds, thresholdDB: Float(thresholdDB))
            let url = store.newURL()
            recordingURL = url
            defaults.set(url.path, forKey: "occupancyRecording")
            summary = nil
            active = []
            revision += 1
        }
        let collector = OccupancyCollector(fftSize: plan.fftSize)
        do {
            try device.setSampleRate(UInt32(OccupancyPlan.sampleRate))
            try applyTunedGains(device)
            try device.startReceiving(owner: self) { collector.process($0) }
        } catch {
            self.error = error.localizedDescription
            return
        }
        self.collector = collector
        self.device = device
        slicer = OccupancySlicer(binCount: plan.binCount, sliceSeconds: sliceSeconds)
        running = true
        pausedReason = nil
        error = nil
        startedAt = Date()
        rounds = 0
        visits = 0
        Self.log.notice("Start \(plan.startMHz, format: .fixed(precision: 3))–\(plan.endMHz, format: .fixed(precision: 3)) MHz, \(plan.binCount) Bins, FFT \(plan.fftSize)")
        task = Task { [weak self] in
            await self?.loop(device: device, plan: plan, collector: collector)
        }
    }

    /// Anhalten auf Wunsch: Strom freigeben, angefangene Scheibe speichern.
    func stop() {
        task?.cancel()
        task = nil
        device?.stopReceiving(owner: self)
        finishRun(reason: nil)
    }

    private func finishRun(reason: String?) {
        collector?.idle()
        if var slicer, let slice = slicer.close() { persist(slice) }
        slicer = nil
        collector = nil
        device = nil
        task = nil
        running = false
        currentWindowMHz = nil
        pausedReason = reason
        if let reason { Self.log.notice("Pause: \(reason, privacy: .public)") }
        refreshEntries()
    }

    private func loop(device: HackRFDevice, plan: OccupancyPlan, collector: OccupancyCollector) async {
        let settle = Duration.milliseconds(80)
        let dwell = Duration.milliseconds(plan.isNarrow ? 1000 : 500)
        var mappings: [Int: OccupancyMapping] = [:]
        var floors: [Int: Float] = [:]
        var tuned: Double?
        var round = 0
        while !Task.isCancelled {
            for center in plan.centers(round: round) {
                guard !Task.isCancelled else { return }
                guard device.isReceiving(for: self) else {
                    let owner = device.currentOwner
                    finishRun(reason: owner == nil
                        ? String(localized: "Der Empfang ist abgerissen oder das Gerät wurde getrennt. Mit „Fortsetzen“ geht die Aufzeichnung weiter.")
                        : String(localized: "Der HackRF empfängt jetzt für \(DeviceArbiter.title(of: owner)). Mit „Fortsetzen“ geht die Aufzeichnung weiter."))
                    return
                }
                if device.isStalled(for: self) {
                    Self.log.notice("Strom steht – starte neu")
                    device.stopReceiving(owner: self)
                    do { try device.startReceiving(owner: self) { collector.process($0) } } catch {
                        finishRun(reason: String(localized: "Neustart des Empfangs fehlgeschlagen: \(error.localizedDescription)"))
                        return
                    }
                    tuned = nil
                }
                let key = Int((center * 1000).rounded())
                let mapping = mappings[key] ?? plan.mapping(centerMHz: center, fftSize: plan.fftSize)
                mappings[key] = mapping
                if tuned != center {
                    collector.idle()
                    do { try device.setFrequency(UInt64(center * 1_000_000)) } catch {
                        finishRun(reason: String(localized: "Umstimmen fehlgeschlagen: \(error.localizedDescription)"))
                        return
                    }
                    tuned = center
                    try? await Task.sleep(for: settle)
                }
                currentWindowMHz = center
                let threshold = floors[key].map { Float(pow(10, Double($0 + Float(thresholdDB)) / 10)) }
                collector.begin(mapping: mapping, thresholdLinear: threshold)
                try? await Task.sleep(for: dwell)
                guard !Task.isCancelled else { return }
                // Hat in der Zwischenzeit jemand anderes übernommen, ist der Besuch ungültig.
                guard device.isReceiving(for: self), let visit = collector.finish() else { continue }
                floors[key] = floors[key].map { $0 * 0.7 + visit.floorDB * 0.3 } ?? visit.floorDB
                visits += 1
                if let slice = slicer?.add(visit, at: Date()) { persist(slice) }
            }
            round += 1
            rounds = round
        }
    }

    private func persist(_ slice: OccupancySlice) {
        guard var rec = recording, let url = recordingURL, slice.mean.count == rec.plan.binCount else { return }
        do {
            let removed = try store.append(slice, to: &rec, url: url, maxBytes: Int(maxMB * 1_000_000))
            if removed > 0 { Self.log.notice("Größengrenze: \(removed) alte Scheiben entfernt") }
        } catch {
            rec.slices.append(slice)
            self.error = String(localized: "Speichern fehlgeschlagen: \(error.localizedDescription)")
        }
        recording = rec
        revision += 1
        recomputeAnalysis()
    }

    private func recomputeAnalysis() {
        guard let rec = recording else { return }
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            let (summary, active) = await Task.detached(priority: .utility) {
                let summary = OccupancyAnalysis.summary(rec.slices, binCount: rec.plan.binCount)
                let mergeBins = max(1, Int((12.5 / rec.plan.binKHz).rounded()))
                return (summary, OccupancyAnalysis.mostActive(summary, slices: rec.slices, plan: rec.plan, mergeBins: mergeBins))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.summary = summary
            self.active = active
        }
    }

    /// Hinweis, wenn der Lauf nicht mehr zu den Einstellungen passt.
    var settingsHint: String? {
        guard let recording, !canContinue else { return nil }
        return String(localized: "Die geöffnete Aufzeichnung „\(recording.name)“ passt nicht zu den Einstellungen – „Start“ beginnt eine neue.")
    }

    // MARK: Export

    /// Zusammenfassung je Frequenz als CSV (Semikolon, Dezimalpunkt).
    func summaryCSV() -> String {
        guard let recording, let summary else { return "" }
        var lines = ["frequenz_mhz;belegung_prozent;mittel_dbfs;spitze_ueber_boden_db"]
        for g in 0..<recording.plan.binCount {
            func f(_ v: Double?, _ digits: Int) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
            lines.append([String(format: "%.5f", recording.plan.binCenterMHz(g)), f(summary.occupancy[g].map { $0 * 100 }, 2),
                          f(summary.meanDB[g].map(Double.init), 1), f(summary.peakAboveFloor[g].map(Double.init), 1)].joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Alle Zeitscheiben im Langformat (eine Zeile je Scheibe und Bin mit Messung).
    func slicesCSV() -> String {
        recording.map(Self.slicesCSV) ?? ""
    }

    /// Wie `slicesCSV()`, ohne Zustand – für den Bau abseits des Main Actors: ein Tag
    /// mit 4000 Bins sind Millionen Zeilen (Review L7/Belegungs-CSV, 29.10.2026).
    /// Die Frequenzspalte wird je Bin einmal formatiert, nicht je Zeile.
    nonisolated static func slicesCSV(_ recording: OccupancyRecording) -> String {
        let frequencies = (0..<recording.plan.binCount).map { String(format: "%.5f", recording.plan.binCenterMHz($0)) }
        var out = "zeit_utc;frequenz_mhz;mittel_dbfs;spitze_dbfs;belegung_prozent;boden_dbfs\n"
        for slice in recording.slices {
            let t = ISOTime.string(slice.start)
            let floor = String(format: "%.1f", slice.floorDB)
            for g in 0..<recording.plan.binCount {
                guard let mean = slice.meanDB(g) else { continue }
                let occ = slice.occupancyFraction(g).map { String(format: "%.1f", $0 * 100) } ?? ""
                out += "\(t);\(frequencies[g]);\(String(format: "%.1f", mean));"
                out += "\(slice.peakDB(g).map { String(format: "%.1f", $0) } ?? "");\(occ);\(floor)\n"
            }
        }
        return out
    }
}

extension OccupancyMonitor: GainTunable {
    var quality: GainQuality? { nil }
    var idleHint: String { "" }
    /// Wie die Wasserstofflinie: feste Verstärkung, sonst sprängen die
    /// gespeicherten Pegel einer Langzeitaufzeichnung (Entscheidung 28.10.2026).
    var wantsAutoGain: Bool { false }
    func applyTunedGains(_ device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }
}
