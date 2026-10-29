import Foundation

/// Ein Tracking-Kanal: DLL (Early/Prompt/Late, ±0,5 Chip), FLL-gestützte
/// PLL (Costas), Bitsynchronisation, Navigationsnachricht.
///
/// Schleifen nach Kaplan/Borre. Der Korrelator liefert je Codeperiode (1 ms)
/// Early/Prompt/Late und einen Rauscharm. Starke Signale: Schleifen je 1 ms,
/// erst 100 ms nur FLL (Atan-Diskriminator über zwei Prompts, unempfindlich
/// gegen Bitwechsel, Fangbereich ±250 Hz), dann PLL 2. Ordnung mit FLL-Stütze.
/// Schwache Signale (C/N0 < 37 dB-Hz): nach der Bitsynchronisation kohärent
/// über ein ganzes Datenbit (20 ms) und mit schmaler PLL – das senkt das
/// Phasenrauschen um den Faktor 20 bei gleicher Bandbreite (Kaplan, Kap. 5).
/// Die DLL ist trägergestützt (Coderate folgt dem Doppler) und braucht
/// deshalb nur eine schmale eigene Bandbreite.
final class GPSChannel {
    enum Stage: Int, Comparable, Sendable {
        case pullIn, tracking, bitSync, frameSync
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    static let halfSpacing = 0.5
    /// Unter dieser C/N0 (dB-Hz) wird nach der Bitsync auf 20 ms umgeschaltet,
    /// über `longIntegrationExit` wieder zurück (Hysterese).
    static let longIntegrationEntry = 37.0
    static let longIntegrationExit = 40.0
    /// Verlust erst nach so vielen Sekunden schlechter Güte (netto, Hysterese).
    static let lossSeconds = 3.0
    /// Darunter gilt die C/N0 als „kein Signal“ (Rauschen allein schätzt ≤ 16 dB-Hz).
    static let lossCN0 = 18.0
    /// Integrationslänge der FLL eines schwach gestarteten Kanals vor der
    /// Bitsync (ms): 1 ms rauschte bei 26 dB-Hz um 100 Hz weg, 5 ms fangen ±50 Hz.
    static let weakSegmentMs = 5

    let prn: Int
    let sampleRate: Double
    private let codeExt: [Int8]
    var state = gps_corr_state()
    /// Startete aus der Schwachsignal-Suche (andere Fangphase, siehe `bandwidths`).
    let weakStart: Bool
    private let cn0Hint: Double
    /// C/N0, vor der ersten Schätzung die der Akquisition.
    var strength: Double { cn0 > 0 ? cn0 : cn0Hint }

    /// Laufende Nummer der aktuell (unvollständig) korrelierten Codeperiode.
    private(set) var epoch = 0
    private(set) var stage = Stage.pullIn
    private(set) var carrierHz: Double
    private var freqIntegrator: Double
    private var codeCorrection = 0.0       // Chips/s aus der DLL
    private var lastPrompt: (i: Double, q: Double)?

    // Güte
    private(set) var cn0 = 0.0
    private(set) var locked = false
    /// War schon einmal eingerastet (dann lohnt die schmale Wiederaufnahme).
    private(set) var wasLocked = false
    /// Geschätzte Phasenlage cos 2φ (1 = eingerastet), rauschbereinigt.
    private(set) var phaseLock = 0.0
    private var avgP2 = 0.0, avgN2 = 0.0, qualityCount = 0
    private var avgDiff = 0.0, avgSum = 0.0, lockCount = 0
    private var windowCount = 0
    private var badSeconds = 0.0
    private(set) var lost = false

    // Bitsynchronisation (Energie je Ausrichtung) und lange Integration
    private var bitSumI = [Double](repeating: 0, count: 20)
    private var bitSumQ = [Double](repeating: 0, count: 20)
    private var bitEnergy = [Double](repeating: 0, count: 20)
    private var bitBlocks = 0
    private var bitSyncStart: Int?
    private var bitSyncCandidate: Int?
    private var bitSyncAgreement = 0
    private(set) var bitPhase: Int?
    /// Kohärent über ganze Datenbits (20 ms) – schwache Signale nach der Bitsync.
    private(set) var longIntegration = false
    private var block = (ie: 0.0, qe: 0.0, ip: 0.0, qp: 0.0, il: 0.0, ql: 0.0)
    private var blockCount = 0, blockStartEpoch = 0
    private var firstHalf = (i: 0.0, q: 0.0)
    /// FLL-Abschnitt eines schwach gestarteten Kanals vor der Bitsync.
    private var segment = (ie: 0.0, qe: 0.0, ip: 0.0, qp: 0.0, il: 0.0, ql: 0.0)
    private var segmentCount = 0
    private var longSince = 0.0
    /// Alter (s), ab dem die PLL läuft; nil = bisher nur FLL.
    private var pllStart: Double?

    // Navigationsnachricht und Zeit
    private var decoder = GPSNavDecoder()
    /// (Sendezeit des Subframebeginns, Codeperiode dort).
    private(set) var timeAnchor: (tow: Double, epoch: Int)?
    private(set) var subframesSeen = Set<Int>()

    /// - Parameter cn0Hint: C/N0-Schätzung der Akquisition (0 = unbekannt).
    init(prn: Int, sampleRate: Double, codePhase: Double, dopplerHz: Double, cn0Hint: Double = 0) {
        self.prn = prn
        self.sampleRate = sampleRate
        let code = GPSCACode.code(prn: prn).map { Int8($0 == 0 ? 1 : -1) }
        codeExt = [code[1022]] + code + [code[0]]
        weakStart = cn0Hint > 0 && cn0Hint < Self.longIntegrationEntry
        self.cn0Hint = cn0Hint
        carrierHz = dopplerHz
        freqIntegrator = dopplerHz
        var p = codePhase.truncatingRemainder(dividingBy: 1023)
        if p < 0 { p += 1023 }
        state.code_phase = p
        state.noise_offset = Double(Self.noiseOffset(code))
        updateNCOs()
    }

    var isSynchronized: Bool { timeAnchor != nil }

    /// Sendezeit laut Satellitenuhr am aktuellen Verarbeitungsstand.
    var transmitTime: Double? {
        guard let a = timeAnchor else { return nil }
        var t = a.tow + Double(epoch - a.epoch) * 1e-3 + state.code_phase / GPSConst.chipRate
        if t >= GPSConst.weekSeconds { t -= GPSConst.weekSeconds }
        return t
    }

    /// Korreliert `count` komplexe Werte; liefert dekodierte Subframes.
    func process(_ iq: UnsafePointer<Float>, count: Int) -> [GPSSubframe] {
        var out: [GPSSubframe] = []
        var offset = 0
        codeExt.withUnsafeBufferPointer { code in
            while offset < count {
                var done: Int32 = 0
                let used = Int(gps_correlate(&state, code.baseAddress!, iq + 2 * offset,
                                             Int32(count - offset), Self.halfSpacing, &done))
                offset += used
                if done != 0 { out += epochCompleted() }
            }
        }
        return out
    }

    /// Codeversatz für den Rauscharm: nahe der halben Periode, wo die
    /// Autokorrelation an drei Nachbarstellen −1/1023 ist (kein Signalrest).
    static func noiseOffset(_ code: [Int8]) -> Int {
        func r(_ k: Int) -> Int {
            var s = 0
            for i in 0..<1023 { s += Int(code[i]) * Int(code[(i + k) % 1023]) }
            return s
        }
        for d in 0..<400 {
            for k in [511 + d, 511 - d] where r(k - 1) == -1 && r(k) == -1 && r(k + 1) == -1 && r(k + 2) == -1 {
                return k
            }
        }
        return 511
    }

    private func updateNCOs() {
        state.carr_step = carrierHz / sampleRate
        let codeRate = GPSConst.chipRate * (1 + carrierHz / GPSConst.l1) + codeCorrection
        state.code_step = codeRate / sampleRate
    }

    private func epochCompleted() -> [GPSSubframe] {
        let ie = Double(state.ie), qe = Double(state.qe)
        let ip = Double(state.ip), qp = Double(state.qp)
        let il = Double(state.il), ql = Double(state.ql)
        let noise = Double(state.in) * Double(state.in) + Double(state.qn) * Double(state.qn)
        state.ie = 0; state.qe = 0; state.ip = 0; state.qp = 0; state.il = 0; state.ql = 0
        state.in = 0; state.qn = 0
        state.count = 0
        let finished = epoch
        epoch += 1
        let age = Double(finished) * 1e-3

        updateQuality(ip: ip, qp: qp, noise: noise, age: age)

        // --- Schleifen: je 1 ms, schwach gestartet je 5 ms (nur FLL), nach der
        // Bitsync bei schwachem Signal je Datenbit (20 ms) ---
        if !longIntegration {
            if weakStart {
                segment.ie += ie; segment.qe += qe; segment.ip += ip; segment.qp += qp; segment.il += il; segment.ql += ql
                segmentCount += 1
                if segmentCount == Self.weakSegmentMs {
                    runLoops(e: (segment.ie, segment.qe), p: (segment.ip, segment.qp), l: (segment.il, segment.ql),
                             t: Double(Self.weakSegmentMs) * 1e-3, age: age, halves: nil)
                    segment = (0, 0, 0, 0, 0, 0); segmentCount = 0
                }
            } else {
                runLoops(e: (ie, qe), p: (ip, qp), l: (il, ql), t: 1e-3, age: age, halves: nil)
            }
        }

        if stage == .pullIn && age >= 0.6 { stage = .tracking }
        guard stage >= .tracking else { return [] }

        // --- Bitsynchronisation: Energie der 20-ms-Summen je Ausrichtung ---
        guard let phase = bitPhase else {
            searchBitSync(finished: finished, ip: ip, qp: qp)
            return []
        }

        // --- Bitweise Summen (Ausrichtung = Bitgrenze) ---
        if (finished - phase) % 20 == 0 {
            block = (0, 0, 0, 0, 0, 0); blockCount = 0; blockStartEpoch = finished
        }
        block.ie += ie; block.qe += qe; block.ip += ip; block.qp += qp; block.il += il; block.ql += ql
        blockCount += 1
        if blockCount == 10 { firstHalf = (block.ip, block.qp) }
        guard blockCount == 20 else { return [] }
        blockCount = 0
        if longIntegration {
            let second = (i: block.ip - firstHalf.i, q: block.qp - firstHalf.q)
            runLoops(e: (block.ie, block.qe), p: (block.ip, block.qp), l: (block.il, block.ql), t: 0.02, age: age,
                     halves: (firstHalf, second))
        }
        // Umschalten nur an der Bitgrenze. Ein schwach gestarteter Kanal hat bis
        // hierher nur die FLL – er wechselt sofort auf 20 ms mit PLL.
        let wantLong = longIntegration ? cn0 < Self.longIntegrationExit
                                       : weakStart && pllStart == nil || (cn0 > 0 && cn0 < Self.longIntegrationEntry)
        if wantLong != longIntegration {
            longIntegration = wantLong
            longSince = age
            lastPrompt = nil
            avgDiff = 0; avgSum = 0; lockCount = 0
            if pllStart == nil { pllStart = age }
        }

        var frames: [GPSSubframe] = []
        for event in decoder.push(bit: block.ip > 0, epoch: blockStartEpoch) {
            switch event {
            case .timing(let tow, let at):
                timeAnchor = (tow, at)
                stage = .frameSync
            case .subframe(let sf):
                subframesSeen.insert(sf.id)
                frames.append(sf)
            }
        }
        if !decoder.isSynchronized && stage == .frameSync {
            stage = .bitSync
            timeAnchor = nil
        }
        return frames
    }

    // MARK: Schleifen

    /// Schleifenbandbreiten (PLL, FLL, DLL in Hz) nach Phase und C/N0.
    /// PLL 0 = nur FLL.
    private func bandwidths(age: Double, t: Double) -> (pll: Double, fll: Double, dll: Double) {
        // Die FLL-Stütze ist nur zum Fangen breit: Ihr Diskriminator rauscht bei
        // schwachem Signal, mit 2 Hz Dauerbandbreite schwankte die Phase um ±40°.
        let fll = age - longSince < 1 ? 2.0 : 0.25
        if longIntegration {
            // 20 ms kohärent: B·T ≤ 0,12 hält die diskrete Schleife stabil. Die
            // trägergestützte DLL darf nach dem Einschwingen sehr schmal sein:
            // 0,05 Hz halbiert das Coderauschen gegenüber 0,2 Hz (bei 25 dB-Hz ≈ 6 → 3 m).
            return (cn0 >= 30 ? 6 : 4, fll, age - longSince < 2 ? 0.2 : 0.05)
        }
        if weakStart {
            // Doppler aus der langen Suche auf ±10 Hz genau. Bis zur Bitsync
            // Costas-PLL über 5-ms-Abschnitte: Mit 1 ms rastete sie bei < 30 dB-Hz
            // nicht ein, eine reine FLL über 1 ms lief um 100 Hz weg.
            return (cn0 >= 30 ? 6 : 4, fll, 0.2)
        }
        switch age {
        case ..<0.1: return (0, 25, 2)
        case ..<0.6: return (20, 10, 2)
        case ..<1: return (15, 2, 2)
        default: return (cn0 > 0 && cn0 < 32 ? 10 : 15, 2, 0.5)
        }
    }

    /// `halves`: Prompt der beiden 10-ms-Hälften eines Datenbits (lange
    /// Integration). Innerhalb eines Bits wechselt das Vorzeichen nicht, der
    /// Frequenzfehler folgt dann eindeutig per atan2 (±25 Hz); der
    /// Costas-Diskriminator über ganze Bits rastete sonst bei ±25 Hz falsch ein.
    private func runLoops(e: (Double, Double), p: (Double, Double), l: (Double, Double), t: Double, age: Double,
                          halves: (first: (i: Double, q: Double), second: (i: Double, q: Double))?) {
        let (ip, qp) = p
        // --- Träger: FLL / PLL ---
        var freqError = 0.0
        if let h = halves {
            let cross = h.first.i * h.second.q - h.second.i * h.first.q
            let dot = h.first.i * h.second.i + h.first.q * h.second.q
            if cross != 0 || dot != 0 { freqError = atan2(cross, dot) / (2 * .pi * t / 2) }
        } else if let last = lastPrompt {
            let cross = last.i * qp - ip * last.q
            let dot = last.i * ip + last.q * qp
            if dot != 0 { freqError = atan(cross / dot) / (2 * .pi * t) }
        }
        lastPrompt = (ip, qp)
        let phaseError = ip != 0 ? atan(qp / ip) / (2 * .pi) : 0   // Zyklen

        let bw = bandwidths(age: age, t: t)
        if bw.pll == 0 {
            freqIntegrator += 4 * bw.fll * t * freqError
            carrierHz = freqIntegrator
        } else {
            // Ein schwach gestarteter Kanal gilt erst mit der 20-ms-PLL als
            // phasenstarr; vorher bewertet die Verlusterkennung nur die C/N0.
            if pllStart == nil && (!weakStart || longIntegration) { pllStart = age }
            let w0 = bw.pll / 0.53
            freqIntegrator += t * (w0 * w0 * phaseError + 4 * bw.fll * freqError)
            carrierHz = freqIntegrator + 1.414 * w0 * phaseError
        }

        // --- Code: DLL, normiertes Early-minus-Late der Beträge ---
        let early = (e.0 * e.0 + e.1 * e.1).squareRoot(), late = (l.0 * l.0 + l.1 * l.1).squareRoot()
        if early + late > 0 {
            let err = 0.5 * (early - late) / (early + late)    // Chips, positiv = Replik zu spät
            codeCorrection = 4 * bw.dll * err
        }
        updateNCOs()

        // --- Phasenlage cos 2φ aus den Summen dieser Integrationslänge ---
        let tau = cn0 >= 35 ? 0.2 : 0.6
        lockCount += 1
        let a = max(1 / Double(lockCount), t / tau)
        avgDiff += a * (ip * ip - qp * qp - avgDiff)
        avgSum += a * (ip * ip + qp * qp - avgSum)
        let noiseHere = avgN2 * t / 1e-3
        let signal = avgSum - noiseHere
        phaseLock = signal > 0 ? max(-1, min(1, avgDiff / max(signal, avgSum * 0.05))) : 0
    }

    // MARK: Güte

    /// C/N0 aus Prompt- und Rauscharm-Leistung (je 1 ms): (|P|² − |N|²)/|N|²/T.
    /// Erwartungstreu auch tief im Rauschen, unabhängig von Phase und Datenbits.
    private func updateQuality(ip: Double, qp: Double, noise: Double, age: Double) {
        let tau = cn0 >= 35 ? 0.3 : 1.0
        qualityCount += 1
        let a = max(1 / Double(qualityCount), 1e-3 / tau)
        avgP2 += a * (ip * ip + qp * qp - avgP2)
        avgN2 += a * (noise - avgN2)
        windowCount += 1
        guard windowCount == 100 else { return }
        windowCount = 0
        let snr = avgN2 > 0 ? (avgP2 - avgN2) / avgN2 : 0
        cn0 = snr > 0 ? max(0, 10 * log10(snr / 1e-3)) : 0
        // Mit 20 ms ist die Phasenlage verlässlich gemessen; dann genügen 20 dB-Hz.
        locked = cn0 >= (longIntegration ? 20 : 23) && phaseLock > 0.5 && pllStart != nil && age >= 0.3
        if locked { wasLocked = true }
        if age > 1 {
            // Phasenlage erst bewerten, wenn die PLL eine Sekunde lief.
            let pllSettled = pllStart.map { age - $0 >= 1 } ?? false
            let bad = cn0 < Self.lossCN0 || (pllSettled && phaseLock < 0.2)
            badSeconds = bad ? badSeconds + 0.1 : max(0, badSeconds - 0.2)
            if badSeconds >= Self.lossSeconds { lost = true }
        }
    }

    // MARK: Bitsynchronisation

    /// Je Ausrichtung k (Bitbeginn bei Epoche ≡ k mod 20) die Energie der
    /// komplexen 20-ms-Summen; die richtige Ausrichtung hat die größte, weil
    /// kein Bitwechsel in ihre Summen fällt. Arbeitet ohne Phasenlock und tief
    /// im Rauschen (anders als das Zählen von Vorzeichenwechseln).
    private func searchBitSync(finished: Int, ip: Double, qp: Double) {
        if bitSyncStart == nil { bitSyncStart = finished }
        for k in 0..<20 { bitSumI[k] += ip; bitSumQ[k] += qp }
        let k = (finished + 1) % 20               // Ausrichtung, deren Bit hier endet
        if finished - 19 >= bitSyncStart! {
            bitEnergy[k] += bitSumI[k] * bitSumI[k] + bitSumQ[k] * bitSumQ[k]
            if k == 0 { bitBlocks += 1 }
        }
        bitSumI[k] = 0; bitSumQ[k] = 0
        guard k == 0 else { return }
        let needed = cn0 >= 35 ? 25 : (cn0 >= 28 ? 60 : 120)
        guard bitBlocks >= needed, bitBlocks % 10 == 0 else { return }
        let best = bitEnergy.indices.max { bitEnergy[$0] < bitEnergy[$1] }!
        if best == bitSyncCandidate { bitSyncAgreement += 1 } else { bitSyncCandidate = best; bitSyncAgreement = 1 }
        guard bitSyncAgreement >= 3 else { return }
        bitPhase = best
        stage = .bitSync
        blockCount = 0
    }
}
