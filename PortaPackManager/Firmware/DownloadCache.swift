import Foundation

/// Überblick über die heruntergeladenen Pakete im Cache und deren Löschung.
/// Ein Eintrag fasst den Download und das daraus entpackte SD-Paket
/// zusammen (gleicher Name ohne Endung), damit beides gemeinsam verschwindet.
struct DownloadCache: Sendable {
    var downloadDirectory: URL = FirmwareDownloader.cacheDirectory
    var extractionDirectory: URL = SDCardPackage.extractionDirectory

    struct Entry: Identifiable, Sendable, Equatable {
        var name: String
        var urls: [URL]
        var size: Int64
        var modified: Date
        /// Abgebrochener Download (`.part`).
        var isPartial: Bool
        /// Es gibt ein entpacktes SD-Paket dazu.
        var isExtracted: Bool
        var id: String { name }
    }

    func entries() -> [Entry] {
        var byName: [String: Entry] = [:]
        for url in contents(of: downloadDirectory) {
            let partial = url.pathExtension == "part"
            let file = partial ? url.deletingPathExtension() : url
            let name = Self.stem(of: file.lastPathComponent)
            var entry = byName[name] ?? Entry(name: name, urls: [], size: 0, modified: .distantPast, isPartial: false, isExtracted: false)
            entry.urls.append(url)
            entry.size += Self.size(of: url)
            entry.modified = max(entry.modified, Self.modified(url))
            entry.isPartial = entry.isPartial || partial
            byName[name] = entry
        }
        for url in contents(of: extractionDirectory) {
            let name = url.lastPathComponent
            var entry = byName[name] ?? Entry(name: name, urls: [], size: 0, modified: .distantPast, isPartial: false, isExtracted: false)
            entry.urls.append(url)
            entry.size += Self.size(of: url)
            entry.modified = max(entry.modified, Self.modified(url))
            entry.isExtracted = true
            byName[name] = entry
        }
        return byName.values.sorted { $0.modified > $1.modified }
    }

    func remove(_ entry: Entry) throws {
        for url in entry.urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func removeAll() throws {
        for directory in [downloadDirectory, extractionDirectory] where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Hilfen

    private func contents(of directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// Name ohne Paketendung: `x.zip` → `x`, `x.ppfw.tar` → `x`.
    static func stem(of fileName: String) -> String {
        for suffix in [".ppfw.tar", ".zip", ".tar", ".bin"] where fileName.lowercased().hasSuffix(suffix) {
            return String(fileName.dropLast(suffix.count))
        }
        return fileName
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Belegter Platz einer Datei oder – rekursiv – eines Ordners.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        func bytes(_ v: URLResourceValues) -> Int64 { Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0) }
        guard values.isDirectory == true else { return bytes(values) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let child = enumerator?.nextObject() as? URL {
            if let v = try? child.resourceValues(forKeys: keys), v.isDirectory != true { total += bytes(v) }
        }
        return total
    }
}
