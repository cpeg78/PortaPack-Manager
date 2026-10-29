import Foundation

/// Liest das zentrale Inhaltsverzeichnis eines ZIP-Archivs, ohne zu entpacken:
/// Namen, entpackte Größen, Links. Damit lässt sich vor `ditto` prüfen, ob
/// das Paket auf die Platte passt und ob ein Pfad aus dem Ziel hinausführte.
enum ZipDirectory {
    struct Entry: Sendable, Equatable {
        var name: String
        var uncompressedSize: Int64
        var isSymlink: Bool

        /// Kein absoluter Pfad, kein `..`-Teil, kein Link.
        var isSafe: Bool {
            guard !isSymlink, !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
            return !name.split(separator: "/").contains("..")
        }
    }

    struct Listing: Sendable {
        var entries: [Entry]
        var uncompressedSize: Int64 { entries.reduce(0) { $0 + $1.uncompressedSize } }
    }

    enum ZipError: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(reason) = self { return String(localized: "Das ZIP-Paket ist beschädigt (\(reason)).") }
            return nil
        }
    }

    static func read(_ url: URL) throws -> Listing {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        // Ende des Verzeichnisses: 22 Bytes + Kommentar bis 64 KiB.
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: UInt64(fileSize - tailLength))
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        let (count, size, offset) = try endOfDirectory(tail, tailStart: fileSize - tailLength, handle: handle)
        guard size >= 0, offset >= 0, offset + size <= fileSize, size <= 512 * 1024 * 1024 else {
            throw ZipError.invalid("Verzeichnis außerhalb der Datei")
        }
        try handle.seek(toOffset: UInt64(offset))
        let directory = try handle.read(upToCount: Int(size)) ?? Data()
        return Listing(entries: try parseDirectory(directory, expectedCount: count))
    }

    /// Findet „End of central directory“ (ggf. ZIP64) und liefert
    /// Eintragszahl, Größe und Anfang des zentralen Verzeichnisses.
    static func endOfDirectory(_ tail: Data, tailStart: Int64, handle: FileHandle?) throws -> (count: Int, size: Int64, offset: Int64) {
        let bytes = [UInt8](tail)
        guard bytes.count >= 22 else { throw ZipError.invalid("zu kurz") }
        var position = bytes.count - 22
        while position >= 0 {
            if le32(bytes, position) == 0x0605_4B50 { break }
            position -= 1
        }
        guard position >= 0 else { throw ZipError.invalid("kein Verzeichnisende") }
        var count = Int(le16(bytes, position + 10))
        var size = Int64(le32(bytes, position + 12))
        var offset = Int64(le32(bytes, position + 16))
        // ZIP64: Locator steht 20 Bytes vor dem normalen Ende.
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            let locator = position - 20
            guard locator >= 0, le32(bytes, locator) == 0x0706_4B50, let handle else { throw ZipError.invalid("ZIP64 ohne Locator") }
            let record = Int64(le64(bytes, locator + 8))
            try handle.seek(toOffset: UInt64(record))
            let zip64 = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard zip64.count == 56, le32(zip64, 0) == 0x0606_4B50 else { throw ZipError.invalid("ZIP64-Ende fehlt") }
            count = Int(clamping: le64(zip64, 32))
            size = Int64(clamping: le64(zip64, 40))
            offset = Int64(clamping: le64(zip64, 48))
        }
        return (count, size, offset)
    }

    static func parseDirectory(_ data: Data, expectedCount: Int) throws -> [Entry] {
        let bytes = [UInt8](data)
        var entries: [Entry] = []
        var position = 0
        while position + 46 <= bytes.count, le32(bytes, position) == 0x0201_4B50 {
            let madeBy = le16(bytes, position + 4) >> 8
            var uncompressed = Int64(le32(bytes, position + 24))
            let nameLength = Int(le16(bytes, position + 28))
            let extraLength = Int(le16(bytes, position + 30))
            let commentLength = Int(le16(bytes, position + 32))
            let external = le32(bytes, position + 38)
            let nameStart = position + 46
            let end = nameStart + nameLength + extraLength + commentLength
            guard end <= bytes.count else { throw ZipError.invalid("Eintrag abgeschnitten") }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
            if uncompressed == 0xFFFF_FFFF {
                // ZIP64-Zusatzfeld 0x0001: erste Angabe ist die entpackte Größe.
                var extra = nameStart + nameLength
                let extraEnd = extra + extraLength
                while extra + 4 <= extraEnd {
                    let id = le16(bytes, extra), length = Int(le16(bytes, extra + 2))
                    if id == 0x0001, length >= 8, extra + 12 <= extraEnd {
                        uncompressed = Int64(clamping: le64(bytes, extra + 4))
                        break
                    }
                    extra += 4 + length
                }
            }
            // Unix-Rechte im oberen Halbwort, wenn „made by“ Unix (3) ist.
            let isSymlink = madeBy == 3 && (external >> 16) & 0o170000 == 0o120000
            entries.append(Entry(name: name, uncompressedSize: max(0, uncompressed), isSymlink: isSymlink))
            position = end
        }
        guard expectedCount == 0xFFFF || entries.count == expectedCount else {
            throw ZipError.invalid("\(entries.count) statt \(expectedCount) Einträge")
        }
        return entries
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(le16(b, i)) | UInt32(le16(b, i + 2)) << 16 }
    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32 }
}
