import Foundation
import Testing
@testable import PortaPackManager

@Suite("Handbuch")
struct HelpTests {
    /// Aus dem App-Bundle (der Test-Host ist die App), nicht aus dem Quellbaum:
    /// Der liegt in ~/Documents, und ein frisch gebauter Test-Host ohne
    /// Ordnerfreigabe bekam dort nur „Interrupted system call“ bzw. hing
    /// minutenlang – alle Kapitel galten dann als fehlend (Fund 28.10.2026).
    private var text: String {
        guard let url = Bundle.main.url(forResource: "Hilfe", withExtension: "md") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("Jede Seite der Seitenleiste hat ein Kapitel – neue Seiten bitte im Handbuch beschreiben")
    func everyPageDocumented() {
        let ids = Set(HelpParser.chapters(text).map(\.id))
        let missing = SidebarItem.allCases.map(\.rawValue).filter { !ids.contains($0) }
        #expect(missing.isEmpty, "Ohne Kapitel in Docs/Hilfe.md: \(missing)")
    }

    @Test("Markdown wird in Überschriften, Listen, Tabellen und Hinweise zerlegt")
    func parsing() {
        let sample = """
        # Titel
        Einleitung.
        <a id="x"></a>
        ## Kapitel
        Absatz eins
        geht weiter.

        ### Unterpunkt
        1. Erstens
           mit Fortsetzung
        - Punkt
          - eingerückt

        | A | B |
        |---|---|
        | 1 | 2 |

        > Achtung
        """
        let chapters = HelpParser.chapters(sample)
        #expect(chapters.map(\.id) == ["intro", "x"])
        let blocks = chapters[1].blocks
        #expect(blocks.count == 5)
        guard case let .paragraph(p) = blocks[0], case let .list(items) = blocks[2],
              case let .table(rows) = blocks[3], case let .note(note) = blocks[4] else {
            Issue.record("Falsche Blockfolge: \(blocks)"); return
        }
        #expect(p == "Absatz eins geht weiter.")
        #expect(items.count == 3 && items[0].text == "Erstens mit Fortsetzung" && items[2].level == 1)
        #expect(rows == [["A", "B"], ["1", "2"]])
        #expect(note == "Achtung")
    }
}
