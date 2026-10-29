import Foundation
import Observation
import os

/// Eine gespeicherte Messung der Wasserstofflinie.
struct HydrogenMeasurement: Codable, Identifiable, Sendable, Hashable {
    var id = UUID()
    var name: String
    /// Mitte der Integration.
    var date: Date
    var seconds: Double
    var method: HydrogenMethod
    var azimuth: Double
    var elevation: Double
    var l: Double
    var b: Double
    var ra: Double
    var dec: Double
    /// v_LSR = v_topozentrisch + lsrCorrection (km/s).
    var lsrCorrection: Double
    var startHz: Double
    var stepHz: Double
    /// Rohwerte relativ zu T_sys; `nil` = ungültig.
    var values: [Float?]

    var spectrum: HydrogenSpectrum {
        HydrogenSpectrum(startHz: startHz, stepHz: stepHz, values: values.map { $0.map(Double.init) ?? .nan })
    }
}

/// Ablage der Messungen als JSON unter Application Support.
struct HydrogenStore: Sendable {
    let folder: URL

    static let shared = HydrogenStore(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("de.christiangolz.portapackmanager/Wasserstofflinie", isDirectory: true))

    func loadAll() -> [HydrogenMeasurement] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(HydrogenMeasurement.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    func save(_ m: HydrogenMeasurement) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(m).write(to: folder.appendingPathComponent("\(m.id.uuidString).json"), options: .atomic)
    }

    func delete(_ m: HydrogenMeasurement) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(m.id.uuidString).json"))
    }
}

/// Wasserstofflinie: lange Integration gemittelter FFT-Spektren um
/// 1420,405752 MHz mit Grundlinienkorrektur.
///
/// **Gerätebesitz** wie beim Belegungsmonitor: läuft weiter, wenn man die Seite
/// verlässt; übernimmt jemand anderes den HackRF, pausiert die Integration mit
/// Hinweis – die bisherigen Summen bleiben, „Fortsetzen“ integriert weiter.
///
/// Bewusst **ohne** Verstärkungsautomatik (kein `GainTunable`): Ändert sich die
/// Verstärkung mitten in einer Integration, passen die Summen nicht mehr
/// zusammen. Die Regler wirken nur auf den eigenen Empfang.
@MainActor
@Observable
final class HydrogenModel {
    static let shared = HydrogenModel()
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Wasserstofflinie")

    nonisolated static let sampleRate = 5_000_000.0
    static let settle = Duration.milliseconds(120)

    enum Capture: Sendable { case signal, reference }

    // MARK: Einstellungen

    var method: HydrogenMethod { didSet { save() } }
    var integrationMinutes: Double { didSet { save() } }
    var switchSeconds: Double { didSet { save() } }
    var offsetMHz: Double { didSet { save() } }
    var fftSize: Int { didSet { save() } }
    var azimuth: Double { didSet { save() } }
    var elevation: Double { didSet { save() } }
    var showVelocity: Bool { didSet { save() } }
    var smoothingKHz: Double { didSet { save() } }
    var baselineOrder: Int { didSet { save() } }
    var excludeKmS: Double { didSet { save() } }
    var rangeKmS: Double { didSet { save() } }

    var lnaGain: Double
    var vgaGain: Double
    var amplifier: Bool
    var antennaPower: Bool { didSet { UserDefaults.standard.set(antennaPower, forKey: "hydrogenAntennaPower") } }

    // MARK: Zustand

    private(set) var running = false
    private(set) var capture = Capture.signal
    private(set) var pausedReason: String?
    private(set) var error: String?
    private(set) var startedAt: Date?
    /// Integrierte Zeit (s) der Messung (A+B bzw. Signal) und der Referenz.
    private(set) var signalSeconds = 0.0
    private(set) var referenceSeconds = 0.0
    private(set) var cycles = 0
    /// Aktuelles (Live-)Spektrum, roh.
    private(set) var current: HydrogenSpectrum?
    private(set) var measurements: [HydrogenMeasurement] = []
    var visible: Set<UUID> = []
    private(set) var lastSaved: String?

    @ObservationIgnored private var accumulator: HydrogenAccumulator?
    /// Einstellungen, mit denen die Summen entstanden – Fortsetzen nur, wenn gleich.
    @ObservationIgnored private var accumulatorKey: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var device: HackRFDevice?
    let store: HydrogenStore

    init(store: HydrogenStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        method = HydrogenMethod(rawValue: defaults.string(forKey: "hydrogenMethod") ?? "") ?? .frequencySwitching
        integrationMinutes = defaults.object(forKey: "hydrogenMinutes") as? Double ?? 10
        switchSeconds = defaults.object(forKey: "hydrogenSwitchSeconds") as? Double ?? 1
        offsetMHz = defaults.object(forKey: "hydrogenOffsetMHz") as? Double ?? 1.0
        fftSize = defaults.object(forKey: "hydrogenFFT") as? Int ?? 4096
        azimuth = defaults.object(forKey: "hydrogenAzimuth") as? Double ?? 180
        elevation = defaults.object(forKey: "hydrogenElevation") as? Double ?? 45
        showVelocity = defaults.object(forKey: "hydrogenShowVelocity") as? Bool ?? true
        smoothingKHz = defaults.object(forKey: "hydrogenSmoothingKHz") as? Double ?? 10
        baselineOrder = defaults.object(forKey: "hydrogenBaselineOrder") as? Int ?? 1
        excludeKmS = defaults.object(forKey: "hydrogenExcludeKmS") as? Double ?? 150
        rangeKmS = defaults.object(forKey: "hydrogenRangeKmS") as? Double ?? 250
        // L-Band wie GPS: hohe Verstärkung, der Abstand zum Rauschen ist winzig.
        let preset = GainProfile.preset(.gps)
        lnaGain = preset.lna
        vgaGain = preset.vga
        amplifier = preset.amplifier
        antennaPower = defaults.bool(forKey: "hydrogenAntennaPower")
        measurements = store.loadAll()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(method.rawValue, forKey: "hydrogenMethod")
        d.set(integrationMinutes, forKey: "hydrogenMinutes")
        d.set(switchSeconds, forKey: "hydrogenSwitchSeconds")
        d.set(offsetMHz, forKey: "hydrogenOffsetMHz")
        d.set(fftSize, forKey: "hydrogenFFT")
        d.set(azimuth, forKey: "hydrogenAzimuth")
        d.set(elevation, forKey: "hydrogenElevation")
        d.set(showVelocity, forKey: "hydrogenShowVelocity")
        d.set(smoothingKHz, forKey: "hydrogenSmoothingKHz")
        d.set(baselineOrder, forKey: "hydrogenBaselineOrder")
        d.set(excludeKmS, forKey: "hydrogenExcludeKmS")
        d.set(rangeKmS, forKey: "hydrogenRangeKmS")
    }

    // MARK: Ort und Ausrichtung

    var home: (latitude: Double, longitude: Double)? {
        let lat = UserDefaults.standard.double(forKey: "homeLat"), lon = UserDefaults.standard.double(forKey: "homeLon")
        return lat == 0 && lon == 0 ? nil : (lat, lon)
    }

    func pointing(at date: Date = Date()) -> HydrogenAstronomy.Pointing? {
        guard let home else { return nil }
        return HydrogenAstronomy.pointing(.init(azimuth: azimuth, elevation: elevation),
                                          latitude: home.latitude, longitude: home.longitude, date: date)
    }

    var localOscillators: (a: Double, b: Double) {
        HydrogenProcessing.localOscillators(centerHz: HydrogenAstronomy.restFrequencyHz, offsetHz: offsetMHz * 1e6,
                                            sampleRate: Self.sampleRate, fftSize: fftSize)
    }

    private var settingsKey: String { "\(method.rawValue)/\(fftSize)/\(offsetMHz)" }

    var targetSeconds: Double { integrationMinutes * 60 }

    var hasReference: Bool { method == .reference && referenceSeconds > 0 }

    /// Kann die bisherige Integration fortgesetzt werden?
    var canContinue: Bool { accumulator != nil && accumulatorKey == settingsKey && signalSeconds > 0 }

    // MARK: Empfang

    func start(on device: HackRFDevice, capture: Capture = .signal, fresh: Bool = false) {
        guard !running else { return }
        if accumulator == nil || accumulatorKey != settingsKey {
            accumulator = HydrogenAccumulator(fftSize: fftSize)
            accumulatorKey = settingsKey
            signalSeconds = 0
            referenceSeconds = 0
            current = nil
        }
        guard let accumulator else { return }
        if capture == .reference {
            accumulator.resetB()
            referenceSeconds = 0
        } else if fresh {
            accumulator.resetA()
            if method == .frequencySwitching { accumulator.resetB() }
            signalSeconds = 0
            current = nil
            cycles = 0
        }
        do {
            try device.setSampleRate(UInt32(Self.sampleRate))
            try device.setBasebandFilter(5_000_000)
            try applyGains(device)
            try device.setFrequency(UInt64(localOscillators.a.rounded()))
            accumulator.setPhase(.off)
            try device.startReceiving(owner: self) { accumulator.process($0) }
        } catch {
            self.error = error.localizedDescription
            return
        }
        self.device = device
        self.capture = capture
        running = true
        pausedReason = nil
        error = nil
        lastSaved = nil
        startedAt = startedAt ?? Date()
        if fresh || capture == .reference { startedAt = Date() }
        Self.log.notice("Start \(capture == .reference ? "Referenz" : "Messung", privacy: .public), \(self.method.rawValue, privacy: .public), FFT \(self.fftSize)")
        task = Task { [weak self] in await self?.loop(device: device, accumulator: accumulator, capture: capture) }
    }

    func stop() {
        task?.cancel()
        task = nil
        accumulator?.setPhase(.off)
        device?.stopReceiving(owner: self)
        finish(reason: nil)
    }

    /// Integration verwerfen (neue Messung).
    func discard() {
        guard !running else { return }
        accumulator = nil
        accumulatorKey = nil
        signalSeconds = 0
        referenceSeconds = 0
        current = nil
        cycles = 0
        startedAt = nil
        pausedReason = nil
    }

    private func finish(reason: String?) {
        accumulator?.setPhase(.off)
        running = false
        device = nil
        task = nil
        pausedReason = reason
        updateCurrent()
        if let reason { Self.log.notice("Pause: \(reason, privacy: .public)") }
    }

    private func loop(device: HackRFDevice, accumulator: HydrogenAccumulator, capture: Capture) async {
        let los = localOscillators
        var phaseIsA = true
        var lastUpdate = Date.distantPast
        while !Task.isCancelled {
            guard device.isReceiving(for: self) else {
                let owner = device.currentOwner
                finish(reason: owner == nil
                       ? String(localized: "Der Empfang ist abgerissen oder das Gerät wurde getrennt. Die bisherige Messung bleibt – „Fortsetzen“ macht weiter.")
                       : String(localized: "Der HackRF empfängt jetzt für \(DeviceArbiter.title(of: owner)). Die bisherige Messung bleibt – „Fortsetzen“ macht weiter."))
                return
            }
            if device.isStalled(for: self) {
                device.stopReceiving(owner: self)
                do { try device.startReceiving(owner: self) { accumulator.process($0) } } catch {
                    finish(reason: String(localized: "Neustart des Empfangs fehlgeschlagen: \(error.localizedDescription)"))
                    return
                }
            }
            // Welche Phase als Nächstes? Umschaltung: A/B im Wechsel. Referenzverfahren:
            // Signal in A, Referenz in B – beide bei LO_A.
            let phase: HydrogenAccumulator.Phase
            let lo: Double
            switch (method, capture) {
            case (.frequencySwitching, _): phase = phaseIsA ? .a : .b; lo = phaseIsA ? los.a : los.b
            case (.reference, .signal): phase = .a; lo = los.a
            case (.reference, .reference): phase = .b; lo = los.a
            }
            accumulator.setPhase(.off)
            do { try device.setFrequency(UInt64(lo.rounded())) } catch {
                finish(reason: String(localized: "Umstimmen fehlgeschlagen: \(error.localizedDescription)"))
                return
            }
            try? await Task.sleep(for: Self.settle)
            accumulator.setPhase(phase)
            // Eine Halbperiode, dabei jede Sekunde die Anzeige auffrischen.
            let end = Date().addingTimeInterval(switchSeconds)
            while Date() < end, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if Date().timeIntervalSince(lastUpdate) >= 1 {
                    lastUpdate = Date()
                    updateCurrent()
                }
            }
            accumulator.setPhase(.off)
            phaseIsA.toggle()
            if phaseIsA || method == .reference { cycles += 1 }
            updateCurrent()
            let done = capture == .reference ? referenceSeconds >= targetSeconds : signalSeconds >= targetSeconds
            if done {
                device.stopReceiving(owner: self)
                finish(reason: nil)
                if capture == .signal { saveMeasurement() }
                return
            }
        }
    }

    /// Summen auslesen, Zeiten und Live-Spektrum rechnen.
    private func updateCurrent() {
        guard let accumulator else { return }
        let snap = accumulator.snapshot()
        let frameSeconds = Double(fftSize) / Self.sampleRate
        let los = localOscillators
        switch method {
        case .frequencySwitching:
            signalSeconds = Double(snap.countA + snap.countB) * frameSeconds
            if snap.countA > 0, snap.countB > 0 {
                current = HydrogenProcessing.fold(a: snap.a, b: snap.b, loA: los.a, loB: los.b, sampleRate: Self.sampleRate)
            }
        case .reference:
            signalSeconds = Double(snap.countA) * frameSeconds
            referenceSeconds = Double(snap.countB) * frameSeconds
            if snap.countA > 0, snap.countB > 0 {
                current = HydrogenProcessing.referenceRatio(signal: snap.a, reference: snap.b, lo: los.a, sampleRate: Self.sampleRate)
            }
        }
    }

    // MARK: Messreihen

    /// Speichert das aktuelle Spektrum als Messung.
    @discardableResult
    func saveMeasurement(name: String? = nil) -> HydrogenMeasurement? {
        updateCurrent()
        guard let current, !current.values.isEmpty else { return nil }
        let mid = Date().addingTimeInterval(-signalSeconds / 2)
        let pointing = pointing(at: mid)
        let title = name?.trimmingCharacters(in: .whitespaces).isEmpty == false ? name! :
            (pointing.map { String(format: "l = %.0f°, b = %.0f°", $0.galactic.l, $0.galactic.b) } ?? String(localized: "Messung")) + " · " + mid.formatted(date: .abbreviated, time: .shortened)
        let m = HydrogenMeasurement(name: title, date: mid, seconds: signalSeconds, method: method,
                                    azimuth: azimuth, elevation: elevation,
                                    l: pointing?.galactic.l ?? .nan, b: pointing?.galactic.b ?? .nan,
                                    ra: pointing?.j2000.ra ?? .nan, dec: pointing?.j2000.dec ?? .nan,
                                    lsrCorrection: pointing?.lsr.total ?? 0,
                                    startHz: current.startHz, stepHz: current.stepHz,
                                    values: current.values.map { $0.isFinite ? Float($0) : nil })
        do {
            try store.save(m)
            measurements.insert(m, at: 0)
            visible.insert(m.id)
            lastSaved = String(localized: "Gespeichert: \(m.name)")
        } catch {
            self.error = String(localized: "Speichern fehlgeschlagen: \(error.localizedDescription)")
        }
        return m
    }

    func delete(_ m: HydrogenMeasurement) {
        store.delete(m)
        measurements.removeAll { $0.id == m.id }
        visible.remove(m.id)
    }

    /// LSR-Korrektur für das Live-Spektrum (jetzt, aktuelle Ausrichtung).
    var currentLSRCorrection: Double { pointing()?.lsr.total ?? 0 }

    func curve(for spectrum: HydrogenSpectrum, lsr: Double) -> HydrogenProcessing.Curve {
        HydrogenProcessing.curve(spectrum, lsrCorrection: lsr, smoothingKHz: smoothingKHz,
                                 baselineOrder: baselineOrder, excludeKmS: excludeKmS)
    }

    /// CSV der sichtbaren Messungen (und des Live-Spektrums), Langformat.
    func csv() -> String {
        var out = "messung;frequenz_mhz;v_lsr_kms;roh_prozent;aufbereitet_prozent\n"
        var series: [(String, HydrogenSpectrum, Double)] = []
        if let current { series.append(("aktuell", current, currentLSRCorrection)) }
        for m in measurements where visible.contains(m.id) { series.append((m.name, m.spectrum, m.lsrCorrection)) }
        for (name, spectrum, lsr) in series {
            let c = curve(for: spectrum, lsr: lsr)
            let label = name.replacingOccurrences(of: ";", with: ",")
            for i in spectrum.values.indices {
                let raw = spectrum.values[i].isFinite ? String(format: "%.5f", spectrum.values[i] * 100) : ""
                let processed = c.values[i].isFinite ? String(format: "%.5f", c.values[i] * 100) : ""
                out += "\(label);\(String(format: "%.6f", c.mhz[i]));\(String(format: "%.3f", c.velocity[i]));\(raw);\(processed)\n"
            }
        }
        return out
    }

    // MARK: Verstärkung (nur eigener Empfang)

    func applyGains(_ device: HackRFDevice) throws {
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    /// Regler der Seite: wirken nur auf den eigenen, laufenden Empfang.
    func applyFromControls(_ device: HackRFDevice?) {
        guard running, let device, device.isReceiving(for: self) else { return }
        try? applyGains(device)
    }
}
