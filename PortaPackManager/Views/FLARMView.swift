import SwiftUI

struct FLARMView: View {
    @Environment(DeviceSession.self) private var session
    /// Lebt im `ReceiverStore` – überlebt den Seitenwechsel samt laufendem Empfang.
    @Bindable private var model = ReceiverStore.shared.flarm

    var body: some View {
        if session.mode != .hackRF || session.hackRF == nil {
            HackRFRequiredView(systemImage: "airplane", text: String(localized: "Die App empfängt FLARM/OGN (Kollisionswarnung im Segelflug) auf 868,2 MHz selbst – dafür muss das PortaPack im HackRF-Modus laufen."))
        } else {
            ControlsSplit(width: 300, issue: model.error) {
                table.frame(minWidth: 460)
            } controls: {
                controls
            }
            .onChange(of: session.mode) { _, mode in if mode != .hackRF { model.stop() } }
        }
    }

    private var table: some View {
        Table(model.detections) {
            TableColumn("Zeit") { Text($0.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(64)
            TableColumn("Prüfsumme") { d in
                Image(systemName: d.crcValid ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(d.crcValid ? .green : .secondary)
            }.width(40)
            TableColumn("Pegel") { Text(String(format: "%.0f dBFS", $0.rssiDB)).monospacedDigit() }.width(70)
            TableColumn("Rohdaten (verschlüsselt)") { Text($0.hex).font(.caption.monospaced()).lineLimit(1) }
        }
        .overlay {
            if model.detections.isEmpty {
                ContentUnavailableView("Keine Rahmen", systemImage: "airplane",
                                       description: Text(model.running ? "Höre auf 868,2 MHz …" : "Mit „Start“ beginnt der Empfang auf 868,2 MHz."))
            }
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
            Section(PanelSection.empfang) {
                ReceiverControls(model: model, device: session.hackRF)
            }
            Section(PanelSection.status) {
                LabeledContent("Rahmen", value: String(localized: "\(model.total) · \(model.crcValidCount) ohne Prüfsummenfehler"))
                if model.running { LabeledContent("Rauschen", value: String(format: "%.0f dBFS", model.noiseDB)) }
            }
            Section(PanelSection.daten) {
                CSVExportButton(fileName: "flarm", isEmpty: model.detections.isEmpty) { csvDocument() }
            }
            Section(PanelSection.hinweis) {
                Text("Zeigt, wann Segelflugzeuge und andere FLARM-Geräte in der Nähe funken. Ihre Position ist verschlüsselt und bleibt verborgen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Rahmen mit geprüfter Prüfsumme (CRC) auf 868,2 MHz; Rahmung und CRC nach OGN nachgebaut.")
            }
        }
        .formStyle(.grouped)
    }
}

extension FLARMView {
    func csvDocument() -> CSVDocument {
        CSVDocument(header: ["zeit", "pruefsumme_ok", "pegel_dbfs", "rohdaten_hex"],
                    rows: model.detections.map { d in
                        [.date(d.date), .flag(d.crcValid), .number(d.rssiDB, digits: 0), .text(d.hex)]
                    })
    }
}
