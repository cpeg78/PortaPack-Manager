import Foundation

/// Zerlegt den Empfang auf 433/868 MHz in Pakete aus Puls/Pause-Folgen –
/// wie rtl_433s Pulsdetektor (`pulse_detect.c`).
///
/// Kette: HackRF bei 2 MS/s um `offset` unter der Wunschfrequenz (die
/// Gleichspannungsspitze liegt dann außerhalb des Kanals), herausmischen,
/// ÷4 auf 500 kS/s (Kanal ±190 kHz). Der Kanal muss so breit sein:
/// billige Sensoren liegen 30–100 kHz neben der Sollfrequenz, und die
/// FSK-Sender auf 868 MHz (Bresser, LaCrosse IT+) haben ±60 kHz Hub –
/// gemessen an den rtl_433-Testaufnahmen. Dann je Abtastwert Leistung (für
/// OOK) und Phasendifferenz (FM, für FSK).
///
/// OOK: Schwelle in der Mitte zwischen Rauschschätzung (sehr träge,
/// nur in Ruhe nachgeführt) und Pulspegel, mit ±12 % Hysterese. Ein Paket
/// endet nach einer Pause von mehr als dem Zehnfachen des längsten Pulses
/// (mindestens 10 ms) oder spätestens nach 100 ms.
/// FSK: Ein FSK-Sender ist für OOK ein einziger langer Puls. Während des
/// ersten Pulses wird deshalb die FM mitgeschnitten; zeigt sie zwei
/// deutlich getrennte Frequenzen, wird daraus die Pulsfolge (hohe
/// Frequenz = Puls) und das OOK-Paket verworfen.
final class SensorDemodulator: @unchecked Sendable {
    static let inputRate = 2_000_000.0
    static let offset = 400_000.0          // = inputRate / 5 → Oszillator mit Periode 5
    static let basebandRate = 500_000.0

    // Grenzwerte wie in rtl_433 (`pulse_detect.h`), dort bei 250 kS/s in Abtastwerten.
    static let minPulseMicroseconds = 40.0
    static let maxPulses = 1200
    static let minGapSeconds = 0.010
    static let maxGapSeconds = 0.100
    static let maxGapRatio = 10
    /// Pulspegel mindestens 25 dB unter Vollaussteuerung.
    static let minHighLevel: Float = 0.003
    /// Erwarteter Pulspegel ohne Messung: 9 dB über dem Rauschen.
    static let highLowRatio: Float = 8
    /// FSK erst ab ±5 kHz Hub.
    static let minFSKSpanHz = 10_000.0

    /// Abtastrate des Basisbands, auf dem der Detektor arbeitet.
    let sampleRate: Double
    private let microsecondsPerSample: Double
    private let minPulseSamples: Int
    private let minGapSamples: Int
    private let maxGapSamples: Int
    private let leadIn: Int
    private let maxFSKSamples: Int

    private let stage1: [Float]
    private let oscillatorRe: [Float]
    private let oscillatorIm: [Float]
    private var phaseIndex = 0
    private var h1Re: [Float] = [], h1Im: [Float] = []
    private var lastRe: Float = 0, lastIm: Float = 0

    private enum State { case idle, pulse, gapStart, gap }
    private var state = State.idle
    private var length = 0
    /// Pausenlänge vor einem Puls, der sich noch als Störspitze erweisen kann.
    private var pendingGap = 0
    private var maxPulse = 0
    private var leadInCounter = 0
    private var lowEstimate: Float = 0
    private var highEstimate: Float = minHighLevel
    private var pulses: [Int] = []
    private var gaps: [Int] = []
    private var fmFirstPulse: [Float] = []
    private var fmSum: Double = 0
    private var fmCount = 0

    /// `sampleRate` nur für Tests mit Aufnahmen anderer Rate ändern –
    /// `process(_:)` liefert immer 500 kS/s.
    init(sampleRate: Double = basebandRate) {
        self.sampleRate = sampleRate
        microsecondsPerSample = 1e6 / sampleRate
        minPulseSamples = Int(Self.minPulseMicroseconds * sampleRate / 1e6)
        minGapSamples = Int(Self.minGapSeconds * sampleRate)
        maxGapSamples = Int(Self.maxGapSeconds * sampleRate)
        leadIn = Int(sampleRate / 250)          // 4 ms Rauschschätzung vorab
        maxFSKSamples = Int(sampleRate)         // 1 s
        stage1 = RadioDemodulator.lowpass(taps: 63, cutoff: 190_000, rate: Self.inputRate)
        oscillatorRe = (0..<5).map { Float(cos(-2 * Double.pi * Double($0) / 5)) }
        oscillatorIm = (0..<5).map { Float(sin(-2 * Double.pi * Double($0) / 5)) }
    }

    func reset() {
        h1Re = []; h1Im = []
        lastRe = 0; lastIm = 0
        state = .idle
        length = 0
        leadInCounter = 0
        lowEstimate = 0
        highEstimate = Self.minHighLevel
        clearPackage()
    }

    /// Rauschpegel in dBFS (für die Anzeige).
    var noiseDB: Double { 10 * log10(Double(max(lowEstimate, 1e-12))) }

    /// IQ-Block vom HackRF (int8, 2 MS/s).
    func process(_ iq: Data) -> [SensorPulseTrain] {
        let count = iq.count / 2
        guard count > 0 else { return [] }
        var re = [Float](repeating: 0, count: count)
        var im = [Float](repeating: 0, count: count)
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var k = phaseIndex
            for n in 0..<count {
                let i = Float(p[2 * n]) / 128, q = Float(p[2 * n + 1]) / 128
                let c = oscillatorRe[k], s = oscillatorIm[k]
                re[n] = i * c - q * s
                im[n] = i * s + q * c
                k += 1
                if k == 5 { k = 0 }
            }
            phaseIndex = k
        }
        let (bRe, bIm) = RadioDemodulator.decimateComplex(re, im, history: &h1Re, &h1Im, filter: stage1, factor: 4)
        return processBaseband(re: bRe, im: bIm)
    }

    /// Komplexes Basisband bei `sampleRate` (auch für Aufnahmen und Tests).
    func processBaseband(re: [Float], im: [Float]) -> [SensorPulseTrain] {
        var packages: [SensorPulseTrain] = []
        for n in re.indices {
            let r = re[n], i = im[n]
            let power = r * r + i * i
            let fm = atan2f(i * lastRe - r * lastIm, r * lastRe + i * lastIm)
            lastRe = r; lastIm = i
            if let package = step(power: power, fm: fm) { packages.append(package) }
        }
        return packages
    }

    // MARK: - Pulsdetektor

    private func step(power: Float, fm: Float) -> SensorPulseTrain? {
        let threshold = (lowEstimate + highEstimate) / 2
        let hysteresis = threshold / 8
        switch state {
        case .idle:
            if power > threshold + hysteresis && leadInCounter > leadIn {
                clearPackage()
                length = 0
                maxPulse = 0
                state = .pulse
            } else {
                // Rauschen sehr träge nachführen (1/1024 je Abtastwert).
                lowEstimate += (power - lowEstimate) / 1024
                highEstimate = max(lowEstimate * Self.highLowRatio, Self.minHighLevel)
                if leadInCounter <= leadIn { leadInCounter += 1 }
            }
        case .pulse:
            length += 1
            if power < threshold - hysteresis {
                if length < minPulseSamples {
                    // Zu kurz: Störspitze. Ganz am Anfang verwerfen, sonst der
                    // Pause davor zuschlagen (rtl_433 beendet hier das Paket –
                    // bei Störern im Band zerfallen Pakete dann in Stücke).
                    if pulses.isEmpty {
                        state = .idle
                    } else {
                        gaps.removeLast()
                        length += pendingGap
                        state = .gap
                    }
                } else {
                    pulses.append(length)
                    maxPulse = max(maxPulse, length)
                    length = 0
                    state = .gapStart
                }
            } else {
                highEstimate += (power - highEstimate) / 64
                highEstimate = max(highEstimate, Self.minHighLevel)
                fmSum += Double(fm)
                fmCount += 1
                if pulses.isEmpty && fmFirstPulse.count < maxFSKSamples {
                    fmFirstPulse.append(fm)
                } else if pulses.isEmpty {
                    // Dauerträger: als FSK auswerten, sonst neu beginnen.
                    let package = fskPackage()
                    state = .idle
                    return package
                }
            }
        case .gapStart:
            length += 1
            if power > threshold + hysteresis {
                // Kurze Lücke im Puls: zusammenfügen.
                length += pulses.removeLast()
                state = .pulse
            } else if length >= minPulseSamples {
                state = .gap
                if pulses.count == 1, let package = fskPackage() {
                    state = .idle
                    return package
                }
            }
        case .gap:
            length += 1
            if power > threshold + hysteresis {
                gaps.append(length)
                pendingGap = length
                length = 0
                if pulses.count >= Self.maxPulses {
                    state = .idle
                    return ookPackage()
                }
                state = .pulse
            } else if (length > Self.maxGapRatio * maxPulse && length > minGapSamples)
                        || length > maxGapSamples {
                gaps.append(length)
                state = .idle
                return ookPackage()
            }
        }
        return nil
    }

    private func clearPackage() {
        pulses = []
        gaps = []
        fmFirstPulse = []
        fmSum = 0
        fmCount = 0
    }

    private var levels: (rssi: Double, snr: Double) {
        let rssi = 10 * log10(Double(max(highEstimate, 1e-12)))
        return (rssi, rssi - noiseDB)
    }

    private func ookPackage() -> SensorPulseTrain? {
        guard !pulses.isEmpty else { return nil }
        // Pause zum letzten Puls ergänzen, falls sie fehlt.
        while gaps.count < pulses.count { gaps.append(length) }
        let us = microsecondsPerSample
        var train = SensorPulseTrain(modulation: .ook,
                                     pulses: pulses.map { Int(Double($0) * us) },
                                     gaps: gaps.map { Int(Double($0) * us) })
        (train.rssiDB, train.snrDB) = levels
        if fmCount > 0 {
            train.offsetKHz = fmSum / Double(fmCount) * sampleRate / (2 * .pi) / 1000
        }
        clearPackage()
        return train
    }

    /// Prüft den mitgeschnittenen ersten Puls auf FSK.
    private func fskPackage() -> SensorPulseTrain? {
        guard let fsk = Self.fskTrain(fm: fmFirstPulse, sampleRate: sampleRate) else { return nil }
        var train = fsk
        (train.rssiDB, train.snrDB) = levels
        clearPackage()
        return train
    }

    /// FSK-Pulsfolge aus FM-Werten (rad je Abtastwert). Verlangt zwei
    /// klar getrennte Frequenzen: mindestens 70 % der Werte liegen nahe
    /// einer der beiden, und die Läufe sind im Mittel mehrere Abtastwerte
    /// lang – die FM von Rauschen ist gleichverteilt und fällt durch.
    static func fskTrain(fm raw: [Float], sampleRate: Double) -> SensorPulseTrain? {
        guard raw.count >= 64 else { return nil }
        // leicht glätten (3 Abtastwerte)
        var fm = raw
        for n in 1..<(raw.count - 1) { fm[n] = (raw[n - 1] + raw[n] + raw[n + 1]) / 3 }
        let sorted = fm.sorted()
        let low = sorted[sorted.count / 10]
        let high = sorted[sorted.count * 9 / 10]
        let span = high - low
        guard Double(span) > 2 * .pi * minFSKSpanHz / sampleRate else { return nil }
        let near = fm.filter { abs($0 - low) < span / 4 || abs($0 - high) < span / 4 }.count
        guard Double(near) >= 0.7 * Double(fm.count) else { return nil }
        let mid = (low + high) / 2
        let hysteresis = span / 8
        // Läufe hoher und tiefer Frequenz
        var runs: [(high: Bool, length: Int)] = []
        var current = fm[0] > mid
        var run = 0
        for value in fm {
            let next = current ? value > mid - hysteresis : value > mid + hysteresis
            if next == current {
                run += 1
            } else {
                runs.append((current, run))
                current = next
                run = 1
            }
        }
        runs.append((current, run))
        guard Double(fm.count) / Double(runs.count) >= 3 else { return nil }
        var pulses: [Int] = [], gaps: [Int] = []
        var index = 0
        if runs.first?.high == false {
            pulses.append(0)
            gaps.append(runs[0].length)
            index = 1
        }
        while index < runs.count {
            pulses.append(runs[index].length)
            gaps.append(index + 1 < runs.count ? runs[index + 1].length : 0)
            index += 2
        }
        guard pulses.count >= 16 else { return nil }
        let us = 1e6 / sampleRate
        let toKHz = sampleRate / (2 * .pi) / 1000
        var train = SensorPulseTrain(modulation: .fsk,
                                     pulses: pulses.map { Int((Double($0) * us).rounded()) },
                                     gaps: gaps.map { Int((Double($0) * us).rounded()) })
        train.offsetKHz = Double(mid) * toKHz
        train.deviationKHz = Double(span) * toKHz
        return train
    }
}
