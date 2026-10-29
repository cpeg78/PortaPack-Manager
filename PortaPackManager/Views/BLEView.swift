import SwiftUI

struct BLEView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.ble
    @State private var selectedDevice: BLEDevice.ID?
    @State private var selectedPacket: BLELogLine.ID?
    @State private var deviceOrder: [ColumnSort<BLEDevice>] = []
    @State private var packetOrder: [ColumnSort<BLELogLine>] = []

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "wave.3.right", text: "Bluetooth-LE-Werbepakete (Tracker, Beacons, Sensoren) dekodiert die App selbst. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 280, issue: model.error) {
                VSplitView {
                    deviceTable.frame(minHeight: 200)
                    HSplitView {
                        packetTable.frame(minWidth: 380)
                        detail.frame(minWidth: 260, idealWidth: 320)
                    }
                    .frame(minHeight: 200)
                }
                .frame(minWidth: 660)
            } controls: {
                controls
            }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop() }
            }
        }
    }

    // MARK: - Geräte

    private var deviceTable: some View {
        Table(model.devices.sorted(by: deviceOrder), selection: $selectedDevice, sortOrder: $deviceOrder) {
            TableColumn("Adresse", sortUsing: ColumnSort("adresse", text: { $0.address.string })) { device in
                Text(device.address.string).font(.body.monospaced())
                    .foregroundStyle(device.address.rotates ? .secondary : .primary)
                    .help(device.address.kind)
            }.width(140)
            TableColumn("Name", sortUsing: ColumnSort("name", text: { $0.name })) { Text($0.name ?? "–") }
            TableColumn("Gerät", sortUsing: ColumnSort("geraet", text: { $0.kind ?? $0.company })) { device in
                Text(device.kind ?? device.company ?? "–").foregroundStyle(device.kind == nil ? .secondary : .primary)
            }
            TableColumn("Werte") { device in
                Text(summary(device.readings)).foregroundStyle(.secondary)
            }
            TableColumn("Pegel", sortUsing: ColumnSort("pegel") { $0.rssiDB }) { device in
                Text(String(format: "%.0f dB", device.rssiDB)).monospacedDigit()
            }.width(50)
            TableColumn("Rahmen", sortUsing: ColumnSort("pakete") { $0.count }) { Text("\($0.count)").monospacedDigit() }.width(50)
            TableColumn("Zuletzt", sortUsing: ColumnSort("zuletzt") { $0.lastSeen }) { Text($0.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(90)
        }
        .overlay {
            if model.devices.isEmpty {
                ContentUnavailableView("Keine Geräte", systemImage: "wave.3.right",
                                       description: Text(model.running
                                                         ? "Noch kein gültiges Werbepaket. Liegt eine 2,4-GHz-Antenne am HackRF?"
                                                         : "Mit „Start“ beginnt der Empfang."))
            }
        }
    }

    private func summary(_ readings: [BLEReading]) -> String {
        readings.filter { $0.label != String(localized: "Sendeleistung") }.prefix(4).map(\.value).joined(separator: " · ")
    }

    // MARK: - Pakete

    private var visibleLog: [BLELogLine] {
        model.showRequests ? model.log : model.log.filter { line in
            guard let type = line.advertisement?.type else { return true }
            return type != .scanReq && type != .connectInd
        }
    }

    private var packetTable: some View {
        Table(visibleLog.sorted(by: packetOrder), selection: $selectedPacket, sortOrder: $packetOrder) {
            TableColumn("Zeit", sortUsing: ColumnSort("zeit") { $0.id }) { Text($0.packet.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(65)
            TableColumn("Kanal", sortUsing: ColumnSort("kanal") { $0.packet.channel }) { Text("\($0.packet.channel)").monospacedDigit() }.width(40)
            TableColumn("Typ", sortUsing: ColumnSort("typ", text: { $0.advertisement?.type.name })) { Text($0.advertisement?.type.name ?? String(format: "0x%02X", $0.packet.pdu[0] & 0x0F)) }.width(120)
            TableColumn("Adresse", sortUsing: ColumnSort("adresse", text: { $0.advertisement?.address?.string })) { line in
                Text(line.advertisement?.address?.string ?? "–").font(.body.monospaced())
            }.width(140)
            TableColumn("Pegel", sortUsing: ColumnSort("pegel") { $0.packet.rssiDB }) { Text(String(format: "%.0f", $0.packet.rssiDB)).monospacedDigit() }.width(40)
            TableColumn("Daten") { Text($0.hex).font(.caption.monospaced()).foregroundStyle(.secondary) }
        }
        .overlay {
            if visibleLog.isEmpty {
                ContentUnavailableView("Keine Pakete", systemImage: "list.bullet.rectangle",
                                       description: Text("Hier erscheint jedes Paket mit gültiger Prüfsumme."))
            }
        }
    }

    // MARK: - Einzelheiten

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let device = model.devices.first(where: { $0.id == selectedDevice }) {
                    deviceDetail(device)
                } else if let line = visibleLog.first(where: { $0.id == selectedPacket }) {
                    packetDetail(line)
                } else {
                    Text("Gerät oder Paket wählen, um die Einzelheiten zu sehen.").foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func deviceDetail(_ device: BLEDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(device.name ?? device.kind ?? device.address.string).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Adresse", "\(device.address.string) (\(device.address.kind))")
                if let kind = device.kind { row("Gerät", kind) }
                if let company = device.company { row("Hersteller", company) }
                row("Werbung", device.connectable ? String(localized: "\(device.lastType.meaning), verbindbar") : device.lastType.meaning)
                row("Kanäle", device.channels.sorted().map(String.init).joined(separator: ", "))
                row("Pegel", String(format: "%.1f dBFS", device.rssiDB))
                row("Rahmen", "\(device.count)")
                row("Zuerst gesehen", device.firstSeen.formatted(date: .omitted, time: .standard))
            }
            .font(.callout)
            if !device.readings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(device.readings, id: \.self) { reading in
                        HStack(alignment: .firstTextBaseline) {
                            Text(reading.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(reading.value).textSelection(.enabled)
                        }
                        .font(.callout)
                    }
                }
                .padding(8)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            fieldList(device.fields)
        }
    }

    private func packetDetail(_ line: BLELogLine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(line.advertisement?.type.meaning ?? String(localized: "Unbekannter Pakettyp")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Kanal", "\(line.packet.channel) (\(Int(BLELink.frequencyMHz(channel: line.packet.channel))) MHz)")
                if let address = line.advertisement?.address { row("Absender", "\(address.string) (\(address.kind))") }
                if let target = line.advertisement?.target { row("Ziel", "\(target.string) (\(target.kind))") }
                row("Länge", String(localized: "\(line.packet.pdu.count - 2) Byte"))
                row("Pegel", String(format: "%.1f dBFS", line.packet.rssiDB))
                row("Frequenzablage", String(format: "%+.0f kHz", line.packet.offsetKHz))
            }
            .font(.callout)
            if let ad = line.advertisement { fieldList(ad.fields) }
            Text("PDU").font(.subheadline.weight(.semibold))
            Text(line.hex).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func fieldList(_ fields: [BLEADField]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !fields.isEmpty { Text("Werbedaten").font(.subheadline.weight(.semibold)) }
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: 1) {
                    Text(field.typeName).font(.caption.weight(.medium))
                    Text(field.hex).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
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
            Section("Werbekanal") {
                Picker("Kanal", selection: $model.choice) {
                    ForEach(BLEModel.ChannelChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: model.choice) { _, _ in model.choiceChanged() }
                Text("Geräte senden auf allen drei Kanälen kurz nacheinander – ein Kanal genügt meist.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Kanal 38 liegt zwischen WLAN-Kanal 1 und 6, Kanal 39 über allen WLAN-Kanälen – dort stört WLAN am wenigsten.")
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Geräte", value: "\(model.devices.count)")
                LabeledContent("Rahmen", value: "\(model.packetCount)")
                LabeledContent("Prüfsummenfehler (CRC)", value: "\(model.crcErrors)")
                if model.running {
                    // Nur beim Wechseln neu – ein fester Kanal steht schon oben.
                    if model.choice == .hop {
                        LabeledContent("Aktueller Kanal", value: "\(model.channel)")
                    }
                    LabeledContent("Rauschen", value: String(format: "%.1f dBFS", model.noiseDB))
                }
            }
            Section(PanelSection.anzeige) {
                Toggle("Scan-Anfragen zeigen", isOn: $model.showRequests)
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "ble-geraete", isEmpty: model.devices.isEmpty) { csvDocument() }
            }
            Section(PanelSection.hinweis) {
                Text("Du siehst nur Werbepakete, keine Verbindungen. Graue Adressen wechseln regelmäßig – dasselbe Gerät kann dann mehrfach erscheinen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Verbindungen springen über 37 Kanäle und lassen sich so nicht verfolgen.")
            }
        }
        .formStyle(.grouped)
    }
}

extension BLEView {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["adresse", "zufaellige_adresse", "name", "geraet", "hersteller", "werte", "kanaele", "verbindbar",
                             "pegel_db", "rahmen", "erste", "letzte"],
                    rows: model.devices.map { d in
                        [.text(d.address.string), .flag(d.address.random), .text(d.name), .text(d.kind), .text(d.company),
                         .text(d.readings.map { "\($0.label) \($0.value)" }.joined(separator: ", ")),
                         .text(d.channels.sorted().map(String.init).joined(separator: " ")), .flag(d.connectable),
                         .number(d.rssiDB), .integer(d.count), .date(d.firstSeen), .date(d.lastSeen)]
                    })
    }
}
