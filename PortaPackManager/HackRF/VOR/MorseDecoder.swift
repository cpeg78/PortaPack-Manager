import Foundation

/// Morse-Dekoder für Funkfeuerkennungen (VOR: 1020 Hz, ≈ 7 Wörter/min, drei
/// Buchstaben, alle paar Sekunden wiederholt).
///
/// Eingang ist der Pegel des Kennungstons in festen Schritten (`rate` Werte/s).
/// Der Schwellwert liegt mittig zwischen gelernter Spitze und gelerntem Boden;
/// ein Zustandswechsel gilt erst nach drei gleichen Werten (30 ms bei 100/s),
/// damit Rauschspitzen keine Punkte erzeugen. Eine Pause über 1 s schließt
/// eine Kennung ab; dann werden Punktlänge und Zeichen aus den Dauern geschätzt.
final class MorseDecoder: @unchecked Sendable {
    static let table: [String: Character] = [
        ".-": "A", "-...": "B", "-.-.": "C", "-..": "D", ".": "E", "..-.": "F", "--.": "G", "....": "H",
        "..": "I", ".---": "J", "-.-": "K", ".-..": "L", "--": "M", "-.": "N", "---": "O", ".--.": "P",
        "--.-": "Q", ".-.": "R", "...": "S", "-": "T", "..-": "U", "...-": "V", ".--": "W", "-..-": "X",
        "-.--": "Y", "--..": "Z",
        "-----": "0", ".----": "1", "..---": "2", "...--": "3", "....-": "4", ".....": "5",
        "-....": "6", "--...": "7", "---..": "8", "----.": "9",
    ]

    /// Ein Abschnitt: Ton an oder aus, Dauer in Sekunden.
    struct Element: Equatable, Sendable {
        var on: Bool
        var seconds: Double
    }

    let rate: Double
    /// Zuletzt dekodierte Kennungen (neueste zuletzt, höchstens 10).
    private(set) var idents: [String] = []
    /// Ob gerade ein Kennungston zu hören ist.
    private(set) var keyed = false

    private var peak: Float = 0
    private var floor: Float = 0
    private var pending = 0
    private var run = 0
    private var elements: [Element] = []
    private var started = false

    static let groupGap = 1.0

    init(rate: Double) { self.rate = rate }

    func reset() {
        idents = []
        keyed = false
        peak = 0; floor = 0; pending = 0; run = 0
        elements = []
        started = false
    }

    /// Neue Pegelwerte; liefert neu abgeschlossene Kennungen.
    @discardableResult
    func feed(_ levels: [Float]) -> [String] {
        var found: [String] = []
        let slow = Float(1 / (20 * rate))
        for x in levels {
            if !started { peak = x; floor = x; started = true }
            if x > peak { peak = x } else { peak += (x - peak) * slow }
            if x < floor { floor = x } else { floor += (x - floor) * slow * 0.5 }
            let span = peak - floor
            // Ton mindestens ≈ 10 dB über dem Boden, sonst gilt alles als Pause.
            let valid = peak > 3 * max(floor, 1e-6)
            let threshold = floor + span * (keyed ? 0.4 : 0.6)
            let wantOn = valid && x > threshold
            if wantOn != keyed {
                pending += 1
                if pending >= 3 {
                    // Wechsel: die drei Wartewerte gehören schon zum neuen Zustand.
                    close(run: run - (pending - 1), state: keyed)
                    keyed = wantOn
                    run = pending
                    pending = 0
                    continue
                }
            } else {
                pending = 0
            }
            run += 1
            if !keyed, Double(run) / rate > Self.groupGap, !elements.isEmpty {
                if let text = Self.decode(elements), !text.isEmpty {
                    found.append(text)
                    idents.append(text)
                    if idents.count > 10 { idents.removeFirst(idents.count - 10) }
                }
                elements = []
            }
        }
        return found
    }

    private func close(run: Int, state: Bool) {
        let seconds = Double(max(run, 0)) / rate
        if state {
            elements.append(Element(on: true, seconds: seconds))
        } else if !elements.isEmpty, Double(run) / rate <= Self.groupGap {
            elements.append(Element(on: false, seconds: seconds))
        }
    }

    /// Häufigste der letzten Kennungen (mindestens zweimal gleich gehört).
    var confirmedIdent: String? {
        let counts = Dictionary(idents.suffix(5).map { ($0, 1) }, uniquingKeysWith: +)
        guard let best = counts.max(by: { $0.value < $1.value }), best.value >= 2 else { return nil }
        return best.key
    }

    /// Dekodiert eine Folge aus Tönen und Pausen (beginnt mit einem Ton).
    /// `nil`, wenn ein Zeichen unbekannt ist.
    static func decode(_ elements: [Element]) -> String? {
        var list = elements
        while list.last?.on == false { list.removeLast() }
        guard !list.isEmpty else { return nil }
        let durations = list.map(\.seconds).filter { $0 > 0 }.sorted()
        guard !durations.isEmpty else { return nil }
        let base = durations[durations.count / 5]
        let small = durations.filter { $0 <= 2 * base }
        var unit = small.reduce(0, +) / Double(small.count)
        // Nur Striche und Buchstabenpausen (z. B. „TTT“): alles ist 3 Einheiten lang.
        if unit > 0.25 { unit /= 3 }
        var text = ""
        var symbol = ""
        func flush() -> Bool {
            guard !symbol.isEmpty else { return true }
            guard let character = table[symbol] else { return false }
            text.append(character)
            symbol = ""
            return true
        }
        for element in list {
            if element.on {
                symbol += element.seconds < 2 * unit ? "." : "-"
            } else if element.seconds >= 2 * unit {
                guard flush() else { return nil }
                if element.seconds >= 5 * unit { text.append(" ") }
            }
        }
        guard flush() else { return nil }
        return text
    }

    /// Erzeugt Ton/Pause-Abschnitte für einen Text (Prüfung und Tests).
    static func elements(for text: String, unit: Double) -> [Element] {
        let reverse = Dictionary(table.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        var result: [Element] = []
        for (w, word) in text.uppercased().split(separator: " ").enumerated() {
            if w > 0 { result.append(Element(on: false, seconds: 7 * unit)) }
            for (c, character) in word.enumerated() {
                guard let code = reverse[character] else { continue }
                if c > 0 { result.append(Element(on: false, seconds: 3 * unit)) }
                for (s, symbol) in code.enumerated() {
                    if s > 0 { result.append(Element(on: false, seconds: unit)) }
                    result.append(Element(on: true, seconds: symbol == "." ? unit : 3 * unit))
                }
            }
        }
        return result
    }
}
