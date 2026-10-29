import Foundation
@testable import PortaPackManager

/// Archiv-Datenbank in einem eigenen Temp-Ordner – Tests berühren nie die echte Ablage.
struct TestDatabase {
    let folder: URL
    let database: ArchiveDatabase

    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("archiv-db-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = ArchiveDatabase(url: folder.appendingPathComponent(ArchiveDatabase.fileName))
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    /// Packt Daten wie früher die Archivpflege (`.lzma`).
    static func lzma(_ data: Data) -> Data {
        (try? (data as NSData).compressed(using: .lzma) as Data) ?? Data()
    }
}
