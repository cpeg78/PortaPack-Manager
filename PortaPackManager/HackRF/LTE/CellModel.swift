import Foundation
import Observation
import os

/// Eine Mobilfunkzelle in der Liste der Seite.
struct LTECell: Identifiable, Sendable, Equatable {
    var band: Int
    var earfcn: Int
    var frequencyMHz: Double
    var pci: Int
    var mib: LTEMIB
    var extendedCP: Bool
    var tdd: Bool
    var measurement: LTEMeasurement?
    var cfoHz: Double
    var sib1: LTESIB1?
    /// Warum SIB1 fehlt (ehrlich: nicht versucht, nicht gefunden, nicht dekodierbar).
    var sib1Note: String?
    var firstSeen: Date
    var lastSeen: Date

    var id: String { "\(earfcn)-\(pci)" }
    var bandwidthMHz: Double { mib.bandwidthMHz }
    var cellIdentityText: String? {
        guard let sib1 else { return nil }
        return "\(sib1.enbID)-\(sib1.localCellID)"
    }
}

/// Ein Messpunkt beim Beobachten einer Zelle.
struct LTELevelSample: Identifiable, Sendable, Equatable {
    var date: Date
    var rsrpDBFS: Double?
    var sinrDB: Double?
    var rsrqDB: Double?
    var id: Date { date }
}

/// Grobes Spektrum eines Bandes für die Übersicht (100-kHz-Raster).
struct LTEBandSpectrum: Sendable, Equatable {
    var band: Int
    var points: [SpectrumPoint]

    struct SpectrumPoint: Identifiable, Sendable, Equatable {
        var mhz: Double
        var db: Double
        var id: Double { mhz }
    }
}

/// Seite „Mobilfunkzellen (LTE)“: Suchlauf über die deutschen LTE-Bänder,
/// PSS/SSS/MIB je Träger, auf Wunsch SIB1 (Netzbetreiber, TAC, Zellkennung),
/// Beobachten einer Zelle (Pegel über die Zeit).
///
/// Gelesen werden nur die öffentlichen Rundsendekanäle der Basisstationen.
@MainActor
@Observable
final class CellModel {
    static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "LTE")
    static let bandsKey = "lteBands"
    static let sib1Key = "lteReadSIB1"

    /// Obergrenze der LNA-Stufe. Die Aufnahmen nehmen je Band selbst zurück
    /// (`bandLNA`); wer den Regler bewegt, setzt diese Rücknahmen zurück.
    var lnaGain = GainProfile.preset(.cells).lna {
        didSet { if lnaGain != oldValue { bandLNA = [:] } }
    }
    var vgaGain = GainProfile.preset(.cells).vga
    var amplifier = GainProfile.preset(.cells).amplifier
    var antennaPower = false

    /// Gewählte Bänder (Vorgabe: alle außer B28).
    var bands: Set<Int> = {
        if let stored = UserDefaults.standard.array(forKey: CellModel.bandsKey) as? [Int] { return Set(stored) }
        return [20, 8, 3, 1, 7]
    }() {
        didSet { UserDefaults.standard.set(Array(bands), forKey: Self.bandsKey) }
    }
    var readSIB1: Bool = UserDefaults.standard.object(forKey: CellModel.sib1Key) as? Bool ?? true {
        didSet { UserDefaults.standard.set(readSIB1, forKey: Self.sib1Key) }
    }

    private(set) var cells: [LTECell] = []
    private(set) var running = false
    private(set) var progress = 0.0
    private(set) var status = ""
    private(set) var error: String?
    private(set) var clipped = 0.0
    private(set) var spectra: [Int: LTEBandSpectrum] = [:]
    /// Geschätzte Taktabweichung des HackRF (ppm) aus der Ablage gefundener Zellen.
    private(set) var ppm: Double?
    private(set) var scansCompleted = 0

    private(set) var observing: LTECell.ID?
    private(set) var history: [LTELevelSample] = []

    private var task: Task<Void, Never>?
    private weak var device: HackRFDevice?
    /// Kennung des laufenden Laufs. Ein abgebrochener alter Task räumt nur auf,
    /// wenn er noch der aktuelle ist – sonst setzte sein Ende den gerade
    /// gestarteten neuen Lauf zurück (Review 28.10.2026, W4).
    private var runID: UUID?
    /// Ob im laufenden Lauf schon aufgenommen wurde. Die erste Aufnahme darf
    /// das Gerät übernehmen; jede weitere prüft vorher den Besitz (W2).
    private var claimed = false
    /// LNA-Stufe je Band nach Rücknahmen wegen Übersteuerung (Y12). Steigt bei
    /// zu leisem Pegel wieder an, höchstens bis `lnaGain`.
    private(set) var bandLNA: [Int: Double] = [:]

    // MARK: Steuerung

    func start(on device: HackRFDevice) {
        guard !running else { return }
        begin(device) { model, device in try await model.scan(device) }
    }

    func check(frequencyMHz: Double, on device: HackRFDevice) {
        guard !running else { return }
        begin(device) { model, device in try await model.checkSingle(frequencyMHz, device) }
    }

    func observe(_ cell: LTECell, on device: HackRFDevice) {
        if running { stop() }
        observing = cell.id
        history = []
        begin(device) { model, device in try await model.observeLoop(cell, device) }
    }

    func stop() {
        task?.cancel()
        task = nil
        runID = nil
        device?.stopReceiving(owner: self)
        device?.releaseBurstReservation(owner: self)
        if running { status = String(localized: "Angehalten.") }
        running = false
        observing = nil
    }

    func clear() {
        cells = []
        spectra = [:]
        history = []
    }

    private func begin(_ device: HackRFDevice, _ work: @escaping @MainActor (CellModel, HackRFDevice) async throws -> Void) {
        self.device = device
        let run = UUID()
        runID = run
        claimed = false
        running = true
        error = nil
        progress = 0
        // Abtastrate, Filter und Verstärkung setzt jede Aufnahme selbst, erst
        // nachdem sie das Gerät übernommen hat (`capture`).
        device.reserveForBursts(owner: self)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self, device)
            } catch is CancellationError {
            } catch {
                if self.runID == run {
                    self.error = error.localizedDescription
                }
                Self.log.error("\(error.localizedDescription, privacy: .public)")
            }
            // Nur der aktuelle Lauf räumt auf (W4).
            guard self.runID == run else { return }
            device.stopReceiving(owner: self)
            device.releaseBurstReservation(owner: self)
            self.runID = nil
            self.running = false
            self.observing = nil
        }
    }

    /// Nächste LNA-Stufe eines Bandes nach einer Aufnahme: übersteuert
    /// (> 0,5 % am Anschlag) eine Stufe zurück, deutlich zu leise
    /// (< −36 dBFS, kaum Anschlag) eine Stufe hoch – höchstens bis `ceiling`.
    nonisolated static func nextLNA(current: Double, ceiling: Double, clipped: Double, rmsDBFS: Double) -> Double {
        if clipped > 0.005, current >= 8 { return current - 8 }
        if rmsDBFS < -36, clipped < 0.0005, current + 8 <= ceiling { return current + 8 }
        return min(current, ceiling)
    }

    /// Die LNA-Stufe, mit der auf `band` aufgenommen wird.
    func lna(forBand band: Int) -> Double { min(bandLNA[band] ?? lnaGain, lnaGain) }

    func applyGains(to device: HackRFDevice?) throws {
        try applyGains(to: device, lna: lnaGain)
    }

    private func applyGains(to device: HackRFDevice?, lna: Double) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lna))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    // MARK: Aufnahme

    /// Sammelt Blöcke. Bis `arm` (Gerät umgestimmt) wird alles verworfen,
    /// danach noch `skipBlocks` Blöcke – sie stammen womöglich noch von der
    /// alten Frequenz, Rate oder Verstärkung.
    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        private var data = Data()
        private var skip = 0
        private var armed = false
        private let wanted: Int

        init(bytes: Int) {
            wanted = bytes
            data.reserveCapacity(bytes + 262_144)
        }

        func arm(skipBlocks: Int) {
            lock.withLock {
                skip = skipBlocks
                armed = true
            }
        }

        func handle(_ block: Data) {
            lock.withLock {
                guard armed else { return }
                if skip > 0 {
                    skip -= 1
                    return
                }
                guard data.count < wanted else { return }
                data.append(block)
            }
        }

        var result: Data? { lock.withLock { data.count >= wanted ? data.prefix(wanted) : nil } }
    }

    enum CaptureError: LocalizedError {
        case timeout
        var errorDescription: String? { String(localized: "Der HackRF liefert keine Daten (Zeitüberschreitung).") }
    }

    /// Nimmt `milliseconds` bei 19,2 MS/s auf `mhz` auf.
    ///
    /// Reihenfolge (Review 28.10.2026, W2/W3/Y12): erst den Besitz prüfen –
    /// ab der zweiten Aufnahme endet der Lauf mit `takenOver`, wenn
    /// inzwischen jemand anderes das Gerät hat –, dann übernehmen, dann
    /// Abtastrate, Filter, Frequenz und Verstärkung selbst setzen (ein
    /// Fernzugriffs-Empfänger kann dazwischen mit anderer Rate gelaufen sein)
    /// und erst danach Blöcke sammeln.
    private func capture(_ device: HackRFDevice, band: Int, mhz: Double, milliseconds: Double, filter: UInt32) async throws -> Data {
        try Task.checkCancellation()
        if claimed {
            guard device.burstOwner === self else { throw HackRFError.takenOver }
            if let other = device.currentOwner, other !== self { throw HackRFError.takenOver }
        }
        let bytes = Int(LTEFrontEnd.captureRate * milliseconds / 1000) * 2
        let collector = Collector(bytes: bytes)
        try device.startReceiving(owner: self) { collector.handle($0) }
        claimed = true
        device.reserveForBursts(owner: self)
        do {
            try device.setSampleRate(UInt32(LTEFrontEnd.captureRate))
            try device.setBasebandFilter(filter)
            try device.setFrequency(UInt64((mhz * 1e6).rounded()))
            try applyGains(to: device, lna: lna(forBand: band))
        } catch {
            device.stopReceiving(owner: self)
            throw error
        }
        collector.arm(skipBlocks: 2)
        let deadline = ContinuousClock.now + .seconds(3)
        while collector.result == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            guard device.isReceiving(for: self) else { throw HackRFError.takenOver }
        }
        device.stopReceiving(owner: self)
        guard let data = collector.result else { throw CaptureError.timeout }
        let stats = HackRFDevice.blockStatistics(data)
        clipped = stats.clipped
        // Die allgemeine Automatik regelt Stoß-Empfänger nicht (siehe AutoGain):
        // je Band eine Stufe zurück bei Übersteuerung, wieder hoch bei zu leisem Pegel.
        let before = lna(forBand: band)
        let next = Self.nextLNA(current: before, ceiling: lnaGain, clipped: stats.clipped, rmsDBFS: stats.rmsDBFS)
        if next != before {
            bandLNA[band] = next
            Self.log.notice("Band \(band, privacy: .public): \(String(format: "%.1f", stats.clipped * 100), privacy: .public) % am Anschlag, \(Int(stats.rmsDBFS), privacy: .public) dBFS – LNA \(Int(before), privacy: .public) → \(Int(next), privacy: .public)")
        }
        return data
    }

    // MARK: Suchlauf

    private struct Window {
        var centerMHz: Double
        var data: Data
    }

    private func scan(_ device: HackRFDevice) async throws {
        let plan = LTEBand.germany.filter { bands.contains($0.number) }
        guard !plan.isEmpty else {
            status = String(localized: "Wähle mindestens ein Band.")
            return
        }
        let totalWindows = plan.reduce(0) { $0 + LTEScanner.windows(for: $1).count }
        var windowsDone = 0
        var foundThisScan = 0
        for band in plan {
            try Task.checkCancellation()
            // 1. Fenster aufnehmen, Spektrum bilden
            var windows: [Window] = []
            var points: [(mhz: Double, db: Float)] = []
            for center in LTEScanner.windows(for: band) {
                status = String(localized: "Nehme Band \(band.number) (\(band.name)) auf: \(String(format: "%.0f", center)) MHz")
                let data = try await capture(device, band: band.number, mhz: center, milliseconds: 45, filter: 15_000_000)
                windows.append(Window(centerMHz: center, data: data))
                let part = await Task.detached(priority: .userInitiated) {
                    let iq = LTEFrontEnd.convert(data)
                    return LTEScanner.spectrumPoints(re: iq.re, im: iq.im, tunedMHz: center)
                }.value
                points += part
                windowsDone += 1
                progress = Double(windowsDone) / Double(totalWindows) * 0.6
            }
            spectra[band.number] = Self.coarse(points, band: band)
            // 2. Abschnitte und Kandidaten
            var segments = LTEScanner.segments(points).filter { $0.highMHz > band.lowMHz && $0.lowMHz < band.highMHz }
            var tried: Set<Int> = []
            var round = 0
            while !segments.isEmpty, round < 3 {
                round += 1
                var next: [LTESegment] = []
                for segment in segments {
                    try Task.checkCancellation()
                    let candidates = LTEScanner.candidates(for: segment, band: band).filter { !tried.contains(Int(($0 * 10).rounded())) }
                    candidates.forEach { tried.insert(Int(($0 * 10).rounded())) }
                    guard !candidates.isEmpty else { continue }
                    status = String(localized: "Prüfe Band \(band.number): \(String(format: "%.1f–%.1f", segment.lowMHz, segment.highMHz)) MHz (\(candidates.count) Kandidaten)")
                    var findings: [LTECellFinding] = []
                    // Je Kandidat das Fenster mit dem kleinsten Abstand
                    let groups = Dictionary(grouping: candidates) { c in
                        windows.indices.min { abs(windows[$0].centerMHz - c) < abs(windows[$1].centerMHz - c) } ?? 0
                    }
                    for (index, list) in groups.sorted(by: { $0.key < $1.key }) {
                        try Task.checkCancellation()
                        let window = windows[index]
                        let ppm = self.ppm
                        let result = await Task.detached(priority: .userInitiated) {
                            let iq = LTEFrontEnd.convert(window.data)
                            return LTEScanner.analyze(re: iq.re, im: iq.im, tunedMHz: window.centerMHz, candidates: list.sorted(), ppm: ppm)
                        }.value
                        findings += result
                        merge(result, band: band)
                    }
                    foundThisScan += findings.count
                    next += LTEScanner.remaining(segment, after: findings)
                }
                segments = next
            }
            progress = min(0.85, progress + 0.25 / Double(plan.count))
        }
        // 3. SIB1 je Träger
        if readSIB1 {
            let carriers = Dictionary(grouping: cells.filter { $0.sib1 == nil && !$0.tdd && !$0.extendedCP }) { $0.earfcn }
            var done = 0
            for (_, list) in carriers.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                try await readSystemInformation(list, device)
                done += 1
                progress = 0.85 + 0.15 * Double(done) / Double(max(carriers.count, 1))
            }
        }
        progress = 1
        scansCompleted += 1
        status = foundThisScan == 0
            ? String(localized: "Keine Zelle gefunden – passt die Antenne (700–2700 MHz)? Prüf auch die Verstärkung.")
            : String(localized: "Suchlauf fertig: \(cells.count) Zellen.")
        Self.log.notice("Suchlauf fertig: \(self.cells.count) Zellen, ppm \(self.ppm ?? 0)")
    }

    /// Prüft eine einzelne Trägerfrequenz (genau abgestimmt), samt SIB1.
    private func checkSingle(_ mhz: Double, _ device: HackRFDevice) async throws {
        guard let (band, _) = LTEBand.locate(mhz: mhz) else {
            status = String(localized: "\(String(format: "%.1f", mhz)) MHz liegt in keinem LTE-Band der Liste.")
            return
        }
        status = String(localized: "Prüfe \(String(format: "%.1f", mhz)) MHz …")
        let data = try await capture(device, band: band.number, mhz: mhz, milliseconds: 90, filter: 20_000_000)
        let ppm = self.ppm
        let findings = await Task.detached(priority: .userInitiated) {
            let iq = LTEFrontEnd.convert(data)
            return LTEScanner.analyzeCarrier(re: iq.re, im: iq.im, offsetHz: 0, carrierMHz: mhz,
                                             hypotheses: LTEScanner.cfoHypotheses(ppm: ppm, carrierMHz: mhz))
        }.value
        merge(findings, band: band)
        progress = 0.5
        if findings.isEmpty {
            status = String(localized: "Auf \(String(format: "%.1f", mhz)) MHz keine Zelle gefunden.")
            return
        }
        if readSIB1 {
            let ids = Set(findings.map { "\(band.earfcn(forMHz: $0.carrierMHz))-\($0.sync.pci)" })
            try await readSystemInformation(cells.filter { ids.contains($0.id) }, device, data: data)
        }
        progress = 1
        status = findings.count == 1
            ? String(localized: "1 Zelle auf \(String(format: "%.1f", mhz)) MHz.")
            : String(localized: "\(findings.count) Zellen auf \(String(format: "%.1f", mhz)) MHz.")
    }

    /// SIB1 für alle Zellen eines Trägers aus einer zentrierten Aufnahme.
    private func readSystemInformation(_ list: [LTECell], _ device: HackRFDevice, data existing: Data? = nil) async throws {
        guard let first = list.first else { return }
        status = String(localized: "Lese Netzbetreiber auf \(String(format: "%.1f", first.frequencyMHz)) MHz …")
        let filter = HackRFDevice.basebandFilters.first { Double($0) >= first.bandwidthMHz * 0.9e6 + 2e6 } ?? 20_000_000
        let data: Data
        if let existing {
            data = existing
        } else {
            data = try await capture(device, band: first.band, mhz: first.frequencyMHz, milliseconds: 90, filter: filter)
        }
        let cellsToRead = list
        let results = await Task.detached(priority: .userInitiated) { () -> [(String, LTESIB1Decoder.Outcome)] in
            let iq = LTEFrontEnd.convert(data)
            return cellsToRead.map { cell in
                (cell.id, LTESIB1Decoder.decode(re: iq.re, im: iq.im, pci: cell.pci, mib: cell.mib, extendedCP: cell.extendedCP,
                                                tdd: cell.tdd, cfoGuessHz: cell.cfoHz, carrierHz: cell.frequencyMHz * 1e6))
            }
        }.value
        for (id, outcome) in results {
            guard let index = cells.firstIndex(where: { $0.id == id }) else { continue }
            if let sib1 = outcome.sib1 { cells[index].sib1 = sib1 }
            cells[index].sib1Note = outcome.note
            Self.log.info("SIB1 \(id, privacy: .public): \(outcome.note, privacy: .public)")
        }
    }

    private func merge(_ findings: [LTECellFinding], band: LTEBand) {
        let now = Date()
        for f in findings {
            let earfcn = band.earfcn(forMHz: f.carrierMHz)
            let id = "\(earfcn)-\(f.sync.pci)"
            if let index = cells.firstIndex(where: { $0.id == id }) {
                cells[index].measurement = f.measurement ?? cells[index].measurement
                cells[index].mib = f.mib
                cells[index].cfoHz = f.sync.cfoHz
                cells[index].lastSeen = now
            } else {
                cells.append(LTECell(band: band.number, earfcn: earfcn, frequencyMHz: f.carrierMHz, pci: f.sync.pci, mib: f.mib,
                                     extendedCP: f.sync.extendedCP, tdd: f.sync.tdd, measurement: f.measurement,
                                     cfoHz: f.sync.cfoHz, sib1: nil, sib1Note: readSIB1 ? String(localized: "noch nicht gelesen") : String(localized: "nicht gelesen (Netzbetreiber lesen ist aus)"),
                                     firstSeen: now, lastSeen: now))
            }
            Self.log.info("Zelle B\(band.number) EARFCN \(earfcn) PCI \(f.sync.pci) \(f.mib.nRB) RB \(f.mib.ports) Ports, Ablage \(Int(f.sync.cfoHz)) Hz")
        }
        // Ablage in Hz je MHz Trägerfrequenz = ppm (alle Zellen hängen an GPS-genauen Takten).
        ppm = cells.isEmpty ? nil : cells.map { $0.cfoHz / $0.frequencyMHz }.reduce(0, +) / Double(cells.count)
    }

    private static func coarse(_ points: [(mhz: Double, db: Float)], band: LTEBand) -> LTEBandSpectrum {
        var bins: [Int: (Double, Int)] = [:]
        for p in points {
            let key = Int((p.mhz * 10).rounded())
            let v = bins[key] ?? (0, 0)
            bins[key] = (v.0 + pow(10, Double(p.db) / 10), v.1 + 1)
        }
        let list = bins.keys.sorted().map { key -> LTEBandSpectrum.SpectrumPoint in
            let v = bins[key]!
            return .init(mhz: Double(key) / 10, db: 10 * log10(v.0 / Double(v.1)))
        }
        return LTEBandSpectrum(band: band.number, points: list.filter { $0.mhz >= band.lowMHz - 1 && $0.mhz <= band.highMHz + 1 })
    }

    // MARK: Beobachten

    private func observeLoop(_ cell: LTECell, _ device: HackRFDevice) async throws {
        status = String(localized: "Beobachte PCI \(cell.pci) auf \(String(format: "%.1f", cell.frequencyMHz)) MHz")
        var cfo = cell.cfoHz
        while !Task.isCancelled {
            let data = try await capture(device, band: cell.band, mhz: cell.frequencyMHz, milliseconds: 25, filter: 15_000_000)
            let hypotheses = [cfo - 4000, cfo, cfo + 4000]
            let result = await Task.detached(priority: .userInitiated) {
                let iq = LTEFrontEnd.convert(data)
                let narrow = LTEFrontEnd.channel(re: iq.re, im: iq.im, offsetHz: 0)
                return LTEScanner.measure(re: narrow.re, im: narrow.im, hypotheses: hypotheses, pci: cell.pci)
            }.value
            // Abgebrochen (z. B. andere Zelle gewählt): nichts mehr in den neuen Verlauf schreiben.
            try Task.checkCancellation()
            let m = result?.measurement
            if let hit = result?.hit { cfo = hit.cfoHz }
            history.append(LTELevelSample(date: Date(), rsrpDBFS: m?.rsrpDBFS, sinrDB: m?.sinrDB, rsrqDB: m?.rsrqDB))
            if history.count > 600 { history.removeFirst(history.count - 600) }
            if let index = cells.firstIndex(where: { $0.id == cell.id }), let m {
                cells[index].measurement = m
                cells[index].lastSeen = Date()
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}

extension CellModel: GainTunable {
    var idleHint: String { String(localized: "Mobilfunkzellen gibt es fast überall – bleibt die Liste leer, passt die Antenne nicht für 700–2700 MHz.") }
    var activity: Int? { cells.count }
    var quality: GainQuality? { nil }
    var receivesInBursts: Bool { true }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}
