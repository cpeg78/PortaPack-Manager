import AppKit
import ServiceManagement
import SwiftUI

/// Einstellungen ▸ Allgemein: Start beim Anmelden und Hintergrundbetrieb.
struct BackgroundSettingsSections: View {
    @AppStorage(BackgroundSettings.launchActionKey) private var actionRaw = LoginLaunchAction.resume.rawValue
    @AppStorage(BackgroundSettings.launchPageKey) private var pageRaw = SidebarItem.adsb.rawValue
    @AppStorage(BackgroundSettings.launchHiddenKey) private var launchHidden = true
    @AppStorage(BackgroundSettings.menuBarIconKey) private var menuBarIcon = true
    @AppStorage(BackgroundSettings.dockOnlyWithWindowKey) private var dockOnlyWithWindow = true
    @Environment(\.scenePhase) private var scenePhase
    private var loginItem: LoginItem { .shared }

    private var action: LoginLaunchAction { LoginLaunchAction(rawValue: actionRaw) ?? .resume }

    var body: some View {
        Section("Start") {
            Toggle("Beim Anmelden starten", isOn: Binding {
                loginItem.isOn
            } set: { on in
                loginItem.set(on)
            })
            Text(loginItem.statusText)
                .font(.caption).foregroundStyle(.secondary)
            if loginItem.status == .requiresApproval {
                Button("Systemeinstellungen öffnen …") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = loginItem.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Picker("Beim automatischen Start", selection: $actionRaw) {
                ForEach(LoginLaunchAction.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if action == .page {
                Picker("Seite", selection: $pageRaw) {
                    ForEach(LaunchStart.choices) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
            }
            Text(actionHint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Im Hintergrund starten (ohne Fenster)", isOn: $launchHidden)
        }
        .onAppear { loginItem.refresh() }
        // Nach der Freigabe in den Systemeinstellungen den Stand neu lesen.
        .onChange(of: scenePhase) { _, phase in if phase == .active { loginItem.refresh() } }

        Section("Fenster und Menüleiste") {
            Toggle("Symbol in der Menüleiste", isOn: $menuBarIcon)
            Toggle("Dock-Symbol nur mit offenem Fenster", isOn: $dockOnlyWithWindow)
                .onChange(of: dockOnlyWithWindow) { _, _ in BackgroundController.shared.updateActivationPolicy() }
            Text(windowHint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionHint: String {
        switch action {
        case .resume:
            let memory = LastReceiverMemory()
            if let item = memory.item, LaunchStart.canStart(item) {
                let when = memory.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
                return String(localized: "Startet wieder, was zuletzt lief: \(item.title) (\(when)). Hast du es selbst gestoppt, startet nur der Empfangsplan.")
            }
            return String(localized: "Zuletzt lief nichts – es läuft nur der Empfangsplan. Was beim Beenden läuft, startet beim nächsten Anmelden wieder.")
        case .planOnly:
            return String(localized: "Es läuft nur der Empfangsplan mit seinen Terminen.")
        case .page:
            return String(localized: "Startet diese Seite, sobald der HackRF da ist (bis 3 Minuten Wartezeit). Läuft gerade ein Plan-Termin, kommt sie danach.")
        case .nothing:
            return String(localized: "Die App startet nur. Der Empfangsplan nimmt trotzdem seine Termine auf.")
        }
    }

    private var windowHint: String {
        if !menuBarIcon && dockOnlyWithWindow {
            return String(localized: "Ohne Fenster zeigt die App dann weder Dock- noch Menüleisten-Symbol. Zurück kommst du, indem du sie im Finder oder mit Spotlight erneut öffnest.")
        }
        return String(localized: "Schließt du das Fenster, läuft die App weiter – Empfang, Empfangsplan und Fernzugriff auch. Zurück über das Symbol in der Menüleiste oder das Dock.")
    }
}
