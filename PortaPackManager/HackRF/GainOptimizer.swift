import Foundation
import Observation
import os

/// Gütezahl eines Empfängers für den Optimierer.
enum GainQuality: Sendable {
    /// Monoton steigender Zähler gültiger Dekodierungen (Meldungen, Rahmen).
    case count(Int)
    /// Augenblickswert, größer ist besser (Störabstand, C/N0). Unterschiede
    /// unter `resolution` gelten als Gleichstand (Messrauschen).
    case value(Double, resolution: Double = 0.3)
    /// Monoton steigende Zähler fehlerfreier und fehlerhafter Blöcke – gewertet
    /// wird der Anteil fehlerfreier im Messfenster. Für DVB-T2 das bessere Maß:
    /// K41 zeigte bei LNA 24 10,7 dB und 79 % gute Blöcke, bei LNA 32 10,5 dB
    /// und nur 27 % (26.10.2026) – der Störabstand allein sah fast gleich aus.
    case ratio(good: Int, bad: Int)
}

/// Was eine Empfangsseite für „Signal optimieren“ bereitstellt.
@MainActor
protocol GainTunable: AnyObject {
    var lnaGain: Double { get set }
    var vgaGain: Double { get set }
    var amplifier: Bool { get set }
    var antennaPower: Bool { get set }
    var running: Bool { get }
    /// `nil`: nur der Pegel wird optimiert (kein Dekoder oder zu seltene Meldungen).
    var quality: GainQuality? { get }
    func applyTunedGains(_ device: HackRFDevice?) throws
    /// Laufender Zähler empfangener Meldungen für die Statuszeile – auch dort,
    /// wo er für den Optimierer zu selten ist (Funkrufe, Sonden …).
    var activity: Int? { get }
    /// Rat in Alltagssprache, wenn eine Weile nichts ankommt.
    var idleHint: String { get }
    /// Gütezahl erscheint erst nach dem Einrasten (DVB-T2, DAB+, METEOR, GPS).
    var needsLock: Bool { get }
    /// Nimmt in kurzen Stößen auf und gibt den HackRF zwischendurch frei
    /// (LTE-Suchlauf). Dann ist „niemand empfängt“ kein Abriss.
    var receivesInBursts: Bool { get }
    /// Ob die allgemeine Verstärkungsautomatik (`AutoGain`) nachregeln darf.
    /// Nein bei Langzeitmessungen, deren Pegel vergleichbar bleiben müssen
    /// (Belegungsmonitor – sonst sprängen gespeicherte Pegel, Review 28.10.2026, Y10).
    var wantsAutoGain: Bool { get }
    /// Startknopf heißt „Abspielen“ statt „Start“ (Radio, DAB+) – die
    /// Statuszeile nennt dann denselben Namen (Bedienungs-Review 29.10.2026).
    var startsByPlaying: Bool { get }
}

extension GainTunable {
    var activity: Int? { if case let .count(n)? = quality { n } else { nil } }
    var idleHint: String { String(localized: "Vielleicht sendet gerade niemand in Reichweite.") }
    var needsLock: Bool { false }
    var receivesInBursts: Bool { false }
    var wantsAutoGain: Bool { true }
    var startsByPlaying: Bool { false }
}

/// Suchlogik ohne Gerät (testbar).
///
/// Stufe 1 – Pegel: Wandler gut ausgesteuert (RMS −32 … −15 dBFS), kaum Werte
/// am Anschlag (< 0,05 %). Zu viel: erst interner Vorverstärker aus, dann LNA
/// (die HF-Stufe übersteuert zuerst), zuletzt VGA. Zu wenig: erst LNA (bessere
/// Rauschzahl), dann VGA, zuletzt – ohne externen Verstärker – der interne
/// Vorverstärker. Eine Stufe, die schon einmal übersteuert hat, wird nicht
/// wieder erreicht (kein Pendeln).
///
/// Stufe 2 – Dekoder (falls Gütezahl): Nachbarn der Pegellösung (LNA ±8 mit
/// gegenläufiger VGA, VGA ±6) je einige Sekunden; gewinnt die beste Gütezahl,
/// bei Gleichstand (±10 %) die geringere Verstärkung.
struct GainSearch: Sendable {
    typealias Preset = GainProfile.Preset

    static let rmsRange = -32.0 ... -15.0
    static let clipLimit = 0.0005
    static let maxSteps = 14

    let externalAmplifier: Bool
    private(set) var current: Preset
    private var lnaCeiling = 40.0
    private var vgaCeiling = 62.0
    private var amplifierAllowed: Bool
    private(set) var steps = 0

    init(start: Preset, externalAmplifier: Bool) {
        self.externalAmplifier = externalAmplifier
        amplifierAllowed = !externalAmplifier
        current = start
        if externalAmplifier { current.amplifier = false }
    }

    /// Nächste Einstellung nach einer Pegelmessung; `nil` = fertig.
    mutating func next(after levels: HackRFDevice.InputLevels) -> Preset? {
        steps += 1
        guard steps <= Self.maxSteps else { return nil }
        var p = current
        if levels.clipped >= Self.clipLimit || levels.rmsDBFS > Self.rmsRange.upperBound {
            if p.amplifier {
                p.amplifier = false
                amplifierAllowed = false
            } else if p.lna >= 8 {
                lnaCeiling = p.lna - 8
                p.lna -= 8
            } else if p.vga >= 4 {
                vgaCeiling = p.vga - 4
                p.vga -= 4
            } else {
                return nil
            }
        } else if levels.rmsDBFS < Self.rmsRange.lowerBound {
            let missing = Self.rmsRange.lowerBound + 8 - levels.rmsDBFS
            if p.lna + 8 <= lnaCeiling {
                p.lna += 8
            } else if p.vga + 2 <= min(vgaCeiling, 50) {
                p.vga = min(min(vgaCeiling, 50), p.vga + max(2, (missing / 2).rounded() * 2))
            } else if amplifierAllowed, !p.amplifier {
                p.amplifier = true
            } else {
                return nil
            }
        } else {
            return nil
        }
        current = p
        return p
    }

    /// Kandidaten für Stufe 2 rund um die Pegellösung.
    static func candidates(around p: Preset) -> [Preset] {
        var list = [p]
        func add(_ lna: Double, _ vga: Double) {
            let c = Preset(lna: min(40, max(0, lna)), vga: min(62, max(0, vga)), amplifier: p.amplifier)
            if !list.contains(c) { list.append(c) }
        }
        add(p.lna - 8, p.vga + 8)
        add(p.lna + 8, p.vga - 8)
        add(p.lna, p.vga + 6)
        add(p.lna, p.vga - 6)
        return list
    }

    /// Bester Kandidat: höchste Güte; innerhalb `tolerance` (ohne Angabe 10 %
    /// des Höchstwerts) die geringere Gesamtverstärkung.
    static func best(_ results: [(preset: Preset, score: Double)], tolerance: Double? = nil) -> Preset? {
        guard let top = results.map(\.score).max() else { return nil }
        let close = results.filter { $0.score >= top - (tolerance ?? max(abs(top) * 0.1, 1e-9)) }
        return close.min { total($0.preset) < total($1.preset) }?.preset
    }

    static func total(_ p: Preset) -> Double { p.lna + p.vga + (p.amplifier ? 14 : 0) }
}

/// Führt die Suche am laufenden Empfang aus.
@MainActor
@Observable
final class GainOptimizer {
    /// Laufende Optimierungen – solange eine läuft, hält sich `AutoGain` heraus.
    static private(set) var activeCount = 0

    /// Genau ein Optimierer je Empfänger: Mac-Seite und Handy teilen ihn. Vorher
    /// hatte jede Ansicht (`@State`) und der Fernzugriff einen eigenen – Seite
    /// verlassen und zurück oder Mac + Handy gleichzeitig ergab zwei Läufe am
    /// selben Modell, deren Messfenster sich überschrieben.
    ///
    /// Der Empfänger wird nur schwach gehalten: Seiten mit `@State var model`
    /// legen je Besuch ein neues Modell an, die Einträge der alten werden beim
    /// nächsten Zugriff entfernt (Review 28.10.2026). Die schwache Referenz
    /// verhindert auch, dass ein neues Modell an der Adresse eines alten
    /// dessen Optimierer erbt.
    private static var registry: [ObjectIdentifier: (model: WeakModel, optimizer: GainOptimizer)] = [:]

    private struct WeakModel {
        weak var object: AnyObject?
    }

    static func shared(for model: AnyObject) -> GainOptimizer {
        let key = ObjectIdentifier(model)
        if let existing = registry[key], existing.model.object === model { return existing.optimizer }
        registry = registry.filter { $0.value.model.object != nil }
        let new = GainOptimizer()
        registry[key] = (WeakModel(object: model), new)
        return new
    }

    /// Zahl der gemerkten Optimierer (für Tests).
    static var registeredCount: Int { registry.count }
    private(set) var active = false {
        didSet { if active != oldValue { Self.activeCount += active ? 1 : -1 } }
    }
    private(set) var status = ""
    private(set) var result: String?
    private var task: Task<Void, Never>?

    /// Messdauer je Kandidat in Stufe 2.
    static let qualitySeconds = 6.0
    /// Einschwingzeit nach jedem Wechsel, bevor Stufe 2 misst (DAB+/DVB-T2
    /// rasten nach einer Pegeländerung mitunter kurz neu ein).
    static let settleSeconds = 1.0
    /// Weniger Meldungen als das im besten Kandidaten: kein Vergleich möglich.
    static let minimumCount = 3.0

    func run(_ model: any GainTunable, device: HackRFDevice?) {
        // Stoß-Empfänger (LTE) regeln je Aufnahme selbst; zwischen den Stößen
        // gäbe es keinen Strom zum Messen.
        guard !active, model.running, !model.receivesInBursts, let device else { return }
        active = true
        result = nil
        let start = GainProfile.Preset(lna: model.lnaGain, vga: model.vgaGain, amplifier: model.amplifier)
        task = Task { [weak self] in
            guard let self else { return }
            var search = GainSearch(start: start, externalAmplifier: GainProfile.externalAmplifier)
            do {
                try self.apply(search.current, to: model, device: device)
                // Stufe 1: Pegel.
                var levels = try await self.measure(device)
                while let next = search.next(after: levels) {
                    self.status = Self.levelStep(levels.rmsDBFS, next)
                    try self.apply(next, to: model, device: device)
                    levels = try await self.measure(device)
                }
                var chosen = search.current
                // Stufe 2: Dekoder.
                if let kind = model.quality {
                    var results: [(GainProfile.Preset, Double)] = []
                    let candidates = GainSearch.candidates(around: chosen)
                    for (index, candidate) in candidates.enumerated() {
                        self.status = String(localized: "Vergleiche am Dekoder \(index + 1)/\(candidates.count): LNA \(Int(candidate.lna)), VGA \(Int(candidate.vga))")
                        try self.apply(candidate, to: model, device: device)
                        try await Task.sleep(for: .seconds(Self.settleSeconds))
                        device.beginLevelMeasurement()
                        let before = model.quality
                        try await Task.sleep(for: .seconds(Self.qualitySeconds))
                        let clipped = device.measuredLevels()?.levels.clipped ?? 0
                        guard let score = Self.score(before: before, after: model.quality) else { continue }
                        // Übersteuerte Kandidaten nur nehmen, wenn sie deutlich besser sind.
                        results.append((candidate, clipped >= GainSearch.clipLimit * 4 ? score * 0.8 : score))
                    }
                    let level = search.current
                    let top = results.map(\.1).max() ?? 0
                    let scores = results.map { Self.format($0.1, kind) }.joined(separator: " / ")
                    if case .count = kind, top < Self.minimumCount {
                        // Ohne Verkehr wäre jeder Kandidat „gleich gut“, und die
                        // Auswahl fiele grundlos auf die geringste Verstärkung.
                        chosen = level
                        self.result = String(localized: "\(Self.describe(chosen)) · Pegel eingestellt; zu wenig Meldungen für einen Vergleich (\(scores))")
                    } else {
                        chosen = GainSearch.best(results, tolerance: Self.tolerance(kind, top: top)) ?? level
                        self.result = String(localized: "\(Self.describe(chosen)) · Güte \(scores)")
                    }
                } else {
                    self.result = String(localized: "\(Self.describe(chosen)) · Pegel \(Int(levels.rmsDBFS.rounded())) dBFS")
                }
                try self.apply(chosen, to: model, device: device)
            } catch is CancellationError {
                try? self.apply(start, to: model, device: device)
                self.result = String(localized: "Abgebrochen – die vorherigen Werte gelten wieder.")
            } catch HackRFError.takenOver {
                self.result = String(localized: "Abgebrochen – der Empfang wurde beendet oder hat gewechselt.")
            } catch {
                self.result = error.localizedDescription
            }
            self.status = ""
            self.active = false
        }
    }

    func cancel() { task?.cancel() }

    /// „LNA 24, VGA 20, eingebauter Verstärker an“.
    private static func describe(_ p: GainProfile.Preset) -> String {
        p.amplifier
            ? String(localized: "LNA \(Int(p.lna)), VGA \(Int(p.vga)), eingebauter Verstärker an")
            : String(localized: "LNA \(Int(p.lna)), VGA \(Int(p.vga))")
    }

    private static func levelStep(_ rms: Double, _ next: GainProfile.Preset) -> String {
        String(localized: "Pegel \(Int(rms.rounded())) dBFS → \(describe(next))")
    }

    private func apply(_ p: GainProfile.Preset, to model: any GainTunable, device: HackRFDevice) throws {
        // Seite gestoppt, Gerät abgezogen oder von einem anderen Empfänger
        // übernommen: sonst bekäme dessen Strom die Werte dieser Seite.
        guard model.running, device.isReceiving(for: model) else { throw HackRFError.takenOver }
        model.lnaGain = p.lna
        model.vgaGain = p.vga
        model.amplifier = p.amplifier
        try model.applyTunedGains(device)
    }

    /// Pegel über mindestens 0,4 s und 3 Blöcke (nach kurzem Einschwingen).
    private func measure(_ device: HackRFDevice) async throws -> HackRFDevice.InputLevels {
        try await Task.sleep(for: .milliseconds(150))
        device.beginLevelMeasurement()
        let start = ContinuousClock.now
        while true {
            try await Task.sleep(for: .milliseconds(100))
            if let (levels, blocks) = device.measuredLevels(), blocks >= 3, ContinuousClock.now - start >= .milliseconds(400) {
                return levels
            }
            if ContinuousClock.now - start > .seconds(3) {
                // Kein einziger Block: Strom tot. Nicht −100 dBFS annehmen – sonst
                // drehte die Suche alles auf Anschlag.
                guard let levels = device.measuredLevels()?.levels else { throw HackRFError.takenOver }
                return levels
            }
        }
    }

    /// Zähler: Zuwachs im Messfenster; Augenblickswert: Wert am Ende;
    /// Blockzähler: Prozent fehlerfreier Blöcke im Fenster (mindestens vier).
    /// Ein zurückgesetzter Zähler (Neueinrasten) zählt ab null.
    nonisolated static func score(before: GainQuality?, after: GainQuality?) -> Double? {
        switch (before, after) {
        case let (.count(a)?, .count(b)?): return Double(b >= a ? b - a : b)
        case let (_, .value(v, _)?): return v
        case let (_, .ratio(g1, b1)?):
            var (good, bad) = (g1, b1)
            if case let .ratio(g0, b0)? = before, g1 >= g0, b1 >= b0 { (good, bad) = (g1 - g0, b1 - b0) }
            guard good + bad >= 4 else { return nil }
            return 100 * Double(good) / Double(good + bad)
        default: return nil
        }
    }

    /// Gleichstand-Spanne je Gütezahl: Zähler 10 %, Störabstand `resolution`,
    /// Blockanteil 3 Prozentpunkte.
    nonisolated static func tolerance(_ kind: GainQuality, top: Double) -> Double {
        switch kind {
        case .count: max(top * 0.1, 1)
        case let .value(_, resolution): resolution
        case .ratio: 3
        }
    }

    private static func format(_ score: Double, _ kind: GainQuality) -> String {
        switch kind {
        case .count: String(format: "%.0f", score)
        case .value: String(format: "%.1f", score)
        case .ratio: String(format: "%.0f %%", score)
        }
    }
}

/// Eine Entscheidung der Schutzautomatik (ohne Gerät, testbar).
struct AutoGainStep: Equatable {
    var lnaCeiling = 40.0
    var vgaCeiling = 62.0

    /// Neue Einstellung samt Grund, `nil` = nichts tun. Zurück nach drei Takten
    /// Übersteuerung (Vorverstärker, LNA −8, VGA −4; die Stufe wird danach nicht
    /// wieder erreicht), hoch bei < −45 dBFS (LNA +8, dann VGA +4 bis 50).
    mutating func next(_ current: GainProfile.Preset, levels: HackRFDevice.InputLevels, clipTicks: Int,
                       raiseAllowed: Bool) -> (GainProfile.Preset, String)? {
        var p = current
        if clipTicks >= 3 {
            if p.amplifier {
                p.amplifier = false
            } else if p.lna >= 8 {
                p.lna -= 8
                lnaCeiling = p.lna
            } else if p.vga >= 4 {
                p.vga -= 4
                vgaCeiling = p.vga
            } else { return nil }
            let percent = (levels.clipped * 100).formatted(.number.precision(.fractionLength(1)))
            return (p, String(localized: "\(percent) % am Anschlag"))
        }
        guard raiseAllowed, levels.rmsDBFS < AutoGain.quietLimit, levels.clipped == 0 else { return nil }
        if p.lna + 8 <= lnaCeiling {
            p.lna += 8
        } else if p.vga + 4 <= min(vgaCeiling, 50) {
            p.vga += 4
        } else { return nil }
        return (p, String(localized: "zu leise, \(Int(levels.rmsDBFS.rounded())) dBFS"))
    }
}

/// Schutzautomatik für die Verstärkung aller Empfänger (Schalter „Verstärkung
/// automatisch nachregeln“, Vorgabe an). Schaut jede Sekunde auf den
/// Empfänger, dem der HackRF gerade gehört – gleich ob am Mac, aus der Ferne
/// oder vom Empfangsplan gestartet:
///
/// - Übersteuert der Wandler drei Takte in Folge (≥ 0,5 % am Anschlag), eine
///   Stufe zurück: erst interner Vorverstärker aus, dann LNA −8, zuletzt
///   VGA −4. Die übersteuernde Stufe wird danach nicht wieder erreicht.
/// - Ist er viel zu leise (unter −45 dBFS liegt das Signal unter einem
///   Wandlerschritt), eine Stufe hoch: LNA +8, dann VGA +4.
///
/// Dazwischen bleiben die Werte der Seite unangetastet – die Vorgaben sind
/// gemessen, die Automatik greift nur bei klaren Fehlern (Bildschirmfoto
/// 27.10.2026: Fernsehen mit externem LNA *und* internem Vorverstärker,
/// 19 % am Anschlag, nichts dekodiert). Radiosonden regeln selbst
/// (`SondeModel.autoBackoff`), „Signal optimieren“ hat Vorrang.
@MainActor
@Observable
final class AutoGain {
    static let shared = AutoGain()
    static let enabledKey = "autoGain"
    /// 0,5 % statt 0,1 %: ADS-B-Antworten naher Flugzeuge sind kurze, starke
    /// Pulse – bei 0,1 % nahm die Automatik live LNA 40 → 24 zurück (27.10.2026),
    /// obwohl 40 dort gemessen am meisten Meldungen bringt.
    static let clipLimit = 0.005
    nonisolated static let quietLimit = -45.0

    var enabled = UserDefaults.standard.object(forKey: AutoGain.enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    /// Letzter Eingriff je Empfänger, z. B. „LNA 32 → 24 (2,1 % am Anschlag, 14:05)“.
    private(set) var notes: [ObjectIdentifier: String] = [:]

    @ObservationIgnored private weak var session: DeviceSession?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var owner: ObjectIdentifier?
    /// Letzter Handeingriff je Empfänger – danach 60 s nicht von selbst hochdrehen.
    @ObservationIgnored private var manual: [ObjectIdentifier: Date] = [:]
    @ObservationIgnored private var since = Date.distantPast
    @ObservationIgnored private var lastChange = Date.distantPast
    @ObservationIgnored private var clipTicks = 0
    @ObservationIgnored private var lnaCeiling = 40.0
    @ObservationIgnored private var vgaCeiling = 62.0

    func note(for model: AnyObject) -> String? { notes[ObjectIdentifier(model)] }

    /// Regler von Hand bewegt: Wer LNA bewusst senkt (Test, Spektrum), bekam
    /// vorher nach 3 s wieder +8 dB. Zurücknehmen bei Übersteuerung gilt weiter.
    func manualChange(_ model: AnyObject) { manual[ObjectIdentifier(model)] = .now }

    func bootstrap(session: DeviceSession) {
        self.session = session
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard enabled, GainOptimizer.activeCount == 0, let device = session?.hackRF,
              let model = device.currentOwner as? GainTunable, model.running, !(model is SondeModel),
              // Stoß-Empfänger (LTE): Der Pegel am Anfang jeder kurzen Aufnahme lag bei
              // −100 dBFS, die Automatik drehte bis LNA 40 auf und übersteuerte (28.10.2026).
              // Sie regeln selbst nach jeder Aufnahme.
              !model.receivesInBursts, model.wantsAutoGain else {
            clipTicks = 0
            return
        }
        // Neuer Besitzer: Grenzen vergessen, kurz einschwingen lassen. Nur beim
        // Besitzerwechsel, nicht bei jedem Neustart des Stroms – Drohnen und
        // LoRaWAN starten ihn alle 2 s neu, die Automatik griff dort sonst nie.
        let id = ObjectIdentifier(model)
        if id != owner {
            owner = id
            since = .now
            clipTicks = 0
            lnaCeiling = 40
            vgaCeiling = 62
            return
        }
        guard Date.now.timeIntervalSince(since) >= 2, Date.now.timeIntervalSince(lastChange) >= 3,
              let levels = device.inputLevels else { return }
        clipTicks = levels.clipped >= Self.clipLimit ? clipTicks + 1 : 0

        let before = GainProfile.Preset(lna: model.lnaGain, vga: model.vgaGain, amplifier: model.amplifier)
        var step = AutoGainStep(lnaCeiling: lnaCeiling, vgaCeiling: vgaCeiling)
        guard let (p, reason) = step.next(before, levels: levels, clipTicks: clipTicks,
                                          raiseAllowed: Date.now.timeIntervalSince(manual[id] ?? .distantPast) >= 60) else { return }
        lnaCeiling = step.lnaCeiling
        vgaCeiling = step.vgaCeiling

        model.lnaGain = p.lna
        model.vgaGain = p.vga
        model.amplifier = p.amplifier
        try? model.applyTunedGains(device)
        device.beginLevelMeasurement()
        lastChange = .now
        clipTicks = 0
        func text(_ x: GainProfile.Preset) -> String {
            x.amplifier ? String(localized: "LNA \(Int(x.lna))/VGA \(Int(x.vga)) + eingebauter Verstärker")
                        : "LNA \(Int(x.lna))/VGA \(Int(x.vga))"
        }
        notes[ObjectIdentifier(model)] = "\(text(before)) → \(text(p)) (\(reason), \(Date().formatted(date: .omitted, time: .shortened)))"
        Self.log.notice("\(String(describing: type(of: model)), privacy: .public): \(self.notes[ObjectIdentifier(model)] ?? "", privacy: .public)")
    }

    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Verstärkung")
}

extension GainTunable {
    /// Regler und Schalter der Seite: wirken nur auf den eigenen, laufenden
    /// Empfang. Vorher stellte z. B. die ADS-B-Seite ohne Empfang LNA, VGA und
    /// die Antennenspeisung am Strom einer anderen Seite oder des Plans um.
    /// Ohne Empfang gelten die Werte beim nächsten Start.
    func applyFromControls(_ device: HackRFDevice?) {
        AutoGain.shared.manualChange(self)
        guard running, let device, device.isReceiving(for: self) else { return }
        try? applyTunedGains(device)
    }
}

// MARK: - Anbindung der Empfangsseiten

extension ADSBModel: GainTunable {
    var idleHint: String { String(localized: "Flugzeuge hört man am besten mit freier Sicht zum Himmel – drinnen reicht es oft nur wenige Kilometer.") }
    var quality: GainQuality? { .count(framesValid) }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}

extension ACARSModel: GainTunable {
    var idleHint: String { String(localized: "Datenfunk kommt in Wellen, in Europa meist über VDL2. Nachts ist wenig los.") }
    /// Laufender Zähler – die Liste ist auf 2000 begrenzt und wächst danach nicht mehr.
    var quality: GainQuality? { .count(lastCount) }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension AISModel: GainTunable {
    var idleHint: String { String(localized: "Schiffe hört man nur in der Nähe von Küste, Fluss oder Hafen.") }
    var quality: GainQuality? { .count(messageCount) }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}

extension APRSModel: GainTunable {
    var idleHint: String { String(localized: "APRS senden Funkamateure – je nach Gegend nur ein paar Pakete pro Stunde.") }
    var quality: GainQuality? { .count(packetCount) }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}

extension PagerModel: GainTunable {
    var idleHint: String { String(localized: "DAPNET-Rufe kommen unregelmäßig, oft nur einige pro Stunde.") }
    var activity: Int? { messageCount }
    var quality: GainQuality? { nil }   // Funkrufe zu selten für einen Vergleich in Sekunden
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}

extension SondeModel: GainTunable {
    var idleHint: String { String(localized: "Wetterballons steigen meist alle sechs Stunden auf – der Empfangsplan passt sie von selbst ab.") }
    var activity: Int? { reportCount }
    var quality: GainQuality? { nil }   // eine Meldung je Sekunde und Sonde – zu grob
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}

extension MeteorModel: GainTunable {
    var idleHint: String { String(localized: "Der Satellit ist nur während eines Überflugs zu hören – die Zeiten stehen unter „Überflüge“.") }
    var needsLock: Bool { true }
    var quality: GainQuality? { snapshot.locked ? .value(Double(snapshot.lockQuality) * 100, resolution: 3) : nil }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}

extension SensorModel: GainTunable {
    var idleHint: String { String(localized: "Funksensoren senden alle 30–60 s – steht eine Wetterstation oder ein Funkthermometer in der Nähe?") }
    var quality: GainQuality? { .count(decodedCount) }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension BLEModel: GainTunable {
    var idleHint: String { String(localized: "Bluetooth-Geräte senden ständig – bleibt es leer, passt die Antenne nicht für 2,4 GHz.") }
    var quality: GainQuality? { .count(packetCount) }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension DroneModel: GainTunable {
    var idleHint: String { String(localized: "Drohnen mit Remote ID sind selten – nur wenn gerade eine in der Nähe fliegt.") }
    var activity: Int? { packetCount }
    // Nur BLE wird gezählt, und der Wechsel BLE/WLAN legt je Fenster mal einen,
    // mal zwei BLE-Abschnitte hinein – der Vergleich wäre Zufall. Nur Pegel.
    var quality: GainQuality? { nil }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension FLARMModel: GainTunable {
    var idleHint: String { String(localized: "Segelflieger sind nur nahe Flugplätzen und bei Flugwetter zu hören, meist am Wochenende.") }
    var activity: Int? { crcValidCount }
    var quality: GainQuality? { nil }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension DCF77Model: GainTunable {
    var idleHint: String { String(localized: "DCF77 braucht eine Langwellenantenne; übliche Antennen fangen 77,5 kHz kaum.") }
    var quality: GainQuality? { nil }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension LoRaWANModel: GainTunable {
    var idleHint: String { String(localized: "LoRaWAN-Sensoren senden selten, oft nur alle 10–15 Minuten.") }
    var activity: Int? { frameCount }
    var quality: GainQuality? { nil }   // LoRaWAN-Rahmen kommen selten
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension MeshtasticModel: GainTunable {
    var idleHint: String { String(localized: "Meshtastic-Knoten senden im Minutenabstand – nur wenn welche in Reichweite sind.") }
    var activity: Int? { frameCount }
    var quality: GainQuality? { nil }   // LoRa-Pakete kommen im Minutenabstand
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension ZigbeeModel: GainTunable {
    var idleHint: String { String(localized: "Zigbee ist meist nur im eigenen Haus zu hören – falscher Kanal? Probier die „Kanalsuche“.") }
    var quality: GainQuality? { .count(frameCount) }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}

extension DABModel: GainTunable {
    var startsByPlaying: Bool { true }
    var idleHint: String { String(localized: "Auf diesem Kanal sendet hier nichts – wähl einen anderen oder starte den Sendersuchlauf.") }
    var needsLock: Bool { true }
    /// Läuft ein Dienst, entscheiden die fehlerfreien Audio-Einheiten, sonst der Störabstand.
    var quality: GainQuality? {
        guard status.synchronized else { return nil }
        return status.accessUnitsGood + status.accessUnitsBad > 0
            ? .ratio(good: status.accessUnitsGood, bad: status.accessUnitsBad) : .value(status.snr)
    }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension TVModel: GainTunable {
    var idleHint: String { String(localized: "Kein DVB-T2 auf diesem Kanal – wähl einen anderen oder starte den Sendersuchlauf. Draußen klappt es meist besser.") }
    var needsLock: Bool { true }
    var quality: GainQuality? { status.locked ? .ratio(good: status.blocksGood, bad: status.blocksBad) : nil }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension GPSModel: GainTunable {
    var idleHint: String { String(localized: "GPS braucht eine aktive GPS-Antenne mit freiem Himmel – drinnen klappt es selten.") }
    var needsLock: Bool { true }
    /// Mittel der vier besten C/N0 verfolgter Satelliten.
    var quality: GainQuality? {
        let best = status.channels.filter(\.locked).map(\.cn0).sorted(by: >).prefix(4)
        return best.isEmpty ? nil : .value(best.reduce(0, +) / Double(best.count))
    }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension RadioModel: GainTunable {
    var startsByPlaying: Bool { true }
    var quality: GainQuality? { nil }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}

extension WiFiModel: GainTunable {
    var quality: GainQuality? { nil }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains(to: device) }
}

extension SpectrumModel: GainTunable {
    var quality: GainQuality? { nil }
    var idleHint: String { "" }
    func applyTunedGains(_ device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }
}
