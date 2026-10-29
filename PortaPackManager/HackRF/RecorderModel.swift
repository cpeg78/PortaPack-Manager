import CoreGraphics
import Foundation
import Observation

/// Aufnahme des IQ-Stroms und Offline-Wiedergabe (Spektrum, ADS-B, GPS,
/// DVB-T2 und DAB+).
@MainActor
@Observable
final class RecorderModel {
    enum Analysis: String, CaseIterable, Identifiable {
        case spectrum, adsb, gps, tv, dab, zigbee
        var id: String { rawValue }
        var title: String {
            switch self {
            case .spectrum: String(localized: "Spektrum")
            case .adsb: String(localized: "ADS-B dekodieren")
            case .gps: String(localized: "GPS-Ortung")
            case .tv: String(localized: "Fernsehen (DVB-T2) dekodieren")
            case .dab: String(localized: "DAB+ dekodieren")
            case .zigbee: String(localized: "Zigbee/Thread dekodieren")
            }
        }
    }

    // Aufnahme-Einstellungen
    var centerMHz: Double = 1090.0
    var sampleRateMHz: Double = 2.0 {
        // Das 20-MHz-Filter gehört zur DVB-T2-Vorlage; bei anderer Rate wählt der HackRF selbst.
        didSet { if sampleRateHz != IQPreset.tvSampleRate { basebandFilterHz = nil } }
    }
    /// Basisbandfilter fest vorgegeben (nil = passend zur Rate).
    private(set) var basebandFilterHz: UInt32?
    /// Kanäle der Vorlagen.
    var tvChannel = TVChannel(number: 23)
    var dabChannel = DABChannel.named("5C")!
    var lnaGain = GainProfile.preset(.recorder).lna
    var vgaGain = GainProfile.preset(.recorder).vga
    var amplifier = GainProfile.preset(.recorder).amplifier
    var antennaPower = false
    /// Gleich als SigMF aufnehmen (`.sigmf-data` + `.sigmf-meta` statt `.c8`).
    var recordAsSigMF = UserDefaults.standard.bool(forKey: RecorderModel.sigmfKey) {
        didSet { UserDefaults.standard.set(recordAsSigMF, forKey: Self.sigmfKey) }
    }
    nonisolated static let sigmfKey = "recordAsSigMF"

    private(set) var recording = false
    private(set) var recordedBytes = 0
    private(set) var level = 0.0
    private(set) var error: String?

    // Wiedergabe
    private(set) var playing = false
    private(set) var progress = 0.0
    var analysis: Analysis = .spectrum
    private(set) var playbackSpectrum: [Float] = []
    private(set) var adsbResults: [Aircraft] = []
    /// Ergebnis des GPS-Empfängers (Kanäle, Position) nach der Wiedergabe.
    private(set) var gpsStatus: GPSReceiverStatus?
    private(set) var tvResult: TVOfflineResult?
    private(set) var dabResult: DABOfflineResult?
    private(set) var zigbeeResult: ZigbeeOfflineResult?
    var zigbeeChannel = UserDefaults.standard.object(forKey: ZigbeeModel.channelKey) as? Int ?? 11
    /// Hinweis, wenn Rate oder Mitte der Aufnahme nicht zur Auswertung passen.
    private(set) var playbackWarning: String?

    private(set) var recordings: [IQRecording] = []

    // SigMF-Import/-Export
    /// Laufende Umwandlung bzw. Kopie („SigMF importieren …“), nil = keine.
    private(set) var transferTitle: String?
    private(set) var transferProgress = 0.0
    /// Ergebnis der letzten Umwandlung (Hinweise des Imports, Zielort des Exports).
    private(set) var transferNotice: String?
    private var transferTask: Task<Void, Never>?
    /// Freier Platz im Aufnahmeordner (für die Höchstdauer).
    private(set) var freeBytes: Int64?

    private let recorder = IQRecorder()
    private let player = IQPlayer()
    private var meterTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    /// Zählt Wiedergaben hoch; Ergebnisse eines abgebrochenen Laufs werden verworfen.
    private var playGeneration = 0
    private weak var device: HackRFDevice?
    /// Die beim Start tatsächlich gesetzten Werte – maßgeblich für die Metadaten.
    private var active: IQRecording?

    init() { refresh() }

    func refresh() {
        recordings = IQStore.list()
        freeBytes = IQStore.availableBytes()
    }

    // MARK: Vorlagen

    private var sampleRateHz: UInt32 { UInt32((sampleRateMHz * 1_000_000).rounded()) }

    /// DVB-T2-Kanal: Rate, Mitte und Filter wie `TVModel.start`.
    func applyTVPreset() {
        sampleRateMHz = Double(IQPreset.tvSampleRate) / 1_000_000
        centerMHz = Double(IQPreset.tvCenter(tvChannel)) / 1_000_000
        basebandFilterHz = IQPreset.tvBasebandFilter
        analysis = .tv
    }

    /// DAB-Block: Rate und Mitte wie `DABModel.start`.
    func applyDABPreset() {
        sampleRateMHz = Double(IQPreset.dabSampleRate) / 1_000_000
        centerMHz = Double(dabChannel.frequency) / 1_000_000
        analysis = .dab
    }

    /// Zigbee-Kanal: Rate und Mitte wie `ZigbeeModel.start`.
    func applyZigbeePreset() {
        sampleRateMHz = Double(IQPreset.zigbeeSampleRate) / 1_000_000
        centerMHz = Double(IQPreset.zigbeeCenter(channel: zigbeeChannel)) / 1_000_000
        analysis = .zigbee
    }

    /// Datenrate der Aufnahme (ein IQ-Paar = 2 Byte).
    var bytesPerSecond: Double { sampleRateMHz * 2_000_000 }

    /// Höchstdauer bis zur Platzreserve (`IQRecorder.reserveBytes`), nil wenn unbekannt.
    var maxRecordingSeconds: Double? {
        guard let freeBytes, bytesPerSecond > 0 else { return nil }
        let usable = max(0, freeBytes - IQRecorder.reserveBytes)
        return Double(usable) / bytesPerSecond
    }

    // MARK: Aufnahme

    func startRecording(on device: HackRFDevice) {
        guard !recording else { return }
        let name = Self.timestampName()
        let sigmf = recordAsSigMF
        let url = sigmf ? IQStore.sigmfDataURL(for: name) : IQStore.dataURL(for: name)
        let centerHz = UInt64((centerMHz * 1_000_000).rounded())
        let sampleRate = sampleRateHz
        var fileCreated = false
        do {
            try device.setSampleRate(sampleRate)
            if let basebandFilterHz { try device.setBasebandFilter(basebandFilterHz) }
            try device.setFrequency(centerHz)
            try device.setLNAGain(Int(lnaGain))
            try device.setVGAGain(Int(vgaGain))
            try device.setAmplifier(amplifier)
            try device.setAntennaPower(antennaPower)
            try recorder.start(url: url)
            fileCreated = true
            let recorder = recorder
            try device.startReceiving(owner: self) { block in recorder.write(block) }
        } catch {
            if fileCreated { _ = recorder.stop() }
            try? FileManager.default.removeItem(at: url)
            self.error = error.localizedDescription
            return
        }
        self.device = device
        active = IQRecording(name: name, centerHz: centerHz, sampleRate: sampleRate, date: Date(), byteCount: 0,
                             lnaGain: Int(lnaGain), vgaGain: Int(vgaGain), amplifier: amplifier, sigmf: sigmf ? true : nil)
        recording = true
        error = nil
        recordedBytes = 0
        meterTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                self.recordedBytes = self.recorder.bytesWritten
                self.level = self.recorder.takePeak()
                ticks += 1
                if ticks % 25 == 0 { self.freeBytes = IQStore.availableBytes() }   // alle 5 s
                if let failure = self.recorder.failure {
                    self.stopRecording()
                    self.error = failure
                    return
                }
            }
        }
    }

    func stopRecording() {
        guard recording, var meta = active else { return }
        meterTask?.cancel(); meterTask = nil
        device?.stopReceiving(owner: self)
        let bytes = recorder.stop()
        recording = false
        level = 0
        active = nil
        guard bytes > 0 else {
            IQStore.delete(meta)
            refresh()
            return
        }
        meta.byteCount = bytes
        IQStore.save(meta)
        refresh()
    }

    // MARK: Wiedergabe

    func play(_ rec: IQRecording) {
        guard !playing, !recording else { return }
        playGeneration += 1
        let generation = playGeneration
        playing = true
        progress = 0
        playbackSpectrum = []
        adsbResults = []
        gpsStatus = nil
        tvResult = nil
        dabResult = nil
        zigbeeResult = nil
        let analysis = analysis
        playbackWarning = Self.mismatch(rec, for: analysis)
        let url = IQStore.dataURL(for: rec)
        let player = player

        playTask = Task.detached { [weak self] in
            let analyzer = SpectrumAnalyzer(fftSize: 1024)
            let demod = ADSBDemodulator()
            // GPS: ganzer Empfänger, Akquisition synchron (reproduzierbar).
            var gpsOptions = GPSReceiver.Options()
            gpsOptions.sampleRate = Double(rec.sampleRate)
            gpsOptions.asynchronousAcquisition = false
            gpsOptions.referenceDate = rec.date
            let receiver = GPSReceiver(options: gpsOptions)
            let tracker = TrackerBox()
            let tv = analysis == .tv ? TVOfflineDecoder() : nil
            let dab = analysis == .dab ? DABOfflineDecoder() : nil
            let zigbee = analysis == .zigbee ? ZigbeeOfflineDecoder(channel: IQPreset.zigbeeChannel(center: rec.centerHz)) : nil

            player.play(url: url, handler: { block in
                switch analysis {
                case .spectrum:
                    analyzer.process(block)
                case .adsb:
                    for m in demod.process(block) { tracker.ingest(m) }
                case .gps:
                    receiver.process(block)
                case .tv:
                    tv?.process(block)
                case .dab:
                    dab?.process(block)
                case .zigbee:
                    zigbee?.process(block)
                }
            }, progress: { [weak self] p in
                Task { @MainActor in
                    guard let self, self.playGeneration == generation, self.playing else { return }
                    self.progress = max(self.progress, p)
                }
            }, isCancelled: { Task.isCancelled })

            guard !Task.isCancelled else { return }
            let spectrum = analyzer.takeSpectrum() ?? []
            let planes = tracker.sorted
            let gps = receiver.status
            let tvResult = tv?.result(channel: IQPreset.tvChannel(center: rec.centerHz))
            let dabResult = dab?.result(channel: IQPreset.dabChannel(center: rec.centerHz))
            let zigbeeResult = zigbee?.result()
            await MainActor.run { [weak self] in
                guard let self, self.playGeneration == generation else { return }
                self.playbackSpectrum = spectrum
                self.adsbResults = planes
                self.gpsStatus = analysis == .gps ? gps : nil
                self.tvResult = tvResult
                self.dabResult = dabResult
                self.zigbeeResult = zigbeeResult
                self.playing = false
                self.progress = 1
            }
        }
    }

    func stopPlayback() {
        playTask?.cancel(); playTask = nil
        playGeneration += 1
        playing = false
    }

    func delete(_ rec: IQRecording) {
        IQStore.delete(rec)
        refresh()
    }

    // MARK: SigMF

    /// Kopiert die Aufnahme als `.sigmf-data` + `.sigmf-meta` nach `url`.
    func exportSigMF(_ rec: IQRecording, to url: URL) {
        guard transferTitle == nil else { return }
        transferTitle = String(localized: "Exportiere als SigMF …")
        transferProgress = 0
        transferNotice = nil
        let source = IQStore.dataURL(for: rec)
        transferTask = Task { [weak self] in
            let result = await Task.detached { () -> Result<(meta: URL, data: URL), Error> in
                Result { try SigMFTransfer.export(rec, from: source, to: url) }
            }.value
            guard let self else { return }
            self.transferTitle = nil
            switch result {
            case .success(let files):
                self.transferNotice = String(localized: "Gesichert: \(files.meta.lastPathComponent) und \(files.data.lastPathComponent)")
            case .failure(let error):
                self.error = error.localizedDescription
            }
        }
    }

    /// Wandelt eine SigMF-Aufnahme in die Ablage um (abseits des Main Actors).
    func importSigMF(from url: URL) {
        guard transferTitle == nil, !recording else { return }
        transferTitle = String(localized: "Importiere SigMF …")
        transferProgress = 0
        transferNotice = nil
        error = nil
        let folder = IQStore.folder
        let existing = Set(recordings.map(\.name)).union(
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { ($0 as NSString).deletingPathExtension })
        let name = SigMFTransfer.storeName(for: url, existing: existing)
        let report: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self, self.transferTitle != nil else { return }
                self.transferProgress = max(self.transferProgress, p)
            }
        }
        transferTask = Task { [weak self] in
            let worker = Task.detached { () -> Result<SigMFTransfer.ImportResult, Error> in
                Result {
                    try SigMFTransfer.importFile(at: url, into: folder, name: name, progress: report,
                                                 isCancelled: { Task.isCancelled })
                }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self else { return }
            self.transferTitle = nil
            self.refresh()
            switch result {
            case .success(let imported):
                var lines = imported.warnings
                if let hint = Self.analysisHint(imported.recording) { lines.append(hint) }
                self.transferNotice = ([String(localized: "Importiert als „\(imported.recording.name)“.")] + lines).joined(separator: "\n")
            case .failure(let error) where error is CancellationError:
                self.transferNotice = String(localized: "Import abgebrochen.")
            case .failure(let error):
                self.error = error.localizedDescription
            }
        }
    }

    func cancelTransfer() {
        transferTask?.cancel()
    }

    /// Welche Auswertungen passen zur Aufnahme? Die Dekoder erwarten feste
    /// Abtastraten (und meist eine bestimmte Mitte); das Spektrum geht immer.
    static func analysisHint(_ rec: IQRecording) -> String? {
        let fitting = Analysis.allCases.filter { $0 != .spectrum && mismatch(rec, for: $0) == nil }
        guard fitting.isEmpty else { return nil }
        return String(format: String(localized: "Mit %.3f MS/s bei %.3f MHz passt nur die Auswertung „Spektrum“ – die Dekoder erwarten feste Abtastraten und Mitten (siehe Vorlagen)."),
                      rec.sampleRateMHz, rec.centerMHz)
    }

    // MARK: Hilfen

    /// Kapselt den nicht-Sendable Tracker für die detachte Task.
    private final class TrackerBox: @unchecked Sendable {
        private var tracker = AircraftTracker()
        func ingest(_ m: ADSBMessage) { tracker.ingest(m) }
        var sorted: [Aircraft] { tracker.sorted }
    }

    /// Passt die Aufnahme zur gewählten Auswertung? Sonst ein Hinweis.
    static func mismatch(_ rec: IQRecording, for analysis: Analysis) -> String? {
        let expected: (rate: UInt32, center: UInt64?)
        switch analysis {
        case .spectrum: return nil
        case .adsb: expected = (ADSBDemodulator.sampleRate, ADSBDemodulator.frequency)
        case .gps:
            // Der Empfänger arbeitet mit Vielfachen von 2,048 MS/s (Akquisition dezimiert).
            expected = ([2_048_000, 4_096_000].contains(rec.sampleRate) ? rec.sampleRate : GPSModel.sampleRate,
                        GPSAcquirer.frequency)
        case .tv, .dab: expected = (analysis == .tv ? IQPreset.tvSampleRate : IQPreset.dabSampleRate, nil)
        case .zigbee: expected = (IQPreset.zigbeeSampleRate, nil)
        }
        var problems: [String] = []
        if rec.sampleRate != expected.rate {
            problems.append(String(format: String(localized: "Abtastrate %.3f statt %.3f MS/s"), rec.sampleRateMHz, Double(expected.rate) / 1_000_000))
        }
        // Wenige kHz Versatz verkraften beide Verfahren (Doppler-Suche bzw. Präambel).
        if let center = expected.center, abs(Double(rec.centerHz) - Double(center)) > 5_000 {
            problems.append(String(format: String(localized: "Mitte %.3f statt %.3f MHz"), rec.centerMHz, Double(center) / 1_000_000))
        }
        // Fernsehen: HackRF ein Viertel der Rate über einer Kanalmitte; DAB: auf einer Blockmitte.
        if analysis == .tv, IQPreset.tvChannel(center: rec.centerHz) == nil {
            problems.append(String(format: String(localized: "Mitte %.3f MHz ist keine Kanalmitte + %.3f MHz (Vorlage „DVB-T2-Kanal“)"),
                                   rec.centerMHz, T2FrontEnd.tuningOffset / 1_000_000))
        }
        if analysis == .zigbee, IQPreset.zigbeeChannel(center: rec.centerHz) == nil {
            problems.append(String(format: String(localized: "Mitte %.3f MHz liegt nicht 2 MHz unter einem Zigbee-Kanal (Vorlage „Zigbee-Kanal“)"), rec.centerMHz))
        }
        if analysis == .dab, IQPreset.dabChannel(center: rec.centerHz) == nil {
            problems.append(String(format: String(localized: "Mitte %.3f MHz ist kein DAB-Block (Vorlage „DAB-Block“)"), rec.centerMHz))
        }
        guard !problems.isEmpty else { return nil }
        let details = problems.joined(separator: ", ")
        return String(localized: "Die Aufnahme passt nicht zu „\(analysis.title)“ (\(details)) – die Ergebnisse sind unbrauchbar.")
    }

    private static func timestampName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "IQ_" + f.string(from: Date())
    }
}

/// Damit die Aufnahme dieselben Regler (`ReceiverControls`) wie die
/// Empfängerseiten nutzt. „Empfang läuft“ heißt hier: es wird aufgenommen.
extension RecorderModel: GainTunable {
    var running: Bool { recording }
    /// Kein Dekoder – „Signal optimieren“ stellt nur den Pegel ein.
    var quality: GainQuality? { nil }
    var idleHint: String { String(localized: "Die Aufnahme speichert alles, was ankommt – auch Rauschen.") }
    /// Die Automatik regelt während einer Aufnahme nicht nach: Pegelsprünge in
    /// der Datei würden die Offline-Auswertung verfälschen.
    var wantsAutoGain: Bool { false }

    func applyTunedGains(_ device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }
}
