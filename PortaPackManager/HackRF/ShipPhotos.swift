import Foundation
import Observation

/// Schiffsfotos von Wikimedia Commons über die IMO-Nummer. Commons ordnet
/// Schiffe in „Category:IMO <nummer>“ ein; darin liegen Dateien oder (meist)
/// eine Unterkategorie je Schiff („Emma Mærsk (ship, 2006)“) mit den Fotos.
/// Freie Lizenzen verlangen Urheber und Lizenz – beides kommt mit der Antwort.
/// Nur im Speicher.
@MainActor
@Observable
final class ShipPhotoLookup {
    static let shared = ShipPhotoLookup()
    static let enabledKey = "aisOnlinePhotos"
    static let api = "https://commons.wikimedia.org/w/api.php"
    /// Wikimedia bittet um einen User-Agent mit Kontakt.
    static let userAgent = AircraftPhotoLookup.userAgent

    private(set) var photos: [Int: InfoCardPhoto] = [:]
    private(set) var error: String?
    @ObservationIgnored private var asked: Set<Int> = []
    @ObservationIgnored private var queue: [Int] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Foto zur IMO-Nummer; fragt beim ersten Mal nach.
    func photo(imo: Int?) -> InfoCardPhoto? {
        guard let imo, (1_000_000...9_999_999).contains(imo) else { return nil }
        if let photo = photos[imo] { return photo }
        guard enabled, !asked.contains(imo) else { return nil }
        asked.insert(imo)
        queue.append(imo)
        if worker == nil {
            worker = Task { [weak self] in
                defer { self?.worker = nil }
                guard let self else { return }
                while !Task.isCancelled, !self.queue.isEmpty {
                    let imo = self.queue.removeFirst()
                    await self.fetch(imo)
                }
            }
        }
        return nil
    }

    private func fetch(_ imo: Int) async {
        do {
            let category = "Category:IMO \(imo)"
            if let photo = Self.firstPhoto(try await query(Self.filesQuery(category))) {
                photos[imo] = photo
                return
            }
            let subcats = Self.subcategories(try await query([
                "list": "categorymembers", "cmtitle": category, "cmtype": "subcat", "cmlimit": "5"]))
            for sub in subcats.prefix(2) {
                if let photo = Self.firstPhoto(try await query(Self.filesQuery(sub))) {
                    photos[imo] = photo
                    return
                }
            }
            error = nil
        } catch {
            asked.remove(imo)   // Netz weg: beim nächsten Anklicken erneut
            self.error = error.localizedDescription
        }
    }

    private func query(_ parameters: [String: String]) async throws -> Data {
        var components = URLComponents(string: Self.api)!
        components.queryItems = (["action": "query", "format": "json"].merging(parameters) { $1 })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.limitedData(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    static func filesQuery(_ category: String) -> [String: String] {
        ["generator": "categorymembers", "gcmtitle": category, "gcmtype": "file", "gcmlimit": "10",
         "prop": "imageinfo", "iiprop": "url|extmetadata|mime", "iiurlwidth": "420",
         "iiextmetadatafilter": "Artist|LicenseShortName"]
    }

    static func subcategories(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let members = (root["query"] as? [String: Any])?["categorymembers"] as? [[String: Any]] else { return [] }
        return members.compactMap { $0["title"] as? String }
    }

    /// Erstes JPEG (nach Titel sortiert, also reproduzierbar) mit Quellenangabe.
    static func firstPhoto(_ data: Data) -> InfoCardPhoto? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: [String: Any]] else { return nil }
        for page in pages.values.sorted(by: { ($0["title"] as? String ?? "") < ($1["title"] as? String ?? "") }) {
            guard let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  (info["mime"] as? String) == "image/jpeg",
                  let thumb = (info["thumburl"] as? String).flatMap(URL.init(string:)),
                  thumb.isSafeWebLink(hosts: ["wikimedia.org"]),
                  let pageURL = (info["descriptionurl"] as? String).flatMap(URL.init(string:)),
                  pageURL.isSafeWebLink(hosts: ["wikimedia.org", "wikipedia.org"]) else { continue }
            let meta = info["extmetadata"] as? [String: Any]
            func value(_ key: String) -> String {
                let raw = (meta?[key] as? [String: Any])?["value"] as? String ?? ""
                return stripHTML(raw)
            }
            let artist = value("Artist")
            let license = value("LicenseShortName")
            let author = [artist.isEmpty ? String(localized: "unbekannt") : artist, license].filter { !$0.isEmpty }
                .joined(separator: ", ")
            return InfoCardPhoto(imageURL: thumb, pageURL: pageURL,
                                 credit: String(localized: "Foto: \(author) · Wikimedia Commons"),
                                 help: String(localized: "Foto auf Wikimedia Commons öffnen"))
        }
        return nil
    }

    static func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
