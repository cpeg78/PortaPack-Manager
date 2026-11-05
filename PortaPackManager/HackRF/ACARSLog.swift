import Foundation

/// ACARS/VDL2-Meldungen in der Archiv-Datenbank (Tabelle `acars_messages`
/// samt Volltextindex `acars_fts`). Gespeichert wird erst, was fertig ist:
/// eine mehrteilige Meldung, sobald der letzte Block da ist – oder nach
/// `completionTimeout`, falls er nie kommt. Bleibt auf dem Mac.
struct ACARSLog: Sendable {
    static let completionTimeout: TimeInterval = 120

    let database: ArchiveDatabase

    static let standard = ACARSLog(database: .shared)

    /// Meldungen, die jetzt zu sichern sind: fertig oder lange genug offen und
    /// noch nicht gesichert.
    static func finished(_ messages: [ACARSMessage], stored: Set<Int>, now: Date) -> [ACARSMessage] {
        messages.filter { message in
            !stored.contains(message.id)
                && (!message.continued || now.timeIntervalSince(message.date) >= completionTimeout)
        }
    }

    func insert(_ items: [ACARSMessage]) {
        guard !items.isEmpty else { return }
        database.write("Datenfunk sichern") { try $0.insertACARS(items) }
    }

    /// Suche aus dem Suchfeld: Wörter im Meldungstext (das letzte auch als
    /// Wortanfang); sieht die Eingabe wie ein Kennzeichen oder Flug aus
    /// („D-AIBL“, „DLH4AB“), kommen dessen Meldungen dazu.
    func search(userInput: String, limit: Int = 500) async -> [ACARSMessage] {
        let input = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count >= 2 else { return [] }
        let match = FullTextSearch.query(input)
        let identifier = input.uppercased()
        let looksLikeIdentifier = !identifier.contains(" ") && identifier.count <= 8
            && identifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        return (try? await database.read {
            try $0.searchACARS(match, identifier: looksLikeIdentifier ? identifier : nil, limit: limit)
        }) ?? []
    }
}
