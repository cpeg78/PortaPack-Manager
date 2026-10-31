import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Konten des Fernzugriffs (seit 30.10.2026, ersetzen den geteilten Zugangsschlüssel).
///
/// Passwörter liegen nur als PBKDF2-HMAC-SHA256 mit eigenem Salz vor, angemeldete
/// Geräte nur als SHA-256 ihres Sitzungsschlüssels – wer die Ablage liest, kann sich
/// mit nichts davon anmelden. Alles zusammen liegt als JSON im Schlüsselbund
/// (`RemoteAccountStore`).
struct RemoteAccount: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, CaseIterable, Sendable {
        /// Empfänger umschalten, abstimmen, Plan ändern.
        case control
        /// Nur lesende Abrufe (`RemoteAccessPolicy.requiresControl`).
        case view
    }

    var name: String
    var role: Role
    var salt: Data
    var hash: Data
    var iterations: Int

    var id: String { name.lowercased() }
}

struct RemoteSession: Codable, Equatable, Sendable {
    /// SHA-256 des Sitzungsschlüssels (hex) – der Schlüssel selbst steht nur im Cookie.
    var tokenHash: String
    /// Konto (`RemoteAccount.id`).
    var account: String
    var created: Date
    var lastUsed: Date
}

/// Konten und Sitzungen als Wert – reine Logik, ohne Schlüsselbund (testbar).
struct RemoteAccountBook: Codable, Equatable, Sendable {
    var accounts: [RemoteAccount] = []
    var sessions: [RemoteSession] = []

    enum Problem: Error, Equatable {
        case invalidName, duplicateName, shortPassword, unknownAccount, lastController
    }

    /// Wiederholungen von PBKDF2 (OWASP 2023 für HMAC-SHA256).
    static let iterations = 600_000
    static let minimumPasswordLength = 8
    /// Höchstens so viele angemeldete Geräte je Konto; das älteste fällt heraus.
    static let maximumSessionsPerAccount = 20
    /// Sitzungen verfallen nach so langer Nichtbenutzung (ein Jahr wie das Cookie).
    static let sessionLifetime: TimeInterval = 365 * 86_400

    /// 1–32 Zeichen aus Buchstaben, Ziffern, `.`, `_`, `-` – nichts, was in HTML,
    /// JavaScript oder Cookies maskiert werden müsste.
    static func isValidName(_ name: String) -> Bool {
        (1...32).contains(name.count)
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    func account(named name: String) -> RemoteAccount? {
        accounts.first { $0.id == name.lowercased() }
    }

    // MARK: Konten pflegen (Mac)

    mutating func add(name: String, password: String, role: RemoteAccount.Role, iterations: Int = iterations) throws(Problem) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard Self.isValidName(name) else { throw .invalidName }
        guard account(named: name) == nil else { throw .duplicateName }
        guard password.count >= Self.minimumPasswordLength else { throw .shortPassword }
        let salt = Self.randomBytes(16)
        accounts.append(RemoteAccount(name: name, role: role, salt: salt,
                                      hash: Self.derive(password, salt: salt, iterations: iterations), iterations: iterations))
        accounts.sort { $0.id < $1.id }
    }

    /// Neues Passwort – meldet alle Geräte des Kontos ab.
    mutating func setPassword(_ password: String, for name: String, iterations: Int = iterations) throws(Problem) {
        guard let index = accounts.firstIndex(where: { $0.id == name.lowercased() }) else { throw .unknownAccount }
        guard password.count >= Self.minimumPasswordLength else { throw .shortPassword }
        let salt = Self.randomBytes(16)
        accounts[index].salt = salt
        accounts[index].hash = Self.derive(password, salt: salt, iterations: iterations)
        accounts[index].iterations = iterations
        signOut(name)
    }

    /// Rolle ändern. Das letzte Konto mit „Bedienen“ bleibt – sonst könnte vom Handy
    /// niemand mehr umschalten, und die Einstellung wäre nur am Mac zu reparieren
    /// (dort ginge es; die Sperre verhindert nur das Versehen).
    mutating func setRole(_ role: RemoteAccount.Role, for name: String) throws(Problem) {
        guard let index = accounts.firstIndex(where: { $0.id == name.lowercased() }) else { throw .unknownAccount }
        if role == .view, accounts[index].role == .control, accounts.filter({ $0.role == .control }).count == 1 {
            throw .lastController
        }
        accounts[index].role = role
    }

    mutating func remove(_ name: String) {
        accounts.removeAll { $0.id == name.lowercased() }
        signOut(name)
    }

    /// Alle Geräte des Kontos abmelden.
    mutating func signOut(_ name: String) {
        sessions.removeAll { $0.account == name.lowercased() }
    }

    func sessionCount(for name: String) -> Int {
        sessions.filter { $0.account == name.lowercased() }.count
    }

    // MARK: Anmelden (Handy)

    /// Prüft Name und Passwort. Bei unbekanntem Namen wird trotzdem gerechnet –
    /// sonst verriete die Antwortzeit, welche Namen es gibt.
    static func verify(name: String, password: String, in accounts: [RemoteAccount]) -> RemoteAccount? {
        let account = accounts.first { $0.id == name.trimmingCharacters(in: .whitespaces).lowercased() }
        let salt = account?.salt ?? Data(repeating: 0, count: 16)
        let derived = derive(password, salt: salt, iterations: account?.iterations ?? iterations)
        guard let account, constantTimeEqual(derived, account.hash) else { return nil }
        return account
    }

    /// Neue Sitzung; gibt den Schlüssel fürs Cookie zurück (32 Zufallsbytes, Base64url).
    mutating func createSession(for account: RemoteAccount, now: Date = Date()) -> String {
        let token = Self.randomBytes(32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        sessions.append(RemoteSession(tokenHash: Self.sha256Hex(token), account: account.id, created: now, lastUsed: now))
        let mine = sessions.filter { $0.account == account.id }.sorted { $0.lastUsed < $1.lastUsed }
        if mine.count > Self.maximumSessionsPerAccount {
            let drop = Set(mine.prefix(mine.count - Self.maximumSessionsPerAccount).map(\.tokenHash))
            sessions.removeAll { drop.contains($0.tokenHash) }
        }
        return token
    }

    /// Konto zur Sitzung aus dem Cookie, `nil` bei unbekannter oder verfallener Sitzung.
    func account(forSession token: String?, now: Date = Date()) -> RemoteAccount? {
        guard let token, !token.isEmpty, token.count <= 64 else { return nil }
        let hash = Self.sha256Hex(token)
        guard let session = sessions.first(where: { $0.tokenHash == hash }),
              now.timeIntervalSince(session.lastUsed) < Self.sessionLifetime else { return nil }
        return accounts.first { $0.id == session.account }
    }

    /// Benutzung vermerken – liefert `true`, wenn sich das Speichern lohnt (höchstens
    /// stündlich, sonst schriebe jede Abfrage den Schlüsselbund).
    mutating func touch(session token: String, now: Date = Date()) -> Bool {
        let hash = Self.sha256Hex(token)
        guard let index = sessions.firstIndex(where: { $0.tokenHash == hash }),
              now.timeIntervalSince(sessions[index].lastUsed) > 3600 else { return false }
        sessions[index].lastUsed = now
        return true
    }

    mutating func endSession(_ token: String) {
        let hash = Self.sha256Hex(token)
        sessions.removeAll { $0.tokenHash == hash }
    }

    /// Verfallene Sitzungen und solche ohne Konto entfernen.
    mutating func prune(now: Date = Date()) -> Bool {
        let ids = Set(accounts.map(\.id))
        let before = sessions.count
        sessions.removeAll { !ids.contains($0.account) || now.timeIntervalSince($0.lastUsed) >= Self.sessionLifetime }
        return sessions.count != before
    }

    // MARK: Krypto

    static func derive(_ password: String, salt: Data, iterations: Int) -> Data {
        let passwordBytes = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            passwordBytes.withUnsafeBufferPointer { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }, pw.count,
                                     saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &out, out.count)
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 fehlgeschlagen")
        return Data(out)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "Zufallszahlen fehlgeschlagen")
        return Data(bytes)
    }
}

/// Bremse für Fehlversuche je Gegenstelle (`RemoteAccessPolicy.peerKey`): fünf frei,
/// danach Sperre ab 30 s, je weiterem Fehlversuch doppelt so lang, höchstens 15 min.
/// Ein Erfolg löscht den Zähler.
struct LoginThrottle: Sendable {
    private var failures: [String: (count: Int, until: Date)] = [:]
    static let freeAttempts = 5

    /// Wartezeit in Sekunden, solange gesperrt; sonst `nil`.
    func blocked(_ peer: String, now: Date = Date()) -> Int? {
        guard let entry = failures[peer], entry.until > now else { return nil }
        return Int(entry.until.timeIntervalSince(now).rounded(.up))
    }

    mutating func fail(_ peer: String, now: Date = Date()) {
        let count = (failures[peer]?.count ?? 0) + 1
        let extra = count - Self.freeAttempts
        let wait = extra > 0 ? min(30 * pow(2, Double(extra - 1)), 900) : 0
        failures[peer] = (count, now.addingTimeInterval(wait))
        if failures.count > 1000 { failures = failures.filter { $0.value.until > now } }
    }

    mutating func succeed(_ peer: String) { failures[peer] = nil }
}

/// Ablage der Konten im Anmelde-Schlüsselbund (ein JSON-Eintrag).
struct RemoteAccountStore: Sendable {
    enum Loaded: Equatable, Sendable {
        case found(RemoteAccountBook)
        case notFound
        /// Schlüsselbund nicht lesbar – dann nichts überschreiben, sonst gingen alle Konten verloren.
        case failed(OSStatus)
    }

    var load: @Sendable () -> Loaded
    var save: @Sendable (RemoteAccountBook) -> Bool

    static let service = "de.christiangolz.portapackmanager.remote"
    static let account = "remoteAccounts"

    /// Der frühere geteilte Zugangsschlüssel (bis 30.10.2026): beim ersten Start mit
    /// Konten aus Schlüsselbund und UserDefaults löschen – er öffnet nichts mehr.
    static func removeLegacyToken(defaults: UserDefaults = .standard) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "remoteToken"]
        SecItemDelete(query as CFDictionary)
        defaults.removeObject(forKey: "remoteToken")
    }

    static let keychain: RemoteAccountStore = {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        nonisolated(unsafe) let base = query
        return RemoteAccountStore(
            load: {
                var q = base
                q[kSecReturnData as String] = true
                q[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(q as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    guard let data = result as? Data,
                          let book = try? Self.decoder.decode(RemoteAccountBook.self, from: data) else { return .failed(errSecDecode) }
                    return .found(book)
                case errSecItemNotFound: return .notFound
                default: return .failed(status)
                }
            },
            save: { book in
                guard let data = try? Self.encoder.encode(book) else { return false }
                return KeychainBlob.save(data, query: base) == errSecSuccess
            })
    }()

    /// Für Tests und den Testwirt: nur im Speicher.
    static func memory(_ initial: RemoteAccountBook? = nil, failing: Bool = false) -> RemoteAccountStore {
        final class Box: @unchecked Sendable { let lock = NSLock(); var value: RemoteAccountBook? }
        let box = Box()
        box.value = initial
        return RemoteAccountStore(
            load: { failing ? .failed(errSecAuthFailed) : box.lock.withLock { box.value.map(Loaded.found) ?? .notFound } },
            save: { book in
                guard !failing else { return false }
                box.lock.withLock { box.value = book }
                return true
            })
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()
}
