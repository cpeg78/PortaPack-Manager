import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FirmwareView: View {
    @Environment(DeviceSession.self) private var session

    /// Rohwert wird gespeichert (`firmwareChannel`) – nicht ändern; Anzeige: `title`.
    enum Channel: String, CaseIterable, Identifiable {
        case nightly = "Nightly"
        case stable = "Stabil"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .nightly: String(localized: "Nightly (täglich neu)")
            case .stable: String(localized: "Stabil")
            }
        }
    }

    enum Method: String, CaseIterable, Identifiable {
        case mayhem = "Über Mayhem (empfohlen)"
        case hackRF = "Über HackRF-Modus (Rettungsweg)"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mayhem: String(localized: "Über Mayhem (empfohlen)")
            case .hackRF: String(localized: "Über den HackRF-Modus (Notweg)")
            }
        }
    }

    @AppStorage("firmwareChannel") private var channel: Channel = .nightly
    @State private var releases: [FirmwareRelease] = []
    @State private var selectedTag: String?
    /// Vom Nutzer gewählter Gerätetyp – nur nötig, wenn das Gerät ihn nicht
    /// selbst meldet (ältere Mayhem-Versionen ohne `Device:`-Zeile). Ein
    /// Pro-Paket auf einem HackRF One (oder umgekehrt) wäre fatal, deshalb
    /// wird nicht mehr still „HackRF One“ angenommen.
    @AppStorage("firmwareDeviceTypeChoice") private var storedTypeChoice: String = ""
    @State private var loading = false
    @State private var catalogError: String?
    @State private var localFile: URL?
    @State private var showingImporter = false
    @State private var method: Method = .mayhem
    @State private var installAppsAfterRescue = true
    @State private var pendingAction: PendingAction?
    /// Der SPI-Rettungsweg hat einen eigenen, deutlicheren Dialog.
    @State private var pendingRescue: FirmwareSource?
    @AppStorage("renewWithWorldMap") private var renewWithWorldMap = false
    @AppStorage("renewKeepFreqman") private var renewKeepFreqman = true
    @AppStorage("renewRemoveOldApps") private var renewRemoveOldApps = true
    @State private var cacheEntries: [DownloadCache.Entry] = []
    @State private var cacheError: String?
    @State private var confirmClearCache = false
    @State private var returningToMayhem = false

    enum PendingAction: Identifiable {
        case install(FirmwareSource), appsOnly(FirmwareSource), renew(FirmwareRelease)
        var id: String {
            switch self {
            case let .renew(r): "n" + r.tag
            case let .install(s): "i" + s.fileName
            case let .appsOnly(s): "a" + s.fileName
            }
        }
    }

    private var installed: FirmwareVersion? { session.info?.version }

    /// Vom Gerät gemeldeter Typ (nur mit `Device:`-Zeile in `info`).
    private var reportedType: DeviceType? { session.info?.reportedDeviceType }

    /// Der Typ, für den Pakete gewählt werden: gemeldet, sonst bewusst gewählt.
    private var deviceType: DeviceType? { reportedType ?? DeviceType(rawValue: storedTypeChoice) }

    private var typeChoice: Binding<DeviceType?> {
        Binding(get: { DeviceType(rawValue: storedTypeChoice) },
                set: { storedTypeChoice = $0?.rawValue ?? "" })
    }

    private var visibleReleases: [FirmwareRelease] {
        releases.filter { channel == .nightly ? $0.isPrerelease : !$0.isPrerelease }
    }

    private var selectedRelease: FirmwareRelease? {
        releases.first { $0.tag == selectedTag }
    }

    private var selectedSource: FirmwareSource? {
        if let localFile { return .localFile(localFile) }
        guard let deviceType, let release = selectedRelease, let asset = release.package(for: deviceType) else { return nil }
        return .release(release, asset)
    }

    var body: some View {
        HSplitView {
            releaseList
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            detail
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .task { await loadCatalog() }
    }

    // MARK: - Liste

    private var releaseList: some View {
        VStack(spacing: 0) {
            // „Ausgabe“, nicht „Kanal“ – sonst mit einem Funkkanal verwechselbar.
            Picker("Ausgabe", selection: $channel) {
                ForEach(Channel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            List(visibleReleases, selection: $selectedTag) { release in
                ReleaseRow(release: release, installed: installed, deviceType: deviceType)
                    .tag(release.tag)
            }
            .overlay {
                if loading && releases.isEmpty {
                    ProgressView("Lade Versionen …")
                } else if let catalogError, releases.isEmpty {
                    ContentUnavailableView("Keine Versionen gefunden", systemImage: "wifi.exclamationmark", description: Text(catalogError))
                }
            }

            HStack {
                Button {
                    Task { await loadCatalog() }
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
                Spacer()
                Button("Lokale Datei …") { showingImporter = true }
            }
            .padding(10)
        }
        .onChange(of: channel) { _, _ in
            selectedTag = visibleReleases.first?.tag
            localFile = nil
        }
        .onChange(of: selectedTag) { _, newValue in
            if newValue != nil { localFile = nil }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        Form {
            if session.installProgress.phase != .idle {
                Section("Fortschritt") {
                    InstallProgressView(progress: session.installProgress)
                    // Nur der Download lässt sich gefahrlos abbrechen – nie das Übertragen oder Schreiben.
                    if session.installProgress.phase == .downloading {
                        Button("Download abbrechen") { session.installer.downloadCancel.cancel() }
                            .help("Bricht nur das Herunterladen ab. Am Gerät hat sich dann noch nichts geändert.")
                    }
                }
            }

            if let pending = session.pendingRenewal {
                let conflict = pending.conflict(with: session.info)
                Section("Erneuern abschließen") {
                    Text(Self.pendingText(pending))
                        .font(.callout)
                    if let conflict {
                        Label(conflict, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    HStack {
                        Button {
                            Task { await session.finishPendingRenewal() }
                        } label: {
                            Label("Erneuern abschließen", systemImage: "bolt.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.device == nil || session.busy || conflict != nil)
                        Button("Verwerfen") { session.pendingRenewal = nil }
                        Spacer()
                        if session.device == nil {
                            Text("Wartet auf das Gerät im Mayhem-Modus").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Im HackRF-Modus geht nur der Notweg – den Weg zurück anbieten, nicht von
            // selbst umschalten (sonst wäre der Notweg unerreichbar).
            if session.mode == .hackRF, method == .mayhem {
                Section("Gerät ist im HackRF-Modus") {
                    Text("Installieren über Mayhem, „Nur Apps aktualisieren“ und „Gerät komplett erneuern“ brauchen den Mayhem-Modus.")
                        .font(.callout).foregroundStyle(.secondary)
                    MayhemReturnButton(switching: $returningToMayhem)
                        .frame(maxWidth: .infinity)
                }
            }

            Section("Gerät") {
                LabeledContent("Installiert") {
                    if let installed {
                        Text(installed.description)
                    } else {
                        Text(session.mode == .hackRF ? "unbekannt (HackRF-Modus)" : "–").foregroundStyle(.secondary)
                    }
                }
                if let reportedType {
                    LabeledContent("Gerätetyp", value: reportedType.displayName)
                } else {
                    Picker("Gerätetyp", selection: typeChoice) {
                        Text("Bitte wählen").tag(DeviceType?.none)
                        ForEach(DeviceType.allCases) { Text($0.displayName).tag(DeviceType?.some($0)) }
                    }
                    Label(deviceType == nil
                          ? "Das Gerät meldet seinen Typ nicht (ältere Mayhem-Version oder nicht verbunden). Wähl ihn bitte selbst – eine Firmware für den falschen Typ macht das Gerät unbrauchbar."
                          : "Vom Gerät nicht gemeldet, von dir gewählt. Stimmt das nicht, unbedingt ändern – eine Firmware für den falschen Typ macht das Gerät unbrauchbar.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let latest = visibleReleases.first, let installed, let older = installed.isOlder(than: latest.version) {
                    LabeledContent("Neueste Version") {
                        HStack {
                            Text(latest.version.description)
                            if older {
                                Text("Update verfügbar").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.green.opacity(0.2), in: Capsule())
                            } else {
                                Text("aktuell").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Auswahl") {
                if let localFile {
                    LabeledContent("Lokale Datei") {
                        HStack {
                            Text(localFile.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Button("Entfernen") { self.localFile = nil }
                        }
                    }
                } else if let release = selectedRelease {
                    LabeledContent("Version") {
                        Link(release.version.description, destination: release.htmlURL)
                    }
                    LabeledContent("Veröffentlicht", value: release.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    if let deviceType {
                        if let asset = release.package(for: deviceType) {
                            LabeledContent("Paket", value: "\(asset.name) · \(FirmwareInstaller.format(Int64(asset.size)))")
                        } else {
                            Text("Für \(deviceType.displayName) gibt es in dieser Version kein Paket.").foregroundStyle(.orange)
                        }
                    } else {
                        Text("Wähl zuerst den Gerätetyp.").foregroundStyle(.orange)
                    }
                } else {
                    Text("Wähl links eine Version oder öffne eine lokale Datei (.ppfw.tar oder .bin).")
                        .foregroundStyle(.secondary)
                }

                Picker("Weg", selection: $method) {
                    ForEach(Method.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if method == .hackRF {
                    Toggle("Danach die Apps installieren", isOn: $installAppsAfterRescue)
                    Text("Nur für den Notfall, wenn die Installation über Mayhem scheitert: Die App schreibt die Firmware direkt in den Speicher des HackRF, liest sie zur Kontrolle zurück und startet neu.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Lädt die Firmware auf die SD-Karte, prüft die Übertragung und lässt Mayhem sie einspielen. Die Apps werden dabei mit aktualisiert.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        guard let source = selectedSource else { return }
                        if method == .mayhem { pendingAction = .install(source) } else { pendingRescue = source }
                    } label: {
                        Label("Installieren", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canInstall)

                    Button("Nur Apps aktualisieren") {
                        guard let source = selectedSource else { return }
                        pendingAction = .appsOnly(source)
                    }
                    .disabled(selectedSource == nil || session.device == nil || session.busy || selectedSource?.fileName.hasSuffix(".bin") == true)
                    .help("Kopiert nur die Apps (.ppma) aus dem Paket aufs Gerät – die Firmware bleibt, wie sie ist.")
                    Spacer()
                }
            }

            Section("Gerät komplett erneuern") {
                Text("Bringt die ganze SD-Karte auf den Stand der gewählten Version und spielt danach die Firmware ein. Die Karte bleibt dabei im Gerät.")
                    .font(.callout).foregroundStyle(.secondary)
                if let release = selectedRelease {
                    let asset = deviceType.flatMap { release.sdCardPackage(for: $0, withWorldMap: renewWithWorldMap) }
                    Toggle("Mit Weltkarte für ADS-B (deutlich größer)", isOn: $renewWithWorldMap)
                    Toggle("Eigene Frequenzlisten (FREQMAN) behalten", isOn: $renewKeepFreqman)
                    Toggle("Alte Apps vorher entfernen", isOn: $renewRemoveOldApps)
                    LabeledContent("Paket") {
                        if let asset {
                            Text("\(asset.name) · \(FirmwareInstaller.format(Int64(asset.size)))")
                                .lineLimit(1).truncationMode(.middle)
                        } else if deviceType == nil {
                            Text("Wähl zuerst den Gerätetyp").foregroundStyle(.orange)
                        } else {
                            Text("Für diese Version nicht vorhanden").foregroundStyle(.orange)
                        }
                    }
                    Button {
                        pendingAction = .renew(release)
                    } label: {
                        Label("Gerät komplett erneuern", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    }
                    .disabled(asset == nil || session.busy || (session.device == nil && session.mode != .sdCard) || localFile != nil)
                } else {
                    Text("Wähl links eine Version.").foregroundStyle(.secondary)
                }
            }

            downloadsSection

            if let release = selectedRelease, localFile == nil, !release.notes.isEmpty {
                Section("Änderungen") {
                    ScrollView {
                        Text(LocalizedStringKey(release.notes))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 160, maxHeight: 320)
                }
            }
        }
        .formStyle(.grouped)
        .task { await reloadCache() }
        .onChange(of: session.busy) { _, busy in
            if !busy { Task { await reloadCache() } }
        }
        // Dialoge hängen bewusst am Formular, nicht am HSplitView: an der
        // AppKit-gestützten Split-Ansicht zeigt SwiftUI sie nicht an.
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "tar") ?? .data, UTType(filenameExtension: "bin") ?? .data]) { result in
            if case let .success(url) = result {
                _ = url.startAccessingSecurityScopedResource()
                localFile = url
            }
        }
        .alert(confirmTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
               presenting: pendingAction) { action in
            Button(confirmButton(action), role: .destructive) { run(action) }
            Button("Abbrechen", role: .cancel) {}
        } message: { action in
            Text(confirmMessage(action))
        }
        // Eigener Dialog für den nie erprobten SPI-Rettungsweg – mit deutlichem
        // Hinweis, was beim Scheitern passiert. Am Formular, nicht am HSplitView.
        .alert("Firmware-Speicher direkt überschreiben?",
               isPresented: Binding(get: { pendingRescue != nil }, set: { if !$0 { pendingRescue = nil } }),
               presenting: pendingRescue) { source in
            Button("Löschen und neu schreiben", role: .destructive) {
                Log.session.notice("Rettungsweg bestätigt: \(source.fileName, privacy: .public)")
                let type = deviceType
                let apps = installAppsAfterRescue
                Task { await session.flashViaHackRFMode(source, deviceType: type, installApps: apps) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { source in
            Text(rescueMessage(source))
        }
        .alert("Alle Downloads löschen?", isPresented: $confirmClearCache) {
            Button("Löschen", role: .destructive) { Task { await clearCache(nil) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle heruntergeladenen Pakete werden entfernt (\(FirmwareInstaller.format(cacheTotal))). Bei Bedarf lädt die App sie neu.")
        }
    }

    // MARK: - Downloads

    private var cacheTotal: Int64 { cacheEntries.reduce(0) { $0 + $1.size } }

    @ViewBuilder
    private var downloadsSection: some View {
        Section {
            if cacheEntries.isEmpty {
                Text("Keine heruntergeladenen Pakete.").foregroundStyle(.secondary)
            }
            ForEach(cacheEntries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                        Text(cacheDetail(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(FirmwareInstaller.format(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        Task { await clearCache(entry) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.busy)
                    .help("Download löschen")
                }
            }
            if let cacheError {
                Text(cacheError).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Im Finder zeigen") {
                    let directory = FirmwareDownloader.cacheDirectory.deletingLastPathComponent()
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
                Spacer()
                Button("Alle löschen", role: .destructive) { confirmClearCache = true }
                    .disabled(cacheEntries.isEmpty || session.busy)
            }
        } header: {
            HStack {
                Text("Downloads")
                Spacer()
                if !cacheEntries.isEmpty {
                    Text(FirmwareInstaller.format(cacheTotal)).monospacedDigit()
                }
            }
        } footer: {
            if session.busy {
                Text("Löschen ist während eines laufenden Vorgangs gesperrt.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func cacheDetail(_ entry: DownloadCache.Entry) -> String {
        var parts: [String] = []
        if entry.isPartial { parts.append(String(localized: "unvollständig")) }
        if entry.isExtracted { parts.append(String(localized: "entpackt")) }
        parts.append(entry.modified.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private func reloadCache() async {
        cacheEntries = await Task.detached { DownloadCache().entries() }.value
    }

    /// `nil` löscht alles.
    private func clearCache(_ entry: DownloadCache.Entry?) async {
        guard !session.busy else { return }
        do {
            try await Task.detached {
                if let entry { try DownloadCache().remove(entry) } else { try DownloadCache().removeAll() }
            }.value
            cacheError = nil
            Log.session.notice("Downloads gelöscht: \(entry?.name ?? "alle", privacy: .public)")
        } catch {
            cacheError = error.localizedDescription
        }
        await reloadCache()
    }

    private var canInstall: Bool {
        guard selectedSource != nil, !session.busy else { return false }
        // Auch eine lokale Datei braucht den Typ – für die Prüfung der Abbildgröße.
        guard deviceType != nil else { return false }
        switch method {
        case .mayhem: return session.device != nil
        case .hackRF: return session.device != nil || session.hackRF != nil
        }
    }

    // MARK: - Aktionen

    private func loadCatalog() async {
        loading = true
        defer { loading = false }
        do {
            releases = try await session.catalog.refresh()
            catalogError = nil
            if selectedTag == nil || !visibleReleases.contains(where: { $0.tag == selectedTag }) {
                selectedTag = visibleReleases.first?.tag
            }
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func run(_ action: PendingAction) {
        Log.session.notice("Aktion bestätigt: \(action.id, privacy: .public)")
        Task {
            switch action {
            case let .install(source): await session.installFirmware(source, deviceType: deviceType)
            case let .appsOnly(source): await session.installAppsOnly(source)
            case let .renew(release):
                guard let deviceType else { return }
                await session.renewDevice(release, type: deviceType, withWorldMap: renewWithWorldMap,
                                          options: SDCardPackage.Options(keepFrequencyLists: renewKeepFreqman,
                                                                         removeOldApps: renewRemoveOldApps))
            }
        }
    }

    private var confirmTitle: String {
        if case .renew = pendingAction { return String(localized: "Gerät komplett erneuern?") }
        return String(localized: "Firmware installieren?")
    }

    private func confirmButton(_ action: PendingAction) -> String {
        switch action {
        case .install: String(localized: "Installieren")
        case .appsOnly: String(localized: "Apps kopieren")
        case .renew: String(localized: "Erneuern")
        }
    }

    /// Hinweis bei einem unterbrochenen Erneuern.
    static func pendingText(_ pending: PendingRenewal) -> String {
        let version = pending.deviceType.flatMap(DeviceType.init(rawValue:))
            .map { String(localized: "\(pending.version) (\($0.displayName))") } ?? pending.version
        return String(localized: "Die Dateien von \(version) liegen schon auf der Karte – es fehlt nur noch das Einspielen der Firmware (\(pending.imagePath)).")
    }

    private func rescueMessage(_ source: FirmwareSource) -> String {
        String(localized: """
            \(source.displayName) wird über den HackRF-Modus direkt in den Firmware-Speicher geschrieben: erst wird alles gelöscht, dann neu geschrieben und zur Kontrolle zurückgelesen.

            Das ist ein Notweg und kaum erprobt. Paket und Datei werden vorher geprüft; scheitert das Schreiben trotzdem, startet das Gerät nach dem Ausschalten nur noch über den DFU-Modus.

            Nur benutzen, wenn die Installation über Mayhem nicht mehr geht. Bis das Gerät wieder im Mayhem-Modus ist: nicht abstecken, nicht ausschalten.
            """)
    }

    private func confirmMessage(_ action: PendingAction) -> String {
        switch action {
        case let .install(source):
            String(localized: "\(source.displayName) wird auf die SD-Karte übertragen und eingespielt. Das Gerät startet danach neu. Währenddessen nicht abstecken.")
        case let .appsOnly(source):
            String(localized: "Die Apps aus \(source.displayName) werden aufs Gerät kopiert. Vorhandene Apps gleichen Namens werden ersetzt.")
        case let .renew(release):
            renewKeepFreqman
                ? String(localized: "Die Dateien von \(release.version.description) werden auf die Karte kopiert und ersetzen gleichnamige Dateien. Aufnahmen, Einstellungen, eigene Dateien und Frequenzlisten bleiben erhalten. Danach wird die Firmware eingespielt. Nicht abstecken.")
                : String(localized: "Die Dateien von \(release.version.description) werden auf die Karte kopiert und ersetzen gleichnamige Dateien. Aufnahmen, Einstellungen und eigene Dateien bleiben erhalten. Danach wird die Firmware eingespielt. Nicht abstecken.")
        }
    }
}

struct ReleaseRow: View {
    let release: FirmwareRelease
    let installed: FirmwareVersion?
    let deviceType: DeviceType?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(release.version.description).font(.body.monospaced())
                if installed == release.version {
                    Text("installiert").font(.caption.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.blue.opacity(0.2), in: Capsule())
                }
                Spacer()
                if let deviceType, release.package(for: deviceType) == nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        .help("Kein Paket für \(deviceType.displayName)")
                }
            }
            Text(release.publishedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct InstallProgressView: View {
    let progress: InstallProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch progress.phase {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                default: ProgressView().controlSize(.small)
                }
                Text(progress.phase.title).font(.headline)
                Spacer()
                if let start = progress.startedAt {
                    let end = progress.finishedAt ?? Date()
                    Text(Duration.seconds(end.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if progress.isRunning {
                ProgressView(value: progress.fraction)
            }
            Text(progress.detail)
                .font(.callout)
                .foregroundStyle(progress.phase == .failed ? .red : .secondary)
                .textSelection(.enabled)
        }
    }
}
