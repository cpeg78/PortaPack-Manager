import Foundation
import Testing
@testable import PortaPackManager

/// Konten des Fernzugriffs (seit 30.10.2026): Passwort-Ableitung, Sitzungen, Rollen,
/// Bremse für Fehlversuche, Formular-Körper. Reine Logik – kein Schlüsselbund, kein Server.
/// Mit wenigen PBKDF2-Runden, sonst dauerte jeder Test Hunderte Millisekunden.
@Suite("Fernzugriff: Konten")
struct RemoteAccountsTests {
    private static let fast = 1_000

    private func problem(_ body: () throws -> Void) -> RemoteAccountBook.Problem? {
        do { try body(); return nil } catch { return error as? RemoteAccountBook.Problem }
    }

    private func book() throws -> RemoteAccountBook {
        var book = RemoteAccountBook()
        try book.add(name: "Anna", password: "geheim123", role: .control, iterations: Self.fast)
        try book.add(name: "gast", password: "zuschauen", role: .view, iterations: Self.fast)
        return book
    }

    @Test("PBKDF2-HMAC-SHA256: Normvektor (RFC 7914, Abschnitt 11)")
    func pbkdf2Vector() {
        let derived = RemoteAccountBook.derive("passwd", salt: Data("salt".utf8), iterations: 1)
        #expect(derived.prefix(8).map { String(format: "%02x", $0) }.joined() == "55ac046e56e3089f")
    }

    @Test("Anmelden: richtiges Passwort, Name ohne Groß/Klein; falsches Passwort und unbekannter Name nicht")
    func verify() throws {
        let book = try book()
        #expect(RemoteAccountBook.verify(name: "anna", password: "geheim123", in: book.accounts)?.name == "Anna")
        #expect(RemoteAccountBook.verify(name: " ANNA ", password: "geheim123", in: book.accounts)?.name == "Anna")
        #expect(RemoteAccountBook.verify(name: "anna", password: "Geheim123", in: book.accounts) == nil)
        #expect(RemoteAccountBook.verify(name: "niemand", password: "geheim123", in: book.accounts) == nil)
        // Kein Klartext in der Ablage.
        let json = try JSONEncoder().encode(book)
        #expect(String(decoding: json, as: UTF8.self).range(of: "geheim123") == nil)
    }

    @Test("Konten anlegen: Namensregeln, doppelte Namen, Mindestlänge")
    func addRules() throws {
        var book = try book()
        do { let p = problem { try book.add(name: "ANNA", password: "12345678", role: .view, iterations: Self.fast) }; #expect(p == RemoteAccountBook.Problem.duplicateName) }
        do { let p = problem { try book.add(name: "bert", password: "1234567", role: .view, iterations: Self.fast) }; #expect(p == RemoteAccountBook.Problem.shortPassword) }
        for bad in ["", "mit leer", "a'b", "<x>", "ümlaut", String(repeating: "x", count: 33)] {
            do { let p = problem { try book.add(name: bad, password: "12345678", role: .view, iterations: Self.fast) }; #expect(p == RemoteAccountBook.Problem.invalidName) }
        }
        try book.add(name: "c.d_e-1", password: "12345678", role: .view, iterations: Self.fast)
        #expect(book.accounts.map(\.name) == ["Anna", "c.d_e-1", "gast"])
    }

    @Test("Sitzung: Cookie-Schlüssel öffnet das Konto, nur der Hash liegt in der Ablage")
    func sessions() throws {
        var book = try book()
        let anna = try #require(book.account(named: "anna"))
        let token = book.createSession(for: anna)
        #expect(token.count >= 40)
        #expect(book.account(forSession: token)?.name == "Anna")
        #expect(book.account(forSession: token + "x") == nil)
        #expect(book.account(forSession: nil) == nil)
        #expect(!book.sessions.contains { $0.tokenHash == token })
        // Verfallen nach einem Jahr ohne Benutzung.
        #expect(book.account(forSession: token, now: Date().addingTimeInterval(366 * 86_400)) == nil)
        // Abmelden beendet nur diese Sitzung.
        let second = book.createSession(for: anna)
        book.endSession(token)
        #expect(book.account(forSession: token) == nil)
        #expect(book.account(forSession: second) != nil)
    }

    @Test("Neues Passwort, Löschen und „Überall abmelden“ beenden die Sitzungen des Kontos")
    func revoke() throws {
        var book = try book()
        let anna = try #require(book.account(named: "anna")), gast = try #require(book.account(named: "gast"))
        let a = book.createSession(for: anna), g = book.createSession(for: gast)
        try book.setPassword("neuesPasswort", for: "Anna", iterations: Self.fast)
        #expect(book.account(forSession: a) == nil)
        #expect(book.account(forSession: g) != nil)
        #expect(RemoteAccountBook.verify(name: "anna", password: "geheim123", in: book.accounts) == nil)
        #expect(RemoteAccountBook.verify(name: "anna", password: "neuesPasswort", in: book.accounts) != nil)
        book.signOut("GAST")
        #expect(book.account(forSession: g) == nil)
        let g2 = book.createSession(for: gast)
        book.remove("gast")
        #expect(book.account(forSession: g2) == nil)
        #expect(book.sessions.isEmpty)
    }

    @Test("Höchstens 20 Geräte je Konto – das am längsten unbenutzte fällt heraus")
    func sessionLimit() throws {
        var book = try book()
        let anna = try #require(book.account(named: "anna"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = book.createSession(for: anna, now: start)
        for i in 1...RemoteAccountBook.maximumSessionsPerAccount { _ = book.createSession(for: anna, now: start.addingTimeInterval(Double(i))) }
        #expect(book.sessionCount(for: "anna") == RemoteAccountBook.maximumSessionsPerAccount)
        #expect(book.account(forSession: first, now: start.addingTimeInterval(100)) == nil)
    }

    @Test("Das letzte Konto mit „Bedienen“ lässt sich nicht auf „Nur ansehen“ stellen")
    func lastController() throws {
        var book = try book()
        do { let p = problem { try book.setRole(.view, for: "anna") }; #expect(p == RemoteAccountBook.Problem.lastController) }
        try book.setRole(.control, for: "gast")
        try book.setRole(.view, for: "anna")
        #expect(book.account(named: "anna")?.role == .view)
    }

    @Test("Benutzung wird höchstens stündlich gespeichert")
    func touch() throws {
        var book = try book()
        let anna = try #require(book.account(named: "anna"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let token = book.createSession(for: anna, now: start)
        let early = book.touch(session: token, now: start.addingTimeInterval(600))
        let later = book.touch(session: token, now: start.addingTimeInterval(4000))
        let unknown = book.touch(session: "unbekannt", now: start.addingTimeInterval(9000))
        #expect(!early && later && !unknown)
    }

    @Test("Ablage: Konten überstehen Speichern und Laden")
    func storeRoundTrip() throws {
        let store = RemoteAccountStore.memory()
        #expect(store.load() == .notFound)
        let book = try book()
        #expect(store.save(book))
        #expect(store.load() == .found(book))
    }

    @Test("Bremse: fünf Fehlversuche frei, dann 30 s, je weiterem doppelt so lang, höchstens 15 min")
    func throttle() {
        var throttle = LoginThrottle()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<5 { throttle.fail("10.0.0.5", now: now) }
        #expect(throttle.blocked("10.0.0.5", now: now) == nil)
        throttle.fail("10.0.0.5", now: now)
        #expect(throttle.blocked("10.0.0.5", now: now) == 30)
        throttle.fail("10.0.0.5", now: now)
        #expect(throttle.blocked("10.0.0.5", now: now) == 60)
        for _ in 0..<10 { throttle.fail("10.0.0.5", now: now) }
        #expect(throttle.blocked("10.0.0.5", now: now) == 900)
        #expect(throttle.blocked("10.0.0.6", now: now) == nil)
        #expect(throttle.blocked("10.0.0.5", now: now.addingTimeInterval(901)) == nil)
        throttle.succeed("10.0.0.5")
        #expect(throttle.blocked("10.0.0.5", now: now) == nil)
    }

    @Test("„Nur ansehen“: lesende Abrufe frei, jedes Umschalten und Einstellen gesperrt")
    func viewerPermissions() {
        let reads: [(String, [String: String])] = [
            ("/", [:]), ("/", ["k": "alt"]), ("/api/state", ["sel": "adsb:3C1234"]), ("/api/archive", ["kind": "ais", "day": "2026-10-30"]),
            ("/api/spectrum", ["t": "1"]), ("/api/ft8", ["cq": "1"]), ("/api/zigbee", ["pan": "1A2B"]),
            ("/api/airband/search", ["q": "Hamburg"]), ("/audio.aac", ["t": "123"]), ("/img", ["n": "x.png", "w": "360"]),
            ("/occupancy.png", ["w": "800", "h": "400", "hours": "6"]), ("/api/plan", [:]), ("/api/sondes", ["serial": "X123"]),
        ]
        for (path, query) in reads { #expect(!RemoteAccessPolicy.requiresControl(path: path, query: query), "\(path) \(query)") }
        let actions: [(String, [String: String])] = [
            ("/api/mode", ["m": "adsb"]), ("/api/mode", ["m": ""]), ("/api/dab/play", ["ch": "5C", "id": "1"]), ("/api/dab/scan", [:]),
            ("/api/spectrum", ["mhz": "100"]), ("/api/fm", ["f": "99.1"]), ("/api/sensors", ["mhz": "868.3"]),
            ("/api/zigbee", ["ch": "15"]), ("/api/ft8", ["band": "6m"]), ("/api/dsc", ["clear": "1"]),
            ("/api/plan", ["skip": "1"]), ("/api/plan", ["sonde": "0"]), ("/api/airband", ["hold": "3"]),
            ("/api/occupancy", ["preset": "x"]), ("/api/optimize", [:]), ("/api/gain", ["auto": "1"]),
            ("/api/neu-und-unbekannt", [:]),
        ]
        for (path, query) in actions { #expect(RemoteAccessPolicy.requiresControl(path: path, query: query), "\(path) \(query)") }
    }

    @Test("Sitzungs-Cookie lesen und beim Abmelden löschen")
    func cookies() {
        #expect(RemoteAccessPolicy.sessionToken(cookieHeader: "k=alt; s=abc_DEF-123; x=1") == "abc_DEF-123")
        #expect(RemoteAccessPolicy.sessionToken(cookieHeader: "k=alt") == nil)
        #expect(RemoteAccessPolicy.sessionToken(cookieHeader: nil) == nil)
        #expect(RemoteAccessPolicy.clearedCookies.allSatisfy { $0.contains("Max-Age=0") })
        // An-/Abmelden: echte Formulare, aber nicht von fremden Seiten.
        #expect(RemoteAccessPolicy.allowsOrigin(path: "/login", headers: ["sec-fetch-site": "same-origin"]))
        #expect(!RemoteAccessPolicy.allowsOrigin(path: "/login", headers: ["sec-fetch-site": "cross-site"]))
        #expect(!RemoteAccessPolicy.allowsOrigin(path: "/logout", headers: ["sec-fetch-site": "same-site"]))
    }

    @Test("Formular-Körper: Felder, Prozent- und Plus-Kodierung")
    func formBody() {
        var request = RemoteHTTPServer.Request()
        request.body = Data("name=Anna&password=geh%26im+1%2B2%3D3".utf8)
        #expect(request.form["name"] == "Anna")
        #expect(request.form["password"] == "geh&im 1+2=3")
        request.body = Data()
        #expect(request.form.isEmpty)
    }

    @Test("Server liest den Formular-Körper eines POST und weist zu große ab")
    func serverReadsBody() async throws {
        let server = RemoteHTTPServer()
        let port = UInt16.random(in: 48_001...55_000)
        try server.start(port: port) { request in
            .data(status: 200, contentType: "text/plain", body: Data((request.method + " " + (request.form["name"] ?? "-")).utf8))
        }
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        var post = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/login")!)
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        post.httpBody = Data("name=Anna&password=x".utf8)
        var body: Data?
        for _ in 0..<50 {
            if let (data, _) = try? await session.data(for: post) { body = data; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(body.map { String(decoding: $0, as: UTF8.self) } == "POST Anna")
        post.httpBody = Data(repeating: 0x61, count: RemoteHTTPServer.maximumBody + 1)
        let (_, response) = try await session.data(for: post)
        #expect((response as? HTTPURLResponse)?.statusCode == 413)
    }
}
