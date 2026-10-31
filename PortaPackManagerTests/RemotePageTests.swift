import Foundation
import JavaScriptCore
import Testing
@testable import PortaPackManager

/// Zweisprachige Fernzugriff-Seite: Deutsch ist Schlüssel und Rückfall, Englisch
/// kommt als Wörterbuch (`RemotePageEnglish`) beim Ausliefern in die Seite.
@Suite("Fernzugriff: Sprache der Webseite")
struct RemotePageTests {
    /// Alle Texte, die die Seite über `t('…')` oder im festen HTML zeigt.
    static func pageTexts() throws -> Set<String> {
        let html = RemotePage.html
        var texts = Set<String>()
        // t('…') und tt('…') im Skript (Kommentare enthalten keine solchen Aufrufe).
        let call = try NSRegularExpression(pattern: #"\btt?\('((?:[^'\\]|\\.)*)'"#)
        for m in call.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            texts.insert(String(html[Range(m.range(at: 1), in: html)!]).replacingOccurrences(of: "\\'", with: "'"))
        }
        // Festes HTML zwischen <body> und dem Wörterbuch-Block: Attribute und Textknoten.
        let start = try #require(html.range(of: "<body>")), end = try #require(html.range(of: #"<script type="application/json""#))
        var body = String(html[start.upperBound..<end.lowerBound])
        body = body.replacingOccurrences(of: #"<svg[\s\S]*?</svg>"#, with: "", options: .regularExpression)
        let unescape = { (s: String) in s.replacingOccurrences(of: "&amp;", with: "&") }
        let attr = try NSRegularExpression(pattern: #"(?:title|aria-label|placeholder)="([^"]*)""#)
        for m in attr.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            texts.insert(unescape(String(body[Range(m.range(at: 1), in: body)!])))
        }
        let node = try NSRegularExpression(pattern: #">([^<>]+)<"#)
        for m in node.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            let text = unescape(String(body[Range(m.range(at: 1), in: body)!])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.insert(text) }
        }
        return texts
    }

    @Test("Jeder Text der Seite hat eine englische Fassung oder ist bewusst gleich")
    func everyTextTranslated() throws {
        let texts = try Self.pageTexts()
        #expect(texts.count > 300)
        let missing = texts.filter { RemotePageEnglish.dictionary[$0] == nil && !RemotePageEnglish.unchanged.contains($0) }
        #expect(missing.isEmpty, "Ohne Übersetzung: \(missing.sorted())")
        let unused = Set(RemotePageEnglish.dictionary.keys).subtracting(texts)
        #expect(unused.isEmpty, "Nicht mehr auf der Seite: \(unused.sorted())")
    }

    @Test("Wörterbuch: keine doppelten Schlüssel, Platzhalter vollständig")
    func dictionaryConsistent() throws {
        let keys = RemotePageEnglish.pairs.map(\.0)
        #expect(Set(keys).count == keys.count)
        let placeholder = try NSRegularExpression(pattern: #"\{\d\}"#)
        func marks(_ s: String) -> [String] {
            placeholder.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
        }
        for (de, en) in RemotePageEnglish.pairs {
            #expect(marks(de) == marks(en), "\(de) → \(en)")
            #expect(!en.isEmpty)
        }
    }

    @Test("Deutsch: lang=de, leeres Wörterbuch, Konto und Rolle eingesetzt")
    func germanPage() {
        let page = RemotePage.page(user: "anna", role: .view, language: "de")
        #expect(page.contains(#"<html lang="de">"#))
        #expect(page.contains(#"<script type="application/json" id="i18n">{}</script>"#))
        #expect(page.contains("const USER = 'anna';"))
        #expect(page.contains("const ROLE = 'view' === 'view'"))
        #expect(!page.contains("__USER__") && !page.contains("__ROLE__") && !page.contains("__LANG__") && !page.contains("__I18N__"))
        // Ungültiger Name (könnte das Skript brechen) wird nicht eingesetzt.
        #expect(RemotePage.page(user: "a';alert(1)//", role: .control, language: "de").contains("const USER = '';"))
    }

    @Test("Englisch: lang=en, Wörterbuch als JSON, kann den Skriptblock nicht schließen")
    func englishPage() throws {
        let page = RemotePage.page(user: "anna", role: .control, language: "en")
        #expect(page.contains(#"<html lang="en">"#))
        #expect(page.contains("const LANG = 'en' === 'en'"))
        let open = try #require(page.range(of: #"<script type="application/json" id="i18n">"#))
        let close = try #require(page.range(of: "</script>", range: open.upperBound..<page.endIndex))
        let json = String(page[open.upperBound..<close.lowerBound])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(object == RemotePageEnglish.dictionary)
        #expect(object["Flugzeuge"] == "Aircraft")
        #expect(!page.contains("__I18N__"))
    }

    @Test("Anmeldeseite und Manifest folgen der Sprache")
    func loginAndManifest() throws {
        #expect(RemotePage.login(language: "de").contains("Anmelden"))
        #expect(RemotePage.login(language: "en").contains("Sign in"))
        #expect(RemotePage.login(language: "de").contains(#"autocomplete="current-password""#))
        #expect(RemotePage.login(language: "de", noAccounts: true).contains("noch kein Konto"))
        #expect(!RemotePage.login(language: "de", noAccounts: true).contains("<form"))
        // Fehlertext und vorbelegter Name werden maskiert.
        let page = RemotePage.login(language: "de", message: "<b>x</b>", name: "\"><script>")
        #expect(!page.contains("<b>x</b>") && !page.contains("\"><script>"))
        for language in ["de", "en"] {
            let data = Data(RemotePage.manifest(language: language).utf8)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["start_url"] as? String == "/")
        }
    }

    @Test("Richtungspfeile: fester Abstand auf dem Bildschirm, beim Herauszoomen weniger")
    func arrowSpacing() throws {
        let html = RemotePage.html
        let start = try #require(html.range(of: "function arrowMarks("))
        let end = try #require(html.range(of: "function placeTrackArrows(", range: start.upperBound..<html.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript(String(html[start.lowerBound..<end.lowerBound]))
        // 600 px gerade nach Osten: bei 60 px Abstand 10 Pfeile, halb so lang (eine Zoomstufe weniger) 5.
        let wide = context.evaluateScript("arrowMarks([[0,0],[600,0]], 60, 200)")!
        let narrow = context.evaluateScript("arrowMarks([[0,0],[300,0]], 60, 200)")!
        #expect(wide.forProperty("length").toInt32() == 10)
        #expect(narrow.forProperty("length").toInt32() == 5)
        // Nach Osten zeigt der Pfeil 90°, nach Norden (Bildschirm-y nimmt ab) 0°.
        #expect(wide.atIndex(0).forProperty("angle").toDouble() == 90)
        #expect(context.evaluateScript("arrowMarks([[0,100],[0,0]], 60, 200)[0].angle").toDouble() == 0)
        #expect(context.evaluateScript("arrowMarks([[0,0],[6000,0]], 60, 12).length").toInt32() == 12)
        #expect(html.contains("m.on('zoomend'"))
    }
}
