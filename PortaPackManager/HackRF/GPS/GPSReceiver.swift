import Accelerate
import Foundation
import OSLog

/// Zustand eines Kanals für die Anzeige.
struct GPSChannelStatus: Sendable, Identifiable, Equatable {
    enum State: Int, Sendable, Comparable {
        case acquired, tracking, bitSync, frameSync, ephemeris
        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .acquired: String(localized: "gefunden")
            case .tracking: String(localized: "verfolgt")
            case .bitSync: String(localized: "Bittakt")
            case .frameSync: String(localized: "Zeit")
            case .ephemeris: String(localized: "Bahndaten")
            }
        }
    }
    let prn: Int
    let state: State
    let cn0: Double
    let dopplerHz: Double
    let locked: Bool
    /// Bereits empfangene Subframes 1–3 der Ephemeride.
    let subframes: Set<Int>
    let elevation: Double?
    let azimuth: Double?
    let usedInFix: Bool
    /// Kohärent über ganze Datenbits (20 ms) – schwaches Signal.
    var longIntegration = false
    /// Von der Schwachsignal-Suche gefunden.
    var weakAcquired = false
    var id: Int { prn }
}

/// Gesamtstand des Empfängers (Schnappschuss für die Oberfläche).
struct GPSReceiverStatus: Sendable {
    var elapsed: Double = 0                 // verarbeitete Signaldauer, s
    var channels: [GPSChannelStatus] = []
    var acquisition: [GPSFix] = []          // letzter Akquisitionslauf
    var solution: GPSSolution?
    var solutionAge: Double?                // s seit der letzten Lösung
    var week: Int?                          // volle GPS-Woche
    var leapSeconds = 18
    var ephemerisCount = 0
    var hasIonosphere = false
    var fixCount = 0
    /// Laut Vorhersage (Almanach/Ephemeride + Ort + Uhrzeit) sichtbare Satelliten; nil ohne Vorhersage.
    var predictedVisible: Int?
    /// Satelliten mit Almanach (eigener Empfang oder gespeichert).
    var almanacCount = 0
    /// Gespeicherte, noch gültige Bahndaten genutzt (Heißstart).
    var hotStart = false

    var utc: Date? {
        guard let s = solution, let week else { return nil }
        return GPSTime.utc(week: week, tow: s.gpsTime, leapSeconds: leapSeconds)
    }
}

/// Vollständiger GPS-L1-C/A-Empfänger: Akquisition → Tracking → Navigations-
/// nachricht → Pseudodistanzen → PVT.
///
/// `process` wird von genau einem Thread aufgerufen (USB-Empfang oder
/// Wiedergabe). Die Akquisition läuft live nebenläufig auf einer eigenen
/// Warteschlange, damit das Tracking nicht stockt; offline (synchron) wartet
/// die Wiedergabe auf sie – dann ist das Ergebnis reproduzierbar.
final class GPSReceiver: @unchecked Sendable {
    private let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "GPS")
    struct Options: Sendable {
        var sampleRate: Double = 4_096_000
        var channels = 12
        var asynchronousAcquisition = true
        /// Abstand der Akquisitionsläufe (Signalzeit, s).
        var acquisitionInterval = 2.0
        /// Abstand der Messepochen (Signalzeit, s).
        var measurementInterval = 1.0
        var troposphere = true
        var ionosphere = true
        /// Bezug für die 1024-Wochen-Mehrdeutigkeit.
        var referenceDate = Date()
        /// Schwachsignal-Suche: 10 ms kohärent, viele Blöcke nichtkohärent
        /// (`GPSAcquirer.acquireWeak`) für alles, was die Grobsuche nicht findet.
        var weakSearch = true
        /// Abstand der Schwachsignal-Suchen (Signalzeit, s): ohne bzw. mit Vorhersage.
        var weakSearchInterval = 6.0
        var weakTargetedInterval = 3.0
        /// Länge der Schwachsignal-Suche (ms): blind über ±10 kHz bzw. gezielt im schmalen Fenster.
        var weakBlindMs = 200
        var weakTargetedMs = 500
    }

    /// Art eines Akquisitionslaufs.
    private enum AcquisitionKind { case coarse, weak }

    let options: Options
    private let decimation: Int
    private let acquirer = GPSAcquirer(dopplerStepHz: 250)
    private let acquisitionQueue = DispatchQueue(label: "GPS-Akquisition", qos: .utility)

    // Nur auf dem Verarbeitungsthread
    private var sampleIndex: Int64 = 0
    private var channels: [GPSChannel] = []
    private var subframes: [Int: [Int: GPSSubframe]] = [:]
    private var ephemerides: [Int: GPSEphemeris] = [:]
    private var ionoUTC: GPSIonoUTC?
    private var week10: Int?
    private var acqBuffer: [Float] = []
    private var acqStart: Int64 = 0
    private var acqCollecting = false
    private var acqInFlight = false
    private var nextAcquisition: Int64 = 0
    private var nextMeasurement: Int64
    private var lastSolution: GPSSolution?
    private var lastSolutionSample: Int64?
    private var fixCount = 0
    private var floatBuffer: [Float] = []
    private var lastAcquisition: [GPSFix] = []
    /// PRN → Sample, ab dem er erneut versucht werden darf (nach Verlust).
    private var retryAfter: [Int: Int64] = [:]
    /// Verlorene Kanäle: letzter Doppler und wann – für die schmale Wiederaufnahme.
    private var lostInfo: [Int: (doppler: Double, sample: Int64)] = [:]
    private var acqKind = AcquisitionKind.coarse
    private var acqNeeded = 0
    private var nextWeakSearch: Int64 = 0
    private var blindInterval = 6.0
    private var nextBlindSearch: Int64 = 0
    private var weakTargets: (narrow: [GPSAcquirer.Target], wide: [GPSAcquirer.Target]) = ([], [])

    // Hilfsdaten (Warm-/Heißstart) und Vorhersage
    private var weakSearchEnabled: Bool
    private var startAiding = GPSAidingData()
    /// Absolute GPS-Sekunden bei Abtastwert 0 (aus der Systemuhr bzw. Aufnahmezeit).
    private var startTime: Double?
    private var approxPosition: SIMD3<Double>?
    private var almanac: [Int: GPSAlmanac] = [:]
    private var predictions: [Int: GPSPredictor.Prediction]?
    private var predictionCoverage = Set<Int>()
    private var nextPrediction: Int64 = 0
    private var clockOffset: Double?
    private var hotStart = false
    private var weakAcquiredPRNs = Set<Int>()

    // Zwischen Threads
    private let lock = NSLock()
    private var inbox: (start: Int64, fixes: [GPSFix], kind: AcquisitionKind)?
    private var snapshot = GPSReceiverStatus()
    private var aidingOut = GPSAidingData()
    private var pendingWeakSearch: Bool?

    init(options: Options = Options()) {
        self.options = options
        weakSearchEnabled = options.weakSearch
        decimation = max(1, Int((options.sampleRate / Double(GPSAcquirer.sampleRate)).rounded()))
        nextMeasurement = Int64(options.measurementInterval * options.sampleRate)
    }

    var status: GPSReceiverStatus { lock.withLock { snapshot } }

    /// Hilfsdaten zum Speichern (Bahnen, Almanach, Position, Quarzablage).
    var aidingData: GPSAidingData { lock.withLock { aidingOut } }

    /// Vor dem Start (nach `reset`) aufrufen, nicht während `process` läuft.
    /// - Parameters:
    ///   - aiding: gespeicherte Hilfsdaten des letzten Laufs.
    ///   - time: ungefähre Uhrzeit beim ersten Abtastwert (Systemuhr, Aufnahmezeit).
    ///   - home: ungefährer Ort (Heimstandort aus den Einstellungen), falls keine Position gespeichert ist.
    ///   - weakSearch: Schwachsignal-Suche ein/aus (sonst `Options.weakSearch`).
    func configure(aiding: GPSAidingData?, time: Date?, home: SIMD3<Double>?, weakSearch: Bool? = nil) {
        startAiding = aiding ?? GPSAidingData()
        startTime = time.map { GPSPredictor.gpsSeconds($0) }
        approxPosition = startAiding.ecef ?? home
        if let weakSearch { weakSearchEnabled = weakSearch }
        almanac = Dictionary(startAiding.almanac.map { ($0.prn, $0) }, uniquingKeysWith: { a, _ in a })
        clockOffset = nil
        // Heißstart: noch gültige Ephemeriden (±2 h um toe) gleich verwenden –
        // dann braucht die erste Position nur die Zeit (TOW), nicht 30 s Bahndaten.
        hotStart = false
        if let t = startTime {
            for s in startAiding.ephemerides where abs(t - s.toeAbsolute) < 7200 {
                ephemerides[s.ephemeris.prn] = s.ephemeris
                week10 = s.ephemeris.weekNumber
                hotStart = true
            }
        }
        nextPrediction = 0
        publish()
    }

    /// Schwachsignal-Suche während des Laufs schalten (Thread-sicher).
    func setWeakSearch(_ on: Bool) { lock.withLock { pendingWeakSearch = on } }

    /// Für Tests: aktuelle Ephemeriden.
    var currentEphemerides: [Int: GPSEphemeris] { ephemerides }

    // MARK: Eingang

    /// Vorzeichenbehaftete 8-Bit-IQ-Paare (wie `HackRFDevice.startReceiving`).
    func process(_ iq: Data) {
        let n = iq.count / 2
        guard n > 0 else { return }
        if floatBuffer.count < 2 * n { floatBuffer = [Float](repeating: 0, count: 2 * n) }
        iq.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int8.self)
            floatBuffer.withUnsafeMutableBufferPointer { f in
                vDSP_vflt8(p.baseAddress!, 1, f.baseAddress!, 1, vDSP_Length(2 * n))
                // Gleichanteil (DC-Spitze des HackRF) blockweise abziehen.
                var meanI: Float = 0, meanQ: Float = 0
                vDSP_meanv(f.baseAddress!, 2, &meanI, vDSP_Length(n))
                vDSP_meanv(f.baseAddress! + 1, 2, &meanQ, vDSP_Length(n))
                var negI = -meanI, negQ = -meanQ
                vDSP_vsadd(f.baseAddress!, 2, &negI, f.baseAddress!, 2, vDSP_Length(n))
                vDSP_vsadd(f.baseAddress! + 1, 2, &negQ, f.baseAddress! + 1, 2, vDSP_Length(n))
            }
        }
        floatBuffer.withUnsafeBufferPointer { process(samples: $0.baseAddress!, count: n) }
    }

    /// Komplexe Abtastwerte als Float (re, im, re, im …).
    func process(samples: UnsafePointer<Float>, count: Int) {
        var offset = 0
        while offset < count {
            // Bis zur nächsten Messepoche, damit alle Kanäle dort gleich weit sind.
            let untilMeasurement = Int(nextMeasurement - sampleIndex)
            let n = min(count - offset, max(untilMeasurement, 1))
            let chunk = samples + 2 * offset
            collectAcquisition(chunk, count: n)
            var lostAny = false
            for ch in channels {
                for sf in ch.process(chunk, count: n) { ingest(sf, prn: ch.prn) }
                if ch.lost { lostAny = true }
            }
            sampleIndex += Int64(n)
            offset += n
            if lostAny {
                for ch in channels where ch.lost {
                    retryAfter[ch.prn] = sampleIndex + Int64(4 * options.sampleRate)
                    if ch.wasLocked {
                        lostInfo[ch.prn] = (ch.carrierHz, sampleIndex)
                        nextWeakSearch = min(nextWeakSearch, sampleIndex)
                        blindInterval = options.weakSearchInterval
                    }
                }
                channels.removeAll { $0.lost }
            }
            adoptAcquisition()
            if sampleIndex >= nextMeasurement {
                measure()
                nextMeasurement += Int64(options.measurementInterval * options.sampleRate)
            }
        }
    }

    func reset() {
        lock.withLock { inbox = nil; snapshot = GPSReceiverStatus() }
        sampleIndex = 0; channels = []; subframes = [:]; ephemerides = [:]; ionoUTC = nil
        week10 = nil; acqBuffer = []; acqCollecting = false; acqInFlight = false
        nextAcquisition = 0; nextMeasurement = Int64(options.measurementInterval * options.sampleRate)
        lastSolution = nil; lastSolutionSample = nil; fixCount = 0; retryAfter = [:]
        lastAcquisition = []; lostInfo = [:]; nextWeakSearch = 0; weakAcquiredPRNs = []
        blindInterval = options.weakSearchInterval; nextBlindSearch = 0
        startAiding = GPSAidingData(); startTime = nil; approxPosition = nil; almanac = [:]
        predictions = nil; predictionCoverage = []; nextPrediction = 0; clockOffset = nil; hotStart = false
        weakSearchEnabled = options.weakSearch
        lock.withLock { aidingOut = GPSAidingData(); pendingWeakSearch = nil }
    }

    // MARK: Akquisition

    /// Grobsuche alle `acquisitionInterval` s über alle freien PRNs (8 ms, schnell);
    /// dazwischen die Schwachsignal-Suche für alles, was fehlt – gezielt, wenn eine
    /// Vorhersage oder ein verlorener Kanal das Doppler-Fenster eingrenzt.
    private func collectAcquisition(_ p: UnsafePointer<Float>, count: Int) {
        if !acqCollecting {
            guard !acqInFlight, channels.count < options.channels else { return }
            if let on = lock.withLock({ () -> Bool? in defer { pendingWeakSearch = nil }; return pendingWeakSearch }) {
                weakSearchEnabled = on
            }
            if sampleIndex >= nextAcquisition {
                acqKind = .coarse
                acqNeeded = GPSAcquirer.fftSize * GPSAcquirer.integrationMs * 2
            } else if weakSearchEnabled && sampleIndex >= nextWeakSearch {
                updatePredictions()
                weakTargets = makeWeakTargets()
                // Blinde Suche (volle Doppler-Spanne) nur in ihrem eigenen, wachsenden Abstand.
                if sampleIndex < nextBlindSearch { weakTargets.wide = [] }
                guard !weakTargets.narrow.isEmpty || !weakTargets.wide.isEmpty else {
                    nextWeakSearch = sampleIndex + Int64(options.weakTargetedInterval * options.sampleRate)
                    return
                }
                acqKind = .weak
                let ms = weakTargets.narrow.isEmpty ? options.weakBlindMs : max(options.weakBlindMs, options.weakTargetedMs)
                acqNeeded = GPSAcquirer.fftSize * ms * 2
            } else { return }
            acqCollecting = true
            acqStart = sampleIndex
            acqBuffer.removeAll(keepingCapacity: true)
            acqBuffer.reserveCapacity(acqNeeded)
        }
        let needed = acqNeeded
        let k = decimation
        var i = 0
        while i + k <= count && acqBuffer.count < needed {
            var re: Float = 0, im: Float = 0
            for j in 0..<k { re += p[2 * (i + j)]; im += p[2 * (i + j) + 1] }
            acqBuffer.append(re); acqBuffer.append(im)
            i += k
        }
        guard acqBuffer.count >= needed else { return }
        acqCollecting = false
        acqInFlight = true
        let samples = acqBuffer
        let start = acqStart
        let kind = acqKind
        let acquirer = acquirer
        // Verfolgte Satelliten als Störer: Codephase auf den Pufferbeginn zurückgerechnet.
        let fs = options.sampleRate
        let elapsed = Double(sampleIndex - start)   // die Kanäle stehen am Anfang dieses Blocks
        let interferers = channels.filter { $0.strength >= 30 }.map { ch -> GPSAcquirer.Interferer in
            let rate = GPSConst.chipRate * (1 + ch.carrierHz / GPSConst.l1)
            return .init(prn: ch.prn, dopplerHz: ch.carrierHz, codePhase: ch.state.code_phase - elapsed * rate / fs,
                         cn0: ch.strength)
        }
        let job: @Sendable () -> [GPSFix]
        switch kind {
        case .coarse:
            let tracked = Set(channels.map(\.prn))
            let wanted = (1...GPSCACode.prnCount).filter { !tracked.contains($0) && (retryAfter[$0] ?? 0) <= sampleIndex }
            job = { acquirer.acquire(samples, prns: wanted, interferers: interferers) }
        case .weak:
            let targets = weakTargets
            let blindBlocks = options.weakBlindMs / GPSAcquirer.weakCoherentMs
            job = {
                acquirer.acquireWeak(samples, targets: targets.narrow, interferers: interferers)
                    + acquirer.acquireWeak(samples, targets: targets.wide, maxBlocks: blindBlocks, interferers: interferers)
            }
        }
        if options.asynchronousAcquisition {
            acquisitionQueue.async { [weak self] in
                let fixes = job()
                guard let self else { return }
                self.lock.withLock { self.inbox = (start, fixes, kind) }
            }
        } else {
            let fixes = job()
            lock.withLock { inbox = (start, fixes, kind) }
        }
    }

    /// Suchaufträge der Schwachsignal-Suche: schmal um den letzten Doppler
    /// verlorener Kanäle und um die Vorhersage; ohne Vorhersage alle freien PRNs
    /// über die volle Doppler-Spanne.
    private func makeWeakTargets() -> (narrow: [GPSAcquirer.Target], wide: [GPSAcquirer.Target]) {
        let tracked = Set(channels.map(\.prn))
        let fs = options.sampleRate
        let span = GPSAcquirer.dopplerSpanHz
        var narrow: [GPSAcquirer.Target] = []
        var done = Set<Int>()
        for (prn, info) in lostInfo.sorted(by: { $0.key < $1.key }) where !tracked.contains(prn) {
            let age = Double(sampleIndex - info.sample) / fs
            guard age < 120 else { continue }
            let window = 100 + 3 * age            // Doppleränderung ≤ 1 Hz/s, Quarzdrift dazu
            narrow.append(.init(prn: prn, doppler: max(-span, info.doppler - window)...min(span, info.doppler + window)))
            done.insert(prn)
        }
        var wide: [GPSAcquirer.Target] = []
        let covered = predictions == nil ? Set<Int>() : predictionCoverage
        if let predictions {
            // Quarzablage bekannt (aus verfolgten Satelliten): ±300 Hz; nur gespeichert: ±2 kHz.
            let offset = clockOffset ?? startAiding.clockOffsetHz
            let window = clockOffset != nil ? 300.0 : 2000.0
            for p in predictions.values.sorted(by: { $0.elevation > $1.elevation })
            where !tracked.contains(p.prn) && !done.contains(p.prn) {
                if let offset {
                    let c = p.dopplerHz + offset
                    narrow.append(.init(prn: p.prn, doppler: max(-span, c - window)...min(span, c + window)))
                } else {
                    wide.append(.init(prn: p.prn, doppler: -span...span))
                }
            }
        }
        for prn in 1...GPSCACode.prnCount where !tracked.contains(prn) && !done.contains(prn) && !covered.contains(prn) {
            wide.append(.init(prn: prn, doppler: -span...span))
        }
        return (narrow, wide)
    }

    private func adoptAcquisition() {
        guard let result = lock.withLock({ () -> (start: Int64, fixes: [GPSFix], kind: AcquisitionKind)? in
            defer { inbox = nil }
            return inbox
        }) else { return }
        acqInFlight = false
        switch result.kind {
        case .coarse:
            nextAcquisition = sampleIndex + Int64(options.acquisitionInterval * options.sampleRate)
            lastAcquisition = result.fixes
        case .weak:
            // Blinde Suche ohne Treffer: Abstand verdoppeln (bis 30 s) – sie kostet
            // ≈ 15 ms je PRN; ein Treffer oder ein Verlust setzt ihn zurück.
            var merged = Dictionary(lastAcquisition.map { ($0.prn, $0) }, uniquingKeysWith: { a, _ in a })
            for f in result.fixes { merged[f.prn] = f }
            lastAcquisition = merged.values.sorted { $0.snrDB > $1.snrDB }
        }
        let fs = options.sampleRate
        let chipPerSample = GPSConst.chipRate / fs
        var adoptedWide = false
        let widePRNs = result.kind == .weak ? Set(weakTargets.wide.map(\.prn)) : []
        for fix in result.fixes where fix.acquired {
            guard channels.count < options.channels, !channels.contains(where: { $0.prn == fix.prn }) else { continue }
            // Verzögerung → Codephase am Akquisitionsbeginn; der dezimierte Wert m
            // liegt zeitlich bei Sample k·m + (k−1)/2.
            let delay = fix.codePhaseChips + Double(decimation - 1) / 2 * chipPerSample
            let rate = GPSConst.chipRate * (1 + fix.dopplerHz / GPSConst.l1)
            let phase = -delay + Double(sampleIndex - result.start) * rate / fs
            if let strong = crossCorrelationSource(prn: fix.prn, codePhase: phase, dopplerHz: fix.dopplerHz,
                                                   cn0: fix.cn0, tolerance: fix.weak ? 60 : 200) {
                log.debug("PRN \(fix.prn) verworfen: Kreuzkorrelation von PRN \(strong)")
                continue
            }
            channels.append(GPSChannel(prn: fix.prn, sampleRate: fs, codePhase: phase, dopplerHz: fix.dopplerHz,
                                       cn0Hint: fix.cn0))
            lostInfo[fix.prn] = nil
            if widePRNs.contains(fix.prn) { adoptedWide = true }
            if fix.weak { weakAcquiredPRNs.insert(fix.prn) } else { weakAcquiredPRNs.remove(fix.prn) }
        }
        if result.kind == .weak {
            // Blinde Suche ohne neuen Kanal: Abstand verdoppeln (bis 30 s) – sie kostet
            // ≈ 15 ms je PRN; ein Treffer oder ein Verlust setzt ihn zurück.
            if adoptedWide {
                blindInterval = options.weakSearchInterval
            } else if !widePRNs.isEmpty {
                blindInterval = min(blindInterval * 2, 30)
            }
            if !widePRNs.isEmpty { nextBlindSearch = sampleIndex + Int64(blindInterval * options.sampleRate) }
            nextWeakSearch = sampleIndex + Int64(options.weakTargetedInterval * options.sampleRate)
        }
    }

    // MARK: Vorhersage

    /// Ungefähre absolute GPS-Zeit am aktuellen Abtastwert.
    private var currentGPSSeconds: Double? {
        let fs = options.sampleRate
        if let s = lastSolution, let w = week10, let at = lastSolutionSample {
            let week = GPSTime.fullWeek(w, near: options.referenceDate)
            return Double(week) * GPSConst.weekSeconds + s.gpsTime + Double(sampleIndex - at) / fs
        }
        return startTime.map { $0 + Double(sampleIndex) / fs }
    }

    /// Sichtbare Satelliten und Doppler, alle 10 s neu.
    private func updatePredictions() {
        guard sampleIndex >= nextPrediction else { return }
        nextPrediction = sampleIndex + Int64(10 * options.sampleRate)
        guard let t = currentGPSSeconds, let rx = lastSolution?.ecef ?? approxPosition else { predictions = nil; return }
        let aiding = currentAiding()
        // Satelliten ohne bekannte Bahn bleiben in der blinden Suche.
        predictionCoverage = Set(aiding.ephemerides.map(\.ephemeris.prn)).union(aiding.almanac.map(\.prn))
        guard !predictionCoverage.isEmpty else { predictions = nil; return }
        let list = GPSPredictor.predict(at: t, rx: rx, aiding: aiding)
        predictions = Dictionary(list.map { ($0.prn, $0) }, uniquingKeysWith: { a, _ in a })
        updateClockOffset()
    }

    /// Quarzablage aus den verfolgten Satelliten: gemessener minus vorhergesagter Doppler (Median).
    private func updateClockOffset() {
        guard let predictions else { return }
        let offsets = channels.filter { $0.locked }
            .compactMap { ch in predictions[ch.prn].map { ch.carrierHz - $0.dopplerHz } }.sorted()
        guard !offsets.isEmpty else { return }
        clockOffset = offsets[offsets.count / 2]
    }

    /// Hilfsdaten aus Start und eigenem Empfang (jüngste Bahn je PRN).
    private func currentAiding() -> GPSAidingData {
        var out = GPSAidingData()
        if let w = week10 {
            let reference = GPSTime.utc(week: GPSTime.fullWeek(w, near: options.referenceDate), tow: 0, leapSeconds: 0)
            out.ephemerides = ephemerides.values.sorted { $0.prn < $1.prn }.map { eph in
                .init(ephemeris: eph, week: GPSTime.fullWeek(eph.weekNumber, near: reference))
            }
        }
        out.almanac = almanac.values.sorted { $0.prn < $1.prn }
        if let s = lastSolution {
            out.position = [s.ecef.x, s.ecef.y, s.ecef.z]
            out.positionDate = currentGPSSeconds.map { GPSTime.epoch.addingTimeInterval($0 - 18) }
        }
        out.clockOffsetHz = clockOffset
        return out.merged(over: startAiding)
    }

    // MARK: Navigationsdaten

    private func ingest(_ sf: GPSSubframe, prn: Int) {
        if sf.id == 4, let ion = GPSIonoUTC(sf4: sf) { ionoUTC = ion }
        if sf.id >= 4, let t = currentGPSSeconds, let alm = GPSAlmanac(page: sf, nearAbsolute: t) {
            almanac[alm.prn] = alm
        }
        guard (1...3).contains(sf.id) else { return }
        subframes[prn, default: [:]][sf.id] = sf
        guard let s1 = subframes[prn]?[1], let s2 = subframes[prn]?[2], let s3 = subframes[prn]?[3],
              let eph = GPSEphemeris(prn: prn, sf1: s1, sf2: s2, sf3: s3) else { return }
        ephemerides[prn] = eph
        week10 = eph.weekNumber
    }

    // MARK: Messung und Lösung

    /// Kreuzkorrelation: Der C/A-Code eines starken Satelliten erzeugt im Code
    /// eines anderen Nebenspitzen bis −21 dB – bei Frequenzablagen nahe einem
    /// Vielfachen von 1 kHz (Codeperiode 1 ms). Die lange Suche fand bei sieben
    /// Satelliten mit 45 dB-Hz so 12–21 Schein-Satelliten. Verdächtig ist ein
    /// Kandidat, wenn ein ≥ 10 dB stärkerer Kanal an dieser Frequenz liegt und
    /// dessen Code an genau dieser Codeverschiebung so viel Leistung in den Code
    /// des Kandidaten streut, dass sie dessen C/N0 erklärt (bis auf 6 dB).
    /// Liefert den PRN des starken Satelliten.
    private func crossCorrelationSource(prn: Int, codePhase: Double, dopplerHz f: Double, cn0: Double,
                                        tolerance: Double) -> Int? {
        for ch in channels where ch.prn != prn && ch.strength - cn0 >= 10 {
            let d = f - ch.carrierHz
            guard abs(d - 1000 * (d / 1000).rounded()) < tolerance else { continue }
            let r = GPSCACode.crossCorrelation(ch.prn, prn, offsetChips: codePhase - ch.state.code_phase,
                                               dopplerHz: ch.carrierHz - f)
            if 20 * log10(max(r, 1e-6)) >= cn0 - ch.strength - 6 { return ch.prn }
        }
        return nil
    }

    /// Kanäle, die einer Kreuzkorrelation folgen, entfernen (ohne Wiederaufnahme).
    private func dropCrossCorrelations() {
        let suspects = channels.filter { ch in
            ch.cn0 > 0 && crossCorrelationSource(prn: ch.prn, codePhase: ch.state.code_phase, dopplerHz: ch.carrierHz,
                                                 cn0: ch.cn0, tolerance: 5) != nil
        }
        guard !suspects.isEmpty else { return }
        for ch in suspects {
            log.debug("Kanal PRN \(ch.prn) folgt einer Kreuzkorrelation – entfernt")
            retryAfter[ch.prn] = sampleIndex + Int64(10 * options.sampleRate)
            lostInfo[ch.prn] = nil
        }
        let ids = Set(suspects.map(\.prn))
        channels.removeAll { ids.contains($0.prn) }
    }

    private func measure() {
        dropCrossCorrelations()
        var observations: [GPSObservation] = []
        for ch in channels where ch.locked {
            guard let t = ch.transmitTime, ephemerides[ch.prn] != nil else { continue }
            observations.append(GPSObservation(prn: ch.prn, transmitTime: t, dopplerHz: ch.carrierHz, cn0: ch.cn0))
        }
        var solution: GPSSolution?
        if observations.count >= 4 {
            // Empfangszeit grob: späteste Sendezeit + 75 ms (≈ 22 500 km Laufzeit).
            let latest = observations.map(\.transmitTime).max()!
            let receive = latest + 0.075
            solution = GPSSolver.solve(observations, ephemerides: ephemerides,
                                       iono: options.ionosphere ? ionoUTC : nil, receiveTime: receive,
                                       initial: lastSolution?.ecef, troposphere: options.troposphere)
            if let s = solution {
                lastSolution = s
                lastSolutionSample = sampleIndex
                fixCount += 1
                // Erste Position: Zeit und Ort sind jetzt genau – Vorhersage gleich neu.
                if predictions == nil { nextPrediction = 0; updatePredictions() }
            }
        }
        publish()
    }

    private func publish() {
        let fix = lastSolution
        var list: [GPSChannelStatus] = []
        for ch in channels {
            var state: GPSChannelStatus.State
            switch ch.stage {
            case .pullIn: state = .acquired
            case .tracking: state = .tracking
            case .bitSync: state = .bitSync
            case .frameSync: state = .frameSync
            }
            if ephemerides[ch.prn] != nil && ch.isSynchronized { state = .ephemeris }
            let geo = fix?.satellites.first { $0.prn == ch.prn }
            var el: Double? = geo?.elevation, az: Double? = geo?.azimuth
            if geo == nil, let fix, let eph = ephemerides[ch.prn] {
                let p = eph.position(at: fix.gpsTime)
                let ae = GPSGeo.azimuthElevation(rx: fix.ecef, sat: p)
                el = ae.el * 180 / .pi; az = ae.az * 180 / .pi
            }
            let seen = Set((subframes[ch.prn] ?? [:]).keys.filter { $0 <= 3 })
            list.append(GPSChannelStatus(prn: ch.prn, state: state, cn0: ch.cn0, dopplerHz: ch.carrierHz,
                                         locked: ch.locked, subframes: seen, elevation: el, azimuth: az,
                                         usedInFix: geo != nil && lastSolutionSample == sampleIndex,
                                         longIntegration: ch.longIntegration, weakAcquired: weakAcquiredPRNs.contains(ch.prn)))
        }
        list.sort { $0.prn < $1.prn }
        var s = GPSReceiverStatus()
        s.elapsed = Double(sampleIndex) / options.sampleRate
        s.channels = list
        s.acquisition = lastAcquisition
        s.solution = fix
        s.solutionAge = lastSolutionSample.map { Double(sampleIndex - $0) / options.sampleRate }
        s.week = week10.map { GPSTime.fullWeek($0, near: options.referenceDate) }
        s.leapSeconds = ionoUTC?.leapSeconds ?? 18
        s.ephemerisCount = ephemerides.count
        s.hasIonosphere = ionoUTC != nil
        s.fixCount = fixCount
        s.predictedVisible = predictions?.count
        s.almanacCount = Set(almanac.keys).union(startAiding.almanac.map(\.prn)).count
        s.hotStart = hotStart
        updateClockOffset()
        let aiding = currentAiding()
        lock.withLock { snapshot = s; aidingOut = aiding }
    }
}
