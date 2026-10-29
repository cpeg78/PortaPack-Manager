import Foundation

/// Eine Mayhem-Versionsangabe: stabil (`v2.4.0`), Nightly (`n_261015`,
/// Datum JJMMTT) oder eigener Build (Commit-Hash).
enum FirmwareVersion: Sendable, Equatable, Hashable, CustomStringConvertible {
    case stable(major: Int, minor: Int, patch: Int)
    case nightly(yymmdd: Int)
    case custom(String)
    case unknown(String)

    init(string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("n_"), let number = Int(text.dropFirst(2)) {
            self = .nightly(yymmdd: number)
            return
        }
        if let range = text.range(of: #"^v?(\d+)\.(\d+)\.(\d+)$"#, options: .regularExpression) {
            let parts = text[range].drop(while: { $0 == "v" }).split(separator: ".").compactMap { Int($0) }
            if parts.count == 3 {
                self = .stable(major: parts[0], minor: parts[1], patch: parts[2])
                return
            }
        }
        if text.range(of: #"^[0-9a-f]{6,40}$"#, options: .regularExpression) != nil {
            self = .custom(text)
            return
        }
        self = .unknown(text)
    }

    /// Aus einem Release-Tag: `v2.4.0` oder `nightly-tag-2026-10-15`.
    init(tag: String) {
        if tag.hasPrefix("nightly-tag-") {
            let digits = tag.dropFirst("nightly-tag-".count).split(separator: "-").map(String.init)
            if digits.count == 3, let y = Int(digits[0]), let m = Int(digits[1]), let d = Int(digits[2]) {
                self = .nightly(yymmdd: (y % 100) * 10000 + m * 100 + d)
                return
            }
        }
        self.init(string: tag)
    }

    var isNightly: Bool {
        if case .nightly = self { return true }
        return false
    }

    var isStable: Bool {
        if case .stable = self { return true }
        return false
    }

    /// Datum eines Nightly-Builds.
    var nightlyDate: Date? {
        guard case let .nightly(number) = self else { return nil }
        var components = DateComponents()
        components.year = 2000 + number / 10000
        components.month = (number / 100) % 100
        components.day = number % 100
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        return components.date
    }

    var description: String {
        switch self {
        case let .stable(major, minor, patch): "v\(major).\(minor).\(patch)"
        case let .nightly(number): String(format: "n_%06d", number)
        case let .custom(hash): hash
        case let .unknown(text): text.isEmpty ? "unbekannt" : text
        }
    }

    var releaseTag: String? {
        switch self {
        case .stable: description
        case let .nightly(number):
            String(format: "nightly-tag-20%02d-%02d-%02d", number / 10000, (number / 100) % 100, number % 100)
        default: nil
        }
    }

    var releaseURL: URL? {
        switch self {
        case .stable, .nightly:
            releaseTag.flatMap { URL(string: "https://github.com/portapack-mayhem/mayhem-firmware/releases/tag/\($0)") }
        case let .custom(hash):
            URL(string: "https://github.com/portapack-mayhem/mayhem-firmware/commit/\(hash)")
        case .unknown:
            nil
        }
    }

    /// Ist `other` neuer als diese Version? Vergleichbar sind nur Nightly mit
    /// Nightly und Stable mit Stable.
    func isOlder(than other: FirmwareVersion) -> Bool? {
        switch (self, other) {
        case let (.nightly(a), .nightly(b)): return a < b
        case let (.stable(a1, a2, a3), .stable(b1, b2, b3)): return (a1, a2, a3) < (b1, b2, b3)
        default: return nil
        }
    }
}
