import Accelerate
import Foundation

/// Antennen-Check: misst die wichtigen Bänder nacheinander mit 20 MS/s und
/// bewertet in Alltagssprache, wofür die Antenne taugt.
///
/// Messverfahren je Band: ein oder mehrere 20-MHz-Fenster (nutzbar ±7 MHz,
/// DC-Lücke ±60 kHz wie beim `BandScanner`), FFT 2048 (≈ 9,8 kHz je Bin,
/// 102 µs je Rahmen – so füllt eine ADS-B-Antwort von 120 µs einen ganzen
/// Rahmen). Gesammelt werden das mittlere Spektrum (Dauersender), ein
/// Spitzenwert-Spektrum über Gruppen zu 8 Rahmen (kurze Funksprüche, AIS,
/// Funksensoren) und für ADS-B die Leistung je Rahmen im Kanal 1090 ± 1 MHz.
/// Der Rauschboden ist das untere Fünftel aller nutzbaren Bins des Bandes –
/// der Median läge im vollen UKW-Band schon auf Sendern.
enum AntennaBand: String, CaseIterable, Codable, Sendable, Identifiable {
    case fm, airband, weatherSat, ais, dab, sonde, sensors, adsb, gps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fm: String(localized: "UKW-Radio")
        case .airband: String(localized: "Flugfunk")
        case .weatherSat: String(localized: "Wettersatelliten")
        case .ais: String(localized: "Schiffe (AIS)")
        case .dab: String(localized: "Digitalradio (DAB+)")
        case .sonde: String(localized: "Wetterballons (Radiosonden)")
        case .sensors: String(localized: "Funksensoren")
        case .adsb: String(localized: "Flugzeuge (ADS-B)")
        case .gps: "GPS"
        }
    }

    var frequencyText: String {
        switch self {
        case .fm: "87,5–108 MHz"
        case .airband: "118–137 MHz"
        case .weatherSat: "137–138 MHz"
        case .ais: "161,975 / 162,025 MHz"
        case .dab: String(localized: "174–240 MHz (Band III)")
        case .sonde: "400–406 MHz"
        case .sensors: "433,9 / 868 MHz"
        case .adsb: "1090 MHz"
        case .gps: "1575,42 MHz"
        }
    }

    var symbol: String {
        switch self {
        case .fm: "radio"
        case .airband: "headphones"
        case .weatherSat: "cloud.sun"
        case .ais: "ferry"
        case .dab: "dot.radiowaves.left.and.right"
        case .sonde: "balloon"
        case .sensors: "sensor"
        case .adsb: "airplane"
        case .gps: "location.viewfinder"
        }
    }

    /// Verstärkung wie auf der jeweiligen Empfängerseite – so misst der Check,
    /// was die Seite später wirklich sieht.
    var receiver: GainProfile.Receiver {
        switch self {
        case .fm: .radio
        case .airband: .acars
        case .weatherSat: .meteor
        case .ais: .ais
        case .dab: .dab
        case .sonde: .sonde
        case .sensors: .sensors
        case .adsb: .adsb
        case .gps: .gps
        }
    }

    /// Fenstermitten in MHz. Schmale Bänder liegen 3 MHz neben der Mitte
    /// (weg von DC-Spitze und Filterflanke).
    var centersMHz: [Double] {
        switch self {
        case .fm: [93.5, 104.5]
        case .airband: [124, 132]
        case .weatherSat: [140.5]
        case .ais: [165]               // AISModel: 162,000 ± 25 kHz
        case .dab: [180, 192, 204, 216, 228, 236]   // DABChannel.bandIII 5A–13F
        case .sonde: [403.2]           // 403,14–403,26 in der DC-Lücke, dort sendet kaum eine Sonde
        case .sensors: [431, 865.5]
        case .adsb: [1087]
        case .gps: [1572.42]
        }
    }

    /// Bereiche (MHz), in denen nach Signalen gesucht wird.
    var rangesMHz: [ClosedRange<Double>] {
        switch self {
        case .fm: [87.5...108]
        case .airband: [118...136.99]
        case .weatherSat: [137...138]
        case .ais: [161.960...161.990, 162.010...162.040]
        case .dab: [174...240]
        case .sonde: [400.15...406]
        case .sensors: [433.05...434.79, 868.0...868.6, 869.4...869.65]
        case .adsb: [1089...1091]
        case .gps: [1574.4...1576.4]
        }
    }

    /// Verweildauer je Fenster in Sekunden. Lang, wo nur gelegentlich gesendet
    /// wird (Funksprüche, AIS alle paar Sekunden, Sensoren alle 30–60 s).
    var dwellSeconds: Double {
        switch self {
        case .fm: 2
        case .airband: 8
        case .weatherSat: 3
        case .ais: 12
        case .dab: 1.5
        case .sonde: 6
        case .sensors: 12
        case .adsb: 10
        case .gps: 2
        }
    }

    /// Dauersender werden im mittleren Spektrum bewertet, kurze Aussendungen
    /// im Spitzenwert-Spektrum.
    var bursty: Bool {
        switch self {
        case .airband, .ais, .sensors: true
        default: false
        }
    }

    /// Benachbarte Bins zu einem Signal zusammenfassen (kHz).
    var mergeKHz: Double {
        switch self {
        case .fm: 150
        case .airband: 15
        case .weatherSat: 60
        case .ais: 30
        case .dab: 1000
        case .sonde: 20
        case .sensors: 60
        case .adsb, .gps: 500
        }
    }

    /// Bereich (MHz) für die Leistung je Rahmen – nur ADS-B.
    var burstChannelMHz: ClosedRange<Double>? {
        self == .adsb ? 1089...1091 : nil
    }

    static var totalSeconds: Double {
        allCases.reduce(0) { $0 + Double($1.centersMHz.count) * ($1.dwellSeconds + AntennaCheck.settleSeconds) }
    }
}

/// Ein gefundenes Signal: Frequenz und Abstand zum Rauschboden.
struct AntennaSignal: Codable, Sendable, Hashable {
    var mhz: Double
    var levelDB: Double
    /// DAB-Blockname (5C …), sonst leer.
    var label: String?
}

/// Messwerte eines Bandes (gespeichert; die Bewertung wird beim Anzeigen
/// gerechnet, damit spätere Schwellen auch für alte Messungen gelten).
struct AntennaBandMeasurement: Codable, Sendable, Hashable {
    var band: AntennaBand
    /// Rauschboden in dBFS (Rauschdichte, als füllte sie das ganze Band).
    var floorDBFS: Double
    /// Stärkste Signale, absteigend (höchstens 12, ab 6 dB über dem Boden).
    var signals: [AntennaSignal]
    /// Wandleranschlag (Anteil der Werte am Anschlag, höchster Wert der Fenster).
    var clipped: Double
    /// Pegel (RMS, dBFS), höchster Wert der Fenster.
    var rmsDBFS: Double
    /// Nur ADS-B: stärkste Antwort über dem Kanalboden (dB) und Antworten > 10 dB je Sekunde.
    var burstPeakDB: Double?
    var burstsPerSecond: Double?
    var seconds: Double
    /// Musste die Verstärkung gegen Übersteuerung gesenkt werden, die verwendete
    /// Einstellung (z. B. „LNA 16/VGA 20“), sonst `nil`.
    var reducedGain: String?

    var strongest: Double { signals.first?.levelDB ?? 0 }
    var countOver10: Int { signals.filter { $0.levelDB >= 10 }.count }
}

struct AntennaCheckResult: Codable, Sendable {
    var date: Date
    var externalAmplifier: Bool
    var antennaPower: Bool
    var measurements: [AntennaBandMeasurement]
    /// false, wenn abgebrochen – dann fehlen Bänder.
    var complete: Bool

    static let storageKey = "antennaCheckResult"

    static func load(_ defaults: UserDefaults = .standard) -> AntennaCheckResult? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(AntennaCheckResult.self, from: data)
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}

/// Spektren eines Messfensters (FFT-geshiftet, in Vollaussteuerungs-Einheiten:
/// weißes Rauschen der Leistung σ² ergibt σ²/(2·127²) je Bin).
struct AntennaWindowSpectrum: Sendable {
    var centerMHz: Double
    var mean: [Float]
    var hold: [Float]
    /// Kanalleistung je Rahmen (nur ADS-B).
    var burst: [Float]
    var seconds: Double
    var clipped: Double
    var rmsDBFS: Double
}

enum AntennaCheck {
    static let sampleRate: UInt32 = 20_000_000
    static let fftSize = 2048
    static let usableHalfSpanMHz = 7.0
    static let dcHoleMHz = 0.06
    static let settleSeconds = 0.25
    static var binMHz: Double { Double(sampleRate) / 1e6 / Double(fftSize) }

    // MARK: - Auswertung der Spektren

    /// Wertet die Fenster eines Bandes aus – reine Funktion.
    /// `blocked`: Dauerstörer im Sondenband (Vorgabe: Einstellung `SondeBlockList`).
    static func analyze(band: AntennaBand, windows: [AntennaWindowSpectrum],
                        blocked: (Double) -> Bool = SondeReceiver.isBlocked) -> AntennaBandMeasurement {
        var meanBins: [Float] = [], holdBins: [Float] = []
        for w in windows {
            for i in 0..<w.mean.count {
                let off = offset(of: i, count: w.mean.count)
                guard abs(off) <= usableHalfSpanMHz, abs(off) >= dcHoleMHz else { continue }
                meanBins.append(w.mean[i])
                if i < w.hold.count { holdBins.append(w.hold[i]) }
            }
        }
        let meanFloor = max(percentile(meanBins, 0.2), 1e-20)
        let holdFloor = max(percentile(holdBins, 0.2), 1e-20)

        var signals: [AntennaSignal]
        if band == .dab {
            signals = dabBlocks(windows: windows, floor: meanFloor)
        } else {
            var points: [(mhz: Double, level: Double)] = []
            for w in windows {
                let values = band.bursty ? w.hold : w.mean
                let floor = band.bursty ? holdFloor : meanFloor
                for i in 0..<values.count {
                    let off = offset(of: i, count: values.count)
                    guard abs(off) <= usableHalfSpanMHz, abs(off) >= dcHoleMHz else { continue }
                    let mhz = w.centerMHz + off
                    guard band.rangesMHz.contains(where: { $0.contains(mhz) }), !isSpur(mhz, band: band, blocked: blocked) else { continue }
                    points.append((mhz, 10 * log10(Double(max(values[i], 1e-20) / floor))))
                }
            }
            signals = merge(points, widthMHz: band.mergeKHz / 1000)
        }
        signals = Array(signals.filter { $0.levelDB >= 6 }.sorted { $0.levelDB > $1.levelDB }.prefix(12))

        var burstPeak: Double?, burstRate: Double?
        if band.burstChannelMHz != nil {
            let frames = windows.flatMap(\.burst)
            let seconds = windows.reduce(0) { $0 + $1.seconds }
            if !frames.isEmpty {
                let median = max(Double(percentile(frames, 0.5)), 1e-20)
                burstPeak = 10 * log10(Double(frames.max() ?? 0) / median)
                let over = frames.filter { Double($0) >= median * 10 }.count
                burstRate = seconds > 0 ? Double(over) / seconds : 0
            }
        }
        return AntennaBandMeasurement(
            band: band,
            floorDBFS: 10 * log10(Double(meanFloor)),
            signals: signals,
            clipped: windows.map(\.clipped).max() ?? 0,
            rmsDBFS: windows.map(\.rmsDBFS).max() ?? -100,
            burstPeakDB: burstPeak, burstsPerSecond: burstRate,
            seconds: windows.reduce(0) { $0 + $1.seconds })
    }

    static func offset(of bin: Int, count: Int) -> Double {
        Double(bin - count / 2) * (Double(sampleRate) / 1e6 / Double(count))
    }

    /// Glatte MHz-Werte sind beim HackRF oft eigene Störlinien; im Sondenband
    /// zusätzlich die eingetragenen Dauerstörer (Einstellungen ▸ Antenne & Gerät).
    static func isSpur(_ mhz: Double, band: AntennaBand, blocked: (Double) -> Bool = SondeReceiver.isBlocked) -> Bool {
        if abs(mhz - mhz.rounded()) < binMHz * 1.5 { return true }
        if band == .sonde, blocked(mhz * 1e6) { return true }
        return false
    }

    /// Fasst Punkte zusammen, die näher als `widthMHz` beieinanderliegen, und behält den stärksten.
    static func merge(_ points: [(mhz: Double, level: Double)], widthMHz: Double) -> [AntennaSignal] {
        var result: [AntennaSignal] = []
        for p in points.sorted(by: { $0.mhz < $1.mhz }) {
            if let last = result.last, p.mhz - last.mhz <= widthMHz {
                if p.level > last.levelDB { result[result.count - 1] = AntennaSignal(mhz: p.mhz, levelDB: p.level) }
            } else {
                result.append(AntennaSignal(mhz: p.mhz, levelDB: p.level))
            }
        }
        return result
    }

    /// DAB-Blöcke: mittlere Leistung über ±700 kHz um die Blockmitte gegen den Boden.
    static func dabBlocks(windows: [AntennaWindowSpectrum], floor: Float) -> [AntennaSignal] {
        var best: [String: AntennaSignal] = [:]
        for channel in DABChannel.bandIII {
            for w in windows {
                let delta = channel.megahertz - w.centerMHz
                guard abs(delta) + 0.7 <= usableHalfSpanMHz else { continue }
                var sum: Float = 0, n = 0
                for i in 0..<w.mean.count {
                    let off = offset(of: i, count: w.mean.count)
                    guard abs(off - delta) <= 0.7, abs(off) >= dcHoleMHz else { continue }
                    sum += w.mean[i]; n += 1
                }
                guard n > 0 else { continue }
                let level = 10 * log10(Double(sum / Float(n) / floor))
                if level > (best[channel.name]?.levelDB ?? -.infinity) {
                    best[channel.name] = AntennaSignal(mhz: channel.megahertz, levelDB: level, label: channel.name)
                }
            }
        }
        return Array(best.values)
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    // MARK: - Bewertung

    enum Rating: String, Codable, Sendable {
        case good, marginal, weak, overloaded, noInformation

        var title: String {
            switch self {
            case .good: String(localized: "gut")
            case .marginal: String(localized: "knapp")
            case .weak: String(localized: "zu schwach")
            case .overloaded: String(localized: "übersteuert")
            case .noInformation: String(localized: "keine Aussage")
            }
        }
    }

    struct Verdict: Sendable, Equatable {
        var rating: Rating
        var text: String
    }

    /// Ab diesem Anteil am Anschlag gilt ein Band als übersteuert (wie `ReceiveLevel`).
    static let overloadedFraction = 0.01
    static let clipWarningFraction = 0.001

    /// Bewertet ein Band – reine Funktion.
    static func verdict(for m: AntennaBandMeasurement) -> Verdict {
        if m.clipped >= overloadedFraction {
            return Verdict(rating: .overloaded, text: String(localized: "Übersteuert (\((m.clipped * 100).formatted(.number.precision(.fractionLength(1)))) % am Anschlag) – ein starker Sender in der Nähe oder zu viel Verstärkung. Verstärkung senken; gegen starke UKW- oder Fernsehsender hilft ein Filter."))
        }
        var v = rawVerdict(for: m)
        if let reduced = m.reducedGain {
            v.text += " " + String(localized: "Dafür musste die Verstärkung auf \(reduced) herunter – starke Sender in der Nähe; die Automatik der Empfängerseite macht das von selbst.")
        }
        if m.clipped >= clipWarningFraction {
            v.text += " " + String(localized: "Knapp an der Übersteuerung – eine Stufe weniger Verstärkung wäre sicherer.")
        }
        return v
    }

    private static func db(_ value: Double) -> String { "\(Int(value.rounded())) dB" }
    private static func mhz(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(3))) }

    private static func rawVerdict(for m: AntennaBandMeasurement) -> Verdict {
        let best = m.strongest
        let count = m.countOver10
        switch m.band {
        case .fm:
            if best >= 30 { return Verdict(rating: .good, text: String(localized: "\(count) Sender, der stärkste \(db(best)) über dem Rauschen – UKW klingt sauber.")) }
            if best >= 15 { return Verdict(rating: .marginal, text: String(localized: "\(count) Sender, der stärkste nur \(db(best)) über dem Rauschen – die starken klingen gut, schwächere rauschen.")) }
            return Verdict(rating: .weak, text: count == 0 ? String(localized: "Kein UKW-Sender deutlich über dem Rauschen – die Antenne fängt hier kaum etwas.") : String(localized: "Nur \(db(best)) über dem Rauschen – UKW rauscht hörbar."))
        case .airband:
            if best >= 20 { return Verdict(rating: .good, text: String(localized: "\(count) Funkkanäle aktiv, der stärkste \(db(best)) über dem Rauschen – Flugfunk ist gut hörbar.")) }
            if best >= 10 { return Verdict(rating: .marginal, text: String(localized: "\(count) Funkkanäle gehört, der stärkste \(db(best)) über dem Rauschen – nahe Stationen ja, ferne kaum.")) }
            return Verdict(rating: .noInformation, text: String(localized: "In der Messzeit hat niemand hörbar gefunkt – für eine Aussage länger lauschen (Seite „Flugfunk“, „Aktive Kanäle finden“)."))
        case .weatherSat:
            if best >= 15 { return Verdict(rating: .good, text: String(localized: "Ein Satellit war \(db(best)) über dem Rauschen zu hören.")) }
            if best >= 8 { return Verdict(rating: .marginal, text: String(localized: "Ein Satellit war schwach zu hören (\(db(best))) – für ein Bild knapp.")) }
            return Verdict(rating: .noInformation, text: String(localized: "Wettersatelliten senden nur beim Überflug (rund 10 min) – ohne Überflug sagt die Messung nichts. Rundstrahler hören sie ohnehin schlecht."))
        case .ais:
            if best >= 20 { return Verdict(rating: .good, text: String(localized: "AIS-Aussendungen \(db(best)) über dem Rauschen – Schiffe in Reichweite sind gut zu empfangen.")) }
            if best >= 10 { return Verdict(rating: .marginal, text: String(localized: "AIS gehört, aber nur \(db(best)) über dem Rauschen – nahe Schiffe ja, ferne kaum.")) }
            return Verdict(rating: .noInformation, text: String(localized: "Kein Schiff hat in der Messzeit gesendet – abseits von Küste und Flüssen ist das normal, keine Aussage über die Antenne."))
        case .dab:
            let blocks = m.signals.filter { $0.levelDB >= 8 }.compactMap(\.label)
            let list = blocks.prefix(5).joined(separator: ", ")
            if best >= 15 { return Verdict(rating: .good, text: String(localized: "\(blocks.count) DAB-Blöcke empfangbar (\(list)), der stärkste \(db(best)) über dem Rauschen.")) }
            if best >= 8 { return Verdict(rating: .marginal, text: String(localized: "DAB-Blöcke \(list) nur \(db(best)) über dem Rauschen – DAB+ braucht rund 9 dB, Aussetzer möglich.")) }
            return Verdict(rating: .weak, text: String(localized: "Kein DAB-Block deutlich über dem Rauschen – in Deutschland gibt es fast überall DAB+, die Antenne fängt Band III zu schwach."))
        case .sonde:
            if best >= 15 { return Verdict(rating: .good, text: String(localized: "Sonde auf \(mhz(m.signals[0].mhz)) MHz \(db(best)) über dem Rauschen – gut zu empfangen.")) }
            if best >= 8 { return Verdict(rating: .marginal, text: String(localized: "Sonde auf \(mhz(m.signals[0].mhz)) MHz nur \(db(best)) über dem Rauschen – sicher empfangen braucht rund 10 dB.")) }
            return Verdict(rating: .noInformation, text: String(localized: "Gerade fliegt keine Sonde in Hörweite – Sonden steigen meist zweimal am Tag (siehe Empfangsplan). Keine Aussage über die Antenne."))
        case .sensors:
            if best >= 20 { return Verdict(rating: .good, text: String(localized: "\(count) Funksensoren gehört, der stärkste \(db(best)) über dem Rauschen.")) }
            if best >= 10 { return Verdict(rating: .marginal, text: String(localized: "\(count) Funksensoren gehört, der stärkste nur \(db(best)) über dem Rauschen.")) }
            return Verdict(rating: .noInformation, text: String(localized: "Kein Sensor hat in der Messzeit gesendet – viele melden sich nur alle ein, zwei Minuten. Keine Aussage."))
        case .adsb:
            let peak = m.burstPeakDB ?? 0
            let rate = m.burstsPerSecond ?? 0
            if peak >= 15 { return Verdict(rating: .good, text: String(localized: "Flugzeuge hörbar: Signale bis \(db(peak)) über dem Rauschen, rund \(Int(rate.rounded())) pro Sekunde.")) }
            if peak >= 8 { return Verdict(rating: .marginal, text: String(localized: "Nur schwache Flugzeug-Signale (bis \(db(peak)), \(Int(rate.rounded())) pro Sekunde) – nahe Flugzeuge ja, ferne kaum.")) }
            return Verdict(rating: .weak, text: String(localized: "Keine Flugzeug-Antworten über dem Rauschen – die Antenne ist für 1090 MHz zu schwach (oder es fliegt gerade nichts in der Nähe)."))
        case .gps:
            return Verdict(rating: .noInformation, text: String(localized: "GPS-Signale liegen immer unter dem Rauschen – ob die Antenne reicht, zeigt nur die Seite „GPS-Ortung“. Aktive GPS-Antennen brauchen die Antennenspeisung (Bias-Tee)."))
        }
    }

    // MARK: - Zusammenfassung

    struct Summary: Sendable, Equatable {
        var good: [String]
        var marginal: [String]
        var weak: [String]
        var overloaded: [String]
        var noInformation: [String]
        var advice: [String]
    }

    static func summary(_ measurements: [AntennaBandMeasurement]) -> Summary {
        var s = Summary(good: [], marginal: [], weak: [], overloaded: [], noInformation: [], advice: [])
        var ratings: [AntennaBand: Rating] = [:]
        for m in measurements {
            let r = verdict(for: m).rating
            ratings[m.band] = r
            switch r {
            case .good: s.good.append(m.band.title)
            case .marginal: s.marginal.append(m.band.title)
            case .weak: s.weak.append(m.band.title)
            case .overloaded: s.overloaded.append(m.band.title)
            case .noInformation: s.noInformation.append(m.band.title)
            }
        }
        func notGood(_ band: AntennaBand) -> Bool { ratings[band].map { $0 != .good } ?? false }
        func poor(_ band: AntennaBand) -> Bool { ratings[band].map { $0 == .weak || $0 == .marginal } ?? false }

        if !s.overloaded.isEmpty {
            s.advice.append(String(localized: "Übersteuert: externen Verstärker ausschalten oder Verstärkung senken. Gegen starke UKW- oder Fernsehsender in der Nähe hilft ein UKW-Sperrfilter bzw. ein Bandpass für das gewünschte Band."))
        }
        if poor(.fm) || poor(.dab) {
            s.advice.append(String(localized: "UKW/DAB+: Antenne nach draußen oder höher setzen. Eine Teleskopantenne auf rund 75 cm (UKW) bzw. 35 cm (DAB) ausziehen, besser ein Dipol."))
        }
        if poor(.airband) {
            s.advice.append(String(localized: "Flugfunk: Antenne höher und mit freier Sicht montieren – Flugzeuge hört man weit, Bodenstationen nur bei Sichtverbindung."))
        }
        if notGood(.weatherSat) {
            s.advice.append(String(localized: "Wettersatelliten (137 MHz): einen V-Dipol (2 × 53 cm, 120°, waagerecht) oder eine QFH-Antenne mit freier Sicht zum Himmel – Rundstrahler hören Satelliten kaum."))
        }
        if poor(.sonde) || ratings[.sonde] == .noInformation {
            s.advice.append(String(localized: "Radiosonden (400–406 MHz): Antenne so hoch und frei wie möglich draußen, kurzes dämpfungsarmes Kabel (RG58 verliert hier ≈ 0,4 dB je Meter), Vorverstärker direkt an die Antenne."))
        }
        if poor(.adsb) {
            s.advice.append(String(localized: "Flugzeuge (1090 MHz): Vorverstärker mit 1090-MHz-Filter direkt an der Antenne oder eine eigene 1090-MHz-Antenne (Groundplane/Collinear) – Breitband-LNAs übersteuern hier an Mobilfunk."))
        }
        if [AntennaBand.ais, .sensors].contains(where: { ratings[$0] == .noInformation }) {
            s.advice.append(String(localized: "AIS und Funksensoren senden nur ab und zu – für eine Aussage den Check später wiederholen oder die Seite eine Weile laufen lassen."))
        }
        if ratings[.gps] != nil {
            s.advice.append(String(localized: "GPS: ob die Antenne reicht, zeigt nur die Seite „GPS-Ortung“. Aktive GPS-Antennen brauchen die Antennenspeisung (Bias-Tee)."))
        }
        return s
    }
}

/// Sammelt während eines Fensters FFTs: Mittel, Spitzenwert über Gruppen zu 8
/// Rahmen und optional die Kanalleistung je Rahmen.
final class AntennaCheckAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let size = AntennaCheck.fftSize
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    /// Normierung auf Vollaussteuerung: Σw² · 2 · 127².
    private let scale: Float
    private var sum: [Float]
    private var frames = 0
    private var group: [Float]
    private var groupCount = 0
    private var hold: [Float]
    private var burstRange: Range<Int>?
    private var burst: [Float] = []
    private var re: [Float], im: [Float], power: [Float]
    private var started = Date()

    static let groupSize = 8

    init() {
        log2n = vDSP_Length(log2(Double(AntennaCheck.fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: AntennaCheck.fftSize)
        vDSP_hann_window(&w, vDSP_Length(AntennaCheck.fftSize), Int32(vDSP_HANN_NORM))
        window = w
        scale = w.reduce(0) { $0 + $1 * $1 } * 2 * 127 * 127
        sum = [Float](repeating: 0, count: AntennaCheck.fftSize)
        group = sum; hold = sum; re = sum; im = sum; power = sum
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Neues Fenster; `burstChannel` als Frequenzbereich relativ zur Mitte (MHz).
    func reset(burstChannel: ClosedRange<Double>? = nil) {
        lock.withLock {
            sum = [Float](repeating: 0, count: size)
            group = sum; hold = sum
            frames = 0; groupCount = 0
            burst = []
            started = Date()
            if let ch = burstChannel {
                let lo = Int((ch.lowerBound / AntennaCheck.binMHz).rounded()) + size / 2
                let hi = Int((ch.upperBound / AntennaCheck.binMHz).rounded()) + size / 2
                burstRange = max(0, lo)..<min(size, hi + 1)
            } else {
                burstRange = nil
            }
        }
    }

    func process(_ iq: Data) {
        let count = iq.count / (2 * size)
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self).baseAddress!
            for f in 0..<count {
                let base = p + f * 2 * size
                vDSP_vflt8(base, 2, &re, 1, vDSP_Length(size))
                vDSP_vflt8(base + 1, 2, &im, 1, vDSP_Length(size))
                vDSP_vmul(re, 1, window, 1, &re, 1, vDSP_Length(size))
                vDSP_vmul(im, 1, window, 1, &im, 1, vDSP_Length(size))
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size))
                    }
                }
                vDSP_vadd(sum, 1, power, 1, &sum, 1, vDSP_Length(size))
                frames += 1
                if let range = burstRange, !range.isEmpty {
                    // Ungeshiftet: positive Frequenzen vorn, negative hinten.
                    var total: Float = 0
                    for k in range {
                        let bin = (k + size / 2) % size
                        total += power[bin]
                    }
                    burst.append(total / Float(range.count) / scale)
                }
                vDSP_vadd(group, 1, power, 1, &group, 1, vDSP_Length(size))
                groupCount += 1
                if groupCount == Self.groupSize {
                    vDSP_vmax(hold, 1, group, 1, &hold, 1, vDSP_Length(size))
                    vDSP_vclr(&group, 1, vDSP_Length(size))
                    groupCount = 0
                }
            }
        }
    }

    /// Spektren des Fensters, FFT-geshiftet und normiert.
    func snapshot(centerMHz: Double, clipped: Double, rmsDBFS: Double) -> AntennaWindowSpectrum {
        lock.withLock {
            let half = size / 2
            let meanScale = 1 / (Float(max(frames, 1)) * scale)
            let holdScale = 1 / (Float(Self.groupSize) * scale)
            let mean = Array(sum[half...] + sum[..<half]).map { $0 * meanScale }
            let held = Array(hold[half...] + hold[..<half]).map { $0 * holdScale }
            return AntennaWindowSpectrum(centerMHz: centerMHz, mean: mean, hold: held, burst: burst,
                                         seconds: Date().timeIntervalSince(started),
                                         clipped: clipped, rmsDBFS: rmsDBFS)
        }
    }
}
