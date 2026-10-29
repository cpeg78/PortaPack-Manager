import SwiftUI

/// Abschnitt „Home Assistant (MQTT)“ der Seite „Daten teilen“. Textfelder
/// wirken erst mit Enter bzw. „Übernehmen“ (sonst verbände jeder Tastendruck
/// neu); Schalter sofort.
struct MQTTSharingSection: View {
    @Bindable private var bridge = MQTTBridge.shared
    @State private var draft = MQTTBridge.shared.settings
    @State private var password = ""
    /// Stand im Schlüsselbund (einmal gelesen) – zum Erkennen von Änderungen.
    @State private var savedPassword: String?
    @State private var portText = String(MQTTBridge.shared.settings.port)
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var showDevices = false

    var body: some View {
        Section {
            Toggle("An Home Assistant weitergeben (MQTT)", isOn: $draft.enabled)
                .onChange(of: draft.enabled) { _, on in
                    if on { loadPassword() }
                    apply()
                }
            TextField("Broker (Host oder IP-Adresse)", text: $draft.host, prompt: Text("homeassistant.local"))
                .onSubmit(apply)
            HStack {
                TextField("Port", text: $portText, prompt: Text("1883"))
                    .onSubmit(apply)
                Toggle("TLS", isOn: $draft.tls)
                    .toggleStyle(.checkbox)
                    .onChange(of: draft.tls) { _, tls in
                        // Übliche Ports mitwechseln, eigene Ports stehen lassen.
                        if tls, portText == "1883" { portText = "8883" }
                        if !tls, portText == "8883" { portText = "1883" }
                        apply()
                    }
            }
            TextField("Benutzer", text: $draft.username).onSubmit(apply)
            SecureField("Passwort", text: $password)
                .onSubmit(apply)
                .help("Liegt nur im Schlüsselbund dieses Macs.")
            if MQTTSettings.sendsPasswordInClear(tls: draft.tls, host: draft.host, password: password) {
                Label("Ohne TLS gehen Benutzer und Passwort unverschlüsselt durchs Netz. Im eigenen Heimnetz meist vertretbar – sonst TLS einschalten (Port 8883).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            TextField("Basis-Thema", text: $draft.baseTopic, prompt: Text("portapack")).onSubmit(apply)
            TextField("Discovery-Präfix", text: $draft.discoveryPrefix, prompt: Text("homeassistant")).onSubmit(apply)

            ForEach(MQTTSource.all) { source in
                Toggle(source.title, isOn: sourceBinding(source))
                    .toggleStyle(.checkbox)
            }
            TextField("Nur Geräte mit diesen Namen/Kennungen (durch Komma getrennt, leer = alle)",
                      text: $draft.allowlist, axis: .vertical)
                .onSubmit(apply)

            HStack {
                Button("Übernehmen", action: apply)
                    .disabled(!hasPendingChanges)
                Button(testing ? "Teste …" : "Verbindung testen", action: test)
                    .disabled(testing || draft.host.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            if let testResult {
                Text(testResult.text).font(.caption).foregroundStyle(testResult.ok ? .green : .red)
            }
            LabeledContent("Status") {
                Text(statusText).foregroundStyle(statusColor)
            }
            if bridge.settings.enabled {
                LabeledContent("Gesendet", value: "\(bridge.publishedStates) Zustände · \(bridge.announcedDevices) Geräte angemeldet")
                if bridge.heldBackDevices > 0 {
                    Text("\(bridge.heldBackDevices) neue Geräte zurückgehalten: Höchstens 20 neue Geräte pro Stunde gehen an Home Assistant (Schutz vor erfundenen Funkgeräten). Trag die gewünschten unter „Nur Geräte mit …“ ein, dann kommen sie sofort.")
                        .font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("Gemeldete Geräte (\(bridge.deviceList.count))", isExpanded: $showDevices) {
                    ForEach(bridge.deviceList.prefix(50)) { device in
                        LabeledContent(device.name) {
                            Text(device.source + " · " + device.lastSeen.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            Text("Gesendet wird nur an deinen eigenen MQTT-Broker (z. B. das Mosquitto-Add-on von Home Assistant). Home Assistant legt die Geräte dann selbst an.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Weitergegeben wird nur, was gerade empfangen wird. Geräte von Nachbarn (Wetterstation, Reifen vorbeifahrender Autos) gibst du besser nicht weiter – die Liste „Nur Geräte mit …“ hilft dabei.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Home Assistant (MQTT)")
        }
        .onAppear {
            draft = bridge.settings
            portText = String(bridge.settings.port)
            if bridge.settings.enabled { loadPassword() }
        }
        .onDisappear {
            if hasPendingChanges { apply() }
        }
    }

    private var parsedPort: UInt16 {
        UInt16(portText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } ?? (draft.tls ? 8883 : 1883)
    }

    private var candidate: MQTTSettings {
        var s = draft
        s.port = parsedPort
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        return s
    }

    private var hasPendingChanges: Bool {
        candidate != bridge.settings || passwordChanged
    }

    private var passwordChanged: Bool { password != (savedPassword ?? "") }

    private func loadPassword() {
        guard savedPassword == nil else { return }
        let stored = bridge.storedPassword()
        savedPassword = stored
        // Ein bei ausgeschalteter Weitergabe schon getipptes Passwort nicht überschreiben.
        if password.isEmpty { password = stored }
    }

    private func apply() {
        let settings = candidate
        portText = String(settings.port)
        // Den Schlüsselbund nur anfassen, wenn das Passwort wirklich geändert wurde.
        if savedPassword == nil, !password.isEmpty { loadPasswordKeepingInput() }
        bridge.apply(settings, password: passwordChanged ? password : nil)
        if passwordChanged { savedPassword = password }
    }

    /// Gespeichertes Passwort merken, ohne die Eingabe zu überschreiben.
    private func loadPasswordKeepingInput() {
        savedPassword = bridge.storedPassword()
    }

    private func test() {
        testing = true
        testResult = nil
        let settings = candidate
        let secret = savedPassword != nil || !password.isEmpty ? password : bridge.storedPassword()
        Task {
            let failure = await bridge.test(settings, password: secret)
            testing = false
            testResult = failure.map { (false, String(localized: "Fehlgeschlagen: \($0)")) }
                ?? (true, String(localized: "Verbindung klappt – der Broker hat die Anmeldung angenommen."))
        }
    }

    private func sourceBinding(_ source: MQTTSource) -> Binding<Bool> {
        Binding {
            draft.sources.contains(source.id)
        } set: { on in
            if on { draft.sources.insert(source.id) } else { draft.sources.remove(source.id) }
            apply()
        }
    }

    private var statusText: String {
        switch bridge.status {
        case .off: bridge.settings.enabled ? String(localized: "Startet …") : String(localized: "Aus – es wird nichts gesendet")
        case .connecting: String(localized: "Verbinde …")
        case let .connected(since): String(localized: "Verbunden seit \(since.formatted(date: .omitted, time: .shortened))")
        case let .waiting(reason, retry): String(localized: "\(reason) – neuer Versuch in \(Int(retry)) s")
        case let .failed(reason): reason
        }
    }

    private var statusColor: Color {
        switch bridge.status {
        case .off: .secondary
        case .connecting: .secondary
        case .connected: .green
        case .waiting: .orange
        case .failed: .red
        }
    }
}
