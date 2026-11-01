import Darwin
import Foundation

/// Regeln des Fernzugriffs als reine Funktionen (Review 29.10.2026, Sicherheit S1–S3):
/// welche Gegenstellen überhaupt hereinkommen, wie sie für die Grenze je Gegenstelle
/// gezählt werden, welche `Host`-Namen gelten, wann eine Anfrage als „aus der eigenen
/// Seite“ gilt und welche Kopfzeilen jede Antwort bekommt.
enum RemoteAccessPolicy {
    // MARK: - Adressen

    /// Rohbytes einer IP-Adresse (4 oder 16), ohne Zonenangabe (`%en0`) und Klammern.
    nonisolated static func ipBytes(_ address: String) -> [UInt8]? {
        var text = address
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    /// IPv4-Adresse aus einer IPv4-gemappten IPv6-Adresse (`::ffff:a.b.c.d`).
    nonisolated static func mappedIPv4(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF else { return nil }
        return Array(bytes[12..<16])
    }

    /// Heimnetz oder VPN? Loopback, RFC 1918, Link-local (169.254/16, fe80::/10),
    /// CGNAT 100.64/10 (Tailscale) und ULA fc00::/7 (darin Tailscale fd7a:115c:a1e0::/48);
    /// IPv4-gemappte IPv6-Adressen wie ihre IPv4-Adresse. Alles andere – öffentliche
    /// IPv4, globales IPv6, Unlesbares – nicht.
    nonisolated static func isHomeOrVPN(_ address: String) -> Bool {
        guard let bytes = ipBytes(address) else { return false }
        if bytes.count == 4 { return isHomeOrVPN(v4: bytes) }
        if let v4 = mappedIPv4(bytes) { return isHomeOrVPN(v4: v4) }
        if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }       // ::1
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }             // fe80::/10
        if bytes[0] & 0xFE == 0xFC { return true }                              // fc00::/7
        return false
    }

    private nonisolated static func isHomeOrVPN(v4 b: [UInt8]) -> Bool {
        switch b[0] {
        case 127, 10: true
        case 172: b[1] & 0xF0 == 16
        case 192: b[1] == 168
        case 169: b[1] == 254
        case 100: b[1] & 0xC0 == 64
        default: false
        }
    }

    /// Netz einer eigenen Schnittstelle (Adresse und Maske als Bytes).
    struct Subnet: Equatable, Sendable {
        var address: [UInt8]
        var mask: [UInt8]

        func contains(_ bytes: [UInt8]) -> Bool {
            bytes.count == address.count && mask.count == address.count
                && mask.contains { $0 != 0 }
                && zip(zip(bytes, address), mask).allSatisfy { ($0.0 & $1) == ($0.1 & $1) }
        }
    }

    /// Liegt die Gegenstelle im selben Netz wie eine eigene Schnittstelle? Dann ist sie im
    /// Heimnetz, auch mit globaler IPv6-Adresse: Ein iPhone im WLAN erreicht `mac.local`
    /// gern über die globale IPv6 des Providers. Von außen kommt niemand mit einer
    /// Absenderadresse aus dem eigenen /64 durch – die Antworten gingen ins eigene Netz.
    nonisolated static func isOnLink(_ address: String, subnets: [Subnet]) -> Bool {
        guard let bytes = ipBytes(address) else { return false }
        let candidates = [bytes] + (mappedIPv4(bytes).map { [$0] } ?? [])
        return candidates.contains { b in subnets.contains { $0.contains(b) } }
    }

    /// Netze der aktiven Schnittstellen (ohne Loopback) – `getifaddrs`, schnell, ohne DNS.
    nonisolated static func localSubnets() -> [Subnet] {
        var result: [Subnet] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let address = entry.ifa_addr, let netmask = entry.ifa_netmask else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) } }
                let m = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) } }
                result.append(Subnet(address: a, mask: m))
            case AF_INET6:
                let a = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
                let m = netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
                result.append(Subnet(address: a, mask: m))
            default: continue
            }
        }
        return result
    }

    /// Schlüssel für die Grenze je Gegenstelle: IPv4 (auch gemappt) als Adresse,
    /// IPv6 nach /64 – ein einzelnes Gerät hat dort beliebig viele Adressen.
    nonisolated static func peerKey(_ address: String) -> String {
        guard let bytes = ipBytes(address) else { return address }
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
        if let v4 = mappedIPv4(bytes) { return v4.map(String.init).joined(separator: ".") }
        return bytes.prefix(8).map { String(format: "%02x", $0) }.joined() + "::/64"
    }

    // MARK: - Host-Kopf (DNS-Rebinding)

    /// Endungen von Namen, die nur im Heimnetz bzw. im Tailnet auflösen.
    static let localSuffixes = [".local", ".ts.net", ".home.arpa", ".fritz.box", ".lan", ".home", ".internal", ".localdomain"]

    /// Gilt der `Host`-Kopf? IP-Literale, `localhost`, Namen ohne Punkt (Router-DNS,
    /// Tailscale-Kurzname), Heimnetz-/Tailscale-Endungen und die eigenen Namen des Macs.
    /// Ein fremder Name (DNS-Rebinding: `angreifer.example` zeigt plötzlich auf den Mac)
    /// fällt durch. Ohne `Host`-Kopf (HTTP/1.0) gilt die Anfrage.
    nonisolated static func allowsHost(_ header: String?, localNames: [String] = []) -> Bool {
        guard let header else { return true }
        var host = header.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            return ipBytes(String(host[...close])) != nil
        }
        if let colon = host.lastIndex(of: ":") {
            guard host[host.index(after: colon)...].allSatisfy(\.isNumber) else { return false }
            host = String(host[..<colon])
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if ipBytes(host) != nil || host == "localhost" { return true }
        guard host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return false }
        if !host.contains(".") { return true }
        if localSuffixes.contains(where: { host.hasSuffix($0) }) { return true }
        return localNames.contains { $0.lowercased() == host }
    }

    // MARK: - Anfragen aus der eigenen Seite (CSRF)

    enum Origin: Equatable, Sendable {
        /// Ohne Prüfung: Seite, Manifest, Symbole, Leaflet.
        case open
        /// Bild/Ton per `<img>`/`<audio>`: nur nicht von fremden Seiten.
        case resource
        /// `/api/…`: zusätzlich der eigene Kopf `X-PortaPack: 1`, den nur `fetch`
        /// aus der Seite setzt – ein `<img>` oder Formular eines anderen Ports
        /// derselben IP kann ihn nicht setzen, und `fetch` von dort scheitert an CORS.
        case action
    }

    nonisolated static func origin(for path: String) -> Origin {
        if path.hasPrefix("/api/") { return .action }
        switch path {
        // Anmelden/Abmelden: echte Formulare (iOS bietet dann an, das Passwort zu
        // sichern) – ohne eigenen Kopf, aber nicht von fremden Seiten.
        case "/audio.aac", "/img", "/occupancy.png", "/login", "/logout": return .resource
        default: return .open
        }
    }

    /// Darf die Anfrage durch? `Sec-Fetch-Site` muss `same-origin` oder `none` sein
    /// oder fehlen (ältere Browser, curl). `same-site` (anderer Port derselben IP) und
    /// `cross-site` fallen durch.
    nonisolated static func allowsOrigin(path: String, headers: [String: String]) -> Bool {
        let kind = origin(for: path)
        guard kind != .open else { return true }
        if let site = headers["sec-fetch-site"]?.lowercased(), site != "same-origin", site != "none" { return false }
        if kind == .action { return headers["x-portapack"] == "1" }
        return true
    }

    // MARK: - Antwortköpfe

    /// Content-Security-Policy der Seite: Skripte und Stile aus der Seite selbst
    /// (inline – die Seite ist eine Datei) und vom Mac, Kacheln von OpenStreetMap,
    /// Fotos von planespotters und Wikimedia; Abrufe und Ton nur vom Mac.
    static let contentSecurityPolicy = [
        "default-src 'self'",
        "script-src 'self' 'unsafe-inline'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob: https://tile.openstreetmap.org https://*.tile.openstreetmap.org "
            + "https://plnspttrs.net https://*.plnspttrs.net https://*.planespotters.net "
            + "https://upload.wikimedia.org https://*.wikimedia.org",
        "connect-src 'self'",
        "media-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'self'",
        "frame-ancestors 'none'",
    ].joined(separator: "; ")

    /// Kopfzeilen jeder Antwort (auch des Audiostroms): kein Einbetten, kein
    /// Raten des Inhaltstyps, kein Referrer.
    static let securityHeaders: [(String, String)] = [
        ("Content-Security-Policy", contentSecurityPolicy),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
    ]

    /// Sitzungs-Cookie, vom Server gesetzt: für Skripte unsichtbar (`HttpOnly`),
    /// nur aus der eigenen Site (`SameSite=Strict`), ein Jahr gültig.
    nonisolated static func sessionCookie(token: String) -> String {
        "s=\(token); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict"
    }

    /// Löscht beim Abmelden das Sitzungs-Cookie und das alte Schlüssel-Cookie `k`.
    static let clearedCookies = [
        "s=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict",
        "k=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict",
    ]

    /// Sitzungsschlüssel aus dem `Cookie`-Kopf.
    nonisolated static func sessionToken(cookieHeader: String?) -> String? {
        cookieHeader?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("s=") }.map { String($0.dropFirst(2)) }
    }

    // MARK: - Rollen

    /// Lesende Parameter je Route – was ein Konto „Nur ansehen“ mitschicken darf.
    /// Alles andere (Umschalten, Abstimmen, Plan, Löschen, Suchlauf) verlangt
    /// „Bedienen“. Eine neue Route ist damit von selbst gesperrt, bis sie hier steht.
    static let readOnlyParameters: [String: Set<String>] = [
        "/api/state": ["sel"],
        "/api/archive": ["kind", "day", "id"],
        "/api/acars": ["since"],
        "/api/spectrum": [],
        "/api/spectrum/presets": [],
        "/api/fm": [],
        "/api/sensors": [],
        "/api/smart868": ["dev"],
        "/api/dsc": [],
        "/api/aprs": ["sel"],
        "/api/ft8": ["cq"],
        "/api/occupancy": ["hours"],
        "/occupancy.png": ["w", "h", "hours", "m"],
        "/api/airband": [],
        "/api/airband/search": ["q"],
        "/api/zigbee": ["pan"],
        "/api/sondes": ["serial"],
        "/api/airports": ["bbox"],
        "/api/plan": [],
        "/img": ["n", "w"],
        "/audio.aac": [],
        // `k`: alte Lesezeichen mit dem früheren Schlüssel – wirkungslos, aber harmlos.
        "/": ["k"], "/index.html": ["k"], "/manifest.webmanifest": ["k"],
    ]

    /// Braucht die Anfrage die Rolle „Bedienen“? `t` (Cache-Bust) zählt nie.
    nonisolated static func requiresControl(path: String, query: [String: String]) -> Bool {
        guard let allowed = readOnlyParameters[path] else { return true }
        return query.keys.contains { $0 != "t" && !allowed.contains($0) }
    }
}
