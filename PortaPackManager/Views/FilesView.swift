import AppKit
import SwiftUI

struct FilesView: View {
    @Environment(DeviceSession.self) private var session
    @State private var path = "/"
    @State private var entries: [SDEntry] = []
    @State private var selection: SDEntry.ID?
    @State private var order: [ColumnSort<SDEntry>] = []
    @State private var loading = false
    @State private var error: String?
    @State private var transfer: (title: String, fraction: Double)?
    /// Laufende Übertragung – „Abbrechen“ bricht sie ab (das Gerät prüft je Paket).
    @State private var transferTask: Task<Void, Never>?
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
                Table(visibleEntries, selection: $selection, sortOrder: $order) {
                    TableColumn("Name", sortUsing: ColumnSort("name", text: { $0.name })) { entry in
                        HStack {
                            Label(entry.name, systemImage: entry.isDirectory ? "folder" : icon(for: entry.name))
                            // „filesize“ ist der längste Befehl, den Laden und Löschen brauchen.
                            if let reason = MayhemDevice.shellProblem(command: "filesize", path: entry.path) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help("Über die USB-Verbindung nicht erreichbar: \(reason). Benenne die Datei am Gerät um oder öffne die SD-Karte als Laufwerk (Übersicht › „SD-Karte als Laufwerk“).")
                            }
                        }
                    }
                    TableColumn("Art", sortUsing: ColumnSort("art", text: { $0.isDirectory ? "" : ($0.name as NSString).pathExtension })) { entry in
                        Text(entry.isDirectory ? "Ordner" : (entry.name as NSString).pathExtension.uppercased())
                            .foregroundStyle(.secondary)
                    }
                    .width(80)
                }
                .contextMenu(forSelectionType: SDEntry.ID.self) { ids in
                    if let entry = entries.first(where: { ids.contains($0.id) }) {
                        if entry.isDirectory {
                            Button("Öffnen") { open(entry) }
                        } else {
                            Button("Auf den Mac laden …") { download(entry) }
                        }
                        Divider()
                        Button("Löschen …", role: .destructive) { confirmDelete = entry }
                    }
                } primaryAction: { ids in
                    if let entry = entries.first(where: { ids.contains($0.id) }) {
                        entry.isDirectory ? open(entry) : download(entry)
                    }
                }
                .onDeleteCommand {
                    if transfer == nil, let entry = entries.first(where: { $0.id == selection }) { confirmDelete = entry }
                }
                .overlay { if loading { ProgressView() } }
                if let transfer {
                    Divider()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transfer.title).font(.callout.monospacedDigit())
                            ProgressView(value: transfer.fraction)
                        }
                        Button("Abbrechen") { transferTask?.cancel() }
                            .disabled(transferTask == nil)
                    }
                    .padding(10)
                }
                if let error {
                    Divider()
                    Text(error).foregroundStyle(.red).font(.callout).padding(8)
                }
            }
            .task(id: path) { await reload() }
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
        .disabled(transfer != nil)
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
        guard let device = session.device, transfer == nil else { return }
        Task {
            guard let url = await SaveSheet.url(name: entry.name) else { return }
            transferTask = Task {
                transfer = (String(localized: "Lade \(entry.name)"), 0)
                defer { transfer = nil; transferTask = nil }
                do {
                    let started = Date()
                    let data = try await device.download(entry.path) { done, total in
                        let title = String(localized: "Lade \(entry.name): \(Self.rate(done, total, since: started))")
                        Task { @MainActor in if transfer != nil { transfer = (title, Double(done) / Double(max(total, 1))) } }
                    }
                    try data.write(to: url)
                    error = nil
                } catch is CancellationError {
                    error = String(localized: "Abgebrochen – \(entry.name) wurde nicht gesichert.")
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func upload() {
        guard let device = session.device, transfer == nil else { return }
        let target = path
        Task {
            let urls = await SaveSheet.open(multiple: true)
            guard !urls.isEmpty else { return }
            transferTask = Task {
                defer { transfer = nil; transferTask = nil }
                for url in urls {
                    let remote = (target == "/" ? "" : target) + "/" + url.lastPathComponent
                    var partial = false
                    do {
                        // Zwischen zwei Dateien abbrechen hinterlässt nichts Halbes.
                        try Task.checkCancellation()
                        let data = try Data(contentsOf: url)
                        transfer = (String(localized: "Sende \(url.lastPathComponent)"), 0)
                        let started = Date()
                        partial = true
                        try await device.upload(data, to: remote) { done, total in
                            let title = String(localized: "Sende \(url.lastPathComponent): \(Self.rate(done, total, since: started))")
                            Task { @MainActor in if transfer != nil { transfer = (title, Double(done) / Double(max(total, 1))) } }
                        }
                        partial = false
                        transfer = (String(localized: "Prüfe \(url.lastPathComponent) …"), 1)
                        let crc = try await device.crc32(remote)
                        if crc != MayhemCRC32.checksum(data) {
                            throw MayhemError.checksumMismatch(expected: MayhemCRC32.checksum(data), actual: crc)
                        }
                        error = nil
                    } catch is CancellationError {
                        // Mitten in der Datei abgebrochen: das halbe Stück wieder entfernen
                        // (`upload` hat die Datei schon geschlossen).
                        if partial { try? await device.remove(remote) }
                        error = String(localized: "Abgebrochen – \(url.lastPathComponent) und alle folgenden Dateien wurden nicht übertragen.")
                        break
                    } catch {
                        self.error = "\(url.lastPathComponent): \(error.localizedDescription)"
                        break
                    }
                }
                await reload()
            }
        }
    }

    nonisolated static func rate(_ done: Int, _ total: Int, since start: Date) -> String {
        let elapsed = Date().timeIntervalSince(start)
        let speed = elapsed > 0.3 ? Double(done) / elapsed : 0
        let amount = FirmwareInstaller.ofTotal(Int64(done), Int64(total))
        guard speed > 0 else { return amount }
        return String(localized: "\(amount) · \(FirmwareInstaller.format(Int64(speed)))/s · noch \(FirmwareInstaller.duration(Double(total - done) / speed))")
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
        guard let device = session.device else { return }
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
