import CoreLocation
import SwiftUI

struct GPSView: View {
    @AppStorage("homeLat") private var homeLat = 0.0
    @AppStorage("homeLon") private var homeLon = 0.0
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.gps
    @State private var mapController = MapController()
    @State private var centered = false

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "location.viewfinder", text: "Die App bestimmt deine Position selbst aus den GPS-Signalen (1575,42 MHz). Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 320, issue: model.error) {
                VSplitView {
                    map.frame(minHeight: 160, idealHeight: 400)
                    table.frame(minHeight: 100)
                }
                .frame(minWidth: 480)
            } controls: {
                controls
            }
            .task { if AppNavigation.shared.takeAutoStart(.gps), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in centered = false; model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop() } }
            .onChange(of: model.status.solution?.latitude) { _, _ in centerOnFirstFix() }
        }
    }

    // MARK: Karte

    private var coordinate: CLLocationCoordinate2D? {
        model.status.solution.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var mapFeatures: [MapFeature] {
        guard let coordinate, let sol = model.status.solution else { return [] }
        var accuracy = MapFeature.circle("accuracy", center: coordinate, radius: max(sol.horizontalAccuracy, 3),
                                         color: MapColor.blue, width: 1, opacity: 0.6, fillOpacity: 0.15)
        accuracy.fit = false
        var dot = MapFeature.marker("gps", at: coordinate, symbol: .dot, color: MapColor.blue, size: 14, label: "GPS")
        dot.fit = false
        return [accuracy, dot]
    }

    private var map: some View {
        LeafletMap(features: mapFeatures, controller: mapController,
                   options: MapOptions(center: (homeLat != 0 || homeLon != 0) ? MapPoint(homeLat, homeLon) : MapPoint(51, 10),
                                       zoom: (homeLat != 0 || homeLon != 0) ? 10 : 5))
            .overlay(alignment: .topLeading) {
                if model.status.solution == nil {
                    Text(model.running ? "Noch keine Position – den Fortschritt siehst du rechts unter „Kaltstart“." : "Keine Position")
                        .font(.callout).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let coordinate, centered {
                    Button("Position zeigen", systemImage: "location") {
                        mapController.show(around: coordinate, radiusMeters: 300)
                    }
                    .padding(10)
                }
            }
    }

    private func centerOnFirstFix() {
        guard !centered, let coordinate else { return }
        centered = true
        mapController.show(around: coordinate, radiusMeters: 300, animated: false)
    }

    // MARK: Satelliten

    private var table: some View {
        Table(model.status.channels) {
            TableColumn("PRN") { ch in
                HStack {
                    Circle().fill(color(ch)).frame(width: 9, height: 9)
                    Text("\(ch.prn)").monospacedDigit()
                }
            }.width(60)
            TableColumn("Zustand") { ch in
                HStack(spacing: 4) {
                    Text(ch.state.title).foregroundStyle(ch.locked ? .primary : .secondary)
                    if ch.longIntegration {
                        Text("schwach").font(.caption2).foregroundStyle(.orange)
                            .help("Schwaches Signal: Die App integriert über ein ganzes Datenbit (20 ms) und regelt mit schmaler Bandbreite nach.")
                    }
                }
            }.width(min: 90, ideal: 120)
            TableColumn("C/N₀") { ch in
                Text(ch.cn0 > 0 ? "\((ch.cn0).formatted(.number.precision(.fractionLength(0)))) dB-Hz" : "–").monospacedDigit()
            }.width(80)
            TableColumn("Doppler") { ch in
                Text(verbatim: "\((ch.dopplerHz).formatted(.number.precision(.fractionLength(0)).sign(strategy: .always()))) Hz").monospacedDigit().foregroundStyle(.secondary)
            }.width(80)
            TableColumn("Bahndaten") { ch in
                HStack(spacing: 3) {
                    ForEach(1...3, id: \.self) { id in
                        Text("\(id)").font(.caption2.monospacedDigit())
                            .frame(width: 14, height: 14)
                            .background(ch.subframes.contains(id) ? Color.green.opacity(0.7) : Color.secondary.opacity(0.2),
                                        in: RoundedRectangle(cornerRadius: 3))
                    }
                }
            }.width(70)
            TableColumn("Höhe") { ch in
                Text(ch.elevation.map { "\(($0).formatted(.number.precision(.fractionLength(0))))°" } ?? "–").monospacedDigit()
                    .foregroundStyle(.secondary)
            }.width(70)
            TableColumn("Richtung") { ch in
                Text(ch.azimuth.map { "\(($0).formatted(.number.precision(.fractionLength(0))))°" } ?? "–").monospacedDigit()
                    .foregroundStyle(.secondary)
            }.width(60)
        }
        .overlay {
            if model.status.channels.isEmpty {
                ContentUnavailableView("Keine Satelliten", systemImage: "location.slash",
                    description: Text(model.running
                        ? "Die App sucht alle zwei Sekunden nach Satelliten, schwache zusätzlich mit langer Integration. Ohne freien Blick zum Himmel kann das eine Weile dauern."
                        : "Klicke auf „Start“, dann sucht die App GPS-Satelliten und bestimmt deine Position."))
            }
        }
    }

    /// Wie gerade gesucht wird – in Alltagssprache.
    private var searchText: String {
        guard model.weakSearch else { return String(localized: "nur schnelle Suche") }
        if let visible = model.status.predictedVisible {
            return String(localized: "gezielt, \(visible) Satelliten über dem Horizont")
        }
        return String(localized: "Schwachsignal-Suche über alle Satelliten")
    }

    private func color(_ ch: GPSChannelStatus) -> Color {
        if ch.usedInFix { return .green }
        if !ch.locked { return .secondary.opacity(0.4) }
        return ch.state >= .frameSync ? .yellow : .orange
    }

    // MARK: Bedienfeld

    private var controls: some View {
        Form {
            Section {
                Button(model.running ? "Stopp" : "Start") {
                    if model.running { model.stop() }
                    else { ReceiverStore.shared.requestStart(model, session: session) { device in centered = false; model.start(on: device) } }
                }
                .buttonStyle(.borderedProminent)
                .startStopShortcut()
                // GPS braucht fast immer eine aktive Antenne – deshalb steht der
                // Schalter hier sichtbar und nicht nur eingeklappt unter „Von Hand
                // einstellen“ (dieselbe Modelleigenschaft wie dort).
                Toggle("Antennenspeisung (Bias-Tee)", isOn: Binding(
                    get: { model.antennaPower },
                    set: { model.antennaPower = $0; model.applyFromControls(session.hackRF) }))
                    .help(GainHelp.biasTee)
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF) {
                    Toggle("Schwachsignal-Suche", isOn: $model.weakSearch)
                        .help("Sucht Satelliten, die die schnelle Suche nicht findet, mit langer Integration (10 ms kohärent, bis 0,5 s) – findet sie am Fenster oder unter Bäumen, kostet aber etwas Rechenzeit.")
                }
            }
            Section(PanelSection.status) {
                LabeledContent("Verfolgte Satelliten", value: "\(model.trackedCount)")
                LabeledContent("Mit Bahndaten", value: "\(model.status.ephemerisCount)")
                    .help("Satelliten, deren Bahndaten (Ephemeriden) vollständig angekommen sind.")
                if model.running {
                    LabeledContent("Suche", value: searchText)
                        .help("Mit Almanach oder gespeicherten Bahndaten, Ort und Uhrzeit sagt die App voraus, welche Satelliten am Himmel stehen und mit welchem Doppler – dann sucht sie gezielt und findet schwächere Signale.")
                }
                if model.status.hotStart {
                    Text("Gespeicherte Bahndaten sind noch gültig – die erste Position braucht nur die Uhrzeit der Satelliten (Heißstart).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.running && model.status.solution == nil {
                coldStart
            }
            if let sol = model.status.solution {
                Section("Position") {
                    LabeledContent("Breite", value: "\((sol.latitude).formatted(.number.precision(.fractionLength(6))))°")
                    LabeledContent("Länge", value: "\((sol.longitude).formatted(.number.precision(.fractionLength(6))))°")
                    LabeledContent("Höhe (Ellipsoid)", value: "\((sol.height).formatted(.number.precision(.fractionLength(0)))) m")
                    LabeledContent("Genauigkeit", value: String(localized: "± \(sol.horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))) m (Höhe ± \(sol.verticalAccuracy.formatted(.number.precision(.fractionLength(0)))) m)"))
                    LabeledContent("DOP", value: String(format: "H %.1f · V %.1f · P %.1f", sol.hdop, sol.vdop, sol.pdop))
                    if let v = sol.speed {
                        LabeledContent("Geschwindigkeit", value: "\((v * 3.6).formatted(.number.precision(.fractionLength(1)))) km/h")
                    }
                    LabeledContent("Satelliten", value: "\(sol.satellites.count)")
                    Button("Als eigenen Standort übernehmen", systemImage: "house") {
                        homeLat = (sol.latitude * 10_000).rounded() / 10_000
                        homeLon = (sol.longitude * 10_000).rounded() / 10_000
                    }
                    .help("Speichert die Position als deinen Standort (Einstellungen) – für Entfernungen auf allen Kartenseiten.")
                    if let age = model.status.solutionAge, age > 2 {
                        Text("Letzte Position vor \(age, format: .number.precision(.fractionLength(0))) s").font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Zeit") {
                    if let utc = model.status.utc {
                        LabeledContent("UTC", value: utc.formatted(.dateTime.day().month().year().hour().minute().second()))
                    }
                    if let week = model.status.week {
                        LabeledContent("GPS-Zeit", value: String(localized: "Woche \(week), \(sol.gpsTime.formatted(.number.precision(.fractionLength(1)))) s"))
                    }
                    LabeledContent("Schaltsekunden", value: model.status.hasIonosphere ? "\(model.status.leapSeconds)" : String(localized: "\(model.status.leapSeconds) (Annahme)"))
                }
            }
            Section {
                Text("Am besten mit einer **aktiven GPS-Antenne mit freiem Blick zum Himmel** – schalte dafür oben „Antennenspeisung (Bias-Tee)“ ein. Am Fenster findet die Schwachsignal-Suche oft trotzdem Satelliten, die erste Position dauert dann länger; tief im Haus klappt es meist nicht.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("GPS-Signale liegen unter dem Rauschen. Eine passive Antenne verträgt die Speisespannung nicht immer. Die schnelle Suche findet Satelliten ab etwa 38 dB-Hz, die Schwachsignal-Suche ab etwa 26 dB-Hz (gezielt ab etwa 23). Verfolgt werden sie bis etwa 22 dB-Hz; für eine Position braucht es mindestens vier mit vollständigen Bahndaten.")
            } header: { Text(PanelSection.hinweis) }
        }
        .formStyle(.grouped)
    }

    /// Kaltstart: Jeder Satellit sendet seine Bahndaten in den Subframes 1–3,
    /// alle 30 s einmal. Vor der ersten Position vergehen deshalb ≥ 30 s.
    private var coldStart: some View {
        Section("Kaltstart") {
            let elapsed = model.status.elapsed
            ProgressView(value: min(elapsed / 36, 1)) {
                Text("\(elapsed, format: .number.precision(.fractionLength(0))) s von meist 30–40 s")
            }
            let withTime = model.status.channels.filter { $0.state >= .frameSync }.count
            let ready = model.status.channels.filter { $0.state == .ephemeris }.count
            LabeledContent("Mit Zeit (TOW)", value: "\(withTime)")
            LabeledContent("Mit Bahndaten", value: String(localized: "\(ready) von mind. 4"))
            Text("Jeder Satellit sendet seine Bahndaten nur alle 30 Sekunden. Bis zur ersten Position dauert es deshalb mindestens so lange, bei schwachem Signal länger.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
