import SwiftUI

/// Seite „Daten teilen“: empfangene Flugzeug-, Schiffs- und Sondendaten an öffentliche
/// Dienste und Messwerte an das eigene Home Assistant (MQTT) weitergeben (alles aus,
/// bis es hier eingeschaltet wird).
struct SharingView: View {
    @Bindable private var sondeHub = SondeHubUploader.shared
    @AppStorage(NMEAFeeder.enabledKey) private var shareAIS = false
    @AppStorage(NMEAFeeder.targetsKey) private var aisTargets = ""
    @State private var aisSent = 0
    @AppStorage(BeastFeeder.enabledKey) private var shareADSB = false
    @AppStorage(BeastFeeder.presetsKey) private var adsbPresets = BeastFeeder.defaultPresets
    @AppStorage(BeastFeeder.customKey) private var adsbCustom = ""
    @AppStorage(BeastFeeder.sendUUIDKey) private var adsbSendUUID = true
    @State private var adsbStatus: [BeastFeeder.Status] = []

    var body: some View {
        Form {
            Section {
                Toggle("ADS-B im Beast-Format einspeisen", isOn: $shareADSB)
                    .onChange(of: shareADSB) { _, _ in applyBeast() }
                ForEach(BeastFeeder.presets) { preset in
                    Toggle(isOn: presetBinding(preset.id)) {
                        LabeledContent(preset.name, value: preset.endpoint)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!shareADSB)
                }
                TextField("Eigene Ziele (Host:Port, durch Komma getrennt)", text: $adsbCustom, axis: .vertical)
                    .onSubmit(applyBeast)
                    .disabled(!shareADSB)
                Toggle("Stationskennung (UUID) mitsenden", isOn: $adsbSendUUID)
                    .onChange(of: adsbSendUUID) { _, _ in
                        // Die Kennung geht nur beim Verbinden hinaus – neu verbinden.
                        BeastFeeder.shared.configure(enabled: false, presets: adsbPresets, custom: adsbCustom)
                        applyBeast()
                    }
                    .disabled(!shareADSB)
                    .help("Eine zufällige Kennung, an der dich die Dienste wiedererkennen – für ihre Statistik „mein Empfänger“. airplanes.live verlangt sie. Sie verrät nichts über dich: \(BeastFeeder.stationUUID)")
                if shareADSB {
                    ForEach(adsbStatus) { status in
                        LabeledContent(status.endpoint) {
                            Text(statusText(status)).foregroundStyle(statusColor(status.state))
                        }
                    }
                }
                Text("Gesendet werden nur die empfangenen Flugzeugnachrichten samt Empfangspegel und – wenn eingeschaltet – eine zufällige Stationskennung. Dein Standort geht nicht hinaus.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Gesendet wird nur, solange Flugzeuge empfangen werden (Seite „Flugzeuge (ADS-B)“ oder Fernzugriff).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Flugzeuge (ADS-B)")
            }
            Section {
                Toggle("AIS als NMEA per UDP weitergeben", isOn: $shareAIS)
                    .onChange(of: shareAIS) { _, _ in applyFeeder() }
                TextField("Ziele (Host:Port, durch Komma getrennt)", text: $aisTargets, axis: .vertical)
                    .onSubmit(applyFeeder)
                    .disabled(!shareAIS)
                Text("AISHub, MarineTraffic und VesselFinder nennen bei der Anmeldung einer Station Adresse und Port. AISHub gibt im Tausch Zugriff auf alle Schiffsdaten.")
                    .font(.caption).foregroundStyle(.secondary)

                if shareAIS {
                    LabeledContent("Gesendet", value: String(localized: "\(aisSent) Sätze"))
                }
                Text("Gesendet wird nur, solange Schiffe empfangen werden (Seite „Schiffe (AIS)“ oder Fernzugriff).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Schiffe (AIS)")
            }
            Section {
                Toggle("Radiosonden an SondeHub hochladen", isOn: $sondeHub.enabled)
                TextField("Rufzeichen / Name", text: $sondeHub.callsign)
                    .disabled(!sondeHub.enabled)
                Toggle("Standort mitsenden (gerundet auf ≈ 1 km)", isOn: $sondeHub.sharePosition)
                    .disabled(!sondeHub.enabled)
                TextField("Antenne", text: $sondeHub.antenna)
                    .disabled(!sondeHub.enabled)
                if sondeHub.enabled && !sondeHub.ready {
                    Text("Ohne Rufzeichen wird nichts hochgeladen.").font(.caption).foregroundStyle(.orange)
                }
                if sondeHub.uploaded > 0 || sondeHub.error != nil {
                    LabeledContent("Hochgeladen", value: sondeHub.lastUpload.map {
                        String(localized: "\(sondeHub.uploaded) Rahmen, zuletzt \($0.formatted(date: .omitted, time: .shortened))")
                    } ?? String(localized: "\(sondeHub.uploaded) Rahmen"))
                }
                if let error = sondeHub.error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Sondenjäger finden mit SondeHub die Landeplätze, die Daten fließen auch in Vorhersagen. Mit Standort erscheint deine Station auf der Karte von sondehub.org.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Radiosonden (SondeHub)")
            }
            MQTTSharingSection()
        }
        .formStyle(.grouped)
        .onDisappear {
            applyFeeder()
            applyBeast()
        }
        .task {
            while !Task.isCancelled {
                aisSent = NMEAFeeder.shared.sentCount
                adsbStatus = BeastFeeder.shared.status()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .navigationTitle("Daten teilen")
    }

    private func applyFeeder() {
        NMEAFeeder.shared.configure(enabled: shareAIS, targets: aisTargets)
    }

    private func applyBeast() {
        BeastFeeder.shared.configure(enabled: shareADSB, presets: adsbPresets, custom: adsbCustom)
    }

    private func presetBinding(_ id: String) -> Binding<Bool> {
        Binding {
            adsbPresets.split(separator: ",").contains { $0 == id }
        } set: { on in
            var ids = adsbPresets.split(separator: ",").map(String.init).filter { $0 != id }
            if on { ids.append(id) }
            adsbPresets = ids.joined(separator: ",")
            applyBeast()
        }
    }

    private func statusText(_ status: BeastFeeder.Status) -> String {
        let sent = status.dropped > 0
            ? String(localized: "\(status.sent) Nachrichten, \(status.dropped) verworfen")
            : String(localized: "\(status.sent) Nachrichten")
        switch status.state {
        case .connecting: return String(localized: "Verbinde … · \(sent)")
        case .connected: return String(localized: "Verbunden · \(sent)")
        case .waiting(let reason): return String(localized: "Fehler: \(reason) – neuer Versuch gleich · \(sent)")
        }
    }

    private func statusColor(_ state: BeastFeeder.Status.State) -> Color {
        switch state {
        case .connecting: .secondary
        case .connected: .green
        case .waiting: .orange
        }
    }
}
