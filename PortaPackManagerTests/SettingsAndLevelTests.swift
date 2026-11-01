import Foundation
import Observation
import Testing
@testable import PortaPackManager

@MainActor
@Suite("Einstellungen, Kacheln und Pegel (Bedienungs-Umbau 29.10.2026)")
struct SettingsAndLevelTests {
    @Test("Kacheln heißen wie die Seiten der Seitenleiste und tragen ihr Symbol")
    func tilesMatchSidebar() {
        for tile in StartTiles.tiles {
            #expect(tile.title == tile.page.title)
            #expect(tile.symbol == tile.page.symbol)
        }
        #expect(Set(StartTiles.tiles.map(\.page)).count == StartTiles.tiles.count)
    }

    @Test("Kein Symbol steht in der Seitenleiste doppelt")
    func uniqueSidebarSymbols() {
        var seen: [String: SidebarItem] = [:]
        var duplicates: [String] = []
        for item in SidebarItem.allCases {
            if let other = seen[item.symbol] { duplicates.append("\(other.rawValue)/\(item.rawValue): \(item.symbol)") }
            seen[item.symbol] = item
        }
        #expect(duplicates.isEmpty, "Doppelte Symbole: \(duplicates)")
    }

    @Test("Empfangsplan steht nicht mehr unter Wetter")
    func plannerGroup() {
        let wetter = SidebarItem.groups.first { $0.title == "Wetter" }
        #expect(wetter?.items.contains(.planner) == false)
        #expect(SidebarItem.groups.first { $0.title == "Werkzeuge" }?.items.contains(.planner) == true)
    }

    @Test("Handbuch hat ein Kapitel für die Einstellungen")
    func settingsChapter() {
        guard let url = Bundle.main.url(forResource: "Hilfe", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Hilfe.md fehlt im Bundle"); return
        }
        let ids = HelpParser.chapters(text).map(\.id)
        #expect(ids.contains(HelpCenter.settingsChapter))
    }

    @Test("Jeder Bereich der Einstellungen hat Titel und Symbol")
    func settingsTabs() {
        #expect(SettingsTab.allCases.count == 9)
        #expect(SettingsTab.allCases.first == .general)
        for tab in SettingsTab.allCases {
            #expect(!tab.title.isEmpty && !tab.symbol.isEmpty)
        }
    }

    /// Nur reine Funktionen – der Testwirt teilt die Voreinstellungen der App,
    /// `AppleLanguages` darf hier nie geschrieben werden.
    @Test("Sprachwahl: gespeicherter Wert ↔ Auswahl")
    func languageChoice() {
        #expect(AppLanguage.from(appleLanguages: nil) == .system)
        #expect(AppLanguage.from(appleLanguages: []) == .system)
        #expect(AppLanguage.from(appleLanguages: ["de"]) == .german)
        #expect(AppLanguage.from(appleLanguages: ["de-DE", "en"]) == .german)
        #expect(AppLanguage.from(appleLanguages: ["en"]) == .english)
        #expect(AppLanguage.from(appleLanguages: ["en-GB"]) == .english)
        #expect(AppLanguage.from(appleLanguages: ["fr"]) == .system)
        #expect(AppLanguage.system.appleLanguages == nil)
        #expect(AppLanguage.german.appleLanguages == ["de"])
        #expect(AppLanguage.english.appleLanguages == ["en"])
        for language in AppLanguage.allCases {
            #expect(AppLanguage.from(appleLanguages: language.appleLanguages) == language)
        }
        #expect(AppLanguage.german.title == "Deutsch" && AppLanguage.english.title == "English")
    }

    @Test("Hilfe: englische Fassung nur bei englischer App-Sprache und vorhandener Datei")
    func helpLanguage() {
        #expect(HelpCenter.resourceName(preferredLanguage: "en", englishAvailable: true) == "Help-en")
        #expect(HelpCenter.resourceName(preferredLanguage: "en", englishAvailable: false) == "Hilfe")
        #expect(HelpCenter.resourceName(preferredLanguage: "de", englishAvailable: true) == "Hilfe")
        #expect(HelpCenter.resourceName(preferredLanguage: nil, englishAvailable: true) == "Hilfe")
    }

    @Test("Eine Pegelbewertung: übersteuert ab 1 %, sehr laut nur als Hinweis")
    func levelThresholds() {
        #expect(ReceiveLevel(.init(rmsDBFS: -20, peakDBFS: 0, clipped: 0.01)) == .overloaded)
        #expect(ReceiveLevel(.init(rmsDBFS: -20, peakDBFS: 0, clipped: 0.009)) == .warning)
        #expect(ReceiveLevel(.init(rmsDBFS: -10, peakDBFS: -2, clipped: 0)) == .warning)
        #expect(ReceiveLevel(.init(rmsDBFS: -41, peakDBFS: -30, clipped: 0)) == .low)
        #expect(ReceiveLevel.warning.title == "Sehr laut")
    }
}

@MainActor
@Suite("Statuszeile und Seitenleiste widersprechen sich nicht")
struct LevelConsistencyTests {
    @Observable
    final class Fake: GainTunable {
        var lnaGain = 24.0
        var vgaGain = 20.0
        var amplifier = false
        var antennaPower = false
        var running = true
        var quality: GainQuality?
        func applyTunedGains(_ device: HackRFDevice?) throws {}
        var activity: Int? { nil }
        var idleHint: String { "Tipp." }
        var needsLock: Bool { false }
    }

    @Test("Übersteuert in der Seitenleiste ⇔ übersteuert in der Statuszeile")
    func overloadAgrees() {
        let model = Fake(), tracker = ActivityTracker()
        for clipped in [0.0, 0.002, 0.0099, 0.01, 0.2] {
            let levels = HackRFDevice.InputLevels(rmsDBFS: -20, peakDBFS: -1, clipped: clipped)
            let sidebar = ReceiveLevel(levels) == .overloaded
            let panel = ReceiverVerdict.make(model: model, levels: levels, tracker: tracker, autoGain: true).tone == .bad
            #expect(sidebar == panel, "Anteil \(clipped)")
        }
    }

    @Test("„Sehr laut“ steht auch in der Statuszeile, statt „der Pegel passt“")
    func loudHint() {
        let model = Fake(), tracker = ActivityTracker()
        let loud = ReceiverVerdict.make(model: model, levels: .init(rmsDBFS: -9, peakDBFS: -1, clipped: 0),
                                        tracker: tracker, autoGain: true)
        #expect(loud.tone == .good && loud.text.contains("sehr laut") && !loud.text.contains("passt"))
        let fine = ReceiverVerdict.make(model: model, levels: .init(rmsDBFS: -25, peakDBFS: -10, clipped: 0),
                                        tracker: tracker, autoGain: true)
        #expect(fine.text.contains("passt"))
    }

    @Test("„Sehr schwach“ in beiden ab derselben Grenze")
    func quietAgrees() {
        let model = Fake(), tracker = ActivityTracker()
        let levels = HackRFDevice.InputLevels(rmsDBFS: -42, peakDBFS: -30, clipped: 0)
        #expect(ReceiveLevel(levels) == .low)
        #expect(ReceiverVerdict.make(model: model, levels: levels, tracker: tracker, autoGain: true).tone == .weak)
    }
}

@Suite("Seitenleiste: eingeklappte Gruppen")
struct SidebarCollapseTests {
    @Test("Eingeklappt bleiben Auswahl und laufender Empfänger sichtbar")
    func pinned() {
        let items: [SidebarItem] = [.adsb, .acars, .vor]
        #expect(ContentView.visibleItems(items, expanded: true, selection: nil, receiving: nil) == items)
        #expect(ContentView.visibleItems(items, expanded: false, selection: .vor, receiving: .adsb) == [.adsb, .vor])
        #expect(ContentView.visibleItems(items, expanded: false, selection: .overview, receiving: nil).isEmpty)
    }
}
