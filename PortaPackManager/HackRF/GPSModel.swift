import Foundation
import Observation

/// GPS-L1-Empfang im HackRF-Modus: Akquisition, Tracking, Navigationsnachricht
/// und Positionsbestimmung (`GPSReceiver`).
@MainActor
@Observable
final class GPSModel {
    var lnaGain = GainProfile.preset(.gps).lna
    var vgaGain = GainProfile.preset(.gps).vga
    var amplifier = GainProfile.preset(.gps).amplifier
    var antennaPower = false      // Bias-Tee für aktive GPS-Antenne
    /// Schwachsignal-Suche (lange Integration) zusätzlich zur Grobsuche – ab Werk an.
    var weakSearch = UserDefaults.standard.object(forKey: GPSModel.weakSearchKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(weakSearch, forKey: Self.weakSearchKey)
            shared.receiver.setWeakSearch(weakSearch)
        }
    }

    private(set) var running = false
    private(set) var status = GPSReceiverStatus()
    private(set) var error: String?

    private let shared = Shared()
    private var pollTask: Task<Void, Never>?
    private weak var device: HackRFDevice?
    /// Hilfsdaten vom Start (zum Zusammenführen beim Speichern).
    private var loadedAiding: GPSAidingData?
    private var lastAidingSave = Date.distantPast

    private static let weakSearchKey = "gpsWeakSearch"

    private final class Shared: @unchecked Sendable {
        let receiver = GPSReceiver()
    }

    /// Abtastrate des Empfängers: 4,096 MS/s – doppelt so fein wie die reine
    /// Akquisition, das verbessert die Codephasen- und damit Distanzmessung.
    static var sampleRate: UInt32 { UInt32(GPSReceiver.Options().sampleRate) }

    /// Ablage der Hilfsdaten (Bahnen, Almanach, letzte Position) zwischen den Läufen.
    static var aidingURL: URL { AppFiles.support.appendingPathComponent(GPSAidingData.fileName) }

    var trackedCount: Int { status.channels.filter { $0.state >= .tracking }.count }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            shared.receiver.reset()
            status = GPSReceiverStatus()
            // Warmstart: gespeicherte Bahnen und Position, sonst der eigene Standort
            // aus den Einstellungen; dazu die Systemuhr – daraus sagt der Empfänger
            // sichtbare Satelliten und ihren Doppler voraus und sucht gezielt.
            let aiding = GPSAidingData.load(from: Self.aidingURL)
            loadedAiding = aiding
            let lat = UserDefaults.standard.double(forKey: "homeLat"), lon = UserDefaults.standard.double(forKey: "homeLon")
            let home = lat == 0 && lon == 0 ? nil : GPSGeo.ecef(lat: lat * .pi / 180, lon: lon * .pi / 180, height: 0)
            shared.receiver.configure(aiding: aiding, time: Date(), home: home, weakSearch: weakSearch)
            try device.setSampleRate(Self.sampleRate)
            try device.setFrequency(GPSAcquirer.frequency)
            try applyGains()
            let shared = shared
            try device.startReceiving(owner: self) { block in shared.receiver.process(block) }
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    self.status = self.shared.receiver.status
                    if Date().timeIntervalSince(self.lastAidingSave) > 60 { self.saveAiding() }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        device?.stopReceiving(owner: self)
        if running { saveAiding() }
        running = false
    }

    /// Schreibt die Hilfsdaten, wenn der Lauf etwas Neues gelernt hat.
    private func saveAiding() {
        lastAidingSave = Date()
        var data = shared.receiver.aidingData
        if let loadedAiding {
            data = data.merged(over: loadedAiding)
            data.savedAt = loadedAiding.savedAt
            guard data != loadedAiding else { return }
        }
        guard !data.isEmpty else { return }
        data.savedAt = Date()
        try? data.save(to: Self.aidingURL)
        loadedAiding = data
    }

    func applyGains() throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }
}
