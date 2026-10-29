import Foundation
import Synchronization

/// Dauerstörer im Sondenband, die die Trägersuche nie belegen soll – je
/// Standort verschieden, deshalb eine Einstellung (Schlüssel
/// `sondeBlockedRanges`, Liste „von-bis“ in Hz). Ab Werk leer: Die am
/// Testplatz gemessenen Störer (400,66, 403,91 und 404,637 MHz) standen bis
/// 29.10.2026 fest im Code bzw. als Vorgabe – andernorts wäre eine Sonde auf
/// 403,91 MHz nie gefunden worden. Seit 1.0 trägt jeder seine eigenen ein.
/// Feste Kanäle (`pin`) gelten
/// trotzdem. Unterhalb des Sondenbands (400,15 MHz, dort u. a. die
/// HackRF-Störlinie 400,000) sucht die App ohnehin nie.
final class SondeBlockList: Sendable {
    static let shared = SondeBlockList()
    static let defaultsKey = "sondeBlockedRanges"
    /// Untergrenze des Sondenbands – darunter wird nie gesucht.
    static let bandStart = 400_150_000.0

    static let factoryRanges: [ClosedRange<Double>] = []

    private let ranges: Mutex<[ClosedRange<Double>]>
    /// In `UserDefaults.standard` speichern; aus nur im Speicher (Tests).
    private let persistent: Bool
    private var defaults: UserDefaults? { persistent ? .standard : nil }

    init(persistent: Bool = true) {
        self.persistent = persistent
        let stored = persistent ? UserDefaults.standard.stringArray(forKey: Self.defaultsKey) : nil
        ranges = Mutex(stored.map { Self.parse(lines: $0) } ?? Self.factoryRanges)
    }

    var current: [ClosedRange<Double>] { ranges.withLock { $0 } }

    /// Ist die Liste noch ab Werk?
    var isFactory: Bool { current == Self.factoryRanges }

    func set(_ list: [ClosedRange<Double>]) {
        let sorted = list.sorted { $0.lowerBound < $1.lowerBound }
        ranges.withLock { $0 = sorted }
        defaults?.set(sorted.map(Self.format), forKey: Self.defaultsKey)
    }

    func resetToFactory() {
        ranges.withLock { $0 = Self.factoryRanges }
        defaults?.removeObject(forKey: Self.defaultsKey)
    }

    func contains(_ frequency: Double) -> Bool {
        frequency <= Self.bandStart || ranges.withLock { $0.contains { $0.contains(frequency) } }
    }

    // MARK: - Text ↔ Bereich

    /// Gespeicherte Form: „403903000-403920000“ (Hz).
    static func format(_ range: ClosedRange<Double>) -> String {
        "\(Int(range.lowerBound.rounded()))-\(Int(range.upperBound.rounded()))"
    }

    static func parse(lines: [String]) -> [ClosedRange<Double>] {
        lines.compactMap { line in
            let parts = line.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, parts[0].isFinite, parts[1].isFinite, parts[0] <= parts[1] else { return nil }
            return parts[0]...parts[1]
        }
    }

    /// Eingabe in MHz, wie im Einstellungsfeld: „403,903–403,920“, „403.903 - 403.920“
    /// oder eine einzelne Frequenz „403,91“ (dann ±5 kHz – so breit fasst die
    /// Suche einen Träger zusammen). Nur Werte im Sondenband 400–406 MHz.
    static func parseMHz(_ text: String) -> ClosedRange<Double>? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "MHz", with: "", options: .caseInsensitive)
        let parts = cleaned.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, (1...2).contains(values.count),
              values.allSatisfy({ (400...406).contains($0) }) else { return nil }
        if values.count == 1 { return (values[0] * 1e6 - 5000)...(values[0] * 1e6 + 5000) }
        let low = min(values[0], values[1]) * 1e6, high = max(values[0], values[1]) * 1e6
        return low...high
    }

    /// Anzeige in MHz: „403,903–403,920 MHz“.
    static func displayMHz(_ range: ClosedRange<Double>) -> String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(3))
        return "\((range.lowerBound / 1e6).formatted(style))–\((range.upperBound / 1e6).formatted(style)) MHz"
    }
}
