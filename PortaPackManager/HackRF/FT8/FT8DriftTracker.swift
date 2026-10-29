import Foundation

/// Schätzt die Frequenzdrift des HackRF (Aufwärmen ohne TCXO) aus wiederholt
/// gehörten Stationen.
///
/// Eine FT8-Station sendet Zyklus für Zyklus auf derselben Audiofrequenz.
/// Ändert sich ihre gemessene Frequenz, hat sich (bis auf ihre eigene, meist
/// viel kleinere Drift) der Empfänger verstimmt – für alle Stationen gleich.
/// Die absolute Ablage bleibt unbekannt (dafür gibt es die Quarzkorrektur),
/// gemessen wird nur die Änderung δ(t) seit dem Start.
///
/// Geführt wird eine Folge von Schätzungen δ̂ an den Auswertezeitpunkten
/// (Start: δ̂ = 0). Jede Station mit einer früheren Messung zur Zeit t₁
/// *innerhalb* dieser Folge liefert einen Vorschlag δ̂(t₁) + (f − f₁), mit
/// δ̂(t₁) linear zwischen den Nachbarn eingesetzt. Der Median trennt Stationen
/// ab, die ihre Sendefrequenz verstellt haben (> `jumpTolerance` Hz daneben);
/// der Mittelwert der übrigen ist die neue Schätzung. Nur mit mindestens
/// `minStations` verschiedenen Stationen wird etwas geschätzt – sonst bleibt
/// alles, wie es ist.
///
/// Warum nicht einfach Δf/Δt je Station integrieren: FT8-Paare spannen 30 s
/// (gerade/ungerade Zyklen), integriert wird in 15-s-Schritten – beim
/// Aufwärmen (Drift nimmt ab) lief das um ≈ 7,5 s × Δ(Drift) weg (gemessen
/// 2,5 Hz Rest am Ende, Test „Aufwärmen“). Feste Frequenzketten je Station
/// wiederum blieben für gerade und ungerade Zyklen um die Drift der ersten
/// 15 s versetzt; die gemeinsame, interpolierte Folge koppelt beide.
struct FT8DriftTracker: Sendable {
    /// Eine Dekodierung: Station, Zeitpunkt (Mitte der Aussendung, Unix-
    /// Sekunden) und **Rohfrequenz** – also ohne die gerade angewandte
    /// Nachführung.
    struct Observation: Sendable {
        var key: String
        var time: Double
        var frequency: Double
    }

    /// Mindestzahl verschiedener Stationen mit Vorgeschichte je Schätzung.
    var minStations = 3
    /// Größte Spanne zur früheren Messung einer Station (s). Lang genug, um
    /// eine stille Viertelstunde zu überbrücken (die Drift dazwischen zeigen die
    /// Stationen danach); WSPR-Stationen senden seltener (`forWSPR`).
    var maxPairGap: Double = 1800
    /// Station gilt als verstellt, wenn ihr Vorschlag um mehr als so viele Hz
    /// vom Median abweicht.
    var jumpTolerance: Double = 3
    /// Fenster für die Drift (Ausgleichsgerade über die Schätzungen, s). Kurz,
    /// weil die Drift beim Aufwärmen abnimmt: mit 180 s lief die Fortschreibung
    /// über ausgefallene Zyklen bis 5,6 Hz zu weit, mit 90 s höchstens 3,3 Hz
    /// (Test „Aufwärmen“, sieben Startwerte).
    var rateWindow: Double = 90
    /// So lange nach der letzten Schätzung wird die Drift fortgeschrieben (s).
    var holdAfter: Double = 180

    static func forWSPR() -> FT8DriftTracker {
        var tracker = FT8DriftTracker()
        tracker.maxPairGap = 3600
        tracker.rateWindow = 900
        tracker.holdAfter = 600
        return tracker
    }

    /// Letzte Messungen je Station (aufsteigend, höchstens `maxPairGap` alt).
    private var heard: [String: [(time: Double, frequency: Double)]] = [:]
    /// Schätzungen δ̂ (aufsteigend nach Zeit); der erste Eintrag ist der Start (0).
    private var history: [(time: Double, offset: Double)] = []
    /// Zahl der Zyklen mit Schätzung.
    private(set) var estimates = 0
    /// Stationen der letzten Schätzung.
    private(set) var lastStations = 0
    /// Median der Steigungen Δf/Δt der letzten Schätzung – Drift, solange die
    /// Ausgleichsgerade noch zu wenige Punkte hat (sonst bliebe die Drift
    /// innerhalb der Aussendungen anfangs unausgeglichen, gerade dann, wenn
    /// sie am größten ist).
    private var pairSlope: Double?

    /// Abweichung seit dem Start (Hz) zur letzten Schätzung.
    var offset: Double { history.last?.offset ?? 0 }
    var offsetTime: Double? { history.last?.time }

    /// Neue Dekodierungen einer Auswertung (`time` = Mitte der Aussendungen).
    /// Liefert, ob daraus eine neue Schätzung entstand.
    @discardableResult
    mutating func add(_ observations: [Observation], at time: Double) -> Bool {
        // Doppelte Rufzeichen in einer Auswertung (zwei QSOs, Fehldekodierung): nicht verwenden.
        var counts: [String: Int] = [:]
        for o in observations { counts[o.key, default: 0] += 1 }
        let unique = observations.filter { counts[$0.key] == 1 }
        defer {
            for o in unique { heard[o.key, default: []].append((o.time, o.frequency)) }
            for key in Array(heard.keys) {
                heard[key]!.removeAll { time - $0.time > maxPairGap }
                if heard[key]!.count > 40 { heard[key]!.removeFirst(heard[key]!.count - 40) }
                if heard[key]!.isEmpty { heard[key] = nil }
            }
            // Die Folge muss so weit zurückreichen wie die ältesten Paare.
            if let keep = history.lastIndex(where: { time - $0.time > maxPairGap + 60 }), keep > 0, history.count > 2 {
                history.removeFirst(min(keep, history.count - 2))
            }
        }
        guard let first = history.first, let last = history.last else {
            if !unique.isEmpty { history = [(time, 0)] }
            return false
        }
        // Je Station ein Vorschlag. Bevorzugt „verankert“: frühere Messung innerhalb
        // der Folge, dort ist δ̂ bekannt. Sonst „lose“: Steigung zur letzten Messung,
        // fortgeschrieben ab der letzten Schätzung – nur zum Anlaufen (und nach
        // Lücken), solange es noch keine drei verankerten Stationen gibt.
        var anchored: [(value: Double, slope: Double)] = [], loose: [(value: Double, slope: Double)] = []
        for o in unique {
            guard let list = heard[o.key] else { continue }
            // Δt einzelner Stationen streut um ±2 s um die Auswertezeit: so viel Spiel.
            if let previous = list.last(where: { $0.time <= last.time + 3 && $0.time >= first.time - 3 }),
               o.time - previous.time > 1, o.time - previous.time <= maxPairGap {
                anchored.append((interpolated(previous.time) + o.frequency - previous.frequency,
                                 (o.frequency - previous.frequency) / (o.time - previous.time)))
            } else if let previous = list.last, previous.time > last.time + 3,
                      o.time - previous.time > 1, o.time - previous.time <= maxPairGap {
                let slope = (o.frequency - previous.frequency) / (o.time - previous.time)
                loose.append((last.offset + slope * (time - last.time), slope))
            }
        }
        let proposals = anchored.count >= minStations ? anchored : anchored + loose
        guard time > last.time else { return false }
        guard proposals.count >= minStations else {
            // Lange nichts geschätzt (Band still): Ohne Messungen innerhalb der Folge
            // käme nie wieder ein Vorschlag zustande. Neu verankern beim fortgeschriebenen
            // Wert – genau der, den der Empfangsweg gerade anwendet.
            if !unique.isEmpty, time - last.time > maxPairGap / 2 {
                history.append((time, correction.value(at: time)))
            }
            return false
        }
        let median = Self.median(proposals.map(\.value))
        let inliers = proposals.filter { abs($0.value - median) <= jumpTolerance }
        guard inliers.count >= minStations else { return false }
        history.append((time, inliers.reduce(0) { $0 + $1.value } / Double(inliers.count)))
        pairSlope = Self.median(inliers.map(\.slope))
        estimates += 1
        lastStations = inliers.count
        return true
    }

    /// δ̂ zur Zeit `t` innerhalb der Folge (linear zwischen den Nachbarn).
    private func interpolated(_ t: Double) -> Double {
        guard let upper = history.firstIndex(where: { $0.time >= t }) else { return history.last?.offset ?? 0 }
        guard upper > 0 else { return history[0].offset }
        let a = history[upper - 1], b = history[upper]
        guard b.time > a.time else { return b.offset }
        return a.offset + (b.offset - a.offset) * (t - a.time) / (b.time - a.time)
    }

    /// Drift in Hz/s: Ausgleichsgerade über die Schätzungen der letzten
    /// `rateWindow` Sekunden (mindestens drei über ≥ 30 s), sonst die
    /// Steigungen der letzten Schätzung; `nil` vor der ersten.
    var rate: Double? {
        guard estimates > 0, let last = history.last else { return nil }
        let points = history.filter { last.time - $0.time <= rateWindow }
        guard points.count >= 3, let first = points.first, last.time - first.time >= 30 else { return pairSlope }
        let mt = points.reduce(0) { $0 + $1.time } / Double(points.count)
        let mo = points.reduce(0) { $0 + $1.offset } / Double(points.count)
        let sxx = points.reduce(0) { $0 + ($1.time - mt) * ($1.time - mt) }
        let sxy = points.reduce(0) { $0 + ($1.time - mt) * ($1.offset - mo) }
        return sxx > 0 ? sxy / sxx : nil
    }

    /// Nachführung ab jetzt: Abweichung zur letzten Schätzung, mit der Drift
    /// höchstens `holdAfter` Sekunden fortgeschrieben. Vor der ersten
    /// Schätzung: keine.
    var correction: FT8FrequencyCorrection {
        guard estimates > 0, let last = history.last else { return .none }
        return FT8FrequencyCorrection(base: last.offset, time: last.time, rate: rate ?? 0, horizon: holdAfter)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}

/// Verschiebung des Audiobands (Hz) als Funktion der Zeit: `base` zur Zeit
/// `time`, danach mit `rate` Hz/s bis höchstens `horizon` Sekunden weiter.
struct FT8FrequencyCorrection: Sendable, Equatable {
    var base: Double
    var time: Double
    var rate: Double
    var horizon: Double

    static let none = FT8FrequencyCorrection(base: 0, time: 0, rate: 0, horizon: 0)

    func value(at t: Double) -> Double {
        base + rate * min(max(t - time, 0), horizon)
    }
}

/// Verschiebt das 12-kHz-Basisband um −`hz` (Phase stetig über die Blöcke).
/// Läuft auf dem Empfangsthread je Kanal.
struct FT8FrequencyShifter: Sendable {
    private var phase = 0.0

    mutating func apply(_ x: inout FT8Signal, hz: Double, rate: Double = FT8Channelizer.outputRate) {
        guard x.count > 0 else { return }
        if hz == 0 && phase == 0 { return }
        let step = -2 * Double.pi * hz / rate
        var p = phase
        for i in 0..<x.count {
            let c = Float(cos(p)), s = Float(sin(p))
            let r = x.re[i], m = x.im[i]
            x.re[i] = r * c - m * s
            x.im[i] = r * s + m * c
            p += step
        }
        phase = p.truncatingRemainder(dividingBy: 2 * Double.pi)
    }
}
