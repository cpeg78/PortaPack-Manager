import SwiftUI
import UniformTypeIdentifiers

/// „Liste als CSV sichern …“ für die Live-Listen, im Abschnitt „Daten & Export“.
///
/// Ablauf: erst der Sichern-Dialog (`SaveSheet`), dann der Schnappschuss der
/// Zeilen auf dem Main Actor (`document` – nur Felder auslesen), Text und
/// Schreiben im Hintergrund. Bei großen Listen (Tausende Zeilen) blockiert so
/// nur das Auslesen, nicht das Zusammensetzen und die Platte.
struct CSVExportButton: View {
    var title: LocalizedStringKey = "Liste als CSV sichern …"
    let fileName: String
    let isEmpty: Bool
    let document: @MainActor () -> CSVDocument

    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(title) { Task { await save() } }
                    .disabled(isEmpty || busy)
                    .help("Speichert die Liste als CSV (Semikolon, UTF-8) für Excel, Numbers oder LibreOffice.")
                if busy { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
            }
        }
    }

    private func save() async {
        guard let url = await SaveSheet.url(name: CSVDocument.fileName(fileName), types: [.commaSeparatedText]) else { return }
        busy = true
        message = nil
        let doc = document()
        let result = await Task.detached { () -> Result<Int, Error> in
            Result {
                try doc.data().write(to: url, options: .atomic)
                return doc.rows.count
            }
        }.value
        busy = false
        switch result {
        case .success(let rows):
            failed = false
            message = String(localized: "\(rows) Zeilen gesichert: \(url.lastPathComponent)")
        case .failure(let error):
            failed = true
            message = error.localizedDescription
        }
    }
}
