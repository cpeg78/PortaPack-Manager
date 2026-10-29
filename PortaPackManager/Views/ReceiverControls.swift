import SwiftUI

/// Gemeinsamer Empfangsbaustein aller Empfängerseiten: eine Statuszeile in
/// Alltagssprache, „Signal optimieren“ samt Automatik und – eingeklappt –
/// die Regler zum Selbsteinstellen. Steht auf jeder Seite direkt unter
/// Start/Kanalwahl und hat bis auf das Aufklappen eine feste Höhe, damit
/// nichts springt (vorher wanderten die Regler, sobald Statuszeilen darüber
/// erschienen).
struct ReceiverControls<Model: GainTunable & Observable, Extra: View>: View {
    @Bindable var model: Model
    let device: HackRFDevice?
    /// Seiteneigene Einstellungen am Ende von „Von Hand einstellen“.
    let extra: Extra
    @AppStorage("manualGainExpanded") private var manualExpanded = false

    init(model: Model, device: HackRFDevice?, @ViewBuilder extra: () -> Extra) {
        self.model = model
        self.device = device
        self.extra = extra()
    }

    var body: some View {
        ReceiverStatusLine(model: model, device: device)
        GainOptimizerRow(model: model, device: device)
        DisclosureGroup("Von Hand einstellen", isExpanded: $manualExpanded) {
            LabeledContent("LNA \(Int(model.lnaGain)) dB") {
                Slider(value: $model.lnaGain, in: 0...40, step: 8) { _ in model.applyFromControls(device) }
            }
            .help(GainHelp.lna)
            LabeledContent("VGA \(Int(model.vgaGain)) dB") {
                Slider(value: $model.vgaGain, in: 0...62, step: 2) { _ in model.applyFromControls(device) }
            }
            .help(GainHelp.vga)
            Toggle("Eingebauter Verstärker (+14 dB)", isOn: $model.amplifier)
                .onChange(of: model.amplifier) { _, _ in model.applyFromControls(device) }
                .help(GainHelp.amplifier)
            Toggle("Antennenspeisung (Bias-Tee)", isOn: $model.antennaPower)
                .onChange(of: model.antennaPower) { _, _ in model.applyFromControls(device) }
                .help(GainHelp.biasTee)
            extra
        }
    }
}

extension ReceiverControls where Extra == EmptyView {
    init(model: Model, device: HackRFDevice?) {
        self.init(model: model, device: device) { EmptyView() }
    }
}

/// Eine Zeile „Wie läuft es?“ – Ampel plus Satz, immer drei Zeilen hoch.
/// Wird wie der Pegel in der Seitenleiste alle 0,5 s neu bewertet: der Pegel
/// am Wandler ist nicht beobachtbar, vorher zog die Zeile nur bei
/// Modelländerungen nach und widersprach der Seitenleiste.
struct ReceiverStatusLine<Model: GainTunable & Observable>: View {
    let model: Model
    let device: HackRFDevice?
    @State private var tracker = ActivityTracker()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            line(now: context.date)
        }
        .task(id: model.running) {
            tracker.reset()
            while model.running, !Task.isCancelled {
                tracker.sample(activity: model.activity, quality: model.quality)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func line(now: Date) -> some View {
        // Sonden regeln selbst nach (`backOffIfClipping`), folgen aber demselben Schalter.
        let auto = AutoGain.shared.enabled
        let verdict = ReceiverVerdict.make(model: model, levels: levels, tracker: tracker, autoGain: auto,
                                           occupant: occupant, now: now)
        return Label {
            Text(verdict.text)
                .lineLimit(3, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: verdict.symbol).foregroundStyle(verdict.color)
        }
        .font(.callout)
    }

    /// Läuft die Seite, gehört der Strom aber jemand anderem: wem (oder
    /// „niemandem“, wenn er abgerissen ist). Vorher hieß es dann „seit n min
    /// nichts empfangen“, und Einsteiger suchten den Fehler an der Antenne.
    private var occupant: String? {
        guard model.running, let device, !device.isReceiving(for: model) else { return nil }
        if device.isReceiving { return DeviceArbiter.title(of: device.currentOwner) }
        // Zwischen zwei Aufnahmestößen empfängt niemand – kein Abriss (Fund 28.10.2026, LTE).
        return model.receivesInBursts ? nil : ""
    }

    private var levels: HackRFDevice.InputLevels? {
        guard model.running, let device, device.isReceiving(for: model) else { return nil }
        return device.inputLevels
    }
}

/// Merkt sich Zählerstände der letzten Minuten, um Raten und Pausen zu sehen.
@MainActor
@Observable
final class ActivityTracker {
    private(set) var started = Date()
    private(set) var lastActivity: Date?
    private var samples: [(date: Date, count: Int)] = []
    private var ratios: [(date: Date, good: Int, bad: Int)] = []
    private var lastCount: Int?

    func reset() {
        started = Date()
        lastActivity = nil
        samples = []
        ratios = []
        lastCount = nil
    }

    func sample(activity: Int?, quality: GainQuality?) {
        let now = Date()
        if let activity {
            if let lastCount, activity > lastCount { lastActivity = now }
            lastCount = activity
            samples.append((now, activity))
        }
        if case let .ratio(good, bad)? = quality { ratios.append((now, good, bad)) }
        samples.removeAll { now.timeIntervalSince($0.date) > 300 }
        ratios.removeAll { now.timeIntervalSince($0.date) > 60 }
    }

    /// Meldungen pro Minute über die letzten fünf Minuten (ab 30 s Daten).
    var perMinute: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        guard span >= 30, last.count >= first.count else { return nil }
        return Double(last.count - first.count) / span * 60
    }

    /// Anteil fehlerfreier Blöcke der letzten Minute (0…1).
    var goodFraction: Double? {
        guard let first = ratios.first, let last = ratios.last, last.good >= first.good, last.bad >= first.bad else { return nil }
        let good = last.good - first.good, total = good + last.bad - first.bad
        return total >= 4 ? Double(good) / Double(total) : nil
    }
}

/// Bewertung in Alltagssprache (testbar ohne Ansicht).
struct ReceiverVerdict: Equatable {
    enum Tone { case idle, good, searching, weak, bad }
    var tone: Tone
    var text: String

    var symbol: String {
        switch tone {
        case .idle: "pause.circle"
        case .good: "checkmark.circle.fill"
        case .searching: "ear"
        case .weak: "exclamationmark.triangle.fill"
        case .bad: "exclamationmark.octagon.fill"
        }
    }

    var color: Color {
        switch tone {
        case .idle: .secondary
        case .good: .green
        case .searching: .blue
        case .weak: .orange
        case .bad: .red
        }
    }

    /// Wie `assess`, dazu bei „sehr laut“ (Seitenleiste: orange) ein Hinweis,
    /// sobald die Zeile sonst nur Gutes meldet – sonst stand links „Sehr laut“
    /// und rechts „der Pegel passt“.
    @MainActor
    static func make(model: some GainTunable, levels: HackRFDevice.InputLevels?, tracker: ActivityTracker,
                     autoGain: Bool, occupant: String? = nil, now: Date = Date()) -> ReceiverVerdict {
        var verdict = assess(model: model, levels: levels, tracker: tracker, autoGain: autoGain, occupant: occupant, now: now)
        if verdict.tone == .good, let levels, ReceiveLevel(levels) == .warning {
            let hint = String(localized: "Hinweis: sehr laut, wenig Reserve bis zur Übersteuerung.")
            verdict.text = verdict.text == levelFine
                ? String(localized: "Empfang läuft. \(hint)")
                : "\(verdict.text) \(hint)"
        }
        return verdict
    }

    private static var levelFine: String { String(localized: "Empfang läuft, der Pegel passt.") }

    @MainActor
    private static func assess(model: some GainTunable, levels: HackRFDevice.InputLevels?, tracker: ActivityTracker,
                     autoGain: Bool, occupant: String? = nil, now: Date = Date()) -> ReceiverVerdict {
        let plays = model.startsByPlaying
        guard model.running else {
            return .init(tone: .idle, text: plays ? String(localized: "Bereit – mit „Abspielen“ geht es los.")
                                                  : String(localized: "Bereit – mit „Start“ geht es los."))
        }
        if let occupant {
            if occupant.isEmpty {
                return .init(tone: .weak, text: plays ? String(localized: "Der Empfang ist abgerissen – drück „Stopp“ und wieder „Abspielen“.")
                                                      : String(localized: "Der Empfang ist abgerissen – drück „Stopp“ und wieder „Start“."))
            }
            return .init(tone: .weak, text: plays
                         ? String(localized: "Der HackRF empfängt gerade für \(occupant) – „Stopp“ und „Abspielen“ holt ihn hierher zurück.")
                         : String(localized: "Der HackRF empfängt gerade für \(occupant) – „Stopp“ und „Start“ holt ihn hierher zurück."))
        }
        let elapsed = now.timeIntervalSince(tracker.started)
        // Dieselbe Bewertung wie der Pegel in der Seitenleiste.
        let level = levels.map { ReceiveLevel($0) }
        if level == .overloaded {
            return .init(tone: .bad, text: autoGain
                         ? String(localized: "Übersteuert – die Automatik nimmt die Verstärkung gerade zurück.")
                         : String(localized: "Übersteuert – drück „Signal optimieren“ oder senk die Verstärkung."))
        }
        let quiet = level == .low
        let weakText = String(localized: "Das Signal ist sehr schwach – Antenne prüfen (draußen, höher, frei) oder „Signal optimieren“.")

        if let fraction = tracker.goodFraction {
            let percent = Int((fraction * 100).rounded())
            if fraction >= 0.95 { return .init(tone: .good, text: String(localized: "Empfang einwandfrei.")) }
            if fraction >= 0.5 {
                return .init(tone: .weak, text: String(localized: "Empfang mit Aussetzern (\(percent) % fehlerfrei) – eine bessere Antenne oder ein anderer Platz hilft."))
            }
            return .init(tone: .weak, text: String(localized: "Signal zu schwach: nur \(percent) % fehlerfrei. Antenne verbessern oder „Signal optimieren“."))
        }
        if model.needsLock {
            if model.quality != nil { return .init(tone: .good, text: String(localized: "Signal gefunden.")) }
            if elapsed < 20 { return .init(tone: .searching, text: String(localized: "Suche das Signal …")) }
            return .init(tone: .weak, text: quiet ? weakText : String(localized: "Kein Signal gefunden. \(model.idleHint)"))
        }
        if model.activity != nil {
            if let last = tracker.lastActivity, now.timeIntervalSince(last) < 120 {
                if let rate = tracker.perMinute, rate >= 1 {
                    return .init(tone: .good, text: String(localized: "Empfang läuft – etwa \(Int(rate.rounded())) Meldungen pro Minute."))
                }
                return .init(tone: .good, text: String(localized: "Empfang läuft – letzte Meldung vor \(Int(now.timeIntervalSince(last))) s."))
            }
            if elapsed < 60 { return .init(tone: .searching, text: String(localized: "Höre zu … die ersten Meldungen kommen meist innerhalb einer Minute.")) }
            let since = tracker.lastActivity ?? tracker.started
            let minutes = max(1, Int(now.timeIntervalSince(since) / 60))
            let lead = tracker.lastActivity == nil
                ? String(localized: "Seit \(minutes) min nichts empfangen.")
                : String(localized: "Seit \(minutes) min keine neue Meldung.")
            return .init(tone: quiet ? .weak : .searching, text: quiet ? "\(lead) \(weakText)" : "\(lead) \(model.idleHint)")
        }
        // Ohne Zähler (Radio, WLAN-Belegung …): nur der Pegel.
        if quiet { return .init(tone: .weak, text: weakText) }
        return .init(tone: .good, text: levelFine)
    }
}
