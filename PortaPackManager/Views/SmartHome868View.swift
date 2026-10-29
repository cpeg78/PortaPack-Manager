import SwiftUI

/// Smart-Home-Funk auf 868 MHz: Z-Wave, Homematic, EnOcean, Wireless M-Bus.
/// Das Model gehört dem Fernzugriff (`RemoteHub.smartHome`), damit Mac und Handy
/// dieselben Geräte sehen.
struct SmartHome868View: View {
    var body: some View { SmartHome868Page(model: RemoteHub.shared.smartHome) }
}

private struct SmartHome868Page: View {
    @Environment(DeviceSession.self) private var session
    @Bindable var model: SmartHome868Model
    @State private var selectedDevice: SmartHomeDevice.ID?
    @State private var selectedFrame: SmartHomeReception.ID?
    @State private var deviceOrder: [ColumnSort<SmartHomeDevice>] = []
    @State private var frameOrder: [ColumnSort<SmartHomeReception>] = []
    @State private var filter: SmartHomeRadio?
    @State private var newMeterID = ""
    @State private var pendingDelete: DeleteConfirmation?
    @State private var newKey = ""
    @State private var newLabel = ""
    @State private var keyError: String?

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "homekit", text: "Smart-Home-Funk auf 868 MHz (Z-Wave, Homematic, EnOcean, Funkzähler) wertet die App selbst aus. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 300, issue: model.error) {
                VSplitView {
                    deviceTable.frame(minHeight: 160)
                    HStack(spacing: 0) {
                        frameTable.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        frameDetail.frame(width: 300).frame(maxHeight: .infinity)
                    }
                    .frame(minHeight: 200)
                }
                // Über der Summe der inneren Mindestbreiten (Tabelle 320 + Trenner 1 +
                // Detail fest 300 = 621) – sonst rechnet AppKit die Constraints endlos
                // neu (Absturz, 27.10.2026). Vorher 600, also innen > außen (Review W9).
                .frame(minWidth: 640)
            } controls: {
                controls
            }
            .task { if AppNavigation.shared.takeAutoStart(.smartHome868), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop() }
            }
        }
    }

    // MARK: - Geräte

    private var visibleDevices: [SmartHomeDevice] {
        filter.map { radio in model.devices.filter { $0.radio == radio } } ?? model.devices
    }

    private var deviceTable: some View {
        Table(of: SmartHomeDevice.self, selection: $selectedDevice, sortOrder: $deviceOrder) {
            TableColumn("Funkart", sortUsing: ColumnSort("funkart", text: { $0.radio.rawValue })) { (device: SmartHomeDevice) in
                Label(device.radio.rawValue, systemImage: device.radio.symbol).lineLimit(1)
            }.width(min: 90, ideal: 120)
            TableColumn("Kennung", sortUsing: ColumnSort("kennung", text: { $0.address })) { (device: SmartHomeDevice) in
                Text(device.address).font(.body.monospaced())
            }.width(min: 80, ideal: 130)
            TableColumn("Hersteller/Typ", sortUsing: ColumnSort("typ", text: { $0.deviceType })) { (device: SmartHomeDevice) in
                Text(device.deviceType.isEmpty ? "–" : device.deviceType).lineLimit(1)
            }.width(min: 90, ideal: 160)
            TableColumn("Letzter Wert", sortUsing: ColumnSort("wert", text: { $0.lastValueText })) { (device: SmartHomeDevice) in
                HStack(spacing: 4) {
                    if device.encrypted { Image(systemName: "lock.fill").foregroundStyle(.secondary).help("verschlüsselt") }
                    Text(device.lastValueText).lineLimit(1)
                }
            }
            TableColumn("Pegel", sortUsing: ColumnSort("pegel") { $0.snrDB }) { (device: SmartHomeDevice) in
                Text(String(format: "%.0f dB", device.snrDB)).monospacedDigit()
                    .help(levelText(rssi: device.rssiDB, snr: device.snrDB))
            }.width(50)
            TableColumn("Zuletzt", sortUsing: ColumnSort("zuletzt") { $0.lastSeen }) { (device: SmartHomeDevice) in
                Text(device.lastSeen, style: .relative).foregroundStyle(.secondary)
            }.width(90)
            TableColumn("Anzahl", sortUsing: ColumnSort("anzahl") { $0.count }) { (device: SmartHomeDevice) in
                Text("\(device.count)").monospacedDigit()
            }.width(50)
        } rows: {
            ForEach(visibleDevices.sorted(by: deviceOrder)) { TableRow($0) }
        }
        .overlay {
            if visibleDevices.isEmpty {
                ContentUnavailableView("Keine Geräte", systemImage: "homekit",
                                       description: Text(model.running
                                                         ? "Noch nichts empfangen. Viele Geräte senden nur bei einer Änderung oder alle paar Minuten."
                                                         : "Mit „Start“ beginnt der Empfang."))
            }
        }
    }

    // MARK: - Rahmen

    private var selectedDeviceValue: SmartHomeDevice? {
        model.devices.first { $0.id == selectedDevice }
    }

    private var visibleFrames: [SmartHomeReception] {
        var frames = model.receptions
        if let radio = filter { frames = frames.filter { $0.frame.radio == radio } }
        if let selectedDevice { frames = frames.filter { $0.frame.deviceKey == selectedDevice } }
        return frames
    }

    private var frameTable: some View {
        VStack(spacing: 0) {
            if let device = selectedDeviceValue {
                HStack {
                    Text("Rahmen von \(device.address)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Alle Rahmen") { selectedDevice = nil }.controlSize(.small)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            Table(visibleFrames.sorted(by: frameOrder), selection: $selectedFrame, sortOrder: $frameOrder) {
                TableColumn("Zeit", sortUsing: ColumnSort("zeit") { $0.id }) {
                    Text($0.date, format: .dateTime.hour().minute().second()).monospacedDigit()
                }.width(65)
                TableColumn("Funkart", sortUsing: ColumnSort("funkart", text: { $0.frame.radio.rawValue })) {
                    Text($0.frame.radio.rawValue).lineLimit(1)
                }.width(min: 60, ideal: 90)
                TableColumn("Absender", sortUsing: ColumnSort("absender", text: { $0.frame.address })) {
                    Text($0.frame.address).font(.body.monospaced()).lineLimit(1)
                }.width(min: 70, ideal: 120)
                TableColumn("Inhalt", sortUsing: ColumnSort("inhalt", text: { $0.frame.summary })) { reception in
                    HStack(spacing: 4) {
                        if reception.frame.encrypted { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                        Text(reception.frame.summary.isEmpty ? reception.frame.kind : reception.frame.summary).lineLimit(1)
                    }
                }
            }
            .overlay {
                if visibleFrames.isEmpty {
                    ContentUnavailableView("Keine Rahmen", systemImage: "waveform",
                                           description: Text("Hier erscheint jeder Rahmen mit gültiger Prüfsumme."))
                }
            }
        }
    }

    private var frameDetail: some View {
        ScrollView {
            if let reception = visibleFrames.first(where: { $0.id == selectedFrame }) {
                let frame = reception.frame
                VStack(alignment: .leading, spacing: 10) {
                    Text(frame.summary.isEmpty ? frame.kind : frame.summary).font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        row("Funkart", "\(frame.radio.rawValue) · \(frame.mode)")
                        row("Frequenz", "\(reception.frequencyMHz.formatted(.number.precision(.fractionLength(2)))) MHz")
                        row("Pegel", levelText(rssi: reception.rssiDB, snr: reception.snrDB))
                        row("Rahmen", frame.kind)
                        if !frame.deviceType.isEmpty { row("Gerät", frame.deviceType) }
                        if let destination = frame.destination { row("Ziel", destination) }
                        row("Prüfsumme", frame.checksumOK ? String(localized: "in Ordnung") : String(localized: "falsch"))
                        if frame.encrypted { row("Inhalt", String(localized: "verschlüsselt")) }
                    }
                    .font(.callout)
                    if !frame.values.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(frame.values, id: \.self) { value in
                                Text(verbatim: "\(value.label): \(value.formatted)")
                            }
                        }
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if !frame.fields.isEmpty {
                        Text("Felder").font(.subheadline.weight(.semibold))
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                            ForEach(Array(frame.fields.enumerated()), id: \.offset) { _, field in
                                fieldRow(field.name, field.value)
                            }
                        }
                        .font(.caption)
                    }
                    Text("Rohdaten").font(.subheadline.weight(.semibold))
                    Text(SmartHomeHex.string(frame.bytes))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Rahmen wählen, um die Einzelheiten zu sehen.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }

    private func row(_ name: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    /// Zeile mit einem Namen aus dem Dekoder (schon übersetzt).
    private func fieldRow(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func levelText(rssi: Double, snr: Double) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        return String(localized: "\(rssi.formatted(format)) dBFS, Störabstand \(snr.formatted(format)) dB")
    }

    // MARK: - Bedienung

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
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Funkarten") {
                ForEach(SmartHomeRadio.allCases) { radio in
                    Toggle(isOn: Binding(get: { model.radios.contains(radio) },
                                         set: { model.setRadio(radio, enabled: $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(radio.rawValue)
                            Text(radio.frequencies).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Schalte nur die Funkarten ein, die du brauchst – das spart Rechenzeit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Geräte", value: "\(model.devices.count)")
                LabeledContent("Rahmen", value: "\(model.frameCount)")
                LabeledContent("Funkstöße", value: "\(model.burstCount)")
                    .help("Alles, was kurz über dem Rauschen lag – auch fremde Sender und Störungen.")
                if model.running {
                    ForEach(SmartHomeChannel.allCases, id: \.self) { channel in
                        if let noise = model.noiseDB[channel] {
                            LabeledContent("Rauschen \(channel.frequencyMHz.formatted(.number.precision(.fractionLength(2)))) MHz",
                                           value: "\(noise.formatted(.number.precision(.fractionLength(1)))) dBFS")
                        }
                    }
                }
            }
            if let device = selectedDeviceValue, device.radio == .enocean {
                enoceanSection(device)
            }
            Section(PanelSection.anzeige) {
                Picker("Anzeigen", selection: $filter) {
                    Text("Alle").tag(SmartHomeRadio?.none)
                    ForEach(SmartHomeRadio.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
            }
            keySection
            Section(PanelSection.hinweis) {
                LegalNotice()
                Text("Werte nur Geräte aus, die dir gehören. Funkverkehr fremder Geräte (z. B. der Zähler deiner Nachbarn) mitzulesen oder weiterzugeben ist nicht erlaubt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .deleteConfirmation($pendingDelete)
        .formStyle(.grouped)
    }

    private func enoceanSection(_ device: SmartHomeDevice) -> some View {
        Section("EnOcean-Profil (\(device.address))") {
            Picker("Profil", selection: Binding(
                get: { model.enoceanProfiles[device.address] },
                set: { model.setProfile($0, for: device.address) })) {
                Text("Vorgabe (A5-02-05)").tag(String?.none)
                ForEach(EnOcean.supportedProfiles, id: \.self) { Text($0).tag(Optional($0)) }
            }
            Text("Das Profil steht auf dem Gerät oder in der Anleitung. Beim Anlernen übernimmt die App es selbst.")
                .font(.caption).foregroundStyle(.secondary)
                .help("4BS-Sensoren senden nicht mit, welche Werte sie übertragen – ohne Profil nimmt die App A5-02-05 an.")
        }
    }

    private var keySection: some View {
        Section(PanelSection.daten) {
            CSVExportButton(title: "Geräteliste als CSV sichern …", fileName: "smart-home-868", isEmpty: model.devices.isEmpty) { csvDocument() }
            Text("Zählerschlüssel (wM-Bus)").font(.subheadline.weight(.semibold))
            ForEach(model.wmbusKeys) { key in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.meterID).font(.body.monospaced())
                        if !key.label.isEmpty { Text(key.label).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        pendingDelete = DeleteConfirmation(
                            title: String(localized: "Schlüssel für Zähler \(key.meterID) löschen?"),
                            message: String(localized: "Er wird aus dem Schlüsselbund dieses Mac gelöscht. Hast du ihn nirgends sonst, lässt er sich nicht wiederherstellen.")) {
                            model.removeKey(key.meterID)
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Schlüssel löschen")
                    .accessibilityLabel("Schlüssel löschen")
                }
            }
            LabeledContent("Zählernummer") {
                TextField("", text: $newMeterID, prompt: Text("12345678"))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Schlüssel") {
                SecureField("", text: $newKey, prompt: Text("32 Hex-Zeichen"))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Bezeichnung") {
                TextField("", text: $newLabel, prompt: Text("z. B. Wasser Keller"))
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                if let keyError { Text(keyError).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Hinzufügen") {
                    keyError = model.addKey(meterID: newMeterID, key: newKey, label: newLabel)
                    if keyError == nil { newMeterID = ""; newKey = ""; newLabel = "" }
                }
                .disabled(newMeterID.isEmpty || newKey.isEmpty)
            }
            Text("Den AES-Schlüssel deines Zählers bekommst du vom Versorger oder Hersteller. Er bleibt im Schlüsselbund dieses Macs.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension SmartHome868Page {
    /// Geräteliste ohne Zählerschlüssel.
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["funkart", "kennung", "typ", "letzter_wert", "werte", "verschluesselt", "pegel_db", "snr_db", "anzahl",
                             "erste", "letzte", "letzte_meldung"],
                    rows: model.devices.map { d in
                        [.text(d.radio.rawValue), .text(d.address), .text(d.deviceType), .text(d.lastValueText),
                         .text(d.values.map { "\($0.label) \($0.value) \($0.unit)".trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")),
                         .flag(d.encrypted), .number(d.rssiDB), .number(d.snrDB), .integer(d.count), .date(d.firstSeen), .date(d.lastSeen),
                         .text(d.lastSummary)]
                    })
    }
}
