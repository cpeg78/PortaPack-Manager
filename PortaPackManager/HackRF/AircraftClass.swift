import Foundation

/// Art und Größe eines Luftfahrzeugs für das Kartensymbol (Wunsch 03.11.2026:
/// „Heli als Heli darstellen, nach Flugzeuggrößen Symbole zeigen“).
///
/// Reihenfolge der Quellen: die ADS-B-Kategorie, die das Flugzeug selbst
/// sendet (TC 1–4, Feld CA), dann die Kategorie aus der OpenSky-Datenbank
/// (bei kaum 1 % der Einträge gefüllt), dann der ICAO-Typcode. Was keine
/// Quelle hergibt, gilt als Verkehrsflugzeug.
enum AircraftClass: String, Sendable, Encodable, CaseIterable {
    case helicopter, light, glider, medium, heavy

    /// `emitter` = TC << 3 | CA aus der Kennungsmeldung (siehe `Aircraft.emitter`).
    static func of(emitter: Int?, info: AircraftInfo?) -> AircraftClass {
        if let emitter, let kind = fromEmitter(emitter) { return kind }
        if let info {
            if let kind = fromCategory(info.category) { return kind }
            if let kind = fromTypeCode(info.typeCode) { return kind }
        }
        return .medium
    }

    /// DO-260B: Satz A (TC 4) nach Gewicht, Satz B (TC 3) Sonderfälle.
    static func fromEmitter(_ emitter: Int) -> AircraftClass? {
        switch (emitter >> 3, emitter & 7) {
        case (4, 1): .light            // < 7 t
        case (4, 2), (4, 3), (4, 4), (4, 6): .medium
        case (4, 5): .heavy            // > 136 t
        case (4, 7): .helicopter
        case (3, 1): .glider
        case (3, 2), (3, 4), (3, 6): .light   // Ballon, Ultraleicht, Drohne
        default: nil
        }
    }

    /// OpenSky `categoryDescription`.
    static func fromCategory(_ text: String) -> AircraftClass? {
        let t = text.lowercased()
        if t.hasPrefix("rotorcraft") { return .helicopter }
        if t.hasPrefix("glider") { return .glider }
        if t.hasPrefix("light") || t.hasPrefix("ultralight") || t.hasPrefix("lighter") || t.hasPrefix("unmanned") { return .light }
        if t.hasPrefix("heavy") { return .heavy }
        if t.hasPrefix("small") || t.hasPrefix("large") || t.hasPrefix("high") { return .medium }
        return nil
    }

    static func fromTypeCode(_ code: String) -> AircraftClass? {
        let c = code.uppercased()
        guard !c.isEmpty else { return nil }
        if helicopters.contains(c) { return .helicopter }
        if c == "GLID" { return .glider }
        if heavyCodes.contains(c) || heavyPrefixes.contains(where: c.hasPrefix) { return .heavy }
        if lightPrefixes.contains(where: c.hasPrefix) { return .light }
        return nil
    }

    /// Hubschrauber-Typcodes, gesammelt aus der OpenSky-Datenbank (Hersteller
    /// bzw. Modell mit Helicopter, Robinson, Sikorsky, Agusta, Kamov …).
    static let helicopters: Set<String> = [
        "R22", "R44", "R66", "B06", "B105", "B212", "B214", "B222", "B230", "B407", "B412", "B427", "B429",
        "B430", "B47G", "B47J", "B505", "B609", "AS32", "AS3B", "AS50", "AS55", "AS65", "A109", "A119",
        "A139", "A169", "A189", "EC20", "EC25", "EC30", "EC35", "EC45", "EC55", "EC75", "H160", "H175",
        "BK17", "EXPL", "MD52", "MD60", "H500", "H269", "EN28", "EN48", "S61", "S61R", "S64", "S76", "S92",
        "S330", "S55P", "S58P", "S58T", "H60", "H53", "H53S", "H47", "H64", "UH1", "UH12", "UHEL", "NH90",
        "MH90", "TIGR", "LYNX", "GAZL", "PUMA", "SA37", "KA26", "KA27", "KA32", "MI2", "MI6", "MI8",
        "MI17", "MI24", "MI26", "MI34", "MI38", "M171", "EH10", "G2CA",
    ]
    /// Großraumflugzeuge (Wirbelschleppenkategorie Heavy).
    static let heavyPrefixes = [
        "A30", "A31", "A33", "A34", "A35", "A38", "A124", "A225", "A3ST", "A337", "A400", "B74", "B76",
        "B77", "B78", "BLCF", "MD11", "DC10", "L101", "IL76", "IL86", "IL96", "AN22", "K35R", "KC10", "B52",
    ]
    /// Kurze Codes nur genau – als Präfix träfe „C17“ die Cessna 172 und
    /// „C5“ die Citation C560.
    static let heavyCodes: Set<String> = ["C5", "C5M", "C17", "E3TF", "E3CF"]
    /// Klein- und Sportflugzeuge.
    static let lightPrefixes = [
        "C1", "C2", "P28", "P32", "P46", "PA1", "PA2", "PA3", "PA4", "DA2", "DA4", "DA6", "SR2", "BE3",
        "M20", "PC6", "PC12", "TBM", "RV", "ULAC", "GYRO", "DR4", "J3", "AAT3", "FDCT", "EV97", "Z42",
        "Z43", "G115", "AN2", "S22T", "EXTR", "TOBA", "TRIN",
    ]

    /// Kartenzeichen und Kantenlänge (Mac-Karte; das Handy rechnet ×1,2).
    var symbol: MapSymbol {
        switch self {
        case .helicopter: .helicopter
        case .light: .planeLight
        case .glider: .glider
        case .medium, .heavy: .plane
        }
    }

    var symbolSize: Double {
        switch self {
        case .light: 18
        case .glider, .helicopter, .medium: 22
        case .heavy: 28
        }
    }
}
