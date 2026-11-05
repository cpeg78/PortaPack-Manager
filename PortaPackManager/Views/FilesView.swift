import AppKit
import SwiftUI

struct FilesView: View {
    @StoredColumns("files.1") private var columns: TableColumnCustomization<SDEntry>
    @Environment(DeviceSession.self) private var session
    @State private var path = "/"
    @State private var entries: [SDEntry] = []
    @State private var selection: SDEntry.ID?
    @State private var order: [ColumnSort<SDEntry>] = []
    @State private var loading = false
    @State private var error: String?
    /// Übertragungen leben außerhalb der Seite – sie überstehen einen Seitenwechsel.
    private var transfers: SDTransfer { .shared }
    @State private var newFolderName = ""
    @State private var showingNewFolder = false
    @State private var confirmDelete: SDEntry?
    @AppStorage("hideMacMetadata") private var hideMetadata = true

    var body: some View {
        if session.device == nil {
            MayhemRequiredView(systemImage: "sdcard",
                               text: "Die SD-Karte ist hier nur im Mayhem-Modus erreichbar.")
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider()
                Table(visibleEntries, selection: $selection, sortOrder: $order, columnCustomization: $columns) {
                    TableColumn("Name", sortUsing: ColumnSort("name", text: { $0.name })) { entry in
                        HStack {
                            Label(entry.name, systemImage: entry.isDirectory ? "folder" : icon(for: entry.name))
                            // „filesize“ ist der längste Befehl, den Laden und Löschen brauchen.
                            if let reason = MayhemDevice.shellProblem(command: "filesize", path: entry.path) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help("Über die USB-Verbindung nicht erreichbar: \(reason). Benenne die Datei am Gerät um oder öffne die SD-Karte als Laufwerk (Übersicht › „SD-Karte als Laufwerk“).")
                            }
                        }
                    }.customizationID("name")
                    TableColumn("Art", sortUsing: ColumnSort("art", text: { $0.isDirectory ? "" : ($0.name as NSString).pathExtension })) { entry in
                        Text(entry.isDirectory ? "Ordner" : (entry.name as NSString).pathExtension.uppercased())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 48, ideal: 80).customizationID("art")
                }
                .contextMenu(forSelectionType: SDEntry.ID.self) { ids in
                    if let entry = entries.first(where: { ids.contains($0.id) }) {
                        if entry.isDirectory {
                            Button("Öffnen") { open(entry) }
                        } else {
                            Button("Auf den Mac laden …") { download(entry) }
                                .disabled(transfers.isRunning)
                        }
                        Divider()
                        // Während einer Übertragung nichts löschen – eine offene Datei zu
                        // löschen verklemmt den Dateizugriff des Geräts.
                        Button("Löschen …", role: .destructive) { confirmDelete = entry }
                            .disabled(transfers.isRunning)
                    }
                } primaryAction: { ids in
                    if let entry = entries.first(where: { ids.contains($0.id) }) {
                        entry.isDirectory ? open(entry) : download(entry)
                    }
                }
                .onDeleteCommand {
                    if !transfers.isRunning, let entry = entries.first(where: { $0.id == selection }) { confirmDelete = entry }
                }
                .overlay { if loading { ProgressView() } }
                if let progress = transfers.progress {
                    Divider()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(progress.title).font(.callout.monospacedDigit())
                            ProgressView(value: progress.fraction)
                        }
                        Button("Abbrechen") { transfers.cancel() }
                    }
                    .padding(10)
                }
                if let message = error ?? transfers.message {
                    Divider()
                    Text(message).foregroundStyle(.red).font(.callout).padding(8)
                }
            }
            .task(id: path) { await reload() }
            .onChange(of: transfers.finished) { _, _ in
                // Nach dem Senden den Ordner neu lesen – auch wenn die Seite zwischendurch weg war.
                if transfers.lastDirectory == path { Task { await reload() } }
            }
            .alert("Neuer Ordner", isPresented: $showingNewFolder) {
                TextField("Name", text: $newFolderName)
                Button("Anlegen") { createFolder() }
                Button("Abbrechen", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                presenting: confirmDelete) { entry in
                Button("Löschen", role: .destructive) { delete(entry) }
            } message: { entry in
                Text(entry.isDirectory ? "Nur leere Ordner lassen sich löschen." : "Die Datei wird von der SD-Karte entfernt.")
            }
        }
    }

    private var deleteTitle: String {
        String(localized: "„\(confirmDelete?.name ?? "")“ löschen?")
    }

    private var visibleEntries: [SDEntry] {
        let filtered = hideMetadata
            ? entries.filter { !$0.name.hasPrefix("._") && ![".Spotlight-V100", ".Trashes", ".fseventsd", ".DS_Store"].contains($0.name) }
            : entries
        // Ordner bleiben in jeder Sortierung oben.
        return filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            for comparator in order {
                let result = comparator.compare(a, b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var toolbar: some View {
        HStack {
            Button {
                path = (path as NSString).deletingLastPathComponent
                if path.isEmpty { path = "/" }
            } label: { Image(systemName: "chevron.up") }
                .disabled(path == "/")
                .help("Übergeordneter Ordner")
                .accessibilityLabel("Übergeordneter Ordner")
            Text(path).font(.body.monospaced()).lineLimit(1).truncationMode(.head)
            Spacer()
            Toggle("Mac-Metadaten ausblenden", isOn: $hideMetadata).toggleStyle(.checkbox)
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Neu laden")
                .accessibilityLabel("Neu laden")
            Button { showingNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help("Neuer Ordner")
                .accessibilityLabel("Neuer Ordner")
            Button { upload() } label: { Label("Hochladen …", systemImage: "square.and.arrow.up") }
        }
        .padding(10)
        .disabled(transfers.isRunning)
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "ppma", "ppmp": "app"
        case "png", "bmp": "photo"
        case "wav": "waveform"
        case "c8", "c16", "cu8", "cs8", "cs16": "dot.radiowaves.left.and.right"
        case "txt", "ini", "csv", "log": "doc.text"
        case "bin", "tar": "shippingbox"
        default: "doc"
        }
    }

    private func open(_ entry: SDEntry) {
        path = entry.path
    }

    private func reload() async {
        guard let device = session.device else { return }
        loading = true
        defer { loading = false }
        do {
            entries = try await device.list(path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func download(_ entry: SDEntry) {
        guard let device = session.device, !transfers.isRunning else { return }
        Task {
            guard let url = await SaveSheet.url(name: entry.name) else { return }
            error = nil
            transfers.download(entry, from: device, to: url)
        }
    }

    private func upload() {
        guard let device = session.device, !transfers.isRunning else { return }
        let target = path
        Task {
            let urls = await SaveSheet.open(multiple: true)
            guard !urls.isEmpty else { return }
            error = nil
            transfers.upload(urls, to: target, on: device)
        }
    }

    private func createFolder() {
        guard let device = session.device, !newFolderName.isEmpty else { return }
        let target = (path == "/" ? "" : path) + "/" + newFolderName
        newFolderName = ""
        Task {
            do {
                try await device.makeDirectory(target)
                await reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func delete(_ entry: SDEntry) {
        guard let device = session.device, !transfers.isRunning else { return }
        Task {
            do {
                try await device.remove(entry.path)
                await reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
