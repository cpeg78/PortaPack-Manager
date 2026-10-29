import Foundation

/// Sprache der Erkennung.
enum AirbandSpeechLanguage: String, CaseIterable, Identifiable, Sendable {
    /// ICAO-Sprechfunk (Standard im Luftraum über Deutschland).
    case english = "en"
    /// Sichtflug an kleinen Plätzen, Rettungshubschrauber.
    case german = "de"
    /// Beide versuchen, die höhere Zuversicht gewinnt.
    case automatic = "auto"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: String(localized: "Englisch")
        case .german: String(localized: "Deutsch")
        case .automatic: String(localized: "Automatisch")
        }
    }

    /// Einzelne Sprachen, die zu versuchen sind (Englisch zuerst).
    var codes: [String] {
        switch self {
        case .english: ["en"]
        case .german: ["de"]
        case .automatic: ["en", "de"]
        }
    }

    static func locale(for code: String) -> Locale {
        Locale(identifier: code == "de" ? "de_DE" : "en_US")
    }
}

/// Ein Rufzeichen aus ADS-B, das in einem Spruch vorkommen kann.
struct AirbandCallsign: Sendable, Hashable, Codable {
    /// Wie im ADS-B-Rahmen, ohne Leerzeichen, z. B. „DLH4AB“.
    var callsign: String
    /// ICAO-Adresse (hex), falls bekannt – für „Flugzeug zeigen“.
    var icao: String?
}

/// Fachwortschatz des Flugfunks: Buchstabieralphabet, Zahlen-Sprechweise,
/// Standardsprechgruppen und Funkrufnamen der Airlines. Dient als Hinweis für
/// die Erkennung (`contextualStrings`) und zur Nachbearbeitung.
enum AirbandPhraseology {
    // MARK: Buchstaben und Ziffern

    static let icaoLetters: [(Character, String)] = [
        ("A", "alpha"), ("B", "bravo"), ("C", "charlie"), ("D", "delta"), ("E", "echo"), ("F", "foxtrot"),
        ("G", "golf"), ("H", "hotel"), ("I", "india"), ("J", "juliett"), ("K", "kilo"), ("L", "lima"),
        ("M", "mike"), ("N", "november"), ("O", "oscar"), ("P", "papa"), ("Q", "quebec"), ("R", "romeo"),
        ("S", "sierra"), ("T", "tango"), ("U", "uniform"), ("V", "victor"), ("W", "whiskey"), ("X", "x-ray"),
        ("Y", "yankee"), ("Z", "zulu"),
    ]

    /// Gesprochene Buchstaben → Buchstabe (inklusive üblicher Schreibweisen der Erkennung).
    static let letterWords: [String: Character] = {
        var map: [String: Character] = [:]
        for (letter, word) in icaoLetters { map[word] = letter }
        for (word, letter) in [("alfa", "A"), ("juliet", "J"), ("whisky", "W"), ("xray", "X"), ("x ray", "X"), ("fox", "F")] as [(String, Character)] {
            map[word] = letter
        }
        return map
    }()

    /// Gesprochene Ziffern (ICAO-Englisch und deutscher Sprechfunk) → Ziffer.
    static let digitWords: [String: Character] = [
        "zero": "0", "one": "1", "wun": "1", "two": "2","three": "3", "tree": "3",
        "four": "4", "fower": "4", "five": "5", "fife": "5", "six": "6", "seven": "7", "eight": "8",
        "ait": "8", "nine": "9", "niner": "9",
        "null": "0", "eins": "1", "zwo": "2", "zwei": "2", "drei": "3", "vier": "4", "fünf": "5",
        "fünnef": "5", "sechs": "6", "sieben": "7", "acht": "8", "neun": "9",
    ]

    /// Dezimaltrenner in Frequenzen („one two one decimal five“).
    static let decimalWords: Set<String> = ["decimal", "dayseemal", "point", "komma"]
    static let hundredWords: Set<String> = ["hundred", "hundert"]
    static let thousandWords: Set<String> = ["thousand", "tousand", "tausend"]

    /// Wörter, nach denen auch eine einzelne gesprochene Ziffer eine Zahl ist.
    static let numberKeywords: Set<String> = [
        "runway", "level", "squawk", "heading", "qnh", "gate", "stand",
        "piste", "fläche", "flugfläche", "steuerkurs", "transponder",
    ]

    static let englishDigitNames = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    // MARK: Sprechgruppen

    static let englishPhrases = [
        "cleared", "cleared to land", "cleared for takeoff", "descend", "climb", "flight level", "maintain",
        "squawk", "squawk ident", "contact", "monitor", "roger", "wilco", "affirm", "negative", "readback",
        "read back correct", "say again", "standby", "QNH", "runway", "taxi", "taxi to holding point", "hold short",
        "line up and wait", "go around", "vacate", "heading", "turn left", "turn right", "direct", "approach",
        "departure", "tower", "ground", "radar", "information", "expect", "ILS", "established", "localizer",
        "wind", "knots", "feet", "altitude", "mayday", "pan pan", "niner", "tree", "fife", "decimal",
        "good day", "behind", "report", "visual", "traffic", "speed", "reduce", "increase",
    ]

    static let germanPhrases = [
        "Piste", "Landung frei", "Start frei", "Rollhalt", "rollen Sie", "Rollweg", "Flugfläche", "steigen",
        "sinken", "Steuerkurs", "Transponder", "Kontakt", "rufen Sie", "verstanden", "korrekt", "wiederholen Sie",
        "Wind", "Knoten", "Fuß", "QNH", "Platzrunde", "Gegenanflug", "Queranflug", "Endanflug", "Turm",
        "Rollkontrolle", "Vorfeld", "Langen Radar", "Bremen Radar", "München Radar", "Information", "zwo",
        "Pflichtmeldepunkt", "Sichtflug", "Durchstarten", "Christoph", "Notfall",
    ]

    // MARK: Funkrufnamen

    /// Funkrufnamen (Telephony) häufiger Betreiber über Deutschland, ICAO-Präfix
    /// → Rufname. Bewusst nur eine kleine Auswahl.
    static let airlines: [String: String] = [
        "DLH": "Lufthansa", "CLH": "Hansaline", "GEC": "Lufthansa Cargo", "EWG": "Eurowings", "OCN": "Discover",
        "CFG": "Condor", "TUI": "TUI jet", "SXS": "Sunexpress", "BOX": "German Cargo", "BCS": "Eurotrans",
        "DHK": "World Express", "GAF": "German Air Force", "CHX": "Christoph",
        "BAW": "Speedbird", "EZY": "Easy", "EJU": "Alpine", "EZS": "Topswiss", "RYR": "Ryanair", "RUK": "Blue Max",
        "KLM": "KLM", "AFR": "Airfrans", "SAS": "Scandinavian", "UAE": "Emirates", "THY": "Turkish",
        "PGT": "Sunturk", "SWR": "Swiss", "EDW": "Edelweiss", "AUA": "Austrian", "BEL": "Beeline", "LOT": "LOT",
        "WZZ": "Wizz Air", "VLG": "Vueling", "IBE": "Iberia", "ITY": "Itarrow", "FIN": "Finnair", "NAX": "Nor Shuttle",
        "DAL": "Delta", "UAL": "United", "AAL": "American", "QTR": "Qatari", "ETD": "Etihad", "ACA": "Air Canada",
        "CPA": "Cathay", "SIA": "Singapore", "UPS": "UPS", "FDX": "Fedex", "CLX": "Cargolux", "ICE": "Iceair",
        "TAP": "Air Portugal", "AEE": "Aegean", "ELY": "El Al", "MSR": "Egyptair", "EXS": "Channex", "TOM": "Tomson",
        "LGL": "Luxair", "BTI": "Air Baltic", "CSA": "CSA Lines", "TRA": "Transavia", "AEA": "Europa",
    ]

    /// Rufname (klein, ohne Leerzeichen) → ICAO-Präfix, für die Zuordnung.
    static let telephonyPrefixes: [String: String] = {
        var map: [String: String] = [:]
        for (prefix, name) in airlines { map[name.lowercased().replacingOccurrences(of: " ", with: "")] = prefix }
        // Wie die Erkennung „Air France“ schreibt.
        map["airfrance"] = "AFR"
        return map
    }()

    /// Rufname auch bei kleinen Hörfehlern der Erkennung („Speedbud“, „Eurowing“,
    /// „Condo“): gleicher Anfangsbuchstabe und höchstens 1 (ab 8 Zeichen 2)
    /// Zeichen Abstand. Nur ab 5 Zeichen – kurze Wörter wären zu oft Zufall. Die
    /// Zuordnung verlangt danach trotzdem genau die Ziffern und Buchstaben eines
    /// Flugzeugs aus ADS-B, deshalb bleibt das ohne erfundene Treffer.
    static func fuzzyTelephonyPrefix(_ word: String) -> String? {
        guard word.count >= 5, let first = word.first else { return nil }
        var best: (distance: Int, prefix: String)?
        for (name, prefix) in telephonyPrefixes where name.first == first && abs(name.count - word.count) <= 2 {
            let limit = name.count >= 8 ? 2 : 1
            let distance = levenshtein(name, word)
            if distance <= limit, distance < (best?.distance ?? .max) { best = (distance, prefix) }
        }
        return best?.prefix
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    // MARK: Sprache erkennen

    /// Typische Wörter je Sprache (ohne gemeinsame wie „Wind“, „Radar“).
    static let englishMarkers: Set<String> = [
        "cleared", "clear", "land", "landing", "runway", "contact", "descend", "climb", "flight", "level", "squawk",
        "hold", "short", "knots", "degrees", "heading", "roger", "wilco", "tower", "ground", "approach", "to", "for",
        "and", "the", "good", "day", "decimal", "alpha", "bravo", "charlie", "maintain", "taxi", "via", "turn",
        "left", "right", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "zero", "niner",
    ]
    static let germanMarkers: Set<String> = [
        "piste", "landung", "frei", "rollen", "sie", "rollhalt", "knoten", "grad", "steigen", "sinken", "flugfläche",
        "kontakt", "verstanden", "zwo", "null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht",
        "neun", "und", "auf", "bis", "nach", "rufen", "turm", "platzrunde", "anflug", "melden", "ihre", "über", "fuß",
    ]

    /// Wertung für „automatisch“: Zuversicht plus ein kleiner Zuschlag für typische
    /// Wörter der Sprache (höchstens 0,2). Messung 29.10.2026: Zuversicht allein
    /// wählte 14–15 von 17 Sprüchen richtig (20 dB Rauschen: 11–12, 5 dB: 7), mit
    /// Zuschlag 17 (16, 5 dB: 16).
    static func languageScore(_ recognition: AirbandRecognition) -> Double {
        let markers = recognition.language == "de" ? germanMarkers : englishMarkers
        let hits = recognition.text.lowercased().split { !$0.isLetter }.filter { markers.contains(String($0)) }.count
        return (recognition.confidence ?? 0) + min(0.2, 0.04 * Double(hits))
    }

    /// Wie ein Rufzeichen gesprochen wird: „DLH4AB“ → „Lufthansa four alpha bravo“
    /// und „Lufthansa 4AB“; Kennzeichen „DEABC“ → „Delta Echo Alpha Bravo Charlie“.
    static func spokenForms(of callsign: String) -> [String] {
        let sign = callsign.uppercased().filter { $0.isLetter || $0.isNumber }
        guard sign.count >= 3 else { return [] }
        func spell(_ part: Substring) -> String {
            part.compactMap { char -> String? in
                if let digit = char.wholeNumberValue { return englishDigitNames[digit] }
                return icaoLetters.first { $0.0 == char }?.1
            }.joined(separator: " ")
        }
        let prefix = String(sign.prefix(3))
        if let name = airlines[prefix], sign.count > 3 {
            let rest = sign.dropFirst(3)
            return ["\(name) \(spell(rest))", "\(name) \(rest)"]
        }
        if sign.allSatisfy(\.isLetter) {
            let words = spell(sign[...]).split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return [words.joined(separator: " ")]
        }
        return [spell(sign[...])]
    }

    /// Hinweise für die Erkennung: zuerst die Rufzeichen der Flugzeuge in
    /// Reichweite (am genauesten), dann Kanalnamen und Sprechgruppen. Apple
    /// empfiehlt höchstens rund 100 Einträge.
    static func contextualStrings(callsigns: [AirbandCallsign], channelNames: [String], language: String,
                                  limit: Int = 100) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, result.count < limit, seen.insert(trimmed.lowercased()).inserted else { return }
            result.append(trimmed)
        }
        for sign in callsigns.prefix(30) { spokenForms(of: sign.callsign).forEach(add) }
        channelNames.forEach(add)
        (language == "de" ? germanPhrases : englishPhrases).forEach(add)
        return result
    }
}

/// Nachbearbeitung einer Abschrift für die Anzeige. Der Rohtext bleibt
/// unverändert gespeichert; hier wird nur umgeformt, was eindeutig ist –
/// nichts wird ergänzt.
enum AirbandTranscriptFormatter {
    private struct Word {
        var core: String
        var suffix: String
        var lower: String { core.lowercased() }
    }

    private static func split(_ token: Substring) -> Word {
        var core = String(token)
        var suffix = ""
        // Satzzeichen am Ende gehören nie zur Zahl („80.“ am Satzende).
        while let last = core.last, ",;:!?.".contains(last) {
            suffix = String(last) + suffix
            core.removeLast()
        }
        return Word(core: core, suffix: suffix)
    }

    /// Einzelne Ziffer (gesprochen oder geschrieben) bzw. ganze Zahl.
    private enum Piece {
        case digit(Character, spoken: Bool)
        case number(String)
        case decimal
    }

    private static func piece(_ word: Word) -> Piece? {
        let lower = word.lower
        if let digit = AirbandPhraseology.digitWords[lower] { return .digit(digit, spoken: true) }
        if AirbandPhraseology.decimalWords.contains(lower) { return .decimal }
        if !word.core.isEmpty, word.core.allSatisfy(\.isNumber) {
            return word.core.count == 1 ? .digit(word.core.first!, spoken: false) : .number(word.core)
        }
        if word.core.contains("."), word.core.split(separator: ".", omittingEmptySubsequences: false).count == 2,
           word.core.allSatisfy({ $0.isNumber || $0 == "." }) {
            return .number(word.core)
        }
        return nil
    }

    /// Zahlwörter → Ziffern, wo es eindeutig ist:
    /// - Folgen einzeln gesprochener Ziffern („eight zero“ → „80“, „one one eight
    ///   decimal zero zero five“ → „118.005“),
    /// - „decimal“ zwischen Zahlen („123 decimal 875“ → „123.875“),
    /// - „two thousand five hundred“ → „2500“,
    /// - eine einzelne Ziffer nur nach einem Stichwort („runway two“ → „runway 2“).
    /// Mehrstellige Zahlen werden nie aneinandergehängt („240 8“ bleibt).
    static func format(_ raw: String) -> String {
        let words = raw.split(whereSeparator: \.isWhitespace).map(split)
        var out: [String] = []
        var i = 0
        while i < words.count {
            if let (text, next) = numberRun(words, from: i) {
                out.append(text)
                i = next
            } else {
                out.append(words[i].core + words[i].suffix)
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    private static func numberRun(_ words: [Word], from start: Int) -> (String, Int)? {
        guard let first = piece(words[start]), !isDecimalPiece(first) else { return nil }
        var text = ""
        var groupDigits = 0       // Ziffern seit Anfang bzw. seit „decimal“
        var endedWithNumber = false
        var spokenDigits = 0
        var elements = 0
        var sawDecimal = false
        var suffix = ""
        var i = start
        scan: while i < words.count, let p = piece(words[i]) {
            switch p {
            case .digit(let d, let spoken):
                // Nach einer mehrstelligen Zahl beginnt eine neue („240 8“ bleibt).
                if endedWithNumber { break scan }
                text.append(d)
                groupDigits += 1
                elements += 1
                if spoken { spokenDigits += 1 }
            case .number(let n):
                if groupDigits > 0 || endedWithNumber || (n.contains(".") && sawDecimal) { break scan }
                text += n
                endedWithNumber = true
                elements += 1
                if n.contains(".") { sawDecimal = true }
            case .decimal:
                // Nur einmal, nur zwischen zwei Zahlen.
                guard elements > 0, !sawDecimal, words[i].suffix.isEmpty, i + 1 < words.count,
                      let after = piece(words[i + 1]), !isDecimalPiece(after) else { break scan }
                text += "."
                sawDecimal = true
                groupDigits = 0
                endedWithNumber = false
            }
            suffix = words[i].suffix
            i += 1
            if !suffix.isEmpty { break scan }
        }
        guard i > start else { return nil }
        // „two thousand five hundred“, „fife hundred“
        if suffix.isEmpty, !sawDecimal, let value = Int(text), value > 0, value < 100, i < words.count {
            var total = 0
            var j = i
            if AirbandPhraseology.thousandWords.contains(words[j].lower) {
                total = value * 1000
                suffix = words[j].suffix
                j += 1
                if suffix.isEmpty, j + 1 < words.count, case .digit(let d, _)? = piece(words[j]),
                   AirbandPhraseology.hundredWords.contains(words[j + 1].lower), let h = d.wholeNumberValue {
                    total += h * 100
                    suffix = words[j + 1].suffix
                    j += 2
                }
            } else if value < 10, AirbandPhraseology.hundredWords.contains(words[j].lower) {
                total = value * 100
                suffix = words[j].suffix
                j += 1
            }
            if j > i { return (String(total) + suffix, j) }
        }
        let convert: Bool
        if sawDecimal {
            convert = elements >= 2 && !text.hasSuffix(".")
        } else if elements >= 2 {
            convert = true
        } else {
            // Eine einzelne gesprochene Ziffer nur nach einem Stichwort.
            let previous = start > 0 ? words[start - 1].lower : ""
            convert = spokenDigits == 1 && AirbandPhraseology.numberKeywords.contains(previous)
        }
        guard convert else { return nil }
        return (text + suffix, i)
    }

    private static func isDecimalPiece(_ piece: Piece) -> Bool {
        if case .decimal = piece { return true }
        return false
    }

    // MARK: Rufzeichen

    /// Sucht ein Rufzeichen aus `candidates` im Text: Funkrufname + Ziffern +
    /// Buchstaben („Lufthansa 4 Alpha Bravo“, „Lufthansa four alpha bravo“,
    /// „DLH4AB“), Kennzeichen buchstabiert („Delta Echo Alpha Bravo Charlie“) oder
    /// – in Deutschland üblich – abgekürzt („Delta Bravo Charlie“ für D-EABC).
    /// Nur Treffer, die genau einem Kandidaten entsprechen; geraten wird nicht.
    static func matchCallsign(in text: String, candidates: [AirbandCallsign]) -> AirbandCallsign? {
        guard !candidates.isEmpty else { return nil }
        var lookup: [String: AirbandCallsign] = [:]
        for candidate in candidates {
            let sign = candidate.callsign.uppercased().filter { $0.isLetter || $0.isNumber }
            guard sign.count >= 3 else { continue }
            lookup[sign] = lookup[sign] ?? candidate
            if sign.count == 5, sign.allSatisfy(\.isLetter) {
                let short = String(sign.prefix(1)) + String(sign.suffix(2))
                lookup[short] = lookup[short] ?? candidate
            }
        }
        let tokens = canonicalTokens(text)
        var best: (length: Int, sign: AirbandCallsign)?
        for start in tokens.indices {
            var paths: [String] = [""]
            for k in start..<min(tokens.count, start + 10) {
                guard let options = tokens[k] else { break }
                paths = paths.flatMap { path in options.map { path + $0 } }.filter { $0.count <= 10 }
                if paths.isEmpty { break }
                for path in paths where path.count >= 3 {
                    // Einzelnes Wort ohne Ziffer (z. B. nur „Delta“) zählt nicht.
                    if k == start, !(path.contains(where: \.isNumber) && path.contains(where: \.isLetter)) { continue }
                    if let hit = lookup[path], path.count > (best?.length ?? 0) { best = (path.count, hit) }
                }
            }
        }
        return best?.sign
    }

    /// Je Wort die möglichen Zeichenfolgen (Funkrufname → Präfix, „alpha“ → A,
    /// „four“ → 4, „4AB“ → 4AB); `nil` für Wörter, die ein Rufzeichen beenden.
    static func canonicalTokens(_ text: String) -> [[String]?] {
        let words = text.split { !($0.isLetter || $0.isNumber || $0 == "-") }.map(String.init)
        var tokens: [[String]?] = []
        var i = 0
        while i < words.count {
            // Mehrwortige Funkrufnamen zuerst (längster Treffer).
            var matched = false
            for length in stride(from: 3, through: 1, by: -1) where i + length <= words.count {
                let joined = words[i..<(i + length)].joined().lowercased().replacingOccurrences(of: "-", with: "")
                if let prefix = AirbandPhraseology.telephonyPrefixes[joined] {
                    var options = [prefix]
                    if length == 1, let letter = AirbandPhraseology.letterWords[joined] { options.append(String(letter)) }
                    tokens.append(options)
                    i += length
                    matched = true
                    break
                }
            }
            if matched { continue }
            // Hörfehler im Rufnamen („Speed Bid“, „Eurowing“) – nur, wenn kein Buchstabierwort.
            for length in stride(from: 2, through: 1, by: -1) where i + length <= words.count {
                let parts = words[i..<(i + length)].map { $0.lowercased() }
                guard !parts.contains(where: { AirbandPhraseology.letterWords[$0] != nil || AirbandPhraseology.digitWords[$0] != nil
                    || $0.contains(where: \.isNumber) }) else { continue }
                if let prefix = AirbandPhraseology.fuzzyTelephonyPrefix(parts.joined()) {
                    tokens.append([prefix])
                    i += length
                    matched = true
                    break
                }
            }
            if matched { continue }
            let word = words[i]
            let lower = word.lowercased()
            if let letter = AirbandPhraseology.letterWords[lower] ?? AirbandPhraseology.letterWords[lower.replacingOccurrences(of: "-", with: "")] {
                tokens.append([String(letter)])
            } else if let digit = AirbandPhraseology.digitWords[lower] {
                tokens.append([String(digit)])
            } else if word.allSatisfy({ $0.isNumber }) || (word.contains(where: \.isNumber) && word.allSatisfy { $0.isLetter || $0.isNumber }) {
                tokens.append([word.uppercased()])
            } else if word.count >= 2, word.count <= 3, word.allSatisfy(\.isUppercase) {
                // „KLM“, „UPS“ als Buchstaben gesprochen.
                tokens.append([word])
            } else if word.count == 1, word.first?.isUppercase == true {
                tokens.append([word])
            } else {
                tokens.append(nil)
            }
            i += 1
        }
        return tokens
    }
}
