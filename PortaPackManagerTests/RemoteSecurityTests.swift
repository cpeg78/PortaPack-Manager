import Foundation
import JavaScriptCore
import Testing
@testable import PortaPackManager

/// Fernzugriff nach der Sicherheitsprüfung vom 29.10.2026: nur Heimnetz/VPN,
/// Grenzen je Gegenstelle, Host-Prüfung, CSRF-Schutz, Kopfzeilen, Schlüssel bei
/// Schlüsselbund-Fehlern, Archiv-Cache, Flugfunk-Halten, `t()` der Webseite.
/// Alles über reine Funktionen – kein Server, keine UserDefaults der App, kein Schlüsselbund.
@Suite("Fernzugriff: Sicherheit")
struct RemoteSecurityTests {
    // MARK: Heimnetz und VPN

    @Test("Heimnetz und VPN werden angenommen", arguments: [
        "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.178.20", "169.254.10.1",
        "100.64.0.1", "100.101.102.103", "100.127.255.254",
        "::1", "fe80::1", "fe80::1%en0", "febf::1", "fc00::1", "fd12:3456::1", "fd7a:115c:a1e0::1234",
        "::ffff:192.168.1.5", "::ffff:100.100.1.1", "[fe80::1]",
    ])
    func homeAccepted(address: String) {
        #expect(RemoteAccessPolicy.isHomeOrVPN(address))
    }

    @Test("Internet und Unsinn werden abgewiesen", arguments: [
        "8.8.8.8", "172.32.0.1", "172.15.255.255", "192.169.0.1", "100.63.255.255", "100.128.0.1", "169.255.0.1",
        "2a02:8070:1234::1", "2001:db8::1", "fec0::1", "::", "::ffff:8.8.8.8", "::8.8.8.8", "64:ff9b::808:808",
        "", "localhost", "999.1.1.1", "fe80::zz",
    ])
    func internetRejected(address: String) {
        #expect(!RemoteAccessPolicy.isHomeOrVPN(address))
    }

    @Test("Globales IPv6 aus dem eigenen Netz (gleiches /64 wie eine Schnittstelle) gilt als Heimnetz")
    func onLinkGlobalIPv6() throws {
        let own = try #require(RemoteAccessPolicy.ipBytes("2a02:8070:1:2::10"))
        let mask64 = [UInt8](repeating: 0xFF, count: 8) + [UInt8](repeating: 0, count: 8)
        let wan = RemoteAccessPolicy.Subnet(address: try #require(RemoteAccessPolicy.ipBytes("85.1.2.3")), mask: [255, 255, 255, 0])
        let subnets = [RemoteAccessPolicy.Subnet(address: own, mask: mask64), wan]
        #expect(RemoteAccessPolicy.isOnLink("2a02:8070:1:2:abcd::99", subnets: subnets))
        #expect(!RemoteAccessPolicy.isOnLink("2a02:8070:1:3::99", subnets: subnets))
        #expect(!RemoteAccessPolicy.isOnLink("2001:db8::1", subnets: subnets))
        #expect(RemoteAccessPolicy.isOnLink("::ffff:85.1.2.77", subnets: subnets))
        #expect(!RemoteAccessPolicy.isOnLink("85.1.3.77", subnets: subnets))
        // Eine Maske aus lauter Nullen (Standardroute) ist kein Heimnetz.
        let all = RemoteAccessPolicy.Subnet(address: own, mask: [UInt8](repeating: 0, count: 16))
        #expect(!RemoteAccessPolicy.isOnLink("2001:db8::1", subnets: [all]))
        // Die echten Schnittstellen lassen sich lesen (ohne Loopback).
        #expect(!RemoteAccessPolicy.localSubnets().contains { $0.address == [127, 0, 0, 1] })
    }

    @Test("Grenze je Gegenstelle zählt IPv6 nach /64, gemappte IPv4 wie IPv4")
    func peerKeyPrefix64() {
        let a = RemoteAccessPolicy.peerKey("2a02:8070:1:2:aaaa::1")
        let b = RemoteAccessPolicy.peerKey("2a02:8070:1:2:bbbb:cccc:dddd:eeee")
        let other = RemoteAccessPolicy.peerKey("2a02:8070:1:3::1")
        #expect(a == b)
        #expect(a != other)
        #expect(RemoteAccessPolicy.peerKey("::ffff:192.168.1.5") == "192.168.1.5")
        #expect(RemoteAccessPolicy.peerKey("192.168.1.5") == "192.168.1.5")
        #expect(RemoteAccessPolicy.peerKey("fe80::1%en0") == RemoteAccessPolicy.peerKey("fe80::2%en1"))
        // 16 Adressen aus einem /64 belegen die Grenze, ein anderes Netz kommt noch herein.
        let busy = [String?]((0..<16).map { RemoteAccessPolicy.peerKey("2a02:8070:1:2::\($0 + 1)") })
        #expect(!RemoteHTTPServer.admits(peer: RemoteAccessPolicy.peerKey("2a02:8070:1:2::ffff"), openPeers: busy))
        #expect(RemoteHTTPServer.admits(peer: other, openPeers: busy))
    }

    // MARK: Host-Kopf

    @Test("Host-Kopf: lokale Namen und IP-Literale gelten, fremde Namen nicht")
    func hostHeader() {
        let ok = ["192.168.1.10:1478", "[fe80::1%25en0]:1478", "[::1]:1478", "localhost:1478", "macbook.local:1478",
                  "MacBook-Pro.local.", "mac.tail1234.ts.net:1478", "mac:1478", "mac.fritz.box", "100.64.1.2",
                  "studio.example.org"]
        for host in ok {
            #expect(RemoteAccessPolicy.allowsHost(host, localNames: ["studio.example.org"]), "\(host)")
        }
        #expect(RemoteAccessPolicy.allowsHost(nil))
        let bad = ["evil.example.com", "evil.example.com:1478", "192.168.1.10.nip.io", "a b.local", "",
                   "local.evil.com", "ts.net.evil.com", "[nonsense]:1478", "mac.local:http"]
        for host in bad {
            #expect(!RemoteAccessPolicy.allowsHost(host), "\(host)")
        }
    }

    // MARK: CSRF

    @Test("Aktionen nur mit eigenem Kopf und nicht von fremden Seiten")
    func originChecks() {
        let own = ["x-portapack": "1", "sec-fetch-site": "same-origin"]
        #expect(RemoteAccessPolicy.allowsOrigin(path: "/api/mode", headers: own))
        #expect(RemoteAccessPolicy.allowsOrigin(path: "/api/mode", headers: ["x-portapack": "1"]))          // alter Browser
        #expect(!RemoteAccessPolicy.allowsOrigin(path: "/api/mode", headers: [:]))                          // <img>
        #expect(!RemoteAccessPolicy.allowsOrigin(path: "/api/plan", headers: ["sec-fetch-site": "same-site"]))
        #expect(!RemoteAccessPolicy.allowsOrigin(path: "/api/plan", headers: ["x-portapack": "1", "sec-fetch-site": "same-site"]))
        #expect(!RemoteAccessPolicy.allowsOrigin(path: "/api/plan", headers: ["x-portapack": "1", "sec-fetch-site": "cross-site"]))
        // Ton und Bilder: ohne eigenen Kopf, aber nicht von anderen Ports derselben Adresse.
        #expect(RemoteAccessPolicy.allowsOrigin(path: "/audio.aac", headers: ["sec-fetch-site": "same-origin"]))
        #expect(RemoteAccessPolicy.allowsOrigin(path: "/img", headers: [:]))
        #expect(!RemoteAccessPolicy.allowsOrigin(path: "/occupancy.png", headers: ["sec-fetch-site": "same-site"]))
        // Seite und Manifest: auch vom QR-Code-Scanner oder aus einer Nachricht.
        #expect(RemoteAccessPolicy.allowsOrigin(path: "/", headers: ["sec-fetch-site": "cross-site"]))
        #expect(RemoteAccessPolicy.allowsOrigin(path: "/manifest.webmanifest", headers: ["sec-fetch-site": "cross-site"]))
    }

    @Test("Cookie vom Server: HttpOnly, SameSite=Strict, Path=/; Sicherheitsköpfe")
    func cookieAndHeaders() {
        let cookie = RemoteAccessPolicy.sessionCookie(token: "abcd2345wxyz")
        #expect(cookie.hasPrefix("k=abcd2345wxyz;"))
        for part in ["HttpOnly", "SameSite=Strict", "Path=/"] { #expect(cookie.contains(part)) }
        let lines = RemoteHTTPServer.extraHeaderLines(["Set-Cookie": cookie])
        #expect(lines.contains("X-Content-Type-Options: nosniff\r\n"))
        #expect(lines.contains("X-Frame-Options: DENY\r\n"))
        #expect(lines.contains("Referrer-Policy: no-referrer\r\n"))
        #expect(lines.contains("Set-Cookie: \(cookie)\r\n"))
        #expect(!lines.contains("Access-Control-Allow-Origin"))
        let csp = RemoteAccessPolicy.contentSecurityPolicy
        for part in ["frame-ancestors 'none'", "default-src 'self'", "connect-src 'self'", "https://tile.openstreetmap.org",
                     "https://*.plnspttrs.net", "https://upload.wikimedia.org", "object-src 'none'"] {
            #expect(csp.contains(part), "\(part)")
        }
    }

    @Test("Seite setzt das Cookie nicht mehr selbst und schickt X-PortaPack")
    func pageUsesServerCookie() {
        let html = RemotePage.html
        #expect(!html.contains("document.cookie"))
        #expect(html.contains("'X-PortaPack': '1'"))
        // Der Schlüssel aus ?k= wird weiter aus der Adresszeile genommen.
        #expect(html.contains("searchParams.delete('k')"))
        // Flugfunk: „lösen“ ist -1, nicht mehr 0 (= 118,000 MHz).
        #expect(html.contains("{ hold: -1 }"))
        #expect(!html.contains("{ hold: 0 }"))
    }

    // MARK: Schlüssel

    @Test("Unlesbarer Schlüsselbund ohne Altwert: kein neuer, ungespeicherter Schlüssel")
    func keychainFailureNoFreshToken() throws {
        let suite = "remote-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let failing = RemoteTokenStore.memory(failing: true)
        var made = 0
        #expect(failing.loadOrMigrate(defaults: defaults, key: "remoteToken", make: { made += 1; return "neu-neu-neu1" }) == nil)
        #expect(made == 0)
        #expect(defaults.string(forKey: "remoteToken") == nil)
        // Mit Altwert: der wird weiterverwendet (und bleibt liegen).
        defaults.set("abcd2345wxyz", forKey: "remoteToken")
        #expect(failing.loadOrMigrate(defaults: defaults, key: "remoteToken", make: { made += 1; return "neu-neu-neu1" }) == "abcd2345wxyz")
        #expect(made == 0)
    }

    // MARK: Flugfunk

    @Test("Flugfunk halten: 0 ist 118,000 MHz, -1 bzw. leer löst, außerhalb wird ignoriert")
    func airbandHold() {
        #expect(RemoteAirband.holdAction("0") == RemoteAirband.HoldAction(index: 0))
        #expect(RemoteAirband.holdAction("17") == RemoteAirband.HoldAction(index: 17))
        #expect(RemoteAirband.holdAction("-1") == RemoteAirband.HoldAction(index: nil))
        #expect(RemoteAirband.holdAction("") == RemoteAirband.HoldAction(index: nil))
        #expect(RemoteAirband.holdAction("\(AirbandGrid.count)") == nil)
        #expect(RemoteAirband.holdAction("1e16") == nil)
        #expect(RemoteAirband.holdAction("abc") == nil)
    }

    // MARK: MQTT

    @Test("MQTT: Eimer für neue Geräte füllt sich je Stunde nach")
    func deviceBudget() {
        var budget = MQTTDeviceBudget(burst: 3, perHour: 20)
        let t0 = Date(timeIntervalSince1970: 0)
        func takes(_ seconds: [Double]) -> [Bool] { seconds.map { budget.take(now: t0.addingTimeInterval($0)) } }
        // 3 sofort, nach 1 min erst 1/3 Platz, nach 3 min ein ganzer.
        #expect(takes([0, 0, 0, 0, 60, 181, 182]) == [true, true, true, false, false, true, false])
        // Nach langer Pause höchstens wieder `burst`.
        #expect(takes([36_000, 36_000, 36_000, 36_000]) == [true, true, true, false])
    }

    @Test("MQTT: Entfernen = leere, gehaltene Konfiguration; Hinweis ohne TLS")
    func removalAndClearText() {
        let messages = MQTTDiscovery.removal(topics: ["b/config", "a/config"])
        #expect(messages.map(\.topic) == ["a/config", "b/config"])
        #expect(messages.allSatisfy { $0.payload.isEmpty && $0.retain })
        #expect(MQTTSettings.sendsPasswordInClear(tls: false, host: "homeassistant.local", password: "x"))
        #expect(!MQTTSettings.sendsPasswordInClear(tls: true, host: "homeassistant.local", password: "x"))
        #expect(!MQTTSettings.sendsPasswordInClear(tls: false, host: "homeassistant.local", password: ""))
        #expect(!MQTTSettings.sendsPasswordInClear(tls: false, host: " localhost ", password: "x"))
    }

    // MARK: Server

    @Test("Server schickt Cookie und Sicherheitsköpfe über die Leitung")
    func serverSendsHeaders() async throws {
        let server = RemoteHTTPServer()
        let port = UInt16.random(in: 41_000...48_000)
        try server.start(port: port) { request in
            .withHeaders(["Set-Cookie": RemoteAccessPolicy.sessionCookie(token: "abcd2345wxyz")],
                         .data(status: 200, contentType: "text/plain", body: Data(request.path.utf8)))
        }
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        var response: HTTPURLResponse?
        var body = Data()
        for _ in 0..<50 {
            if let (data, r) = try? await session.data(from: URL(string: "http://127.0.0.1:\(port)/hallo")!) {
                body = data; response = r as? HTTPURLResponse; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let http = try #require(response)
        #expect(String(decoding: body, as: UTF8.self) == "/hallo")
        #expect(http.value(forHTTPHeaderField: "Set-Cookie")?.contains("HttpOnly") == true)
        #expect(http.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
        #expect(http.value(forHTTPHeaderField: "X-Frame-Options") == "DENY")
        #expect(http.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true)
    }

    // MARK: t() der Webseite

    /// Führt die Übersetzungsfunktionen der Seite in JavaScriptCore aus.
    private func pageContext() throws -> JSContext {
        let html = RemotePage.html
        let start = try #require(html.range(of: "function tt(s, ...a) {"))
        let end = try #require(html.range(of: "// Feste Texte im HTML", range: start.upperBound..<html.endIndex))
        let escLine = try #require(html.split(separator: "\n").first { $0.contains("function esc(s)") })
        let context = try #require(JSContext())
        context.evaluateScript("const LANG = 'de'; const EN = {};\n" + html[start.lowerBound..<end.lowerBound] + "\n" + escLine)
        #expect(context.exception == nil, "\(String(describing: context.exception))")
        return context
    }

    @Test("t() maskiert eingesetzte Werte, raw() und tt() nicht")
    func translationEscapes() throws {
        let context = try pageContext()
        func run(_ script: String) -> String? { context.evaluateScript(script)?.toString() }
        #expect(run("t('Netz {0}', '<img src=x onerror=alert(1)>')") == "Netz &lt;img src=x onerror=alert(1)&gt;")
        #expect(run("t('Aufzeichnung „{0}“', 'A & \"B\"')") == "Aufzeichnung „A &amp; &quot;B&quot;“")
        #expect(run("t('Gerade läuft: {0}', raw('<b>' + esc('<x>') + '</b>'))") == "Gerade läuft: <b>&lt;x&gt;</b>")
        #expect(run("t('{0} Flugzeuge', 12)") == "12 Flugzeuge")
        #expect(run("t('Fehler: {0}', null)") == "Fehler: ")
        #expect(run("tt('Fehler: {0}', 'a < b')") == "Fehler: a < b")
    }

    @Test("Seite: t() mit Platzhaltern nie in esc() oder textContent (sonst doppelt maskiert)")
    func noDoubleEscaping() throws {
        let html = RemotePage.html
        let doubled = try NSRegularExpression(pattern: #"(esc\(|textContent = )t\('[^']*\{\d\}"#)
        let hits = doubled.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { String(html[Range($0.range, in: html)!]) }
        #expect(hits.isEmpty, "\(hits)")
    }
}
