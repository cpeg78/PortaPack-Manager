import SwiftUI

/// Das Handbuch (`Docs/Hilfe.md`, im Bundle als `Hilfe.md`) – dieselbe Datei
/// wie auf GitHub, hier als Fenster mit Kapitelliste. Kapitel beginnen mit
/// `<a id="…"></a>` + `## Titel`; die Kennungen entsprechen `SidebarItem.rawValue`,
/// damit der „?“-Knopf jeder Seite direkt ihr Kapitel öffnet.
@MainActor
@Observable
final class HelpCenter {
    static let shared = HelpCenter()
    static let windowID = "help"
    /// Kapitel der Seite „Einstellungen“ (Seitenleiste, ⌘,).
    static let settingsChapter = "settings"
    var chapter: String?
    /// Gesetzt von Links (`portapack://help/…`); das Hauptfenster öffnet dann die Hilfe.
    var openRequested = false

    let chapters: [HelpChapter] = {
        let name = HelpCenter.resourceName(
            preferredLanguage: Bundle.main.preferredLocalizations.first,
            englishAvailable: Bundle.main.url(forResource: "Help-en", withExtension: "md") != nil)
        guard let url = Bundle.main.url(forResource: name, withExtension: "md")
                ?? Bundle.main.url(forResource: "Hilfe", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return HelpParser.chapters(text)
    }()

    /// Welche Handbuchdatei geladen wird: `Help-en.md`, wenn die App auf
    /// Englisch läuft und die Datei im Bundle liegt, sonst `Hilfe.md`.
    nonisolated static func resourceName(preferredLanguage: String?, englishAvailable: Bool) -> String {
        preferredLanguage == "en" && englishAvailable ? "Help-en" : "Hilfe"
    }

    /// Kapitel zu einer Seite; Seiten ohne eigenes Kapitel landen bei „Empfangen“.
    func show(page: String) {
        chapter = chapters.contains { $0.id == page } ? page : "empfang"
    }
}

struct HelpChapter: Identifiable, Hashable {
    var id: String
    var title: String
    var blocks: [HelpBlock]
}

enum HelpBlock: Hashable {
    case heading(String)
    case paragraph(String)
    case list([(level: Int, marker: String, text: String)])
    case table([[String]])
    case note(String)

    static func == (a: HelpBlock, b: HelpBlock) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }
    private var key: String { "\(self)" }
}

/// Kleiner Markdown-Leser für genau die Formen des Handbuchs: Überschriften,
/// Absätze, Listen (auch eingerückt und nummeriert), Tabellen, Zitate.
enum HelpParser {
    static func chapters(_ text: String) -> [HelpChapter] {
        var result: [HelpChapter] = []
        var pendingID: String?
        var current: HelpChapter?
        var lines: [String] = []

        func flush() {
            guard var c = current else { return }
            c.blocks = blocks(lines)
            result.append(c)
            lines = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("<a id=\""), let end = line.dropFirst(7).firstIndex(of: "\"") {
                pendingID = String(line[line.index(line.startIndex, offsetBy: 7)..<end])
            } else if line.hasPrefix("## ") {
                flush()
                let title = String(line.dropFirst(3))
                current = HelpChapter(id: pendingID ?? title, title: title, blocks: [])
                pendingID = nil
            } else if line.hasPrefix("# ") {
                // Titel des Dokuments: die Einleitung wird zum Kapitel „Willkommen“.
                flush()
                current = HelpChapter(id: "intro", title: String(localized: "Willkommen"), blocks: [])
            } else {
                lines.append(line)
            }
        }
        flush()
        return result
    }

    static func blocks(_ lines: [String]) -> [HelpBlock] {
        var blocks: [HelpBlock] = []
        var paragraph: [String] = []
        var list: [(Int, String, String)] = []
        var table: [[String]] = []
        var note: [String] = []

        func close() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !list.isEmpty { blocks.append(.list(list)); list = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
            if !note.isEmpty { blocks.append(.note(note.joined(separator: " "))); note = [] }
        }
        for raw in lines {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { close(); continue }
            if line.hasPrefix("### ") { close(); blocks.append(.heading(String(line.dropFirst(4)))); continue }
            if line.hasPrefix("|") {
                if table.isEmpty { close() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }   // Trennzeile
                table.append(cells)
                continue
            }
            if line.hasPrefix("> ") { note.append(String(line.dropFirst(2))); continue }
            if line.hasPrefix("- ") {
                if !paragraph.isEmpty { close() }
                list.append((indent / 2, "•", String(line.dropFirst(2))))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                if !paragraph.isEmpty { close() }
                list.append((indent / 3, String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            if !list.isEmpty, indent > 0 {
                // Fortsetzungszeile eines Listenpunkts.
                list[list.count - 1].2 += " " + line
                continue
            }
            if !note.isEmpty { note.append(line); continue }
            if !list.isEmpty || !table.isEmpty { close() }
            paragraph.append(line)
        }
        close()
        return blocks
    }
}

struct HelpView: View {
    @Bindable private var center = HelpCenter.shared
    @State private var search = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $center.chapter) { chapter in
                Text(chapter.title).tag(chapter.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .searchable(text: $search, placement: .sidebar, prompt: "Hilfe durchsuchen")
        } detail: {
            if let chapter = center.chapters.first(where: { $0.id == (center.chapter ?? "intro") }) ?? center.chapters.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(chapter.title).font(.largeTitle.bold())
                        ForEach(Array(chapter.blocks.enumerated()), id: \.offset) { _, block in
                            HelpBlockView(block: block)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .id(chapter.id)
            } else {
                ContentUnavailableView("Hilfe nicht gefunden", systemImage: "questionmark.circle")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            // Stellt macOS beim Start nur die Hilfe wieder her, das Hauptfenster dazu öffnen.
            let mainOpen = NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix(AppServices.mainWindowID) == true && $0.isVisible }
            if !mainOpen { openWindow(id: AppServices.mainWindowID) }
        }
    }

    /// Suche über Titel und Text.
    private var filtered: [HelpChapter] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return center.chapters }
        return center.chapters.filter { chapter in
            chapter.title.localizedCaseInsensitiveContains(term)
                || chapter.blocks.contains { "\($0)".localizedCaseInsensitiveContains(term) }
        }
    }
}

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case let .heading(text):
            Text(text).font(.title3.bold()).padding(.top, 8)
        case let .paragraph(text):
            Text(Self.inline(text))
        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).monospacedDigit().foregroundStyle(.secondary)
                        Text(Self.inline(item.text))
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }
        case let .table(rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell))
                                .fontWeight(index == 0 ? .semibold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case let .note(text):
            Label { Text(Self.inline(text)) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Fett, Kursiv, Code, Links – Markdown innerhalb einer Zeile.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
