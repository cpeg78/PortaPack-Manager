import AppKit
import SwiftUI

/// Seite „Empfangsplan“: Überflüge der Wettersatelliten und der
/// Amateurfunk-Satelliten, Sondenfenster und automatischer Empfang. Die
/// Planung steht nur hier; METEOR-, Amateurfunk- und Sondenseite verweisen
/// darauf (Bedienungs-Umbau 29.10.2026).
struct PlannerView: View {
    @Bindable private var planner = ReceptionPlanner.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    /// Eingeklappt zeigt die Liste nur die nächsten Überflüge – 48 h sind rund 30 Zeilen.
    @AppStorage("plannerPassesExpanded") private var passesExpanded = false
    @AppStorage("plannerHistoryExpanded") private var historyExpanded = false
    @AppStorage("plannerAmateurExpanded") private var amateurExpanded = false
    private static let collapsedCount = 3

    /// Warum die Amateurfunk-Liste leer ist – nicht ewig „wird geladen“.
    private var amateurEmptyText: String {
        if planner.amateurSelection.isEmpty { return String(localized: "Kein Satellit gewählt.") }
        if homeLat == 0 && homeLon == 0 { return String(localized: "Ohne Standort lassen sich keine Überflüge berechnen.") }
        if planner.amateurTLEDate == nil {
            return planner.amateurTLEError ?? String(localized: "Bahndaten werden geladen …")
        }
        return String(localized: "Keine Überflüge in den nächsten 48 Stunden.")
    }

    var body: some View {
        ControlsSplit(width: 300) {
            List {
                if planner.userPaused {
                    Section {
                        HStack {
                            Label("Empfangsplan pausiert – keine neuen Termine.", systemImage: "pause.circle")
                            Spacer()
                            Button("Fortsetzen") { Task { await planner.setUserPaused(false) } }
                        }
                    }
                }
                if let note = planner.waitingNote {
                    Section { Label(note, systemImage: "hourglass").foregroundStyle(.secondary) }
                }
                if let status = planner.status {
                    Section {
                        HStack {
                            Label(status, systemImage: "record.circle").foregroundStyle(.red)
                            Spacer()
                            Button("Überspringen") { Task { await planner.skipActive() } }
                                .help("Diese Aufnahme beenden und nicht wieder aufnehmen – der vorherige Empfang läuft weiter.")
                        }
                    }
                } else if let next = planner.upcoming.first {
                    Section {
                        Label {
                            Text("Nächster Termin: \(next.title), ")
                                + Text(next.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                + Text(" (") + Text(next.start, style: .relative) + Text(")")
                        } icon: {
                            Image(systemName: next.isPass ? "dot.radiowaves.up.forward" : next.isAmateur ? "photo.on.rectangle" : "balloon")
                        }
                    }
                }
                if homeLat == 0 && homeLon == 0 {
                    Section { SettingsHint(.location, "Für die Vorhersage fehlt der eigene Standort.") }
                }
                // Nur, was automatisch empfangen wird – abgeschaltete Arten blendet die
                // Liste aus (Nutzer, 29.10.2026). Jeder Termin hat rechts einen eigenen
                // Schalter, ein Klick zeigt Einzelheiten.
                if !planner.autoMeteor && !planner.autoAmateur && !planner.autoSonde {
                    Section {
                        Text("Nichts geplant – schalte rechts ein, was automatisch empfangen werden soll.")
                            .foregroundStyle(.secondary)
                    }
                }
                if planner.autoMeteor {
                    Section {
                        if planner.passes.isEmpty, homeLat != 0 || homeLon != 0 {
                            Text(planner.tleError ?? String(localized: "Bahndaten werden geladen …")).foregroundStyle(.secondary)
                        }
                        ForEach(passesExpanded ? planner.passes : Array(planner.passes.prefix(Self.collapsedCount))) { pass in
                            PlanPassRow(pass: pass, id: ReceptionPlanner.jobID(pass: pass),
                                        eligible: planner.isPlanned(pass), minElevation: planner.minElevation, weather: true)
                        }
                    } header: {
                        CollapsibleHeader(title: "Wettersatelliten (nächste 48 h)", count: planner.passes.count,
                                          shown: Self.collapsedCount, expanded: $passesExpanded)
                    }
                }
                if planner.autoAmateur {
                    Section {
                        if planner.amateurPasses.isEmpty {
                            Text(amateurEmptyText).foregroundStyle(.secondary)
                        }
                        ForEach(amateurExpanded ? planner.amateurPasses : Array(planner.amateurPasses.prefix(Self.collapsedCount))) { pass in
                            PlanPassRow(pass: pass, id: ReceptionPlanner.jobID(amateur: pass),
                                        eligible: planner.isPlannedAmateur(pass), minElevation: planner.amateurMinElevation, weather: false)
                        }
                    } header: {
                        CollapsibleHeader(title: "Amateurfunk-Satelliten (nächste 48 h)", count: planner.amateurPasses.count,
                                          shown: Self.collapsedCount, expanded: $amateurExpanded)
                    }
                }
                if planner.autoSonde {
                    Section("Sondenfenster") {
                        if planner.sondeWindows.isEmpty {
                            Text("Keine Startzeiten gewählt.").foregroundStyle(.secondary)
                        }
                        ForEach(planner.sondeWindows) { window in
                            PlanSondeRow(window: window)
                        }
                    }
                }
                Section {
                    if planner.history.isEmpty { Text("Noch nichts aufgenommen.").foregroundStyle(.secondary) }
                    ForEach(historyExpanded ? planner.history : Array(planner.history.prefix(Self.collapsedCount))) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.title).fontWeight(.medium)
                                Spacer()
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                            }
                            Text(entry.result).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    CollapsibleHeader(title: "Verlauf", count: planner.history.count,
                                      shown: Self.collapsedCount, expanded: $historyExpanded)
                }
            }
            .frame(minWidth: 480)
        } controls: {
            Form {
                if !planner.history.isEmpty {
                    Section {
                        Button("Leeren") { planner.clearHistory() }
                            .help("Verlauf der Aufnahmen leeren")
                    }
                }
                Section("Wettersatelliten (METEOR)") {
                    Toggle("Überflüge automatisch empfangen", isOn: $planner.autoMeteor)
                    LabeledContent("Mindesthöhe \(Int(planner.minElevation))°") {
                        Slider(value: $planner.minElevation, in: 10...70, step: 5)
                    }
                    Text("Empfängt jeden Überflug von selbst und speichert die Bilder. Unter etwa 20° Höhe kommt mit einer einfachen Antenne selten ein Bild.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Nächsten Überflug als Rohdaten mitschneiden", isOn: $planner.recordMeteorIQ)
                        .help("Speichert den nächsten Überflug zusätzlich als Rohdaten (≈ 5 GB) zum späteren Auswerten auf der METEOR-Seite. Schaltet sich danach selbst ab.")
                    Button("Bilder im Finder zeigen") { NSWorkspace.shared.open(MeteorPNG.folder) }
                }
                PlannerAmateurSection()
                Section("Radiosonden") {
                    Toggle("Aufstiege automatisch empfangen", isOn: $planner.autoSonde)
                    ForEach(ReceptionPlanner.sondeSlotChoices, id: \.self) { slot in
                        Toggle(Self.slotTitle(slot), isOn: Binding(
                            get: { planner.sondeSlots.contains(slot) },
                            set: { on in if on { planner.sondeSlots.insert(slot) } else { planner.sondeSlots.remove(slot) } }))
                    }
                    LabeledContent("Dauer \(Int(planner.sondeMinutes)) min") {
                        Slider(value: $planner.sondeMinutes, in: 60...240, step: 15)
                    }
                    Toggle("Nur wenn SondeHub eine Sonde in Reichweite meldet", isOn: $planner.sondeOnlyInRange)
                    if planner.sondeOnlyInRange {
                        LabeledContent("Reichweite \(Int(planner.sondeRangeKm)) km") {
                            Slider(value: $planner.sondeRangeKm, in: 50...400, step: 10)
                        }
                        Text("Der Plan schaltet nur um, wenn laut SondeHub gerade eine Sonde in Reichweite fliegt. Dein Standort wird dabei nicht gesendet.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(planner.sondesInRange, id: \.serial) { s in
                            Text("\(s.serial) · \(s.type ?? "?") · \(s.frequencyMHz.map { String(format: "%.3f MHz", $0) } ?? "–") · \(Int(s.distanceKm)) km · \(Int(s.altitude)) m")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    if let window = planner.sondeForecastWindow {
                        Text("Vorhersage für das Fenster ab \(window.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.weight(.semibold))
                        ForEach(planner.sondeForecast) { f in
                            Label {
                                Text(Self.forecastText(f)).font(.caption.monospacedDigit())
                            } icon: {
                                Image(systemName: f.inRange == nil ? "xmark.circle" : "checkmark.circle")
                                    .foregroundStyle(f.inRange == nil ? Color.secondary : Color.green)
                            }
                        }
                        if planner.sondeForecast.isEmpty { Text("Kein Start in der Nähe erwartet.").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let error = planner.sondeForecastError {
                        Text("Vorhersage: \(error)").font(.caption).foregroundStyle(.orange)
                    }
                    Text("Fliegt eine Sonde laut Vorhersage länger in Reichweite, bleibt das Fenster entsprechend länger offen.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Wetterballons steigen meist kurz vor 0 und 12 Uhr UTC auf, an manchen Orten auch vor 6 und 18 Uhr. Alle Meldungen landen im Sondenarchiv; dort lässt sich jeder Flug als CSV sichern.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sondenarchiv …") { openWindow(id: "sondeArchive") }
                }
                Section("Bahndaten") {
                    LabeledContent("Stand", value: planner.tleDate?.formatted(date: .abbreviated, time: .shortened) ?? "–")
                    if let error = planner.tleError { Text(error).font(.caption).foregroundStyle(.red) }
                    Button("Aktualisieren") { planner.refreshOrbits() }
                    Text("Kommen einmal täglich von CelesTrak. Über dich geht dabei nichts hinaus.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(PanelSection.hinweis) {
                    Text("Die App muss laufen – solange ein Plan an ist, schläft der Mac nicht ein. Während eines Termins übernimmt der Plan den HackRF; ADS-B, AIS oder DAB+ laufen danach von selbst weiter, andere Seiten nicht.")
                        .font(.caption).foregroundStyle(.secondary)
                    SettingsHint(.notifications, "Vor Überflügen und nach jeder Aufnahme kann die App Bescheid geben.")
                }
            }
            .formStyle(.grouped)
        }
    }

    /// „22:45 UTC (23:45 Uhr)“
    static func forecastText(_ f: SondeForecast.Flight) -> String {
        let t = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        let site = f.frequencyMHz.map { "\(f.site) \($0.formatted(.number.precision(.fractionLength(1)))) MHz" } ?? f.site
        let range = f.inRange.map { String(localized: "in Reichweite \(t($0.lowerBound))–\(t($0.upperBound))") }
            ?? String(localized: "nicht in Reichweite")
        let height = (f.closestAltitude / 1000).formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(site), Start \(t(f.launch)): \(range) · am nächsten \(Int(f.closestKm)) km um \(t(f.closestAt)) in \(height) km Höhe · Landung \(Int(f.landingKm)) km entfernt")
    }

    static func slotTitle(_ minutes: Int) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.startOfDay(for: Date()).addingTimeInterval(Double(minutes) * 60)
        let utcText = String(format: "%02d:%02d UTC", minutes / 60, minutes % 60)
        return String(localized: "\(utcText) (\(date.formatted(date: .omitted, time: .shortened)) Uhr)")
    }
}

/// Amateurfunk-Satelliten im Plan (vorher `AmateurPlanSection` auf der
/// Amateurfunk-Seite; die Planung steht jetzt nur noch hier).
private struct PlannerAmateurSection: View {
    @Bindable private var planner = ReceptionPlanner.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Amateurfunk-Satelliten & ISS") {
            Toggle("Überflüge automatisch empfangen", isOn: $planner.autoAmateur)
            ForEach(satellites) { sat in
                Toggle("\(sat.name) im Empfangsplan", isOn: Binding(
                    get: { planner.amateurSelection.contains(sat.id) },
                    set: { on in if on { planner.amateurSelection.insert(sat.id) } else { planner.amateurSelection.remove(sat.id) } }))
            }
            LabeledContent("Mindesthöhe \(Int(planner.amateurMinElevation))°") {
                Slider(value: $planner.amateurMinElevation, in: 10...60, step: 5)
            }
            Text("Hört während des Überflugs auf allen Kanälen des Satelliten mit und speichert SSTV-Bilder. Überschneiden sich Termine, geht METEOR vor, dann Amateurfunk, dann Radiosonden. Eigene Satelliten trägst du auf der Seite „Amateurfunk-Satelliten & ISS“ ein.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var satellites: [AmateurSatellite] {
        let own = AmateurSatellite.custom
        let extra = !own.channels.isEmpty && AmateurSatellite.catalog.allSatisfy { $0.id != own.id } ? [own] : []
        return AmateurSatellite.catalog + extra
    }
}

/// Abschnittskopf mit Ein-/Ausklappen; eingeklappt zeigt der Abschnitt die
/// ersten `shown` Zeilen, der Knopf nennt, wie viele es insgesamt sind.
struct CollapsibleHeader: View {
    let title: Text
    let count: Int
    let shown: Int
    @Binding var expanded: Bool

    /// Literale werden übersetzt (wie bei `Text`) …
    init(title: LocalizedStringKey, count: Int, shown: Int, expanded: Binding<Bool>) {
        self.init(text: Text(title), count: count, shown: shown, expanded: expanded)
    }

    /// … fertige (schon übersetzte) Texte erscheinen unverändert.
    @_disfavoredOverload
    init<S: StringProtocol>(title: S, count: Int, shown: Int, expanded: Binding<Bool>) {
        self.init(text: Text(title), count: count, shown: shown, expanded: expanded)
    }

    private init(text: Text, count: Int, shown: Int, expanded: Binding<Bool>) {
        self.title = text
        self.count = count
        self.shown = shown
        self._expanded = expanded
    }

    var body: some View {
        HStack {
            title
            Spacer()
            if count > shown {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Label(expanded ? "Weniger" : "Alle \(count) zeigen",
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}

struct PassRow: View {
    let pass: SatellitePass
    let planned: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pass.daylight ? "sun.max.fill" : "moon.fill")
                .foregroundStyle(pass.daylight ? .orange : .indigo)
                .frame(width: 18)
                .help(pass.daylight ? "Tag – sichtbare Kanäle und Infrarot" : "Nacht – nur Infrarot")
            VStack(alignment: .leading, spacing: 1) {
                Text(pass.satellite.name).fontWeight(.medium)
                Text(pass.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · "
                     + pass.start.formatted(date: .omitted, time: .shortened) + "–"
                     + pass.end.formatted(date: .omitted, time: .shortened)
                     + " · " + GeoMath.compass(pass.startAzimuth) + " → " + GeoMath.compass(pass.endAzimuth))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(pass.maxElevation.rounded()))°")
                .font(.body.monospacedDigit())
                .foregroundStyle(pass.maxElevation >= 30 ? .primary : .secondary)
            if planned {
                Image(systemName: "record.circle").foregroundStyle(Color.accentColor).help("Wird automatisch aufgenommen")
            }
        }
    }
}

/// Schalter rechts in einer Planzeile: dieser eine Termin an/aus.
private struct PlanSwitch: View {
    let id: String
    let end: Date
    private var planner: ReceptionPlanner { .shared }

    var body: some View {
        Toggle("Geplant", isOn: Binding(get: { !planner.isSkipped(id) },
                                       set: { planner.setSkipped(id, end: end, !$0) }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help("Diesen Termin aufnehmen oder auslassen")
    }
}

/// Überflug im Plan: Zeile mit Schalter, Klick zeigt Einzelheiten.
private struct PlanPassRow: View {
    let pass: SatellitePass
    let id: String
    let eligible: Bool
    let minElevation: Double
    let weather: Bool
    @State private var showDetails = false
    private var planner: ReceptionPlanner { .shared }

    var body: some View {
        HStack {
            PassRow(pass: pass, planned: false)
            if eligible {
                PlanSwitch(id: id, end: pass.end)
            } else {
                Text("zu niedrig").font(.caption).foregroundStyle(.secondary)
                    .help("Unter der Mindesthöhe von \(Int(minElevation))° – wird nicht aufgenommen.")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showDetails = true }
        .popover(isPresented: $showDetails, arrowEdge: .trailing) { details }
    }

    private var status: String {
        if planner.status != nil, planner.isActive(id) { return String(localized: "Läuft gerade.") }
        if !eligible { return String(localized: "Wird nicht aufgenommen: unter der Mindesthöhe von \(Int(minElevation))°.") }
        if planner.isSkipped(id) { return String(localized: "Ausgelassen – mit dem Schalter wieder einplanen.") }
        return String(localized: "Geplant: Die Aufnahme beginnt eine Minute vor dem Aufgang.")
    }

    private var details: some View {
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        return Form {
            Section {
                LabeledContent("Tag", value: pass.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                LabeledContent("Aufgang", value: time(pass.start) + " · " + GeoMath.compass(pass.startAzimuth))
                LabeledContent("Höchster Stand", value: time(pass.culmination) + " · \(Int(pass.maxElevation.rounded()))°")
                LabeledContent("Untergang", value: time(pass.end) + " · " + GeoMath.compass(pass.endAzimuth))
                LabeledContent("Dauer", value: Duration.seconds(pass.duration).formatted(.units(allowed: [.minutes], width: .abbreviated)))
                if weather {
                    LabeledContent("Frequenz", value: (pass.satellite.frequency / 1e6).formatted(.number.precision(.fractionLength(3))) + " MHz")
                    LabeledContent("Bild", value: pass.daylight ? String(localized: "Tag – sichtbar und Infrarot") : String(localized: "Nacht – nur Infrarot"))
                }
            } header: {
                Text(pass.satellite.name).font(.headline)
            } footer: {
                Text(status).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
    }
}

/// Sondenfenster im Plan: Zeile mit Schalter, Klick zeigt Einzelheiten.
private struct PlanSondeRow: View {
    let window: ReceptionPlanner.SondeWindow
    @State private var showDetails = false
    private var planner: ReceptionPlanner { .shared }
    private var id: String { ReceptionPlanner.jobID(window: window) }

    var body: some View {
        HStack {
            Image(systemName: "balloon").foregroundStyle(planner.isSkipped(id) ? Color.secondary : Color.accentColor)
            Text(window.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
            Text(verbatim: "– " + window.end.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
            Spacer()
            PlanSwitch(id: id, end: window.end)
        }
        .contentShape(Rectangle())
        .onTapGesture { showDetails = true }
        .popover(isPresented: $showDetails, arrowEdge: .trailing) { details }
    }

    private var details: some View {
        var utc = Date.FormatStyle(date: .omitted, time: .shortened)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        let forecast = planner.sondeForecastWindow == window.start ? planner.sondeForecast : []
        return Form {
            Section {
                LabeledContent("Tag", value: window.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                LabeledContent("Zeit", value: "\(time(window.start))–\(time(window.end))")
                LabeledContent("UTC", value: "\(window.start.formatted(utc))–\(window.end.formatted(utc))")
                LabeledContent("Dauer", value: Duration.seconds(window.end.timeIntervalSince(window.start)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                if planner.sondeOnlyInRange {
                    Text("Startet nur, wenn SondeHub eine Sonde in \(Int(planner.sondeRangeKm)) km meldet – sonst läuft der bisherige Empfang weiter.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Radiosonden").font(.headline)
            } footer: {
                Text(planner.isActive(id) ? String(localized: "Läuft gerade.")
                     : planner.isSkipped(id) ? String(localized: "Ausgelassen – mit dem Schalter wieder einplanen.")
                     : String(localized: "Geplant.")).foregroundStyle(.secondary)
            }
            Section("Vorhersage (SondeHub)") {
                if forecast.isEmpty {
                    Text("Die Flugvorhersage holt die App kurz vor dem Fenster.").foregroundStyle(.secondary)
                } else {
                    ForEach(forecast) { f in
                        Text(PlannerView.forecastText(f)).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }
}
