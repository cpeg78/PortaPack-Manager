import Foundation
import Observation
import os

/// DSC-Empfang im HackRF-Modus: UKW-Kanal 70 (156,525 MHz), FM, AFSK 1200 Bd,
/// Rufe nach ITU-R M.493.
///
/// Eigener Empfang, nicht zusammen mit AIS: `FMChannelizer` arbeitet mit
/// 2,4 MS/s und ±120 kHz Kanalbereich; für AIS (162 MHz) und Kanal 70 zugleich
/// (≈ 5,5 MHz Abstand) bräuchte es ≥ 8 MS/s und eine andere Vorstufe – die
/// live bestätigte AIS-Kette wäre dafür umzubauen (siehe `ADS-B-AIS-Archiv.md`).
@MainActor
@Observable
final class DSCModel {
    static let shared = DSCModel()
    nonisolated static let frequencyMHz = 156.525

    // Gleiches Band wie AIS – dessen Verstärkungsvorgaben passen.
    var lnaGain = GainProfile.preset(.ais).lna
    var vgaGain = GainProfile.preset(.ais).vga
    var amplifier = GainProfile.preset(.ais).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne

    private(set) var running = false
    private(set) var entries: [DSCLogEntry] = []
    private(set) var callCount = 0
    private(set) var correctedSymbols = 0
    private(set) var signalDB: Float = -100
    private(set) var error: String?

    private let shared = Shared()
    private var updateTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "DSC")

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let front = FMChannelizer(channelOffsets: [0], stage1Cutoff: 50_000, channelCutoff: 8_000)
        let demod = DSCDemodulator()
        var callLog = DSCCallLog()
        var fresh: [DSCCall] = []
        var count = 0
        var corrected = 0
        var power: Float = -100
    }

    var distressCount: Int { entries.filter { $0.call.concernsDistress }.count }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            try device.setSampleRate(UInt32(FMChannelizer.inputRate))
            try device.setFrequency(UInt64(Self.frequencyMHz * 1_000_000 - FMChannelizer.offset))
            try applyGains(to: device)
            let shared = shared
            shared.front.reset()
            shared.demod.reset()
            try device.startReceiving(owner: self) { block in
                let disc = shared.front.process(block)[0]
                let frames = shared.demod.process(disc)
                let power = shared.front.channelPowerDB.first ?? -100
                shared.lock.withLock {
                    shared.power = power
                    for frame in frames {
                        guard let call = DSCCall.parse(frame.symbols) else { continue }
                        shared.count += 1
                        shared.corrected += frame.corrected
                        if shared.callLog.ingest(call, corrected: frame.corrected) { shared.fresh.append(call) }
                    }
                }
            }
            running = true
            error = nil
            Self.log.notice("Empfang gestartet")
            updateTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self else { return }
                    let (entries, count, corrected, fresh, power) = self.shared.lock.withLock {
                        defer { self.shared.fresh.removeAll() }
                        return (self.shared.callLog.entries, self.shared.count, self.shared.corrected, self.shared.fresh, self.shared.power)
                    }
                    if count != self.callCount {
                        self.entries = entries
                        self.callCount = count
                        self.correctedSymbols = corrected
                    }
                    for call in fresh { self.announce(call) }
                    self.signalDB = power
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop(on device: HackRFDevice?) {
        updateTask?.cancel()
        updateTask = nil
        device?.stopReceiving(owner: self)
        running = false
    }

    func applyGains(to device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    func clear() {
        shared.lock.withLock { shared.callLog = DSCCallLog() }
        entries = []
    }

    /// Neuer Ruf: ins Systemprotokoll, Notfälle als Benachrichtigung.
    private func announce(_ call: DSCCall) {
        Self.log.notice("\(call.kindText, privacy: .public) von \(call.sender, privacy: .public) (\(call.format.title, privacy: .public))")
        guard call.concernsDistress, !call.isTest else { return }
        Notifier.shared.dscDistress(kind: call.kindText, nature: call.natureText,
                                    key: "\(call.distressID ?? call.sender)-\(call.firstCommand ?? 0)-\(call.nature ?? 0)")
    }
}

extension DSCModel: GainTunable {
    var idleHint: String { String(localized: "Seefunk-Rufe sind selten – meist Tests und Routinerufe, nahe der Küste einige pro Stunde.") }
    var activity: Int? { callCount }
    var quality: GainQuality? { nil }   // zu selten für einen Vergleich in Sekunden
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}

// MARK: - Schiffsnamen aus AIS

/// Name zu einer MMSI aus den AIS-Daten: zuerst die laufende AIS-Seite, dann
/// das AIS-Archiv der letzten sieben Tage (`TrafficArchive.ais`). Ein eigenes
/// Schiffsregister gibt es nicht – das Archiv ist die einzige dauerhafte Quelle.
@MainActor
enum ShipNameDirectory {
    /// Beobachtbar, damit die DSC-Liste nachzieht, sobald das Archiv geladen ist.
    @MainActor @Observable
    final class Store {
        var archived: [Int: String] = [:]
        @ObservationIgnored var loaded: Date?
        @ObservationIgnored var loading = false
    }

    static let store = Store()

    static func name(for mmsi: Int) -> String? {
        if let station = MaritimeIdentity.stations[mmsi] { return station }
        if let live = RemoteHub.shared.ais.vessels.first(where: { $0.mmsi == mmsi })?.name, !live.isEmpty { return live }
        refreshIfNeeded()
        return store.archived[mmsi]
    }

    /// Baut die Namensliste im Hintergrund auf. Früher las der erste Aufruf aus dem
    /// View-Body bis zu sieben Tage AIS-Archiv synchron (Review 28.10.2026, Y16).
    private static func refreshIfNeeded() {
        if store.loading { return }
        if let loaded = store.loaded, Date().timeIntervalSince(loaded) < 300 { return }
        store.loading = true
        Task {
            let sightings = await TrafficArchive.ais.sightings(since: Date().addingTimeInterval(-7 * 86_400))
            store.archived = names(from: sightings)
            store.loaded = Date()
            store.loading = false
        }
    }

    /// MMSI → Name; neuere Sichtungen gewinnen.
    nonisolated static func names(from sightings: [ArchiveSighting]) -> [Int: String] {
        var map: [Int: String] = [:]
        for sighting in sightings.sorted(by: { $0.last < $1.last }) {
            if let mmsi = Int(sighting.key), let name = sighting.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                map[mmsi] = name
            }
        }
        return map
    }
}
