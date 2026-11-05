import Foundation

/// Markiertes Stück eines Lauftexts: Titel, Interpret, Sendung …
struct RadioTextTag: Sendable, Equatable {
    let type: Int
    let text: String

    var name: String? { RadioTextPlus.name(type) }
}

/// RadioText+ (RDS, IEC 62106-2 Anhang P) und DL Plus (DAB, ETSI TS 102 980)
/// markieren Teile des Lauftexts mit derselben Tabelle von Inhaltsarten –
/// Anfang und Länge in Zeichen. Gedeutet werden die Arten, die ein Hörer
/// braucht; der Rest bleibt unbenannt.
enum RadioTextPlus {
    /// Eine Markierung: Inhaltsart, erstes Zeichen, Zahl der Zeichen.
    struct Marker: Sendable, Equatable {
        let type: Int
        let start: Int
        let length: Int
    }

    static let title = 1, album = 2, artist = 4, composer = 8, band = 9, programme = 33, host = 36

    static func name(_ type: Int) -> String? {
        switch type {
        case title: String(localized: "Titel")
        case album: String(localized: "Album")
        case artist: String(localized: "Interpret")
        case composer: String(localized: "Komponist")
        case band: String(localized: "Band")
        case programme: String(localized: "Sendung")
        case host: String(localized: "Moderation")
        default: nil
        }
    }

    /// Markierungen (Art, Anfang, Länge) auf den Text anwenden; Stücke außerhalb
    /// des Texts und die Art 0 (Platzhalter) fallen weg.
    static func tags(in text: String, markers: [Marker]) -> [RadioTextTag] {
        let characters = Array(text)
        return markers.compactMap { marker in
            guard marker.type > 0, marker.start >= 0, marker.length > 0, marker.start < characters.count else { return nil }
            let end = min(characters.count, marker.start + marker.length)
            let piece = String(characters[marker.start..<end]).trimmingCharacters(in: .whitespaces)
            return piece.isEmpty ? nil : RadioTextTag(type: marker.type, text: piece)
        }
    }

    /// „Interpret – Titel“, sonst was davon da ist; `nil` ohne beides.
    static func nowPlaying(_ tags: [RadioTextTag]) -> String? {
        let title = tags.first { $0.type == title }?.text
        let artist = tags.first { $0.type == artist || $0.type == band }?.text
        switch (artist, title) {
        case let (artist?, title?): return "\(artist) – \(title)"
        case let (nil, title?): return title
        case let (artist?, nil): return artist
        default: return nil
        }
    }
}
