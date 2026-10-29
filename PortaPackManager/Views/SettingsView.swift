import SwiftUI
import UniformTypeIdentifiers

/// Bereiche der Seite „Einstellungen“ (⌘,). Allgemeine Einstellungen stehen
/// nur hier; Seiten verweisen mit `SettingsHint` darauf, statt sie zu
/// wiederholen (Bedienungs-Review 29.10.2026).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, location, device, frequencies, remote, sharing, notifications, online, archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "Allgemein")
        case .location: String(localized: "Standort")
        case .device: String(localized: "Antenne & Gerät")
        case .frequencies: String(localized: "Frequenzen")
        case .remote: String(localized: "Fernzugriff")
        case .sharing: String(localized: "Daten teilen")
        case .notifications: String(localized: "Benachrichtigungen")
        case .online: String(localized: "Online-Dienste")
        case .archive: String(localized: "Archiv")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .location: "location"
        case .device: "antenna.radiowaves.left.and.right"
        case .frequencies: "bookmark"
        case .remote: "globe"
        case .sharing: "square.and.arrow.up.on.square"
        case .notifications: "bell"
        case .online: "network"
        case .archive: "archivebox"
        }
    }

    static let storageKey = "settingsTab"

    /// Kapitel im Handbuch (Fernzugriff und Daten teilen behalten ihre eigenen).
    var helpChapter: String {
        switch self {
        case .remote: "remote"
        case .sharing: "sharing"
        default: "settings"   // = HelpCenter.settingsChapter
        }
    }
}

extension SidebarItem {
    /// Handbuchkapitel der Seite; auf „Einstellungen“ das des gewählten Bereichs.
    @MainActor var helpChapter: String {
        guard self == .settings else { return rawValue }
        let raw = UserDefaults.standard.string(forKey: SettingsTab.storageKey) ?? ""
        return (SettingsTab(rawValue: raw) ?? .general).helpChapter
    }
}

/// Feste Abschnittsnamen im Bedienfeld. Reihenfolge auf jeder Empfängerseite:
/// Start/Stopp · Leeren → Kanal/Frequenz → `empfang` (`ReceiverControls`) →
/// `status` → `anzeige` → `daten` → `hinweis`.
enum PanelSection {
    static var empfang: String { String(localized: "Empfang") }
    static var status: String { String(localized: "Status") }
    static var anzeige: String { String(localized: "Anzeige") }
    static var daten: String { String(localized: "Daten & Export") }
    static var hinweis: String { String(localized: "Hinweis") }
}

/// Allgemeine Einstellung auf einer Seite, z. B. „Standort: 53,55° N … [Einstellungen …]“.
/// Der Knopf springt zur Seite „Einstellungen“ in der Seitenleiste, auf den
/// passenden Bereich. Alle Einstellungen stehen nur dort (Nutzer, 29.10.2026:
/// ein eigenes Fenster bzw. Popover war verwirrend).
struct SettingsHint: View {
    let tab: SettingsTab
    let text: Text
    @AppStorage(SettingsTab.storageKey) private var selected = SettingsTab.general.rawValue

    /// Literale werden übersetzt (wie bei `Text`) …
    init(_ tab: SettingsTab, _ text: LocalizedStringKey) {
        self.tab = tab
        self.text = Text(text)
    }

    /// … fertige (schon übersetzte) Texte erscheinen unverändert.
    @_disfavoredOverload
    init<S: StringProtocol>(_ tab: SettingsTab, _ text: S) {
        self.tab = tab
        self.text = Text(text)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            text
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Einstellungen …") {
                selected = tab.rawValue
                AppNavigation.shared.page = .settings
            }
            .controlSize(.small)
        }
    }
}

/// Inhalt eines Einstellungsbereichs auf der Seite „Einstellungen“.
struct SettingsPaneContent: View {
    let tab: SettingsTab

    var body: some View {
        switch tab {
        case .general: GeneralSettingsPane()
        case .location: LocationSettingsPane()
        case .device: DeviceSettingsPane()
        case .frequencies: FrequencyMemorySettingsPane()
        case .remote: RemoteView()
        case .sharing: SharingView()
        case .notifications: NotificationSettingsPane()
        case .online: OnlineSettingsPane()
        case .archive: ArchiveSettingsPane()
        }
    }
}

/// Seite „Einstellungen“ (Seitenleiste, Gruppe Gerät; Menü ⌘,): alle
/// allgemeinen Einstellungen, oben nach Bereichen umschaltbar.
struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var selected = SettingsTab.general.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Picker("Bereich", selection: $selected) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 4)
            SettingsPaneContent(tab: SettingsTab(rawValue: selected) ?? .general)
                .formStyle(.grouped)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Sprache der App. Gespeichert wie bei „Systemeinstellungen ▸ Allgemein ▸
/// Sprache & Region ▸ Apps“: als `AppleLanguages` in den Voreinstellungen
/// der App; fehlt der Schlüssel, gilt die Systemsprache. Wirkt erst nach
/// einem Neustart der App (Bundle-Texte werden beim Start gewählt).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, german, english

    static let defaultsKey = "AppleLanguages"

    var id: String { rawValue }

    /// Sprachnamen bleiben in ihrer eigenen Sprache.
    var title: String {
        switch self {
        case .system: String(localized: "Wie das System")
        case .german: "Deutsch"
        case .english: "English"
        }
    }

    /// Wert für `AppleLanguages`; `nil` = Schlüssel entfernen (Systemsprache).
    var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .german: ["de"]
        case .english: ["en"]
        }
    }

    /// Welche Wahl ein gespeicherter `AppleLanguages`-Wert der App bedeutet.
    static func from(appleLanguages: [String]?) -> AppLanguage {
        guard let first = appleLanguages?.first?.lowercased() else { return .system }
        if first == "de" || first.hasPrefix("de-") || first.hasPrefix("de_") { return .german }
        if first == "en" || first.hasPrefix("en-") || first.hasPrefix("en_") { return .english }
        return .system
    }

    /// Die gespeicherte Wahl – nur aus der Domäne der App, nicht der globalen
    /// (`UserDefaults.standard.array` lieferte sonst die Systemsprachen).
    static var current: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        return from(appleLanguages: domain?[defaultsKey] as? [String])
    }

    func store(in defaults: UserDefaults = .standard) {
        if let appleLanguages {
            defaults.set(appleLanguages, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// Startet die App neu: ein kleiner Helfer wartet, bis dieser Prozess
    /// beendet ist, und öffnet die App dann wieder – so laufen nie zwei
    /// Instanzen gleichzeitig (beide griffen sonst auf HackRF und Fernzugriff zu).
    @MainActor
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundleURL.path
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", path]
        do {
            try helper.run()
            // Die Einstellungsseite hat schon gefragt – keine zweite Rückfrage beim Beenden.
            QuitGuard.bypass = true
            NSApp.terminate(nil)
        } catch {
            // Ohne Helfer nicht beenden – sonst wäre die App einfach weg.
        }
    }
}

/// Allgemein: Sprache, Start beim Anmelden, Hintergrundbetrieb.
struct GeneralSettingsPane: View {
    @Environment(DeviceSession.self) private var session
    @State private var language = AppLanguage.current
    /// Beim Öffnen der Seite gültige Sprache – nur bei einer Änderung den Neustart anbieten.
    @State private var initial = AppLanguage.current
    @State private var confirmRestart = false
    /// Was ein Neustart gerade abbräche (für die Rückfrage).
    @State private var runningSummary = ""

    var body: some View {
        Form {
            BackgroundSettingsSections()
            Section("Sprache") {
                Picker("Sprache", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, new in new.store() }
                if language != initial {
                    HStack {
                        Text("Wirkt nach einem Neustart der App.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Jetzt neu starten") {
                            let work = RunningWork.current(session: session)
                            if work.isEmpty {
                                AppLanguage.relaunch()
                            } else {
                                runningSummary = work.items.formatted(.list(type: .and))
                                confirmRestart = true
                            }
                        }
                        .disabled(session.busy)
                    }
                    .confirmationDialog("Es läuft etwas – trotzdem neu starten?", isPresented: $confirmRestart) {
                        Button("Neu starten", role: .destructive) { AppLanguage.relaunch() }
                        Button("Abbrechen", role: .cancel) {}
                    } message: {
                        Text("Läuft gerade: \(runningSummary). Ein Neustart bricht das ab.")
                    }
                }
            }
        }
    }
}

/// Standort: von Hand, über die Ortungsdienste oder von der GPS-Seite.
struct LocationSettingsPane: View {
    var body: some View {
        Form {
            HomeLocationSection(note: "Für Karten, Entfernungen und den Empfangsplan. Die App fragt ihn beim ersten Start selbst ab; er bleibt auf diesem Mac.")
        }
    }
}

/// Antenne & Gerät: alles, was für alle Empfänger gilt.
struct DeviceSettingsPane: View {
    var body: some View {
        Form { DeviceSettingsSections() }
    }
}

/// Die Abschnitte von „Antenne & Gerät“ ohne eigenes `Form` – so stehen sie
/// auch direkt in der Übersicht.
struct DeviceSettingsSections: View {
    @Environment(DeviceSession.self) private var session
    @AppStorage(GainProfile.externalAmplifierKey) private var externalAmplifier = false
    @AppStorage(HackRFDevice.displayEnabledKey) private var displayEnabled = false
    @AppStorage(HackRFRequiredView.autoSwitchKey) private var autoSwitch = true
    @Bindable private var autoGain = AutoGain.shared

    var body: some View {
        Group {
            Section("Antenne") {
                // Neuaufbau der offenen Seite und neue Vorgaben übernimmt `ContentView`
                // (beobachtet denselben Schlüssel).
                Toggle("Externer LNA", isOn: $externalAmplifier)
                Text("Schalte das ein, wenn ein Vorverstärker (≈ 20 dB) vor dem HackRF hängt: Alle Empfänger starten dann mit weniger Verstärkung und ohne den eingebauten Verstärker.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Verstärkung automatisch nachregeln", isOn: $autoGain.enabled)
                Text("Gilt für alle Empfänger: Übersteuert der Empfang, nimmt die App die Verstärkung eine Stufe zurück; ist das Signal viel zu leise, dreht sie eine Stufe hoch. Sonst bleiben deine Werte unverändert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Gerät") {
                Toggle("Automatisch in den HackRF-Modus wechseln", isOn: $autoSwitch)
                Text("Öffnest du eine Empfängerseite, während das PortaPack im Mayhem-Modus läuft, wechselt es von selbst in den HackRF-Modus. Zurück geht es über „Zurück zu Mayhem (Neustart)“ in der Übersicht.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Display am Gerät", isOn: $displayEnabled)
                    .onChange(of: displayEnabled) { _, on in try? session.hackRF?.setDisplay(on) }
                Text("Im HackRF-Modus zeigt das PortaPack Frequenz und Verstärkung an. Aus: Bildschirm dunkel (spart Strom).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CrystalCorrectionSection()
            SondeBlockListSection()
        }
    }
}

/// Benachrichtigungen (siehe `Notifier`): Mac-Mitteilungen und ntfy aufs Handy.
struct NotificationSettingsPane: View {
    @Bindable private var notifier = Notifier.shared

    var body: some View {
        Form {
            Section("Wege") {
                Toggle("Mitteilungen am Mac", isOn: $notifier.macEnabled)
                Toggle("Aufs Handy (ntfy)", isOn: $notifier.ntfyEnabled)
                    .help("Mit der kostenlosen Handy-App „ntfy“ (iOS/Android) bekommst du die Meldungen aufs Handy. Hinaus gehen nur die Meldungstexte, keine Koordinaten.")
                if notifier.ntfyEnabled {
                    LabeledContent("Server") { TextField("https://ntfy.sh", text: $notifier.ntfyServer).multilineTextAlignment(.trailing) }
                    LabeledContent("Thema") { TextField("", text: $notifier.ntfyTopic).multilineTextAlignment(.trailing).font(.body.monospaced()) }
                    HStack {
                        if let qr = RemoteView.qrCode(notifier.subscribeURL) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 96, height: 96)
                        }
                        Text("Scanne den Code mit dem Handy oder trag das Thema in der ntfy-App unter „Thema abonnieren“ ein. Wer das Thema kennt, liest mit – gib es nicht weiter.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !notifier.anyEnabled {
                    Text("Beides ist aus – die App meldet nichts.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if notifier.anyEnabled {
                Section("Ereignisse") {
                    Toggle("Wetterballons in Reichweite / empfangen", isOn: $notifier.notifySondes)
                    Toggle("Satellit kommt in 10 Minuten", isOn: $notifier.notifyPasses)
                    Toggle("Ergebnis geplanter Aufnahmen", isOn: $notifier.notifyPlan)
                    Toggle("Gerät nicht erreichbar", isOn: $notifier.notifyProblems)
                    Toggle("Seefunk-Notruf (DSC)", isOn: $notifier.notifyDSC)
                    HStack {
                        Button("Testnachricht senden") { notifier.testMessage() }
                        if let result = notifier.lastResult { Text(result).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

/// Online-Dienste: Schalter, mit denen die App Daten aus dem Netz holt. Was
/// empfangene Daten an Dienste *hinausschickt*, steht auf der Seite „Daten teilen“.
struct OnlineSettingsPane: View {
    @AppStorage(SettingsTab.storageKey) private var selectedTab = SettingsTab.general.rawValue
    /// Derselbe Schlüssel wie `AircraftDatabase.onlineLookup` – geschrieben wird
    /// über die Eigenschaft (sie stößt beim Einschalten die Warteschlange an).
    @AppStorage("adsbOnlineLookup") private var adsbOnline = true
    @AppStorage(ShipPhotoLookup.enabledKey) private var shipPhotos = true

    var body: some View {
        Form {
            Section("Flugzeuge (ADS-B)") {
                Toggle("Online nachschlagen (hexdb.io, adsbdb.com, planespotters.net)", isOn: Binding(
                    get: { adsbOnline },
                    set: { AircraftDatabase.shared.onlineLookup = $0; adsbOnline = $0 }))
                Text("Holt Typ, Strecke und Foto eines Flugzeugs aus dem Netz, wenn die eingebaute Datenbank sie nicht kennt. Dabei gehen nur Kennung und Rufzeichen an diese Dienste; die Ergebnisse bleiben gespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Schiffe (AIS)") {
                Toggle("Fotos online (Wikimedia Commons)", isOn: $shipPhotos)
                Text("Sucht zum gewählten Schiff über die IMO-Nummer ein Foto bei Wikimedia Commons. Dabei geht nur die IMO-Nummer hinaus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Funkfeuer und Flugplätze") {
                Text("Die Listen der Funkfeuer und Flugplätze (OurAirports) lädt die App nur auf Knopfdruck – auf den Seiten Funkfeuer und Flugzeuge. Dabei geht nur die Anfrage selbst hinaus, kein Standort; danach liegen sie auf dem Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Bahndaten der Satelliten (CelesTrak) und die Sonden-Vorhersage (SondeHub) holt die App nur für den Empfangsplan; dein Standort geht dabei nicht hinaus. Was du selbst empfängst, an andere Dienste weitergeben, stellst du unter „Daten teilen“ ein.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("„Daten teilen“ öffnen") { selectedTab = SettingsTab.sharing.rawValue }
            }
        }
    }
}

/// Archiv: Inhalt der Ablage, Aufbewahrung, Sicherung und die Archivfenster.
struct ArchiveSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @State private var stats: [ArchiveStat]?
    @State private var includeRecordings = false
    @State private var working: String?
    @State private var message: String?
    @State private var pendingRestore: URL?
    @State private var confirmDeleteOld = false
    @State private var migration = ArchiveMigrationState.shared

    var body: some View {
        Form {
            if migration.running || migration.outcome?.failures.isEmpty == false || ArchiveDatabase.shared.notice != nil {
                Section("Datenbank") {
                    if migration.running {
                        let progress = migration.progress
                        ProgressView(value: Double(progress?.done ?? 0), total: Double(max(progress?.total ?? 1, 1))) {
                            Text("Übernehme die alten Archivdateien in die Datenbank …")
                        } currentValueLabel: {
                            if let progress { Text("\(progress.done) von \(progress.total) Dateien") }
                        }
                    }
                    if let failures = migration.outcome?.failures, !failures.isEmpty {
                        Text("Die Übernahme ist unvollständig. Die alten Dateien bleiben an ihrem Platz; beim nächsten Start versucht es die App erneut.")
                            .font(.caption).foregroundStyle(.orange)
                        ForEach(failures.prefix(5), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let notice = ArchiveDatabase.shared.notice {
                        Text(notice).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Section {
                if let stats {
                    ForEach(stats.filter { $0.files > 0 || ($0.entries ?? 0) > 0 || $0.inDatabase }) { stat in
                        LabeledContent {
                            HStack(spacing: 10) {
                                if !stat.inDatabase {
                                    Text(Self.byteText(stat.bytes)).monospacedDigit()
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([folderURL(stat.id)]) } label: {
                                        Image(systemName: "folder")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Im Finder zeigen")
                                    .accessibilityLabel("Im Finder zeigen")
                                    .disabled(stat.id == ArchiveBackup.otherID)
                                }
                                if stat.id == ArchiveMigration.oldFolderName {
                                    Button("Alte Dateien löschen …", role: .destructive) { confirmDeleteOld = true }
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.title(stat.id))
                                Text(Self.detail(stat)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("Zusammen") {
                        Text(Self.byteText(stats.reduce(0) { $0 + $1.bytes })).monospacedDigit().bold()
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Zähle Einträge …").foregroundStyle(.secondary) }
                }
            } header: {
                HStack {
                    Text("Inhalt")
                    Spacer()
                    Button("Aktualisieren") { Task { await refresh() } }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(stats == nil)
                }
            }
            Section("Aufbewahrung") {
                ArchiveRetentionPicker()
                Text("Gilt für Flugzeuge, Schiffe, Radiosonden und den Flugfunk-Verlauf. Ältere Einträge löscht die App von selbst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sicherung") {
                Toggle("IQ-Aufnahmen einschließen", isOn: $includeRecordings)
                    .help("IQ-Aufnahmen sind oft mehrere Gigabyte groß.")
                HStack {
                    Button("Sicherung erstellen …") { Task { await backup() } }
                    Button("Sicherung einspielen …") { Task { await chooseRestore() } }
                    if let working {
                        ProgressView().controlSize(.small)
                        Text(working).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(working != nil)
                Text("Die Sicherung ist eine ZIP-Datei mit der Archiv-Datenbank, Plänen und Aufnahmen der App (ohne Einstellungen und Schlüssel). Beim Einspielen kommen nur fehlende Dateien und Archiveinträge dazu – Vorhandenes bleibt unverändert. Auch ältere Sicherungen mit Tagesdateien lassen sich einspielen.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.caption)
                }
            }
            Section("Archive öffnen") {
                HStack {
                    Button("Flugzeuge …") { openWindow(id: "archive", value: "adsb") }
                    Button("Schiffe …") { openWindow(id: "archive", value: "ais") }
                    Button("Radiosonden …") { openWindow(id: "sondeArchive") }
                }
            }
        }
        .task { await refresh() }
        .onChange(of: migration.running) { _, running in if !running { Task { await refresh() } } }
        .confirmationDialog("Alte Archivdateien löschen?", isPresented: $confirmDeleteOld) {
            Button("Löschen", role: .destructive) { Task { await deleteOldFiles() } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Ihr Inhalt steht vollständig in der Datenbank – die App hat jeden Eintrag beim Übernehmen geprüft. Das Löschen lässt sich nicht rückgängig machen.")
        }
        .confirmationDialog("Sicherung einspielen?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            presenting: pendingRestore) { url in
            Button("Einspielen") { Task { await restore(url) } }
            Button("Abbrechen", role: .cancel) { pendingRestore = nil }
        } message: { url in
            Text("Aus „\(url.lastPathComponent)“ kommen nur Dateien dazu, die hier fehlen. Nichts wird überschrieben oder gelöscht.")
        }
    }

    private func folderURL(_ id: String) -> URL {
        AppFiles.support.appendingPathComponent(id, isDirectory: id != ArchiveBackup.Area.database)
    }

    private func deleteOldFiles() async {
        let root = AppFiles.support
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            do { try ArchiveMigration.deleteOldFiles(root: root); return nil } catch { return error.localizedDescription }
        }.value
        message = error
        await refresh()
    }

    private func refresh() async {
        stats = nil
        let root = AppFiles.support
        stats = await Task.detached(priority: .utility) { ArchiveBackup.stats(root: root) }.value
    }

    private func backup() async {
        let name = "PortaPack-Sicherung-\(TrafficArchive.dayStamp(Date())).zip"
        guard let url = await SaveSheet.url(name: name, types: [.zip]) else { return }
        working = String(localized: "Erstelle Sicherung …")
        message = nil
        let root = AppFiles.support, recordings = includeRecordings
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            do { try ArchiveBackup.createBackup(root: root, destination: url, includeRecordings: recordings); return nil }
            catch { return error.localizedDescription }
        }.value
        working = nil
        if let error {
            message = error
        } else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            message = String(localized: "Gesichert: \(url.lastPathComponent) (\(Self.byteText(Int64(size))))")
        }
    }

    private func chooseRestore() async {
        guard let url = await SaveSheet.open(types: [.zip], message: String(localized: "Wähle eine Sicherung des PortaPack Managers.")).first else { return }
        pendingRestore = url
    }

    private func restore(_ url: URL) async {
        pendingRestore = nil
        working = String(localized: "Spiele Sicherung ein …")
        message = nil
        let root = AppFiles.support
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ArchiveBackup.RestoreResult, Error> in
            Result { try ArchiveBackup.restore(from: url, root: root) }
        }.value
        working = nil
        switch outcome {
        case .success(let result):
            message = String(localized: "\(result.restored) Dateien übernommen, \(result.skipped) schon vorhanden, \(result.imported) Einträge neu im Archiv.")
            await refresh()
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    static func title(_ id: String) -> String {
        switch id {
        case ArchiveBackup.Area.adsb: String(localized: "Flugzeuge")
        case ArchiveBackup.Area.ais: String(localized: "Schiffe")
        case ArchiveBackup.Area.sondes: String(localized: "Radiosonden")
        case ArchiveBackup.Area.database: String(localized: "Archiv-Datenbank")
        case ArchiveMigration.oldFolderName: String(localized: "Alte Archivdateien (übernommen)")
        case "Archiv", "Radiosonden": String(localized: "Alte Archivdateien (noch nicht übernommen)")
        case "Aufnahmen": String(localized: "IQ-Aufnahmen")
        case "Belegung": String(localized: "Belegungsmonitor")
        case "Flugfunk": String(localized: "Flugfunk")
        case "SSTV": String(localized: "SSTV-Bilder")
        case "Wettersatellit": String(localized: "Wettersatellit (METEOR)")
        default: String(localized: "Sonstiges")
        }
    }

    static func detail(_ stat: ArchiveStat) -> String {
        var parts: [String] = []
        switch stat.id {
        case ArchiveBackup.Area.adsb:
            parts.append(String(localized: "\(stat.entries ?? 0) Sichtungen, \(stat.distinct ?? 0) verschiedene Flugzeuge"))
        case ArchiveBackup.Area.ais:
            parts.append(String(localized: "\(stat.entries ?? 0) Sichtungen, \(stat.distinct ?? 0) verschiedene Schiffe"))
        case ArchiveBackup.Area.sondes:
            parts.append(String(localized: "\(stat.entries ?? 0) Flüge, \(stat.distinct ?? 0) Meldungen"))
        case "Flugfunk":
            parts.append(String(localized: "\(stat.entries ?? 0) Übertragungen im Verlauf"))
        case ArchiveBackup.Area.database:
            parts.append(String(localized: "enthält Flugzeuge, Schiffe, Radiosonden und den Flugfunk-Verlauf"))
        case ArchiveMigration.oldFolderName:
            parts.append(String(localized: "Inhalt steht in der Datenbank"))
        default:
            break
        }
        if !stat.inDatabase {
            parts.append(stat.files == 1 ? String(localized: "1 Datei") : String(localized: "\(stat.files) Dateien"))
        }
        if let oldest = stat.oldest {
            parts.append(String(localized: "seit \(oldest.formatted(date: .abbreviated, time: .omitted))"))
        }
        return parts.joined(separator: " · ")
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
