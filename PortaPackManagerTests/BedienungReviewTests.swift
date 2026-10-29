import AppKit
import Foundation
import Testing
@testable import PortaPackManager

/// Funde des Bedienungs-Reviews vom 29.10.2026: Frequenzeingabe, Tastatur,
/// Rückfragen.
@Suite("Bedienung 29.10.: Frequenzeingabe, Tastatur, Rückfragen")
struct BedienungReviewTests {
    // MARK: Frequenzeingabe

    @Test("Komma und Punkt sind beide Dezimaltrenner", arguments: [
        ("433,92", 433.92), ("433.92", 433.92), (" 98,5 ", 98.5), ("1090", 1090.0),
        ("145,500 MHz", 145.5), ("145.5mhz", 145.5), ("433920 kHz", 433.92), ("1,57542 GHz", 1575.42),
        ("1.090,5", 1090.5), ("1,090.5", 1090.5), ("1 090", 1090.0),
    ])
    func kommaUndPunkt(text: String, expected: Double) throws {
        let value = try #require(FrequencyInput.parseMHz(text))
        #expect(abs(value - expected) < 1e-9)
    }

    @Test("Unsinn wird abgelehnt statt still verworfen", arguments: [
        "", "abc", "1.090.000", "1,2,3", "1e3", "inf", "nan", ".", "12a", "4 3 3,9,2",
    ])
    func unsinn(text: String) {
        #expect(FrequencyInput.parseMHz(text) == nil)
    }

    @Test("Bereichsprüfung mit Grund")
    func bereich() {
        #expect(FrequencyInput.validate("403,5", range: 400...406) == .success(403.5))
        #expect(FrequencyInput.validate("407", range: 400...406) == .failure(.outOfRange(400...406)))
        #expect(FrequencyInput.validate("vierhundert", range: 400...406) == .failure(.notANumber))
        #expect(FrequencyInput.validate("6000,1", range: 1...6000) == .failure(.outOfRange(1...6000)))
    }

    @Test("Anzeige folgt dem Gebietsschema, ohne Tausendertrennung")
    func anzeige() {
        #expect(FrequencyInput.format(1090, decimals: 3, locale: Locale(identifier: "de_DE")) == "1090,000")
        #expect(FrequencyInput.format(433.92, decimals: 2, locale: Locale(identifier: "en_US")) == "433.92")
        // Was angezeigt wird, liest das Feld auch wieder.
        let shown = FrequencyInput.format(1575.42, decimals: 3, locale: Locale(identifier: "de_DE"))
        #expect(FrequencyInput.parseMHz(shown) == 1575.42)
    }

    // MARK: Tastatur

    @Test("Leertaste und Pfeile gehen ans Textfeld, Kürzel mit ⌘/⌥/⌃ nicht")
    func textfeldSchutz() {
        for key: UInt16 in [49, 123, 124, 125, 126] {
            #expect(TextInputKeyGuard.shouldRoute(keyCode: key, modifiers: []))
            #expect(TextInputKeyGuard.shouldRoute(keyCode: key, modifiers: [.shift]))
            #expect(!TextInputKeyGuard.shouldRoute(keyCode: key, modifiers: [.command]))
            #expect(!TextInputKeyGuard.shouldRoute(keyCode: key, modifiers: [.option]))
        }
        // Andere Tasten (Buchstaben, ⏎, Entf) bleiben unberührt.
        #expect(!TextInputKeyGuard.shouldRoute(keyCode: 0, modifiers: []))
        #expect(!TextInputKeyGuard.shouldRoute(keyCode: 36, modifiers: []))
        #expect(!TextInputKeyGuard.shouldRoute(keyCode: 51, modifiers: []))
    }

    // MARK: Rückfragen der Übersicht

    @Test("Geräteknöpfe nennen, was gerade läuft")
    func geraeteRueckfrage() {
        let running = "Der Empfangsplan nimmt gerade auf: METEOR-M2 3 bis 12:00."
        let text = OverviewView.DeviceAction.reboot.message(running: running)
        #expect(text.contains(running))
        #expect(!OverviewView.DeviceAction.reboot.message(running: nil).contains("Läuft gerade"))
        // DFU erklärt sich immer, auch wenn nichts läuft.
        #expect(OverviewView.DeviceAction.dfu.message(running: nil).contains("DFU"))
    }
}
