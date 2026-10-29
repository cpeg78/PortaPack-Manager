import SwiftUI

struct SensorView: View {
    @Environment(DeviceSession.self) private var session
    /// Geteilt mit dem Fernzugriff (`RemoteHub.sensors`).
    @Bindable private var model = RemoteHub.shared.sensors
    @State private var selectedSensor: SensorDevice.ID?
    @State private var selectedPacket: SensorPacket.ID?
    @State private var sensorOrder: [ColumnSort<SensorDevice>] = []
    @State private var packetOrder: [ColumnSort<SensorPacket>] = []
    @State private var query = ""
    /// Wie auf der Handy-Seite: Reifendrucksensoren vorbeifahrender Autos ausblenden.
    @AppStorage("sensorHideTPMS") private var hideTPMS = true
    @AppStorage("sensorSort") private var storedSort = SensorSort.lastSeen.rawValue

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "sensor", text: "Funksensoren (Wetterstationen, Thermometer) auf 433 und 868 MHz dekodiert die App selbst. Dafür muss das PortaPack im HackRF-Modus laufen.")
        } else {
            ControlsSplit(width: 280, issue: model.error) {
                VSplitView {
                    sensorTable.frame(minHeight: 180)
                    HSplitView {
                        packetTable.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                        packetDetail.frame(minWidth: 240, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: 200)
                }
                // Mindestbreite über der Summe der inneren Spalten (300 + 240 + Trenner):
                // lag sie darunter, rechnete AppKit die Constraints endlos neu und die
                // App stürzte beim Öffnen der Seite ab (27.10.2026).
                .frame(minWidth: 600)
            } controls: {
                controls
            }
            .onAppear { if sensorOrder.isEmpty { sensorOrder = (SensorSort(rawValue: storedSort) ?? .lastSeen).order } }
            .task { if AppNavigation.shared.takeAutoStart(.sensors), !model.running { ReceiverStore.shared.requestStart(model, session: session) { device in model.start(on: device) } } }
            .onChange(of: session.mode) { _, mode in
                if mode != .hackRF { model.stop() }
            }
        }
    }

    // MARK: - Sensoren

    /// Sortierung wie auf der Handy-Seite; ein Klick in einen Spaltenkopf
    /// sortiert weiterhin nach jeder Spalte.
    enum SensorSort: String, CaseIterable, Identifiable {
        case lastSeen = "last", name, temperature = "temp"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .lastSeen: String(localized: "Zuletzt gehört")
            case .name: String(localized: "Name")
            case .temperature: String(localized: "Temperatur")
            }
        }
        var order: [ColumnSort<SensorDevice>] {
            switch self {
            case .lastSeen:
                var sort = ColumnSort<SensorDevice>("zuletzt") { $0.lastSeen }
                sort.order = .reverse
                return [sort]
            case .name:
                return [ColumnSort("modell", text: { MQTTFeeds.name(of: $0) })]
            case .temperature:
                var sort = ColumnSort<SensorDevice>("temperatur") { $0.latest.temperatureC }
                sort.order = .reverse
                return [sort]
            }
        }
    }

    private var sortBinding: Binding<SensorSort?> {
        Binding(get: { SensorSort.allCases.first { $0.order == sensorOrder } },
                set: { if let sort = $0 { sensorOrder = sort.order; storedSort = sort.rawValue } })
    }

    /// Nach TPMS-Filter und Suche (Name, Modell, ID, Kanal, Werte).
    private var visibleSensors: [SensorDevice] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.sensors.filter { sensor in
            if hideTPMS, MQTTFeeds.isTPMS(sensor) { return false }
            guard !needle.isEmpty else { return true }
            let r = sensor.latest
            let haystack = [MQTTFeeds.name(of: sensor), r.model, "ID \(r.id)",
                            r.temperatureC.map { String(format: "%.1f °C", $0) } ?? "",
                            r.humidity.map { "\($0) %" } ?? "", wind(r), more(r)]
            return haystack.joined(separator: " ").lowercased().contains(needle)
        }
    }

    private var sensorTable: some View {
        Table(of: SensorDevice.self, selection: $selectedSensor, sortOrder: $sensorOrder) {
            // Mehr als zehn Spalten nur in Gruppen
            Group {
            TableColumn("Modell", sortUsing: ColumnSort("modell", text: { $0.latest.model })) { (sensor: SensorDevice) in Text(sensor.latest.model) }
            TableColumn("ID", sortUsing: ColumnSort("id", text: { $0.latest.id })) { (sensor: SensorDevice) in Text(sensor.latest.id).font(.body.monospaced()) }.width(70)
            TableColumn("Kanal", sortUsing: ColumnSort("kanal") { $0.latest.channel }) { (sensor: SensorDevice) in Text(sensor.latest.channel.map(String.init) ?? "–") }.width(45)
            TableColumn("Temperatur", sortUsing: ColumnSort("temperatur") { $0.latest.temperatureC }) { (sensor: SensorDevice) in
                Text(sensor.latest.temperatureC.map { String(format: "%.1f °C", $0) } ?? "–").monospacedDigit()
            }.width(80)
            TableColumn("Feuchte", sortUsing: ColumnSort("feuchte") { $0.latest.humidity }) { (sensor: SensorDevice) in
                Text(sensor.latest.humidity.map { "\($0) %" } ?? "–").monospacedDigit()
            }.width(60)
            TableColumn("Wind", sortUsing: ColumnSort("wind") { $0.latest.windAverageMS ?? $0.latest.windGustMS }) { (sensor: SensorDevice) in Text(wind(sensor.latest)).monospacedDigit() }.width(120)
            TableColumn("Regen", sortUsing: ColumnSort("regen") { $0.latest.rainMM }) { (sensor: SensorDevice) in
                Text(sensor.latest.rainMM.map { String(format: "%.1f mm", $0) } ?? "–").monospacedDigit()
            }.width(70)
            }
            Group {
            TableColumn("Weitere", sortUsing: ColumnSort("weitere", text: { more($0.latest) })) { (sensor: SensorDevice) in Text(more(sensor.latest)).foregroundStyle(.secondary) }
            TableColumn("Batterie", sortUsing: ColumnSort("batterie") { $0.latest.batteryOK.map { $0 ? 1 : 0 } }) { (sensor: SensorDevice) in battery(sensor.latest.batteryOK) }.width(55)
            TableColumn("Pegel", sortUsing: ColumnSort("pegel") { $0.snrDB }) { (sensor: SensorDevice) in
                Text(String(format: "%.0f dB", sensor.snrDB)).monospacedDigit()
                    .help(String(format: String(localized: "%.1f dBFS, Störabstand %.1f dB, Ablage %+.0f kHz"), sensor.rssiDB, sensor.snrDB, sensor.offsetKHz))
            }.width(50)
            TableColumn("Zuletzt", sortUsing: ColumnSort("zuletzt") { $0.lastSeen }) { (sensor: SensorDevice) in Text(sensor.lastSeen, style: .relative).foregroundStyle(.secondary) }.width(90)
            TableColumn("Anzahl", sortUsing: ColumnSort("anzahl") { $0.count }) { (sensor: SensorDevice) in Text("\(sensor.count)").monospacedDigit() }.width(50)
            }
        } rows: {
            ForEach(visibleSensors.sorted(by: sensorOrder)) { TableRow($0) }
        }
        .overlay {
            if model.sensors.isEmpty {
                ContentUnavailableView("Keine Sensoren", systemImage: "thermometer.medium",
                                       description: Text(model.running
                                                         ? "Noch nichts erkannt. Viele Sensoren senden nur alle 30 bis 60 Sekunden. Unbekannte Pakete erscheinen unten."
                                                         : "Mit „Start“ beginnt der Empfang."))
            } else if visibleSensors.isEmpty {
                ContentUnavailableView("Keine Sensoren", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                                                         ? "Bisher nur Reifendrucksensoren gehört (\(model.sensors.filter(MQTTFeeds.isTPMS).count)). Um sie zu sehen, schalte unter „Anzeige“ „Reifendruck (TPMS) ausblenden“ aus."
                                                         : "Kein Sensor passt zur Suche."))
            }
        }
    }

    // MARK: - Pakete

    private var visiblePackets: [SensorPacket] {
        model.showUnknown ? model.packets : model.packets.filter { !$0.readings.isEmpty }
    }

    private var packetTable: some View {
        Table(visiblePackets.sorted(by: packetOrder), selection: $selectedPacket, sortOrder: $packetOrder) {
            TableColumn("Zeit", sortUsing: ColumnSort("zeit") { $0.id }) { Text($0.train.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(65)
            TableColumn("Art", sortUsing: ColumnSort("art", text: { $0.train.modulation.rawValue })) { Text($0.train.modulation.rawValue) }.width(35)
            TableColumn("Pulse", sortUsing: ColumnSort("pulse") { $0.train.count }) { Text("\($0.train.count)").monospacedDigit() }.width(45)
            TableColumn("Inhalt", sortUsing: ColumnSort("inhalt", text: { $0.readings.first.map { "\($0.model) \($0.id)" } ?? $0.analysis.coding.title })) { packet in
                if let reading = packet.readings.first {
                    Text("\(reading.model) \(reading.id)").fontWeight(.medium)
                } else {
                    Text(packet.analysis.coding.title).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if visiblePackets.isEmpty {
                ContentUnavailableView("Keine Pakete", systemImage: "waveform",
                                       description: Text("Hier erscheint jedes empfangene Paket – auch von Geräten, die die App nicht kennt."))
            }
        }
    }

    private var packetDetail: some View {
        ScrollView {
            if let packet = visiblePackets.first(where: { $0.id == selectedPacket }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(packet.analysis.summary).font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        GridRow { Text("Frequenz").foregroundStyle(.secondary); Text(String(format: "%.3f MHz %+.1f kHz", packet.frequencyMHz, packet.train.offsetKHz)) }
                        if packet.train.modulation == .fsk {
                            GridRow { Text("Hub").foregroundStyle(.secondary); Text(String(format: "%.0f kHz", packet.train.deviationKHz)) }
                        }
                        GridRow { Text("Pegel").foregroundStyle(.secondary); Text(String(format: String(localized: "%.1f dBFS, Störabstand %.1f dB"), packet.train.rssiDB, packet.train.snrDB)) }
                        GridRow { Text("Dauer").foregroundStyle(.secondary); Text(String(format: String(localized: "%.1f ms, %d Pulse"), Double(packet.train.durationMicroseconds) / 1000, packet.train.count)) }
                    }
                    .font(.callout)
                    ForEach(Array(packet.readings.enumerated()), id: \.offset) { _, reading in
                        readingBox(reading)
                    }
                    binTable("Pulsbreiten", packet.analysis.pulses)
                    binTable("Pausen", packet.analysis.gaps)
                    if !packet.analysis.rows.isEmpty {
                        Text("Bits").font(.subheadline.weight(.semibold))
                        Text(packet.analysis.rows.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Text("Rohdaten (Puls/Pause µs)").font(.subheadline.weight(.semibold))
                    Text(zip(packet.train.pulses, packet.train.gaps).prefix(200).map { "\($0)/\($1)" }.joined(separator: " "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Paket wählen, um die Pulsanalyse zu sehen.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }

    private func readingBox(_ reading: SensorReading) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if let channel = reading.channel {
                    Text("\(reading.model) · ID \(reading.id) · Kanal \(channel)")
                } else {
                    Text("\(reading.model) · ID \(reading.id)")
                }
            }
            .font(.callout.weight(.semibold))
            let values = [reading.temperatureC.map { String(format: "%.1f °C", $0) },
                          reading.humidity.map { String(localized: "\($0) % rF") },
                          wind(reading) == "–" ? nil : wind(reading),
                          reading.rainMM.map { String(format: String(localized: "Regen %.1f mm"), $0) },
                          more(reading).isEmpty ? nil : more(reading)].compactMap { $0 }
            Text(values.joined(separator: " · ")).font(.callout)
            Text("Absicherung: \(reading.integrity)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func binTable(_ title: LocalizedStringKey, _ bins: [SensorPulseAnalysis.Bin]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(Array(bins.prefix(8).enumerated()), id: \.offset) { _, bin in
                Text("\(bin.mean) µs (\(bin.min)–\(bin.max)) × \(bin.count)")
                    .font(.caption.monospacedDigit())
            }
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
            Section("Frequenz") {
                Picker("Band", selection: Binding(
                    get: { SensorModel.Band.allCases.first { abs($0.frequencyMHz - model.frequencyMHz) < 0.001 } },
                    set: { if let band = $0 { model.tune(to: band.frequencyMHz) } })) {
                    ForEach(SensorModel.Band.allCases) { Text($0.title).tag(Optional($0)) }
                    if !SensorModel.Band.allCases.contains(where: { abs($0.frequencyMHz - model.frequencyMHz) < 0.001 }) {
                        Text("Eigene").tag(SensorModel.Band?.none)
                    }
                }
                .pickerStyle(.radioGroup)
                LabeledContent("MHz") {
                    FrequencyField(mhz: model.frequencyMHz, width: 90) { model.tune(to: $0) }
                }
                Text("433,92 MHz: einfache Thermometer (Nexus, LaCrosse TX141, inFactory). 868,3 MHz: Bresser-Wetterstationen, LaCrosse/TFA IT+.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Die App wertet ±190 kHz um die eingestellte Frequenz aus.")
            }
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Sensoren", value: "\(model.sensors.count)")
                LabeledContent("Rahmen", value: "\(model.packetCount)")
                LabeledContent("Davon erkannt", value: "\(model.decodedCount)")
                if model.running {
                    LabeledContent("Rauschen", value: String(format: "%.1f dBFS", model.noiseDB))
                }
            }
            FrequencyMemorySection(page: .sensors, currentMHz: model.frequencyMHz) { model.tune(to: $0.mhz) }
            Section(PanelSection.anzeige) {
                TextField("Suchen", text: $query, prompt: Text("Modell, ID, Wert"))
                Picker("Sortierung", selection: sortBinding) {
                    ForEach(SensorSort.allCases) { Text($0.title).tag(Optional($0)) }
                    if sortBinding.wrappedValue == nil {
                        Text("Nach Spalte").tag(SensorSort?.none)
                    }
                }
                Toggle("Reifendruck (TPMS) ausblenden", isOn: $hideTPMS)
                Toggle("Unbekannte Pakete zeigen", isOn: $model.showUnknown)
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "funksensoren", isEmpty: model.sensors.isEmpty) { csvDocument() }
            }
            Section("Bekannte Sensoren") {
                ForEach(SensorDecoders.all, id: \.name) { decoder in
                    HStack {
                        Text(decoder.name).font(.caption)
                        Spacer()
                        Text(decoder.modulation.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Formatierung

    private func wind(_ reading: SensorReading) -> String {
        guard reading.windAverageMS != nil || reading.windGustMS != nil else { return "–" }
        var parts: [String] = []
        if let average = reading.windAverageMS { parts.append(String(format: "%.1f", average)) }
        if let gust = reading.windGustMS { parts.append(String(format: String(localized: "Böe %.1f"), gust)) }
        var text = parts.joined(separator: " / ") + " m/s"
        if let direction = reading.windDirection { text += String(format: " %.0f°", direction) }
        return text
    }

    private func more(_ reading: SensorReading) -> String {
        var parts = reading.extra.sorted { $0.key < $1.key }.map { "\(SensorReading.extraLabel($0.key)) \($0.value)" }
        if let uv = reading.uvIndex { parts.insert(String(format: "UV %.1f", uv), at: 0) }
        if let lux = reading.lightLux { parts.insert(String(format: "%.0f lx", lux), at: 0) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func battery(_ ok: Bool?) -> some View {
        switch ok {
        case true?: Image(systemName: "battery.100").foregroundStyle(.green).help("Batterie in Ordnung")
        case false?: Image(systemName: "battery.25").foregroundStyle(.red).help("Batterie schwach")
        case nil: Text("–").foregroundStyle(.secondary)
        }
    }
}

extension SensorView {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["modell", "id", "kanal", "temperatur_c", "feuchte_prozent", "wind_mittel_ms", "wind_boee_ms",
                             "wind_richtung_grad", "regen_mm", "uv_index", "licht_lux", "weitere", "batterie_ok", "frequenz_mhz",
                             "pegel_db", "snr_db", "anzahl", "erste", "letzte", "pruefung"],
                    rows: model.sensors.map { s in
                        let r = s.latest
                        let extra = r.extra.sorted { $0.key < $1.key }.map { "\(SensorReading.extraLabel($0.key)) \($0.value)" }
                        return [.text(r.model), .text(r.id), .integer(r.channel), .number(r.temperatureC), .integer(r.humidity),
                                .number(r.windAverageMS), .number(r.windGustMS), .number(r.windDirection, digits: 0), .number(r.rainMM),
                                .number(r.uvIndex), .number(r.lightLux, digits: 0), .text(extra.joined(separator: ", ")), .flag(r.batteryOK),
                                .number(s.frequencyMHz, digits: 3), .number(s.rssiDB), .number(s.snrDB), .integer(s.count),
                                .date(s.firstSeen), .date(s.lastSeen), .text(r.integrity)]
                    })
    }
}
