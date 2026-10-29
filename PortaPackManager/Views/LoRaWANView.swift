import SwiftUI

struct LoRaWANView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.lorawan
    @State private var selection: LoRaWANDevice.ID?
    @State private var devAddr = ""
    @State private var pendingDelete: DeleteConfirmation?
    @State private var nwkSKey = ""
    @State private var appSKey = ""
    @State private var label = ""
    @State private var keyMessage: String?

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "point.3.connected.trianglepath.dotted", text: "LoRaWAN-Funksensoren (EU868) empfängt die App selbst über den HackRF. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 300, issue: model.error) {
                VSplitView {
                    deviceTable.frame(minHeight: 120)
                    logTable.frame(minHeight: 100)
                }
                .frame(minWidth: 560)
            } controls: {
                controls
            }
            .task { if AppNavigation.shared.takeAutoStart(.lorawan), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop() } }
        }
    }

    private var deviceTable: some View {
        Table(model.devices, selection: $selection) {
            TableColumn("Adresse") { (d: LoRaWANDevice) in
                HStack(spacing: 4) {
                    if d.hasKeys { Image(systemName: "key.fill").foregroundStyle(.green).help("Schlüssel hinterlegt") }
                    Text(d.address).font(.body.monospaced())
                }
            }.width(min: 90, ideal: 120)
            TableColumn("Name") { (d: LoRaWANDevice) in Text(d.label ?? "–") }.width(min: 70, ideal: 110)
            TableColumn("FCnt") { (d: LoRaWANDevice) in Text(d.lastFCnt.map(String.init) ?? "–").monospacedDigit() }.width(55)
            TableColumn("Rahmen") { (d: LoRaWANDevice) in Text("\(d.frames)").monospacedDigit() }.width(55)
            TableColumn("SNR") { (d: LoRaWANDevice) in Text(String(format: "%.0f dB", d.snrDB)).monospacedDigit() }.width(55)
            TableColumn("Letzter Rahmen") { (d: LoRaWANDevice) in Text(d.lastSummary).lineLimit(1).foregroundStyle(.secondary) }
            TableColumn("Gehört") { (d: LoRaWANDevice) in Text(d.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(70)
        }
        .overlay {
            if model.devices.isEmpty {
                ContentUnavailableView("Keine Geräte", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(model.running ? "Höre auf \(String(format: "%.1f", model.channelMHz)) MHz, SF\(model.spreadingFactor) …"
                                                         : "Mit „Start“ beginnt der Empfang."))
            }
        }
    }

    private var logTable: some View {
        Table(model.log) {
            TableColumn("Zeit") { Text($0.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(64)
            TableColumn("MHz") { Text(String(format: "%.1f", $0.channelMHz)).monospacedDigit() }.width(50)
            TableColumn("SF") { Text("\($0.sf)").monospacedDigit() }.width(36)
            TableColumn("Inhalt") { Text($0.frame.summary).lineLimit(1) }
        }
    }

    private var controls: some View {
        Form {
            Section {
                HStack {
                    Button(model.running ? "Stopp" : "Start") {
                        if model.running { model.stop() }
                        else { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .startStopShortcut()
                    Spacer()
                    Button("Leeren") { model.clear() }
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Kanal") {
                Picker("Spreizfaktor", selection: $model.spreadingFactor) {
                    Text("Alle (SF7–12 gleichzeitig)").tag(0)
                    ForEach(7...12, id: \.self) { Text("SF\($0)").tag($0) }
                }
                .help("Wie „langsam“ ein Sensor sendet: SF7 schnell und kurz, SF12 langsam mit großer Reichweite. Unbekannt? „Alle“ hört auf jeden.")
                .onChange(of: model.spreadingFactor) { _, _ in model.spreadingFactorChanged() }
                Text("Die EU868-Kanäle 868,1/868,3/868,5 MHz wechseln von selbst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                if model.running {
                    LabeledContent("Aktueller Kanal", value: String(format: "%.1f MHz", model.channelMHz))
                    LabeledContent("Rauschen", value: String(format: "%.0f dBFS", model.noiseDB))
                }
                LabeledContent("Rahmen", value: "\(model.frameCount)")
                LabeledContent("Davon entschlüsselt", value: "\(model.decryptedCount)")
            }
            Section(PanelSection.daten) {
                CSVExportButton(title: "Geräteliste als CSV sichern …", fileName: "lorawan-geraete", isEmpty: model.devices.isEmpty) { csvDocument() }
                Text("Sitzungsschlüssel (ABP)").font(.subheadline.weight(.semibold))
                ForEach(model.sessions, id: \.devAddr) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.label ?? String(format: "%08X", s.devAddr)).font(.body)
                            Text(String(format: "%08X", s.devAddr)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            pendingDelete = DeleteConfirmation(
                                title: String(localized: "Sitzungsschlüssel für \(s.label ?? String(format: "%08X", s.devAddr)) löschen?"),
                                message: String(localized: "NwkSKey und AppSKey werden aus dem Schlüsselbund dieses Mac gelöscht. Hast du sie nirgends sonst, lassen sie sich nicht wiederherstellen.")) {
                                model.removeSession(s)
                            }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Sitzungsschlüssel löschen")
                            .accessibilityLabel("Sitzungsschlüssel löschen")
                    }
                }
                TextField("DevAddr (8 Hex)", text: $devAddr).font(.body.monospaced())
                TextField("NwkSKey (32 Hex)", text: $nwkSKey).font(.body.monospaced())
                TextField("AppSKey (32 Hex)", text: $appSKey).font(.body.monospaced())
                TextField("Name (optional)", text: $label)
                Button("Hinzufügen") {
                    keyMessage = model.addSession(devAddr: devAddr, nwkSKey: nwkSKey, appSKey: appSKey, label: label)
                    if keyMessage == nil { devAddr = ""; nwkSKey = ""; appSKey = ""; label = "" }
                }
                .disabled(devAddr.isEmpty || nwkSKey.isEmpty || appSKey.isEmpty)
                if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.red) }
                Text("Mit den Schlüsseln deiner eigenen Geräte liest die App auch die Messwerte. Du findest sie in deinem LoRaWAN-Server; sie liegen nur im Schlüsselbund dieses Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("TTN: Geräte ▸ „Activation information“; ChirpStack: Geräteschlüssel. Nur ABP-Sitzungen (DevAddr, NwkSKey, AppSKey).")
            }
            Section(PanelSection.hinweis) {
                LegalNotice()
                Text("Ohne Schlüssel siehst du nur, welche Geräte senden – die Inhalte sind verschlüsselt. Werte nur Geräte aus, die dir gehören.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .deleteConfirmation($pendingDelete)
        .formStyle(.grouped)
    }
}

extension LoRaWANView {
    /// Geräteliste ohne Sitzungsschlüssel und ohne Nutzdaten.
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["devaddr", "deveui", "name", "fcnt", "rahmen", "snr_db", "rssi_db", "letzter_rahmen", "schluessel_hinterlegt", "zuletzt"],
                    rows: model.devices.map { d in
                        [.text(d.devAddr.map { String(format: "%08X", $0) }), .text(d.devEUI.map { String(format: "%016llX", $0) }),
                         .text(d.label), .integer(d.lastFCnt.map(Int.init)), .integer(d.frames), .number(d.snrDB), .number(d.rssiDB),
                         .text(d.lastSummary), .flag(d.hasKeys), .date(d.lastSeen)]
                    })
    }
}
