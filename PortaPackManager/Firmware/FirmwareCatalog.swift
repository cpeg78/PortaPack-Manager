import CryptoKit
import Foundation

/// Ein Release-Asset auf GitHub.
struct FirmwareAsset: Sendable, Hashable, Identifiable, Codable {
    let name: String
    let size: Int
    let downloadURL: URL
    /// Prüfsumme laut GitHub-API (`sha256:<hex>`), bei älteren Assets fehlt sie.
    var digest: String? = nil
    var id: String { downloadURL.absoluteString }

    /// SHA-256 in Kleinbuchstaben-Hex, falls die API eine geliefert hat.
    var sha256: String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? String(hex) : nil
    }

    /// Der Name dient als Dateiname im Cache. Er kommt aus dem Netz, also nur
    /// den letzten Pfadteil nehmen und `..`, Verstecktes und Leeres ablehnen.
    static func safeFileName(_ name: String) -> String? {
        let last = (name as NSString).lastPathComponent
        guard !last.isEmpty, last != "..", !last.hasPrefix("."), !last.contains("/"), !last.contains("\0") else { return nil }
        return last
    }

    var isFirmwarePackage: Bool { name.hasSuffix(".ppfw.tar") }

    /// Für welchen Gerätetyp das Paket gebaut ist (`OCI_<typ>_…`).
    var deviceType: DeviceType? {
        for type in DeviceType.allCases where name.lowercased().contains("_\(type.rawValue)_") {
            return type
        }
        return nil
    }
}

/// Ein Firmware-Release (stabil oder Nightly).
struct FirmwareRelease: Sendable, Hashable, Identifiable, Codable {
    let tag: String
    let title: String
    let publishedAt: Date
    let isPrerelease: Bool
    let notes: String
    let htmlURL: URL
    let assets: [FirmwareAsset]
    var id: String { tag }

    var version: FirmwareVersion { FirmwareVersion(tag: tag) }

    /// Das passende `.ppfw.tar` für einen Gerätetyp. Ältere Releases ohne
    /// Gerätetyp im Namen kannten nur den HackRF One – ihr typloses Paket gilt
    /// deshalb nur für `.hackrf`, nie für Pro oder PortaRF (anderer Flash).
    func package(for type: DeviceType) -> FirmwareAsset? {
        let packages = assets.filter(\.isFirmwarePackage)
        if let exact = packages.first(where: { $0.deviceType == type }) { return exact }
        return type == .hackrf ? packages.first { $0.deviceType == nil } : nil
    }
}

/// Holt die Release-Liste von GitHub.
actor FirmwareCatalog {
    static let repository = "portapack-mayhem/mayhem-firmware"
    /// Höchstgröße der Release-Liste von GitHub.
    static let catalogLimit = 10_000_000
    private let session: URLSession
    private(set) var releases: [FirmwareRelease] = []
    private(set) var lastFetch: Date?

    init(session: URLSession = .shared) {
        self.session = session
    }

    @discardableResult
    func refresh(perPage: Int = 40) async throws -> [FirmwareRelease] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=\(perPage)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PortaPackManager", forHTTPHeaderField: "User-Agent")
        // Mit Größengrenze (Review 28.10.2026): 40 Releases sind ≈ 0,5 MB.
        let (data, response) = try await session.limitedData(for: request, limit: Self.catalogLimit)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CatalogError.httpStatus(http.statusCode, Self.rateLimitHint(http))
        }
        let parsed = try Self.parse(data)
        releases = parsed
        lastFetch = Date()
        return parsed
    }

    var latestStable: FirmwareRelease? { releases.first { !$0.isPrerelease && $0.version.isStable } }
    var latestNightly: FirmwareRelease? { releases.first { $0.isPrerelease && $0.version.isNightly } }
    var nightlies: [FirmwareRelease] { releases.filter { $0.isPrerelease } }
    var stables: [FirmwareRelease] { releases.filter { !$0.isPrerelease } }

    nonisolated static func parse(_ data: Data) throws -> [FirmwareRelease] {
        struct APIAsset: Decodable {
            let name: String
            let size: Int
            let browser_download_url: URL
            let digest: String?
        }
        struct APIRelease: Decodable {
            let tag_name: String
            let name: String?
            let published_at: Date
            let prerelease: Bool
            let body: String?
            let html_url: URL
            let assets: [APIAsset]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([APIRelease].self, from: data).map { api in
            FirmwareRelease(
                tag: api.tag_name,
                title: api.name ?? api.tag_name,
                publishedAt: api.published_at,
                isPrerelease: api.prerelease,
                notes: api.body ?? "",
                htmlURL: api.html_url,
                assets: api.assets.compactMap { asset in
                    // Namen ohne sicheren Dateinamen (Pfadteile, „..“) fallen weg.
                    guard let name = FirmwareAsset.safeFileName(asset.name), asset.size >= 0 else { return nil }
                    return FirmwareAsset(name: name, size: asset.size, downloadURL: asset.browser_download_url, digest: asset.digest)
                })
        }.sorted { $0.publishedAt > $1.publishedAt }
    }

    private static func rateLimitHint(_ response: HTTPURLResponse) -> String? {
        guard response.statusCode == 403 || response.statusCode == 429,
              let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining"), remaining == "0",
              let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset"), let seconds = TimeInterval(reset)
        else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return String(localized: "GitHub lässt gerade keine weiteren Anfragen zu – versuch es ab \(date.formatted(date: .omitted, time: .shortened)) wieder.")
    }

    enum CatalogError: Error, LocalizedError {
        case httpStatus(Int, String?)
        case incompleteDownload(name: String, received: Int64, expected: Int)
        case digestMismatch(name: String)
        case unsafeName(String)
        case tooLarge(name: String, expected: Int)
        var errorDescription: String? {
            switch self {
            case let .httpStatus(code, hint):
                return hint ?? String(localized: "GitHub antwortete mit Status \(code).")
            case let .incompleteDownload(name, received, expected):
                return String(localized: "Der Download von \(name) ist unvollständig (\(received) von \(expected) Bytes). Versuch es noch einmal.")
            case let .digestMismatch(name):
                return String(localized: "Der Download von \(name) ist beschädigt (Prüfsumme stimmt nicht). Versuch es noch einmal.")
            case let .unsafeName(name):
                return String(localized: "Ungültiger Dateiname in der Firmware-Version: \(name)")
            case let .tooLarge(name, expected):
                return String(localized: "Der Download von \(name) wurde abgebrochen: größer als die angekündigten \(expected) Bytes.")
            }
        }
    }
}

/// Lädt Assets in den Cache-Ordner der App und meldet den Fortschritt.
///
/// Erst nach vollständiger Prüfung (Größe laut API und, falls geliefert,
/// SHA-256) wird aus der `.part`-Datei die eigentliche – ein abgeschnittener
/// Download landete sonst im Cache und später im Flash.
actor FirmwareDownloader {
    static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("de.christiangolz.portapackmanager/Firmware", isDirectory: true)
    }()

    private static func destination(for asset: FirmwareAsset) throws -> URL {
        guard let name = FirmwareAsset.safeFileName(asset.name) else { throw FirmwareCatalog.CatalogError.unsafeName(asset.name) }
        return cacheDirectory.appendingPathComponent(name)
    }

    /// Die Datei im Cache, wenn Größe und (falls bekannt) SHA-256 stimmen.
    /// Eine beschädigte Datei wird gelöscht, damit sie neu geladen wird.
    func cachedFile(for asset: FirmwareAsset) -> URL? {
        guard let url = try? Self.destination(for: asset),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size == asset.size else { return nil }
        if let expected = asset.sha256 {
            guard let actual = try? Self.sha256(of: url), actual == expected else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        return url
    }

    func download(_ asset: FirmwareAsset, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws -> URL {
        if let cached = cachedFile(for: asset) {
            progress(Int64(asset.size), Int64(asset.size))
            return cached
        }
        try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        let destination = try Self.destination(for: asset)
        let temporary = destination.appendingPathExtension("part")
        var finished = false
        defer {
            // Bei jedem Fehler (auch Abbruch) die halbe Datei wegräumen.
            if !finished { try? FileManager.default.removeItem(at: temporary) }
        }

        // Als Datei laden (URLSession schreibt selbst), danach hashen – vorher
        // lief jedes Byte einzeln über AsyncBytes (Review 28.10.2026). Wird
        // die angekündigte Größe überschritten, bricht der Download sofort ab.
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("PortaPackManager", forHTTPHeaderField: "User-Agent")
        let response: URLResponse
        do {
            response = try await FileDownload.run(request, to: temporary, limit: Int64(asset.size), progress: progress)
        } catch is FileDownload.TooLarge {
            throw FirmwareCatalog.CatalogError.tooLarge(name: asset.name, expected: asset.size)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FirmwareCatalog.CatalogError.httpStatus(http.statusCode, nil)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let received = Int64((attributes[.size] as? Int) ?? 0)
        guard received == Int64(asset.size) else {
            throw FirmwareCatalog.CatalogError.incompleteDownload(name: asset.name, received: received, expected: asset.size)
        }
        if let wanted = asset.sha256 {
            let actual = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: temporary) }.value
            guard actual == wanted else { throw FirmwareCatalog.CatalogError.digestMismatch(name: asset.name) }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        finished = true
        progress(received, Int64(asset.size))
        return destination
    }

    /// SHA-256 einer Datei, stückweise gelesen (SD-Pakete haben über 500 MB).
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Lädt eine Datei mit `URLSessionDownloadTask` nach `target`, meldet den
/// Fortschritt und bricht ab, sobald mehr als `limit` Bytes ankommen.
enum FileDownload {
    static func run(_ request: URLRequest, to target: URL, limit: Int64,
                    progress: @Sendable @escaping (Int64, Int64) -> Void) async throws -> URLResponse {
        let delegate = Delegate(target: target, limit: limit, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Größer als angekündigt.
    struct TooLarge: Error {}

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let target: URL
        let limit: Int64
        let progress: @Sendable (Int64, Int64) -> Void
        private let lock = NSLock()
        private var stored: CheckedContinuation<URLResponse, Error>?
        private var exceeded = false
        private var moveError: Error?
        private var lastReport = Date.distantPast

        var continuation: CheckedContinuation<URLResponse, Error>? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }

        init(target: URL, limit: Int64, progress: @Sendable @escaping (Int64, Int64) -> Void) {
            self.target = target
            self.limit = limit
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > limit {
                lock.withLock { exceeded = true }
                downloadTask.cancel()
                return
            }
            let report = lock.withLock { () -> Bool in
                guard Date().timeIntervalSince(lastReport) > 0.1 else { return false }
                lastReport = Date()
                return true
            }
            if report { progress(totalBytesWritten, limit) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // Die Datei verschwindet nach der Rückkehr – sofort verschieben.
            do {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: location, to: target)
            } catch {
                lock.withLock { moveError = error }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, exceeded, moveError) = lock.withLock { () -> (CheckedContinuation<URLResponse, Error>?, Bool, Error?) in
                defer { stored = nil }
                return (stored, self.exceeded, self.moveError)
            }
            guard let continuation else { return }
            if exceeded {
                continuation.resume(throwing: TooLarge())
            } else if let error {
                continuation.resume(throwing: error)
            } else if let moveError {
                continuation.resume(throwing: moveError)
            } else if let response = task.response {
                continuation.resume(returning: response)
            } else {
                continuation.resume(throwing: URLError(.badServerResponse))
            }
        }
    }
}
