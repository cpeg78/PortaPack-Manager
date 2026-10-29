import SwiftUI

/// Liest und schreibt Frequenzen in MHz – unabhängig vom Gebietsschema.
///
/// Vorher las jede Seite anders: Radio, Spektrum und VOR ersetzten „,“ durch
/// „.“, Funkruf, Sensoren, Sonden, Aufnahme und Meshtastic nahmen
/// `TextField(value:format:)` nach Gebietsschema – mit deutschem Schema wurde
/// „433.92“ dort als Tausendertrennung gelesen oder still verworfen, und
/// ungültige Eingaben verpufften ohne Rückmeldung (Bedienungs-Review 29.10.2026).
enum FrequencyInput {
    enum Problem: Error, Equatable {
        case notANumber
        case outOfRange(ClosedRange<Double>)
    }

    /// MHz aus einer Eingabe: „,“ und „.“ sind beide Dezimaltrenner; Leerzeichen
    /// und eine Einheit („MHz“, „kHz“, „GHz“, „Hz“) am Ende sind erlaubt. Stehen
    /// beide Trenner da, gilt der letzte als Dezimaltrenner („1.090,5“ = 1090,5).
    /// `nil`, wenn keine Zahl darin steht.
    nonisolated static func parseMHz(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var factor = 1.0
        for (unit, f) in [("mhz", 1.0), ("khz", 1e-3), ("ghz", 1e3), ("hz", 1e-6)] where t.hasSuffix(unit) {
            t = String(t.dropLast(unit.count))
            factor = f
            break
        }
        t = t.filter { !$0.isWhitespace && $0 != "\u{2009}" && $0 != "\u{202F}" }
        guard !t.isEmpty else { return nil }
        let commas = t.filter { $0 == "," }.count
        let dots = t.filter { $0 == "." }.count
        if commas > 0, dots > 0 {
            // Der letzte Trenner ist der Dezimaltrenner, der andere gruppiert.
            let lastComma = t.lastIndex(of: ",")!, lastDot = t.lastIndex(of: ".")!
            let (group, decimal): (Character, Character) = lastComma > lastDot ? (".", ",") : (",", ".")
            guard t.filter({ $0 == decimal }).count == 1 else { return nil }
            t = t.filter { $0 != group }
        } else if commas + dots > 1 {
            // „1.090.000“ – mehrdeutig, lieber ablehnen als falsch abstimmen.
            return nil
        }
        t = t.replacingOccurrences(of: ",", with: ".")
        // Nur Ziffern, ein Punkt und ein Vorzeichen – `Double("1e3")`, „inf“ usw. nicht.
        guard t.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }),
              let value = Double(t), value.isFinite else { return nil }
        return value * factor
    }

    /// Wie `parseMHz`, dazu die Bereichsprüfung.
    nonisolated static func validate(_ text: String, range: ClosedRange<Double>) -> Result<Double, Problem> {
        guard let mhz = parseMHz(text) else { return .failure(.notANumber) }
        guard range.contains(mhz) else { return .failure(.outOfRange(range)) }
        return .success(mhz)
    }

    /// Anzeige mit fester Nachkommazahl und dem Dezimaltrenner des Gebietsschemas.
    nonisolated static func format(_ mhz: Double, decimals: Int, locale: Locale = .current) -> String {
        mhz.formatted(.number.precision(.fractionLength(decimals)).grouping(.never).locale(locale))
    }

    /// Fehlertext für die Anzeige unter dem Feld.
    nonisolated static func message(_ problem: Problem) -> String {
        switch problem {
        case .notANumber:
            String(localized: "Keine gültige Frequenz – z. B. 433,92 oder 433.92.")
        case let .outOfRange(range):
            String(localized: "Erlaubt: \(format(range.lowerBound, decimals: range.lowerBound.rounded() == range.lowerBound ? 0 : 3)) – \(format(range.upperBound, decimals: range.upperBound.rounded() == range.upperBound ? 0 : 3)) MHz")
        }
    }
}

/// Gemeinsames Eingabefeld für Frequenzen in MHz (alle Seiten). Nimmt „,“ und
/// „.“ an, prüft den Bereich und zeigt Fehler rot unter dem Feld.
///
/// Zwei Arten:
/// - `FrequencyField(mhz:…) { neu in … }` – übernimmt mit ⏎ und beim Verlassen
///   des Felds (Abstimmen erst nach der Eingabe, nicht bei jeder Ziffer).
/// - `FrequencyField(value: $wert …)` – schreibt jeden gültigen Zwischenstand
///   sofort (für Felder, die erst ein Knopf daneben benutzt).
struct FrequencyField: View {
    private let current: Double
    private let live: Binding<Double>?
    private let onCommit: ((Double) -> Void)?
    var range: ClosedRange<Double>
    var decimals: Int
    var width: CGFloat?
    var label: LocalizedStringKey

    @State private var text = ""
    @State private var problem: FrequencyInput.Problem?
    @FocusState private var focused: Bool

    init(mhz: Double, range: ClosedRange<Double> = 1...6000, decimals: Int = 3, width: CGFloat? = 100,
         label: LocalizedStringKey = "MHz", onCommit: @escaping (Double) -> Void) {
        current = mhz
        live = nil
        self.onCommit = onCommit
        self.range = range
        self.decimals = decimals
        self.width = width
        self.label = label
    }

    init(value: Binding<Double>, range: ClosedRange<Double> = 1...6000, decimals: Int = 3, width: CGFloat? = 100,
         label: LocalizedStringKey = "MHz", onCommit: ((Double) -> Void)? = nil) {
        current = value.wrappedValue
        live = value
        self.onCommit = onCommit
        self.range = range
        self.decimals = decimals
        self.width = width
        self.label = label
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(label, text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: width)
                .focused($focused)
                .overlay {
                    if problem != nil {
                        RoundedRectangle(cornerRadius: 4).stroke(.red, lineWidth: 1.5).allowsHitTesting(false)
                    }
                }
                .onSubmit { commit(explicit: true) }
                .onChange(of: text) { _, newText in
                    guard focused else { return }
                    // Fehlermarke verschwindet, sobald die Eingabe wieder stimmt.
                    if case let .success(mhz) = FrequencyInput.validate(newText, range: range) {
                        problem = nil
                        if let live, live.wrappedValue != mhz { live.wrappedValue = mhz }
                    }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit(explicit: false) }
                }
                .accessibilityLabel(Text("Frequenz in MHz"))
            if let problem {
                Text(FrequencyInput.message(problem))
                    .font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onAppear { text = FrequencyInput.format(current, decimals: decimals) }
        .onChange(of: current) { _, value in
            if !focused { text = FrequencyInput.format(value, decimals: decimals) }
        }
        .onChange(of: decimals) { _, newDecimals in
            if !focused { text = FrequencyInput.format(current, decimals: newDecimals) }
        }
    }

    /// ⏎ übernimmt immer; beim Verlassen des Felds nur, wenn sich etwas geändert hat.
    private func commit(explicit: Bool) {
        switch FrequencyInput.validate(text, range: range) {
        case let .success(mhz):
            problem = nil
            if let live, live.wrappedValue != mhz { live.wrappedValue = mhz }
            if explicit || abs(mhz - current) > 1e-9 { onCommit?(mhz) }
            if !focused { text = FrequencyInput.format(mhz, decimals: decimals) }
        case let .failure(reason):
            problem = reason
        }
    }
}
