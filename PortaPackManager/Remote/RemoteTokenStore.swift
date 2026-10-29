import Foundation
import Security

/// Ablage des Fernzugriffsschlüssels: im Anmelde-Schlüsselbund statt im Klartext
/// in UserDefaults (Review 28.10.2026, Y22 – das MQTT-Passwort lag schon dort).
///
/// Der bisherige Wert unter `remoteToken` wird beim ersten Start **unverändert**
/// übernommen: Handys und Home-Bildschirm-Web-Apps haben ihn gespeichert und
/// müssen weiter hineinkommen. Den Klartext löscht die Migration erst, wenn der
/// Schlüsselbund ihn sicher hat.
struct RemoteTokenStore: Sendable {
    enum Loaded: Equatable, Sendable {
        case found(String)
        case notFound
        /// Schlüsselbund nicht lesbar (z. B. Zugriff verweigert) – dann nichts überschreiben.
        case failed(OSStatus)
    }

    var load: @Sendable () -> Loaded
    var save: @Sendable (String) -> Bool

    static let service = "de.christiangolz.portapackmanager.remote"
    static let account = "remoteToken"

    static let keychain: RemoteTokenStore = {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        nonisolated(unsafe) let base = query
        return RemoteTokenStore(
            load: {
                var q = base
                q[kSecReturnData as String] = true
                q[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(q as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    guard let data = result as? Data else { return .failed(errSecDecode) }
                    return .found(String(decoding: data, as: UTF8.self))
                case errSecItemNotFound: return .notFound
                default: return .failed(status)
                }
            },
            save: { token in KeychainBlob.save(Data(token.utf8), query: base) == errSecSuccess })
    }()

    /// Für Tests: im Speicher.
    static func memory(_ initial: String? = nil, failing: Bool = false) -> RemoteTokenStore {
        final class Box: @unchecked Sendable { let lock = NSLock(); var value: String? }
        let box = Box()
        box.value = initial
        return RemoteTokenStore(
            load: { failing ? .failed(errSecAuthFailed) : box.lock.withLock { box.value.map(Loaded.found) ?? .notFound } },
            save: { value in
                guard !failing else { return false }
                box.lock.withLock { box.value = value }
                return true
            })
    }

    /// Schlüssel beim Start: aus dem Schlüsselbund, sonst der alte Wert aus
    /// UserDefaults (wird übernommen und dort gelöscht), sonst ein neuer.
    /// `nil`: Schlüsselbund nicht lesbar und kein Altwert – dann **keinen** neuen
    /// Schlüssel erzeugen (er wäre nirgends gespeichert, jeder Start sperrte alle
    /// Handys aus), sondern den Fernzugriff aussetzen und später erneut lesen.
    func loadOrMigrate(defaults: UserDefaults, key: String, make: () -> String) -> String? {
        let legacy = defaults.string(forKey: key).flatMap { $0.count >= 8 ? $0 : nil }
        switch load() {
        case .found(let token) where token.count >= 8:
            // Übernahme ist schon geschehen; ein übrig gebliebener Klartext muss weg.
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            return token
        case .failed:
            // Nicht lesbar: lieber den alten Wert weiterverwenden, als einen neuen
            // zu erzeugen und damit alle Handys auszusperren.
            return legacy
        case .found, .notFound:
            if let legacy {
                if save(legacy) { defaults.removeObject(forKey: key) }
                return legacy
            }
            let token = make()
            // Scheitert der Schlüsselbund, bleibt der Schlüssel wie bisher in UserDefaults.
            if !save(token) { defaults.set(token, forKey: key) }
            return token
        }
    }

    /// Neuer Schlüssel („Neu erzeugen“).
    func replace(with token: String, defaults: UserDefaults, key: String) {
        if save(token) { defaults.removeObject(forKey: key) } else { defaults.set(token, forKey: key) }
    }
}
