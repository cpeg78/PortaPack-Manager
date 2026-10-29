import Foundation
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

    @Test("Deutsch: lang=de, leeres Wörterbuch, Schlüssel eingesetzt")
    func germanPage() {
        let page = RemotePage.page(token: "abc123", language: "de")
        #expect(page.contains(#"<html lang="de">"#))
        #expect(page.contains(#"<script type="application/json" id="i18n">{}</script>"#))
        #expect(page.contains("const K = 'abc123';"))
        #expect(!page.contains("__K__") && !page.contains("__LANG__") && !page.contains("__I18N__"))
    }

    @Test("Englisch: lang=en, Wörterbuch als JSON, kann den Skriptblock nicht schließen")
    func englishPage() throws {
        let page = RemotePage.page(token: "abc123", language: "en")
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

    @Test("Sperrseite und Manifest folgen der Sprache")
    func forbiddenAndManifest() throws {
        #expect(RemotePage.forbidden(language: "de").contains("Zugangsschlüssel fehlt"))
        #expect(RemotePage.forbidden(language: "en").contains("Access key missing"))
        for language in ["de", "en"] {
            let data = Data(RemotePage.manifest(token: "abc", language: language).utf8)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["start_url"] as? String == "/?k=abc")
        }
    }
}
