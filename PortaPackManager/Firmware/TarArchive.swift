import Foundation

/// Leser für tar-Archive (POSIX-ustar und GNU) – genug für die
/// `.ppfw.tar`-Pakete von Mayhem (Verzeichnisse `APPS/` und `FIRMWARE/`,
/// reguläre Dateien). Mayhem baut sie mit GNU tar (Magic `ustar  `).
///
/// Streng, weil aus diesen Bytes am Ende der SPI-Flash beschrieben wird:
/// Magic und Kopf-Prüfsumme müssen stimmen, Größen dürfen nicht negativ sein
/// oder über das Archivende reichen, und das Archiv muss mit einem Nullblock
/// enden – sonst ist der Download abgeschnitten.
struct TarArchive: Sendable {
    struct Entry: Sendable, Identifiable {
        let name: String
        let size: Int
        let isDirectory: Bool
        /// Nur Typ `'0'`/`'\0'` – Links, Geräte und Erweiterungsköpfe nicht.
        let isFile: Bool
        let offset: Int
        var id: String { name }
    }

    let data: Data
    let entries: [Entry]

    /// Mehr Kopfblöcke sind in einem Firmware-Paket nicht zu erwarten; die
    /// Grenze verhindert, dass ein präpariertes Archiv ewig gelesen wird.
    static let maximumEntries = 100_000

    init(data input: Data) throws {
        // Eigene Kopie mit Index 0 – ein Data-Ausschnitt behielte die Indizes
        // des Ganzen, und `data[offset…]` griffe daneben.
        let data = Data(input)
        self.data = data
        var entries: [Entry] = []
        var offset = 0
        var sawEndBlock = false
        // Aus GNU-`L`- bzw. pax-`x`-Köpfen: Name für den nächsten Eintrag.
        var pendingLongName: String?

        while offset + 512 <= data.count {
            let header = data[offset..<offset + 512]
            // Zwei Nullblöcke beenden das Archiv (einer genügt uns).
            if header.allSatisfy({ $0 == 0 }) {
                sawEndBlock = true
                break
            }
            guard entries.count < Self.maximumEntries else { throw TarError.invalid }
            let format = try Self.format(of: header)
            guard Self.checksumMatches(header) else { throw TarError.badChecksum(offset: offset) }

            let size = try Self.size(header)
            let dataStart = offset + 512
            // Inhalt muss vollständig im Archiv liegen – ein abgeschnittener
            // Download endet sonst mitten in der Datei.
            guard size <= data.count - dataStart else { throw TarError.truncated }
            let blocks = (size + 511) / 512
            let next = dataStart + blocks * 512

            let typeFlag = header[header.startIndex + 156]
            switch typeFlag {
            case UInt8(ascii: "L"):
                // GNU-Langname: Inhalt ist der Name des folgenden Eintrags.
                pendingLongName = Self.cString(data[dataStart..<dataStart + size])
            case UInt8(ascii: "x"):
                // pax-Erweiterung für den folgenden Eintrag; nur `path` zählt.
                if let path = Self.paxPath(data[dataStart..<dataStart + size]) { pendingLongName = path }
            case UInt8(ascii: "g"), UInt8(ascii: "K"):
                // Globale pax-Angaben, GNU-Langer-Linkname: für uns ohne Belang.
                break
            default:
                let name = Self.string(header, at: 0, length: 100)
                // Das Präfixfeld gibt es nur in POSIX-ustar; bei GNU stehen an
                // derselben Stelle Zeitstempel.
                let prefix = format == .posix ? Self.string(header, at: 345, length: 155) : ""
                let fullName = pendingLongName ?? (prefix.isEmpty ? name : prefix + "/" + name)
                pendingLongName = nil
                let isDirectory = typeFlag == UInt8(ascii: "5")
                let isFile = (typeFlag == UInt8(ascii: "0") || typeFlag == 0) && !fullName.hasSuffix("/")
                if !fullName.isEmpty {
                    entries.append(Entry(name: fullName, size: size, isDirectory: isDirectory || fullName.hasSuffix("/"),
                                         isFile: isFile, offset: dataStart))
                }
            }
            offset = next
        }
        guard !entries.isEmpty else { throw TarError.invalid }
        guard sawEndBlock else { throw TarError.truncated }
        self.entries = entries
    }

    /// Inhalt eines Eintrags. Wirft, wenn er nicht vollständig im Archiv liegt –
    /// still leere Daten hätten beim Flashen einen gelöschten Chip hinterlassen.
    func contents(of entry: Entry) throws -> Data {
        guard entry.offset >= 0, entry.size >= 0, entry.offset <= data.count, entry.size <= data.count - entry.offset else {
            throw TarError.truncated
        }
        return data.subdata(in: entry.offset..<entry.offset + entry.size)
    }

    var files: [Entry] { entries.filter(\.isFile) }
    /// Apps unter `APPS/`; Namen, deren letzter Teil leer, `.` oder `..` ist,
    /// fallen weg – sie landen sonst als `/APPS/..` auf der Karte.
    var apps: [Entry] {
        files.filter { entry in
            guard entry.name.uppercased().hasPrefix("APPS/") else { return false }
            let last = Self.lastComponent(entry.name)
            return !last.isEmpty && last != "." && last != ".."
        }
    }
    var firmwareImages: [Entry] { files.filter { $0.name.lowercased().hasSuffix(".bin") } }

    static func lastComponent(_ name: String) -> String {
        name.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }

    enum TarError: Error, LocalizedError, Equatable {
        case invalid
        case badChecksum(offset: Int)
        case truncated
        case unsupportedSize

        var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "Die Datei ist kein lesbares Firmware-Paket (tar).")
            case let .badChecksum(offset): String(localized: "Das Firmware-Paket ist beschädigt (Prüfsumme bei Byte \(offset) stimmt nicht).")
            case .truncated: String(localized: "Das Firmware-Paket ist unvollständig – vermutlich wurde der Download abgebrochen. Lade es noch einmal.")
            case .unsupportedSize: String(localized: "Das Firmware-Paket enthält eine ungültige Größenangabe.")
            }
        }
    }

    // MARK: - Kopf

    enum Format { case posix, gnu }

    /// `ustar\0` + `00` (POSIX) oder `ustar  \0` (GNU); alles andere ist kein
    /// Archiv, das wir lesen wollen.
    private static func format(of header: Data) throws -> Format {
        let base = header.startIndex
        let magic = Array(header[base + 257..<base + 265])
        if magic[0..<6].elementsEqual("ustar\0".utf8) { return .posix }
        if magic.elementsEqual("ustar  \0".utf8) { return .gnu }
        throw TarError.invalid
    }

    /// Summe aller Kopfbytes, das Prüfsummenfeld als Leerzeichen gezählt.
    /// Manche alten Programme summieren vorzeichenbehaftet – beides gilt.
    static func checksumMatches(_ header: Data) -> Bool {
        let base = header.startIndex
        guard let stored = octal(header, at: 148, length: 8), stored >= 0 else { return false }
        var unsigned = 0
        var signed = 0
        for index in 0..<512 {
            let byte = (148..<156).contains(index) ? UInt8(ascii: " ") : header[base + index]
            unsigned += Int(byte)
            signed += Int(Int8(bitPattern: byte))
        }
        return stored == unsigned || stored == signed
    }

    private static func size(_ header: Data) throws -> Int {
        // Basis-256 (erstes Byte mit gesetztem Hochbit) gibt es nur für Dateien
        // über 8 GiB – in einem Firmware-Paket ein Fehler.
        guard header[header.startIndex + 124] & 0x80 == 0 else { throw TarError.unsupportedSize }
        guard let value = octal(header, at: 124, length: 12), value >= 0 else { throw TarError.unsupportedSize }
        return value
    }

    private static func string(_ header: Data, at position: Int, length: Int) -> String {
        let start = header.startIndex + position
        return cString(header[start..<start + length])
    }

    private static func cString(_ bytes: Data) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Oktalzahl aus einem Kopffeld; `nil` bei Unsinn. Ein leeres Feld gilt als 0.
    /// Nur Ziffern 0–7 – `Int(_:radix:)` nähme auch ein Minuszeichen an.
    static func octal(_ header: Data, at position: Int, length: Int) -> Int? {
        let text = string(header, at: position, length: length).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "7")).contains($0) }), text.count <= 21 else { return nil }
        return Int(text, radix: 8)
    }

    /// `path` aus pax-Sätzen der Form `<länge> <schlüssel>=<wert>\n`.
    static func paxPath(_ bytes: Data) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        var path: String?
        for record in text.split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let keyValue = record[record.index(after: space)...]
            guard let equals = keyValue.firstIndex(of: "=") else { continue }
            if keyValue[..<equals] == "path" { path = String(keyValue[keyValue.index(after: equals)...]) }
        }
        return path
    }
}
