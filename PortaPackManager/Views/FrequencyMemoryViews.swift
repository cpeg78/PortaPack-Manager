import SwiftUI
import UniformTypeIdentifiers

extension PanelSection {
    static var speicher: String { String(localized: "Frequenzspeicher") }
}

extension FrequencyMemoryEntry {
    /// Name, sonst die Frequenz.
    var displayName: String {
        name.isEmpty ? FrequencyInput.format(mhz, decimals: mhz < 1000 ? 4 : 3) + " MHz" : name
    }

    /// Zweite Zeile: Frequenz (wenn ein Name dasteht), Ordner bzw. Funkart, Betriebsart.
    var detail: String { detail(withFrequency: !name.isEmpty) }

    func detail(withFrequency: Bool) -> String {
        var parts: [String] = []
        if withFrequency { parts.append(FrequencyInput.format(mhz, decimals: mhz < 1000 ? 4 : 3) + " MHz") }
        if !group.isEmpty { parts.append(group) }
        else if let kind { parts.append(ScanBands.all.first { $0.name == kind }?.title ?? kind) }
        if let modeTitle { parts.append(modeTitle) }
        if let bandwidthHz { parts.append(FrequencyMemoryEntry.bandwidthText(bandwidthHz)) }
        return parts.joined(separator: " · ")
    }

    /// Anzeigename der Betriebsart (unbekannte Rohwerte unverändert).
    var modeTitle: String? {
        guard let mode else { return nil }
        return radioMode?.title ?? mode
    }

    static func bandwidthText(_ hz: Int) -> String {
        hz >= 1_000_000 ? (Double(hz) / 1e6).formatted(.number.precision(.fractionLength(0...3))) + " MHz"
            : (Double(hz) / 1000).formatted(.number.precision(.fractionLength(0...2))) + " kHz"
    }
}

/// Abschnitt „Frequenzspeicher“ im Bedienfeld der Seiten mit Frequenzfeld:
/// „Merken …“ (aktuelle Frequenz/Betriebsart) und die passenden Einträge –
/// ein Klick stimmt ab. Bearbeiten, Import/Export: Einstellungen ▸ Frequenzen.
struct FrequencyMemorySection: View {
    let page: SidebarItem
    /// Aktuelle Frequenz zum Merken; `nil` = kein „Merken“ (z. B. Belegung).
    let currentMHz: Double?
    var currentMode: String? = nil
    var suggestedName: String = ""
    /// Erlaubter Bereich der Seite – Einträge außerhalb sind nicht anklickbar.
    var range: ClosedRange<Double>? = nil
    let tune: (FrequencyMemoryEntry) -> Void

    private var memory: FrequencyMemory { FrequencyMemory.shared }
    @AppStorage("frequencyMemoryShowAll") private var showAll = false
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general.rawValue
    @State private var saving = false
    @State private var editing: FrequencyMemoryEntry?
    @State private var deleting: DeleteConfirmation?

    var body: some View {
        Section(PanelSection.speicher) {
            HStack {
                if currentMHz != nil {
                    Button("Merken …") { saving = true }
                        .popover(isPresented: $saving, arrowEdge: .leading) {
                            if let currentMHz {
                                FrequencyMemorySaveForm(mhz: currentMHz, mode: currentMode, page: page, name: suggestedName) { saving = false }
                            }
                        }
                }
                Spacer()
                Picker("Anzeigen", selection: $showAll) {
                    Text("Diese Seite").tag(false)
                    Text("Alle").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            let list = memory.entries(for: page, all: showAll)
            if list.isEmpty {
                Text(showAll ? "Noch nichts gemerkt." : "Für diese Seite ist noch nichts gemerkt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(list) { entry in
                row(entry)
            }
            Button("Frequenzen verwalten …") {
                settingsTab = SettingsTab.frequencies.rawValue
                AppNavigation.shared.page = .settings
            }
            .controlSize(.small)
        }
        .sheet(item: $editing) { entry in
            FrequencyMemoryEditor(entry: entry) { editing = nil }
        }
        .deleteConfirmation($deleting)
    }

    private func row(_ entry: FrequencyMemoryEntry) -> some View {
        let usable = range.map { $0.contains(entry.mhz) } ?? true
        let current = currentMHz.map { entry.matches(mhz: $0) } ?? false
        return Button {
            tune(entry)
        } label: {
            HStack {
                Image(systemName: current ? "dot.radiowaves.left.and.right" : "bookmark")
                    .foregroundStyle(current ? Color.accentColor : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName).fontWeight(current ? .semibold : .regular)
                    let detail = entry.detail
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .help(usable ? (entry.note.isEmpty ? String(localized: "Klicken stimmt hierauf ab.") : entry.note)
                     : String(localized: "Liegt außerhalb des Bereichs dieser Seite."))
        .contextMenu {
            Button("Bearbeiten …") { editing = entry }
            Button("Im Radio hören") { FrequencyMemoryActions.listen(entry) }
            Divider()
            Button("Löschen …", role: .destructive) { deleting = FrequencyMemoryActions.confirmDelete([entry]) }
        }
    }
}

/// Gemeinsame Aktionen für Einträge.
@MainActor
enum FrequencyMemoryActions {
    /// Öffnet die Radio-Seite mit Frequenz und Betriebsart (sonst Vorschlag aus dem Band).
    static func listen(_ entry: FrequencyMemoryEntry) {
        AppNavigation.shared.openRadio(mhz: entry.mhz, mode: entry.radioMode ?? FrequencyMemory.suggestedRadioMode(mhz: entry.mhz))
    }

    static func confirmDelete(_ entries: [FrequencyMemoryEntry], memory: FrequencyMemory = .shared) -> DeleteConfirmation {
        let ids = Set(entries.map(\.id))
        let title = entries.count == 1
            ? String(localized: "„\(entries[0].displayName)“ löschen?")
            : String(localized: "\(entries.count) Einträge löschen?")
        return DeleteConfirmation(title: title,
                                  message: String(localized: "Name, Notiz und Einstellungen der Einträge gehen verloren."),
                                  action: { memory.remove(ids: ids) })
    }
}

/// Kleines Formular zum Merken der aktuellen Frequenz (Popover am Knopf).
struct FrequencyMemorySaveForm: View {
    let mhz: Double
    let mode: String?
    let page: SidebarItem
    @State var name: String
    @State private var group = ""
    let done: () -> Void

    init(mhz: Double, mode: String?, page: SidebarItem, name: String, done: @escaping () -> Void) {
        self.mhz = mhz
        self.mode = mode
        self.page = page
        _name = State(initialValue: name)
        self.done = done
    }

    var body: some View {
        let memory = FrequencyMemory.shared
        Form {
            LabeledContent("Frequenz", value: FrequencyInput.format(mhz, decimals: 4) + " MHz")
            if let mode {
                LabeledContent("Betriebsart", value: FrequencyMemory.radioMode(fromStored: mode)?.title ?? mode)
            }
            TextField("Name", text: $name, prompt: Text("optional"))
            GroupField(group: $group, groups: memory.groups)
            if let existing = memory.entry(atMHz: mhz, page: page) {
                Text("Schon gemerkt als „\(existing.displayName)“.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { done() }
                Button("Merken") {
                    var entry = FrequencyMemoryEntry(mhz: mhz, name: name.trimmingCharacters(in: .whitespaces), mode: mode, page: page)
                    entry.group = group.trimmingCharacters(in: .whitespaces)
                    memory.add(entry)
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
    }
}

/// Ordnerfeld mit Auswahl der vorhandenen Ordner.
private struct GroupField: View {
    @Binding var group: String
    let groups: [String]

    var body: some View {
        HStack {
            TextField("Ordner", text: $group, prompt: Text("optional"))
            if !groups.isEmpty {
                Menu {
                    ForEach(groups, id: \.self) { name in Button(name) { group = name } }
                } label: {
                    Image(systemName: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Vorhandenen Ordner wählen")
                .accessibilityLabel("Vorhandenen Ordner wählen")
            }
        }
    }
}

/// Blatt zum Bearbeiten eines Eintrags (auch für neue Einträge).
struct FrequencyMemoryEditor: View {
    @State private var entry: FrequencyMemoryEntry
    @State private var mhz: Double
    @State private var bandwidthKHz: String
    private let isNew: Bool
    let done: () -> Void

    init(entry: FrequencyMemoryEntry, isNew: Bool = false, done: @escaping () -> Void) {
        _entry = State(initialValue: entry)
        _mhz = State(initialValue: entry.mhz)
        _bandwidthKHz = State(initialValue: entry.bandwidthHz.map { (Double($0) / 1000).formatted(.number.precision(.fractionLength(0...3)).grouping(.never)) } ?? "")
        self.isNew = isNew
        self.done = done
    }

    /// Seiten, für die ein Eintrag gelten kann (alles außer der Geräte-Gruppe).
    static var pages: [SidebarItem] { SidebarItem.groups.dropFirst().flatMap(\.items) }

    var body: some View {
        let memory = FrequencyMemory.shared
        let bandwidth = parsedBandwidth
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $entry.name, prompt: Text("optional"))
                LabeledContent("Frequenz") {
                    FrequencyField(value: $mhz, range: 1...7250, decimals: 6, width: 140)
                }
                Picker("Betriebsart", selection: $entry.mode) {
                    Text("–").tag(String?.none)
                    ForEach(RadioMode.allCases) { Text($0.title).tag(Optional($0.rawValue)) }
                    if let mode = entry.mode, FrequencyMemory.radioMode(fromStored: mode) == nil {
                        Text(mode).tag(Optional(mode))
                    }
                }
                LabeledContent("Bandbreite (kHz)") {
                    TextField("Bandbreite (kHz)", text: $bandwidthKHz, prompt: Text("optional"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                if bandwidth == nil {
                    Text("Keine gültige Bandbreite.").font(.caption).foregroundStyle(.red)
                }
                Picker("Seite", selection: $entry.page) {
                    Text("Alle Seiten").tag(String?.none)
                    ForEach(Self.pages) { Text($0.title).tag(Optional($0.rawValue)) }
                }
                GroupField(group: $entry.group, groups: memory.groups)
                TextField("Notiz", text: $entry.note, prompt: Text("optional"), axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { done() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Hinzufügen" : "Sichern") {
                    var result = entry
                    result.frequencyHz = FrequencyMemoryEntry.hz(mhz)
                    result.bandwidthHz = bandwidth ?? nil
                    result.name = result.name.trimmingCharacters(in: .whitespaces)
                    result.group = result.group.trimmingCharacters(in: .whitespaces)
                    if isNew { memory.add(result) } else { memory.update(result) }
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bandwidth == nil || !(1...7250).contains(mhz))
            }
            .padding()
        }
        .frame(width: 440)
    }

    /// `.some(nil)` = leer, `nil` = ungültig.
    private var parsedBandwidth: Int?? {
        let text = bandwidthKHz.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .some(nil) }
        guard let value = FrequencyInput.parseMHz(text), value > 0, value <= 20_000 else { return nil }
        return .some(Int((value * 1000).rounded()))
    }
}

/// Einstellungen ▸ Frequenzen: alle Einträge suchen, bearbeiten, löschen,
/// als CSV ein- und auslesen.
struct FrequencyMemorySettingsPane: View {
    private var memory: FrequencyMemory { FrequencyMemory.shared }
    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var editing: FrequencyMemoryEntry?
    @State private var creating: FrequencyMemoryEntry?
    @State private var deleting: DeleteConfirmation?
    @State private var message: String?

    var body: some View {
        let rows = filtered
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Suchen", text: $search, prompt: Text("Name, Frequenz, Ordner, Notiz"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button {
                    creating = FrequencyMemoryEntry(mhz: 100, page: nil)
                } label: { Label("Neu …", systemImage: "plus") }
                Button("Importieren …") { importCSV() }
                Button("Exportieren …") { exportCSV(rows) }
                    .disabled(memory.entries.isEmpty)
            }
            Table(rows, selection: $selection) {
                TableColumn("Name") { e in Text(e.displayName) }.width(min: 100, ideal: 160)
                TableColumn("Frequenz") { e in
                    Text(FrequencyInput.format(e.mhz, decimals: 4) + " MHz").monospacedDigit()
                }.width(min: 90, ideal: 110)
                TableColumn("Betriebsart") { e in Text(e.modeTitle ?? "–") }.width(min: 60, ideal: 110)
                TableColumn("Bandbreite") { e in Text(e.bandwidthHz.map(FrequencyMemoryEntry.bandwidthText) ?? "–").monospacedDigit() }.width(70)
                TableColumn("Ordner") { e in Text(e.group.isEmpty ? "–" : e.group) }.width(min: 60, ideal: 100)
                TableColumn("Seite") { e in Text(e.sidebarItem?.title ?? String(localized: "Alle")) }.width(min: 60, ideal: 110)
                TableColumn("Notiz") { e in Text(e.note).lineLimit(1) }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                let chosen = memory.entries.filter { ids.contains($0.id) }
                if chosen.count == 1, let entry = chosen.first {
                    Button("Bearbeiten …") { editing = entry }
                    Button("Im Radio hören") { FrequencyMemoryActions.listen(entry) }
                }
                if !chosen.isEmpty {
                    Button("Exportieren …") { exportCSV(chosen) }
                    Divider()
                    Button("Löschen …", role: .destructive) { deleting = FrequencyMemoryActions.confirmDelete(chosen) }
                }
            } primaryAction: { ids in
                if ids.count == 1, let entry = memory.entries.first(where: { ids.contains($0.id) }) { editing = entry }
            }
            .onDeleteCommand {
                let chosen = memory.entries.filter { selection.contains($0.id) }
                if !chosen.isEmpty { deleting = FrequencyMemoryActions.confirmDelete(chosen) }
            }
            .deleteConfirmation($deleting)
            HStack(alignment: .firstTextBaseline) {
                if let error = memory.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Merken geht auf jeder Seite mit Frequenzfeld im Bedienfeld unter „Frequenzspeicher“, im Spektrum per Rechtsklick. Doppelklick bearbeitet, Entf löscht. CSV: Name;Frequenz (MHz);Modus;Bandbreite (kHz);Notiz;Gruppe;Seite – auch Listen aus SDR++ oder CHIRP mit diesen Spalten.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(memory.entries.count) Einträge").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(16)
        .sheet(item: $editing) { entry in FrequencyMemoryEditor(entry: entry) { editing = nil } }
        .sheet(item: $creating) { entry in FrequencyMemoryEditor(entry: entry, isNew: true) { creating = nil } }
    }

    private var filtered: [FrequencyMemoryEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return memory.entries }
        let number = FrequencyInput.parseMHz(query)
        return memory.entries.filter { e in
            [e.name, e.group, e.note, e.modeTitle ?? "", e.sidebarItem?.title ?? "", e.kind ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
                || FrequencyInput.format(e.mhz, decimals: 4).contains(query)
                || number.map { abs(e.mhz - $0) < 0.0005 || String(e.mhz).hasPrefix(String(format: "%g", $0)) } ?? false
        }
    }

    private func importCSV() {
        Task {
            guard let url = await SaveSheet.open(types: [.commaSeparatedText, .plainText, .tabSeparatedText],
                                                 message: String(localized: "CSV-Datei mit Frequenzen wählen (Name;Frequenz;Modus;Bandbreite;Notiz).")).first
            else { return }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                message = String(localized: "Die Datei ließ sich nicht lesen.")
                return
            }
            let result = memory.importCSV(text)
            message = String(localized: "\(result.entries.count) übernommen, \(result.duplicates) schon vorhanden, \(result.invalid) ohne gültige Frequenz.")
        }
    }

    private func exportCSV(_ entries: [FrequencyMemoryEntry]) {
        let text = memory.exportCSV(entries)
        Task {
            guard let url = await SaveSheet.url(name: String(localized: "Frequenzspeicher") + ".csv", types: [.commaSeparatedText]) else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                message = String(localized: "\(entries.count) Einträge exportiert.")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
