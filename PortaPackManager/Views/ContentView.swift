import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, settings, firmware, screen, files, console
    case planner, spectrum, radio, dab, tv, adsb, acars, ais, aprs, pager, sonde, meteor, sensors, ble, zigbee, wifi, drones, meshtastic, lorawan, flarm, dcf77, gps, recorder, antennaCheck
    case smartHome868, airband, vor, dsc, amateurSat, ft8, hydrogen, cells, occupancy

    var id: String { rawValue }

    /// Gruppen der Seitenleiste: zuerst das Gerät (Mayhem), dann die
    /// Empfänger des HackRF-Modus nach Themen. **Jeder neue Fall muss hier
    /// eingetragen werden** – sonst taucht die Seite nicht auf
    /// (`SidebarTests` prüft das).
    static let groups: [(title: String, items: [SidebarItem])] = [
        (String(localized: "Gerät"), [.overview, .settings, .firmware, .screen, .files, .console]),
        // Empfangsplan unter Werkzeuge: er plant auch Amateurfunk-Satelliten, nicht nur Wetter.
        (String(localized: "Werkzeuge"), [.planner, .spectrum, .occupancy, .cells, .antennaCheck, .recorder]),
        (String(localized: "Rundfunk"), [.radio, .dab, .tv]),
        (String(localized: "Luftfahrt"), [.adsb, .acars, .airband, .vor, .flarm, .drones]),
        (String(localized: "Schifffahrt & Funkdienste"), [.ais, .dsc, .aprs, .pager]),
        (String(localized: "Wetter"), [.sonde, .meteor]),
        (String(localized: "Navigation & Zeit"), [.gps, .dcf77]),
        (String(localized: "Smart Home & IoT"), [.sensors, .smartHome868, .zigbee, .ble, .wifi, .lorawan, .meshtastic]),
        (String(localized: "Amateurfunk & Weltraum"), [.amateurSat, .ft8, .hydrogen]),
    ]

    var title: String {
        switch self {
        case .overview: String(localized: "Übersicht")
        case .settings: String(localized: "Einstellungen")
        case .firmware: String(localized: "Firmware")
        case .screen: String(localized: "Bildschirm & Steuerung")
        case .files: String(localized: "SD-Karte")
        case .spectrum: String(localized: "Spektrum")
        case .radio: String(localized: "Radio")
        case .dab: String(localized: "Digitalradio (DAB+)")
        case .tv: String(localized: "Fernsehen (DVB-T2)")
        case .adsb: String(localized: "Flugzeuge (ADS-B)")
        case .acars: String(localized: "Flugzeug-Datenfunk (ACARS)")
        case .ais: String(localized: "Schiffe (AIS)")
        case .aprs: String(localized: "Funkamateure (APRS)")
        case .pager: String(localized: "Funkruf (POCSAG)")
        case .planner: String(localized: "Empfangsplan")
        case .sonde: String(localized: "Wetterballons (Radiosonden)")
        case .meteor: String(localized: "Wettersatellit (METEOR)")
        case .flarm: String(localized: "FLARM/OGN (Segelflug)")
        case .sensors: String(localized: "Funksensoren")
        case .ble: String(localized: "Bluetooth-Geräte")
        case .zigbee: String(localized: "Zigbee")
        case .wifi: String(localized: "WLAN")
        case .drones: String(localized: "Drohnen (Remote ID)")
        case .meshtastic: String(localized: "Meshtastic (LoRa)")
        case .lorawan: String(localized: "Funknetz LoRaWAN")
        case .dcf77: String(localized: "Funkuhr (DCF77)")
        case .gps: String(localized: "GPS-Ortung")
        case .recorder: String(localized: "Aufnahme")
        case .antennaCheck: String(localized: "Antennen-Check")
        case .console: String(localized: "Konsole")
        case .smartHome868: String(localized: "Smart Home 868 MHz")
        case .airband: String(localized: "Flugfunk")
        case .vor: String(localized: "Funkfeuer (VOR)")
        case .dsc: String(localized: "Seefunk-Notruf (DSC)")
        case .amateurSat: String(localized: "Amateurfunk-Satelliten & ISS")
        case .ft8: String(localized: "Amateurfunk FT8/WSPR")
        case .hydrogen: String(localized: "Wasserstofflinie")
        case .cells: String(localized: "Mobilfunkzellen (LTE)")
        case .occupancy: String(localized: "Belegungsmonitor")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "info.circle"
        case .settings: "gearshape"
        case .firmware: "arrow.down.circle"
        case .screen: "rectangle.on.rectangle"
        case .files: "sdcard"
        case .spectrum: "waveform.path.ecg"
        case .radio: "radio"
        case .dab: "dot.radiowaves.left.and.right"
        case .tv: "tv"
        case .adsb: "airplane"
        case .acars: "text.bubble"
        case .ais: "ferry"
        case .aprs: "antenna.radiowaves.left.and.right"
        case .pager: "message"
        case .planner: "calendar.badge.clock"
        case .sonde: "balloon"
        case .meteor: "cloud.sun"
        case .flarm: "airplane.departure"
        case .sensors: "sensor"
        case .ble: "wave.3.right"
        case .zigbee: "point.3.filled.connected.trianglepath.dotted"
        case .wifi: "wifi"
        case .drones: "airplane.circle"
        case .meshtastic: "point.3.connected.trianglepath.dotted"
        case .lorawan: "dot.radiowaves.up.forward"
        case .dcf77: "clock"
        case .gps: "location.viewfinder"
        case .recorder: "waveform.badge.plus"
        case .antennaCheck: "antenna.radiowaves.left.and.right.circle"
        case .console: "terminal"
        case .smartHome868: "homekit"
        case .airband: "headphones"
        case .vor: "location.north.line"
        case .dsc: "sos"
        case .amateurSat: "photo.on.rectangle"
        case .ft8: "globe.europe.africa"
        case .hydrogen: "sparkles"
        case .cells: "cellularbars"
        case .occupancy: "chart.bar.xaxis"
        }
    }
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    /// Auf-/Zuklappen einer Gruppe, gespeichert über Programmläufe hinweg.
    private func expanded(_ title: String) -> Binding<Bool> {
        Binding {
            !collapsedGroups.split(separator: "|").contains(Substring(title))
        } set: { isExpanded in
            var set = Set(collapsedGroups.split(separator: "|").map(String.init))
            if isExpanded { set.remove(title) } else { set.insert(title) }
            collapsedGroups = set.sorted().joined(separator: "|")
        }
    }

    /// Sichtbare Einträge einer Gruppe: alle, oder eingeklappt nur die gewählte
    /// und die gerade empfangende Seite.
    nonisolated static func visibleItems(_ items: [SidebarItem], expanded: Bool, selection: SidebarItem?, receiving: SidebarItem?) -> [SidebarItem] {
        expanded ? items : items.filter { $0 == selection || $0 == receiving }
    }

    @Environment(DeviceSession.self) private var session
    @State private var selection: SidebarItem? = .overview
    private var navigation: AppNavigation { .shared }
    private var receivers: ReceiverStore { .shared }
    @AppStorage(GainProfile.externalAmplifierKey) private var externalAmplifier = false
    /// Eingeklappte Gruppen der Seitenleiste (Titel, durch „|“ getrennt).
    @AppStorage("sidebarCollapsedGroups") private var collapsedGroups = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarItem.groups, id: \.title) { group in
                    let open = expanded(group.title)
                    Section {
                        // Eingeklappt bleiben die gewählte und die gerade empfangende
                        // Seite sichtbar – sonst verschwand die Auswahl (Nutzer, 29.10.2026).
                        ForEach(Self.visibleItems(group.items, expanded: open.wrappedValue,
                                                  selection: selection, receiving: receivers.activeItem)) { item in
                            SidebarRow(item: item, receiving: receivers.activeItem == item)
                                .tag(item)
                        }
                    } header: {
                        Button {
                            withAnimation { open.wrappedValue.toggle() }
                        } label: {
                            HStack {
                                Text(group.title)
                                Spacer()
                                Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(open.wrappedValue ? "Gruppe einklappen" : "Gruppe ausklappen")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            // Grüner Punkt und Aufräumen (`ReceiverStore.track`) sowie das Beenden
            // aller Empfänger beim Verlassen des HackRF-Modus laufen seit dem
            // Hintergrundbetrieb in `AppServices.start` – auch ohne Fenster.
            .onAppear {
                BackgroundController.shared.windowAppeared()
                let open = openWindow
                BackgroundController.shared.openMainWindowAction = { open(id: AppServices.mainWindowID) }
            }
            .onChange(of: navigation.page) { _, page in
                if let page { selection = page; navigation.page = nil }
            }
            // Für Hilfe-Menü (⌘?) und Pegelanzeige: welche Seite gerade zu sehen ist.
            .onChange(of: selection, initial: true) { _, page in navigation.visiblePage = page ?? .overview }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Deckend: sonst scrollen die letzten Einträge sichtbar unter
                // den Pegel- und Verbindungsbereich (Fund 25.10.2026). Nur Anzeige –
                // Schalter (externer LNA, Display) stehen in den Einstellungen.
                VStack(spacing: 8) {
                    if session.mode == .hackRF {
                        ReceiveLevelBadge()
                    }
                    ConnectionBadge()
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .top) { Divider() }
            }
        } detail: {
            // Band unter der ganzen Seite (samt Bedienfeld) – als Einschub lag es über dem
            // Inspektor. Unten statt oben: macOS 26 legt an die Oberkante der Seite einen
            // Unschärfestreifen der Symbolleiste; mit dem Band dazwischen lag er über den
            // Spaltenköpfen der Tabellen (ACARS, 27.10.2026), auch `scrollEdgeEffectHidden`
            // und `safeAreaBar` halfen nicht.
            VStack(spacing: 0) {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView()
                case .settings: SettingsView()
                case .firmware: FirmwareView()
                case .screen: ScreenView()
                case .files: FilesView()
                case .spectrum: SpectrumView()
                case .radio: RadioView()
                case .dab: DABView()
                case .tv: TVView()
                case .adsb: ADSBView()
                case .acars: ACARSView()
                case .ais: AISView()
                case .aprs: APRSView()
                case .pager: PagerView()
                case .planner: PlannerView()
                case .sonde: SondeView()
                case .meteor: MeteorView()
                case .flarm: FLARMView()
                case .sensors: SensorView()
                case .ble: BLEView()
                case .zigbee: ZigbeeView()
                case .wifi: WiFiView()
                case .drones: DroneView()
                case .meshtastic: MeshtasticView()
                case .lorawan: LoRaWANView()
                case .dcf77: DCF77View()
                case .gps: GPSView()
                case .recorder: RecorderView()
                case .antennaCheck: AntennaCheckView()
                case .console: ConsoleView()
                case .smartHome868: SmartHome868View()
                case .airband: AirbandView()
                case .vor: VORView()
                case .dsc: DSCView()
                case .amateurSat: AmateurSatView()
                case .ft8: FT8View()
                case .hydrogen: HydrogenView()
                case .cells: CellView()
                case .occupancy: OccupancyView()
                }
            }
            // Neue Verstärkungsvorgaben: Seite neu aufbauen, damit sie greifen.
            .id(externalAmplifier)
            .onChange(of: externalAmplifier) { _, _ in
                RemoteHub.shared.applyGainPresets()
                ReceiverStore.shared.applyGainPresets()
            }
            .frame(maxHeight: .infinity)
            PlanBanner { selection = $0 }
            RemoteBanner()
            }
            // Die eine Rückfrage beim Umschalten des Empfängers (`ReceiverStore.requestStart`).
            // Hier an einer SwiftUI-Ansicht – an `HSplitView`/Inspektor erschiene sie nie.
            .alert(receivers.pendingSwitch?.prompt.title ?? "",
                   isPresented: Binding { receivers.pendingSwitch != nil } set: { if !$0 { receivers.cancelSwitch() } },
                   presenting: receivers.pendingSwitch) { request in
                Button("Umschalten") { receivers.confirmSwitch(request) }
                    .keyboardShortcut(.defaultAction)
                Button("Abbrechen", role: .cancel) { receivers.cancelSwitch() }
            } message: { request in
                Text(request.prompt.message)
            }
            .navigationTitle((selection ?? .overview).title)
            // Hilfe-Link (`portapack://help/…`, siehe `AppServices.open`).
            .onChange(of: HelpCenter.shared.openRequested) { _, requested in
                guard requested else { return }
                HelpCenter.shared.openRequested = false
                openWindow(id: HelpCenter.windowID)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Öffnet das Kapitel zur aktuellen Seite im Handbuch.
                    Button("Hilfe zu dieser Seite", systemImage: "questionmark.circle") {
                        HelpCenter.shared.show(page: (selection ?? .overview).helpChapter)
                        openWindow(id: HelpCenter.windowID)
                    }
                    .help("Hilfe zu dieser Seite")
                }
            }
        }
    }
}

/// Eintrag der Seitenleiste; ein grüner Punkt zeigt, dass dieser Empfänger
/// gerade empfängt – auch wenn eine andere Seite zu sehen ist (seit 29.10.2026
/// beendet ein Seitenwechsel den Empfang nicht mehr).
struct SidebarRow: View {
    let item: SidebarItem
    let receiving: Bool

    var body: some View {
        HStack(spacing: 4) {
            Label(item.title, systemImage: item.symbol)
            if receiving {
                Spacer(minLength: 4)
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .help("Empfängt gerade")
                    .accessibilityLabel(Text("Empfängt gerade"))
            }
        }
    }
}

/// Hinweis auf jeder Seite, solange der Empfangsplan einen Termin aufnimmt.
struct PlanBanner: View {
    let open: (SidebarItem) -> Void
    private var planner: ReceptionPlanner { .shared }

    var body: some View {
        if let job = planner.active, let status = planner.status {
            HStack(spacing: 8) {
                Image(systemName: "record.circle").foregroundStyle(.red).symbolEffect(.pulse)
                Text(status).font(.callout.weight(.medium))
                Text(progress(job)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(job.isSonde ? "Sonden ansehen" : job.isAmateur ? "Empfang ansehen" : "Bild ansehen") {
                    open(job.isSonde ? .sonde : job.isAmateur ? .amateurSat : .meteor)
                }
                Button("Plan") { open(.planner) }
                Button("Überspringen") { Task { await planner.skipActive() } }
                    .help("Diese Aufnahme beenden und nicht wieder aufnehmen – der vorherige Empfang läuft weiter.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.red.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func progress(_ job: ReceptionPlanner.Job) -> String {
        if job.isPass {
            let s = planner.meteor.snapshot
            return String(localized: "· \(s.frame.framesOK) Rahmen · \(s.lines) Zeilen · \(Int(s.levelDB)) dBFS")
        }
        if job.isAmateur {
            let a = planner.amateur
            if let mode = a.liveStatus.mode {
                return String(localized: "· \(a.frameCount) Pakete · \(a.imageCount) Bilder · SSTV \(mode.title) \(a.liveStatus.rows) Zeilen")
            }
            return String(localized: "· \(a.frameCount) Pakete · \(a.imageCount) Bilder")
        }
        return String(localized: "· \(planner.sonde.sondes.count) Sonden · \(planner.sonde.reportCount) Meldungen")
    }
}

/// Hinweis, solange der HackRF aus der Ferne belegt ist.
struct RemoteBanner: View {
    private var hub: RemoteHub { .shared }

    var body: some View {
        if let mode = hub.remoteMode {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                Text("Fernzugriff empfängt gerade \(mode.title). Startest du hier einen anderen Empfänger, endet der Fernbetrieb.")
                    .font(.callout)
                Spacer()
                Button("Fernbetrieb beenden") { hub.endRemoteMode() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.yellow.opacity(0.18))
            .overlay(alignment: .top) { Divider() }
        }
    }
}

struct ConnectionBadge: View {
    @Environment(DeviceSession.self) private var session

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.mode.title)
                    .font(.callout.weight(.medium))
                if session.busy {
                    Text(session.busyReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let version = session.info?.mayhemVersion {
                    Text("Mayhem \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        if session.busy { return .orange }
        switch session.mode {
        case .disconnected: return .gray
        case .mayhem: return .green
        case .hackRF: return .blue
        case .dfu: return .purple
        case .sdCard: return .teal
        }
    }
}

/// Pegel am Wandler während des Empfangs – mit derselben Bewertung
/// (`ReceiveLevel`) wie die Statuszeile im Bedienfeld, damit sich beide nicht
/// widersprechen. Nennt, für wen der HackRF gerade empfängt („Pegel für
/// Flugfunk“): die Seitenleiste ist auf jeder Seite sichtbar, der Empfänger
/// läuft aber oft für eine andere.
///
/// Feste Größe während des Empfangs (Review L2, 29.10.2026): Der Badge sitzt in
/// der Seitenleiste der AppKit-Split-Ansicht; änderte sich seine Wunschgröße
/// (wechselnde Textbreite, `minimumScaleFactor` mit Mehrfachmessung), lief bei
/// jedem Takt das Constraint-Layout des ganzen Fensters (≈ 12 % eines Kerns).
/// Jetzt: eine Zeile je Text ohne Skalierung, feste Wunschbreite, Takt 1 s.
struct ReceiveLevelBadge: View {
    @Environment(DeviceSession.self) private var session
    @AppStorage(GainProfile.externalAmplifierKey) private var externalAmplifier = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                level
            }
            if externalAmplifier {
                Text("Externer LNA an")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("Alle Empfänger starten mit niedrigerer Verstärkung. Ändern in den Einstellungen (Antenne & Gerät).")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var level: some View {
        if let device = session.hackRF, device.isReceiving, let levels = device.inputLevels {
            let state = ReceiveLevel(levels)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pegel für \(DeviceArbiter.title(of: device.currentOwner))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    Image(systemName: state.symbol).foregroundStyle(state.color)
                    Text(state.title).font(.caption.weight(.medium))
                }
                LevelMeter(levels: levels).frame(height: 10)
                Text(Self.caption(levels))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).truncationMode(.tail)
            }
            // Wunschbreite fest, damit wechselnde Zahlen die Seitenleiste nicht neu vermessen.
            .frame(minWidth: 0, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
            .help(state.advice)
        } else {
            Label("Kein Empfang", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension ReceiveLevelBadge {
    /// „−24 dBFS · Spitze −11“, bei Werten am Anschlag mit Anteil.
    static func caption(_ levels: HackRFDevice.InputLevels) -> String {
        let db = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
        let rms = levels.rmsDBFS.formatted(db), peak = levels.peakDBFS.formatted(db)
        let text: String
        if levels.clipped >= 0.00005 {
            let clipped = levels.clipped.formatted(.percent.precision(.fractionLength(2)))
            text = String(localized: "\(rms) dBFS · Spitze \(peak) · \(clipped) am Anschlag")
        } else {
            text = String(localized: "\(rms) dBFS · Spitze \(peak)")
        }
        return text.replacingOccurrences(of: "-", with: "−")
    }
}

/// Pegelbalken −50 … 0 dBFS: Hintergrund zeigt die Bereiche (zu schwach,
/// gut, knapp, übersteuert), der Balken den mittleren Pegel, der Strich die Spitze.
struct LevelMeter: View {
    let levels: HackRFDevice.InputLevels
    static let range = -50.0...0.0

    private func x(_ db: Double, _ width: CGFloat) -> CGFloat {
        let clamped = min(max(db, Self.range.lowerBound), Self.range.upperBound)
        return CGFloat((clamped - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)) * width
    }

    private static let zones: [(ClosedRange<Double>, Color)] = [
        (range.lowerBound...ReceiveLevel.lowBelow, .gray),
        (ReceiveLevel.lowBelow...ReceiveLevel.highAbove, .green),
        (ReceiveLevel.highAbove...ReceiveLevel.overloadAbove, .orange),
        (ReceiveLevel.overloadAbove...range.upperBound, .red),
    ]

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Self.zones.indices, id: \.self) { i in
                        Self.zones[i].1.opacity(0.25)
                            .frame(width: x(Self.zones[i].0.upperBound, w) - x(Self.zones[i].0.lowerBound, w))
                    }
                }
                ReceiveLevel(levels).color
                    .frame(width: max(1, x(levels.rmsDBFS, w)))
                Color.primary
                    .frame(width: 2)
                    .padding(.leading, max(0, x(levels.peakDBFS, w) - 2))
            }
            .frame(width: w, height: h, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .animation(.easeOut(duration: 0.25), value: levels)
        .accessibilityLabel(Text("Pegel \(Int(levels.rmsDBFS.rounded())) dBFS"))
    }
}

/// Bewertung des Pegels am Wandler – die eine Bewertung für Seitenleiste
/// (`ReceiveLevelBadge`) und Statuszeile im Bedienfeld (`ReceiverVerdict`):
/// übersteuert ab 1 % am Anschlag, „sehr laut“ (ab 0,1 % oder über −12 dBFS)
/// ist nur ein Hinweis, „sehr schwach“ unter −40 dBFS. Übersteuerung nach dem Anteil der Werte
/// am Anschlag (ab 0,1 % stiegen in der Messung vom 24.10.2026 Rauschboden und
/// Mischprodukte merklich an), Reserve nach dem mittleren Pegel: Rauschartige
/// Signale haben ≈ 10 dB Scheitelfaktor – bei UKW gab −14 dBFS noch 0 %,
/// −6 dBFS schon 4 % Anschlag. Unter −40 dBFS nutzt das Signal nur noch
/// wenige der 8 Bit.
enum ReceiveLevel: Equatable {
    case low, fine, warning, overloaded

    static let lowBelow = -40.0
    static let highAbove = -12.0
    static let overloadAbove = -6.0

    init(clippedFraction: Double) {
        switch clippedFraction {
        case ..<0.001: self = .fine
        case ..<0.01: self = .warning
        default: self = .overloaded
        }
    }

    init(_ levels: HackRFDevice.InputLevels) {
        let byClipping = ReceiveLevel(clippedFraction: levels.clipped)
        if byClipping != .fine {
            self = byClipping
        } else if levels.rmsDBFS > Self.highAbove {
            self = .warning
        } else if levels.rmsDBFS < Self.lowBelow {
            self = .low
        } else {
            self = .fine
        }
    }

    var title: String {
        switch self {
        case .low: String(localized: "Sehr schwach")
        case .fine: String(localized: "Pegel in Ordnung")
        case .warning: String(localized: "Sehr laut")
        case .overloaded: String(localized: "Übersteuert")
        }
    }

    var symbol: String {
        switch self {
        case .low: "arrow.down.circle.fill"
        case .fine: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .overloaded: "exclamationmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .low: .gray
        case .fine: .green
        case .warning: .orange
        case .overloaded: .red
        }
    }

    var advice: String {
        switch self {
        case .low: String(localized: "Das Signal kommt sehr leise an. Erhöhe die Verstärkung (erst VGA, dann LNA) oder drück „Signal optimieren“.")
        case .fine: String(localized: "Der Pegel passt, es ist noch Reserve. Bei schwachen Signalen darf die Verstärkung höher.")
        case .warning: String(localized: "Nur ein Hinweis: wenig Reserve bis zur Übersteuerung. Kommen Meldungen an, passt es; sonst LNA eine Stufe zurücknehmen.")
        case .overloaded: String(localized: "Das Signal ist zu stark, dadurch entstehen Störungen. Drück „Signal optimieren“ – oder schalte den eingebauten Verstärker aus und nimm LNA, dann VGA zurück.")
        }
    }
}

/// Platzhalter einer Empfängerseite, solange das Gerät nicht im HackRF-Modus
/// ist. Hängt es im Mayhem-Modus am USB, wechselt die Seite von selbst
/// (Schalter, Vorgabe an) – vorher musste man auf jeder Seite erst einen
/// Knopf finden und danach ohne Rückmeldung warten.
struct HackRFRequiredView: View {
    static let autoSwitchKey = "autoHackRFMode"
    @Environment(DeviceSession.self) private var session
    @AppStorage(HackRFRequiredView.autoSwitchKey) private var autoSwitch = true
    @State private var switching = false
    let systemImage: String
    let text: Text

    /// Literale werden übersetzt (wie bei `Text`) …
    init(systemImage: String, text: LocalizedStringKey) {
        self.systemImage = systemImage
        self.text = Text(text)
    }

    /// … fertige (schon übersetzte) Texte erscheinen unverändert.
    @_disfavoredOverload
    init<S: StringProtocol>(systemImage: String, text: S) {
        self.systemImage = systemImage
        self.text = Text(text)
    }

    var body: some View {
        ContentUnavailableView {
            if switching || (session.mode == .hackRF && session.hackRF == nil) {
                Label { Text("Wechsle in den HackRF-Modus …") } icon: { ProgressView() }
            } else if session.device == nil {
                Label("PortaPack anschließen", systemImage: "cable.connector")
            } else {
                Label("HackRF-Modus nötig", systemImage: systemImage)
            }
        } description: {
            if session.device == nil, !switching, session.mode != .hackRF {
                Text("Schließ das PortaPack per USB an und schalte es ein – die Seite wechselt dann von selbst in den HackRF-Modus.")
                    + Text(verbatim: "\n\n") + text
            } else {
                text
            }
        } actions: {
            if session.device != nil, !switching {
                Button("In HackRF-Modus wechseln") { switchMode() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.busy)
            }
            if autoSwitch {
                SettingsHint(.device, "Empfängerseiten wechseln von selbst in den HackRF-Modus.")
                    .frame(maxWidth: 380)
            } else {
                SettingsHint(.device, "Der automatische Wechsel in den HackRF-Modus ist aus.")
                    .frame(maxWidth: 380)
            }
        }
        .task(id: session.device != nil) {
            if autoSwitch, session.device != nil, !session.busy { switchMode() }
        }
    }

    private func switchMode() {
        guard !switching else { return }
        switching = true
        Task {
            await session.enterHackRFMode()
            // Die Erkennung meldet den HackRF nach ein, zwei Sekunden; bis dahin Fortschritt zeigen.
            for _ in 0..<20 where session.hackRF == nil { try? await Task.sleep(for: .milliseconds(500)) }
            switching = false
        }
    }
}
