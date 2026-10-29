import Foundation

/// Das Flugfunkraster 118,000–136,990 MHz: Kanalabstand exakt 25/3 kHz
/// (8,33-kHz-Raster); die 25-kHz-Kanäle liegen auf jedem dritten Rasterpunkt.
/// Index 0 = 118,000 MHz, Index 2279 = 136,99167 MHz.
enum AirbandGrid {
    static let startHz = 118_000_000.0
    static let spacingHz = 25_000.0 / 3
    static let count = 2280
    static let range = 0..<count

    static func hz(_ index: Int) -> Double { startHz + Double(index) * spacingHz }
    static func mhz(_ index: Int) -> Double { hz(index) / 1e6 }

    /// Nächster Rasterpunkt zu einer echten Frequenz.
    /// Unsinnige Werte (NaN, ±∞, weit außerhalb) ergeben einen Index außerhalb
    /// von `range` statt eines Absturzes in `Int(...)`.
    static func index(nearestHz hz: Double) -> Int {
        let raw = ((hz - startHz) / spacingHz).rounded()
        guard raw.isFinite else { return -1 }
        return Int(max(-1e9, min(1e9, raw)))
    }

    /// Kanalname, wie er im Funk und auf Karten steht. 25-kHz-Kanäle heißen wie
    /// ihre Frequenz (118,000 / ,025 / ,050 / ,075); im 8,33-Raster heißen die drei
    /// Kanäle eines 25-kHz-Blocks ,005 / ,010 / ,015 (Frequenzen +0 / +8,33 / +16,67 kHz).
    /// Rasterpunkte auf einem 25-kHz-Kanal zeigen die 25-kHz-Schreibweise.
    static func channelName(_ index: Int) -> String {
        let block = index / 3, rest = index % 3
        let khz = 118_000 + block * 25 + (rest == 0 ? 0 : 5 * (rest + 1))
        return String(format: "%d.%03d", khz / 1000, khz % 1000)
    }

    /// Liest einen Kanalnamen oder eine Frequenz in MHz („118.005“, „121,5“,
    /// „118.00833“) und liefert den Rasterindex – `nil` außerhalb des Bandes.
    static func index(parsing text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        // Bereich vor jeder Wandlung in `Int` prüfen: „1e20“ im Eingabefeld oder
        // `/api/airband?add=1e16` brachten die App sonst zum Absturz (Review 29.10.2026).
        guard let mhz = Double(cleaned), mhz.isFinite, (100...200).contains(mhz) else { return nil }
        let khzExact = mhz * 1000
        let khz = Int(khzExact.rounded())
        var index: Int?
        // Nur eine Nachkommastelle mehr als kHz? Dann Kanalname.
        if abs(khzExact - Double(khz)) < 0.0005 {
            let offset = khz - 118_000
            if offset >= 0 {
                let block = offset / 25, rest = offset % 25
                switch rest {
                case 0, 5: index = block * 3
                case 10: index = block * 3 + 1
                case 15: index = block * 3 + 2
                default: break
                }
            }
        }
        let resolved = index ?? Self.index(nearestHz: mhz * 1e6)
        // Echte Frequenzen müssen auf dem Raster liegen (± 1 kHz).
        if index == nil, abs(hz(resolved) - mhz * 1e6) > 1_000 { return nil }
        return range.contains(resolved) ? resolved : nil
    }

    /// Glatte MHz-Werte sind beim HackRF oft Störlinien (siehe Suchlauf).
    static func possiblySpur(_ index: Int) -> Bool { index % 120 == 0 }
}

/// Ein Eintrag der Kanalliste.
struct AirbandChannel: Codable, Identifiable, Hashable, Sendable {
    var id: Int { index }
    /// Rasterindex (siehe `AirbandGrid`).
    var index: Int
    var name: String
    /// Hat Vorrang vor allen anderen (Notfrequenz 121,5).
    var priority = false
    /// Gesperrt: wird nie hörbar (Dauerträger, ATIS, Störung).
    var locked = false

    var mhz: Double { AirbandGrid.mhz(index) }
    var channelName: String { AirbandGrid.channelName(index) }

    static let emergencyIndex = AirbandGrid.index(nearestHz: 121_500_000)
    static let defaults = [AirbandChannel(index: emergencyIndex, name: String(localized: "Notfrequenz"), priority: true)]

    static let defaultsKey = "airbandChannels"

    static func load() -> [AirbandChannel] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([AirbandChannel].self, from: data) else { return defaults }
        return list.filter { AirbandGrid.range.contains($0.index) }.sorted { $0.index < $1.index }
    }

    static func save(_ list: [AirbandChannel]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
}

/// Lage des Empfangsausschnitts im Raster.
struct AirbandWindow: Equatable, Sendable {
    /// Rasterindex der Mitte (dort liegt die Gleichspannungsspitze).
    var center: Int
    /// Kanäle der Filterbank (960 bei 8 MS/s, 1920 bei 16 MS/s).
    var bins: Int

    /// Nutzbar ist ±37,5 % der Abtastrate – das Basisbandfilter (75 % der
    /// Abtastrate) dämpft den Rand.
    var halfWidth: Int { Int(Double(bins) * 0.375) }

    /// Ablage in Kanälen, wenn nutzbar (nicht die Mitte, nicht am Rand).
    func offset(of index: Int) -> Int? {
        let offset = index - center
        guard offset != 0, abs(offset) <= halfWidth else { return nil }
        return offset
    }

    func covers(_ index: Int) -> Bool { offset(of: index) != nil }

    var centerHz: Double { AirbandGrid.hz(center) }

    /// Mitte, die möglichst viele Listenkanäle abdeckt; Vorrangkanäle zählen
    /// mehr. Kein Listenkanal darf auf der Mitte (DC) liegen. Bei Gleichstand
    /// die Mitte, die dem Schwerpunkt der abgedeckten Kanäle am nächsten liegt.
    static func best(for channels: [AirbandChannel], bins: Int) -> AirbandWindow {
        let probe = AirbandWindow(center: 0, bins: bins)
        let lo = probe.halfWidth, hi = AirbandGrid.count - 1 - probe.halfWidth
        let wanted = channels.filter { !$0.locked }
        guard !wanted.isEmpty else { return AirbandWindow(center: (lo + hi) / 2, bins: bins) }
        var best = (score: -1, distance: Double.infinity, center: lo)
        let indices = Set(wanted.map(\.index))
        for center in max(0, lo - probe.halfWidth)...min(AirbandGrid.count - 1, hi + probe.halfWidth) where !indices.contains(center) {
            let window = AirbandWindow(center: center, bins: bins)
            let covered = wanted.filter { window.covers($0.index) }
            let score = covered.reduce(0) { $0 + ($1.priority ? 1000 : 1) }
            guard score >= best.score, !covered.isEmpty else { continue }
            let mean = Double(covered.map(\.index).reduce(0, +)) / Double(covered.count)
            let distance = abs(Double(center) - mean)
            if score > best.score || distance < best.distance {
                best = (score, distance, center)
            }
        }
        return AirbandWindow(center: best.center, bins: bins)
    }

    /// Fenster, die zusammen das ganze Band abdecken (für den Suchlauf). Die
    /// Mitte jedes Fensters (DC) fehlt; `shift` verschiebt alle Mitten um so
    /// viele Kanäle – der Suchlauf wechselt je Runde, damit auch sie drankommen.
    static func sweep(bins: Int, shift: Int = 0) -> [AirbandWindow] {
        let half = AirbandWindow(center: 0, bins: bins).halfWidth
        var result: [AirbandWindow] = []
        var center = half + shift
        while true {
            result.append(AirbandWindow(center: min(center, AirbandGrid.count - 1 - half), bins: bins))
            if center + half >= AirbandGrid.count - 1 { break }
            center += 2 * half
        }
        return result
    }
}

/// Rauschsperre eines Kanals: Leistung je Messung gegen einen gelernten
/// Rauschboden (nach unten schnell, nach oben 0,3 dB/s – wie im Radio).
/// Ein Dauerträger hebt den Boden nach rund einer Minute und schließt sich so selbst.
struct ChannelSquelch: Sendable {
    var floorDB: Float = .nan
    var levelDB: Float = -150
    private(set) var open = false
    private var hold = 0.0
    private var streak = 0

    static let holdSeconds = 0.4

    var excessDB: Float { floorDB.isNaN ? 0 : levelDB - floorDB }

    /// Neue Leistungsmessung; liefert, ob das Signal über der Schwelle liegt
    /// (vor Nachlauf). `seconds`: Dauer der Messung.
    @discardableResult
    mutating func update(powerDB: Float, seconds: Double, thresholdDB: Float) -> Bool {
        levelDB = powerDB
        if floorDB.isNaN { floorDB = powerDB }
        else if powerDB < floorDB { floorDB += (powerDB - floorDB) * 0.3 }
        else { floorDB += Float(0.3 * seconds) }
        return powerDB > floorDB + thresholdDB
    }

    /// Nachlauf: offen bis `holdSeconds` nach dem letzten Treffer. Öffnen erst
    /// nach zwei Treffern in Folge (≈ 30 ms): das Ein- und Austasten eines
    /// starken Senders spritzt für einen Block in die Nachbarkanäle (im Test
    /// bis +15 dB zwei Kanäle weit) – ein echter Spruch dauert länger.
    mutating func gate(_ above: Bool, seconds: Double) {
        streak = above ? streak + 1 : 0
        if above && (open || streak >= 2) { hold = Self.holdSeconds } else { hold -= seconds }
        open = hold > 0
    }

    mutating func reset() {
        floorDB = .nan
        levelDB = -150
        open = false
        hold = 0
        streak = 0
    }

    /// Übersprechen: Ein Kanal gilt nicht als belegt, wenn ein Nachbar
    /// mindestens `margin` dB stärker über seinem Boden liegt – die Filterbank
    /// dämpft den Nachbarkanal um ≈ 60 dB, ein sehr starker Sender schimmert
    /// sonst daneben durch.
    static func isLeakage(excess: Float, neighborExcess: Float, margin: Float = 40) -> Bool {
        neighborExcess - excess > margin
    }
}

/// Wer gerade hörbar ist (reine Funktion, testbar).
enum AirbandSelector {
    struct Candidate: Equatable, Sendable {
        var index: Int
        var excessDB: Float
        var priority: Bool
        var locked: Bool
    }

    /// - `open`: Kanäle, deren Rauschsperre offen ist.
    /// - `current`: bisher hörbarer Kanal.
    /// - `hold`: festgehaltener Kanal – bleibt hörbar, auch wenn er schweigt.
    static func choose(open: [Candidate], current: Int?, hold: Int?) -> Int? {
        if let hold { return hold }
        let usable = open.filter { !$0.locked }
        // Vorrang (121,5) schlägt alles, auch einen laufenden Spruch.
        if let priority = usable.filter(\.priority).max(by: { $0.excessDB < $1.excessDB }) {
            return priority.index
        }
        // Ein laufender Spruch wird nicht unterbrochen.
        if let current, usable.contains(where: { $0.index == current }) { return current }
        return usable.max(by: { $0.excessDB < $1.excessDB })?.index
    }
}
