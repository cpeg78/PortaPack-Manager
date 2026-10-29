import Foundation
import Observation

/// Seitenwechsel aus einer Seite heraus (z. B. „auf der ADS-B-Karte zeigen“):
/// die Seitenleiste folgt `page`, die Zielseite holt sich `aircraft` beim
/// Erscheinen ab und leert es.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()
    var page: SidebarItem?
    /// Die Seite, die das Hauptfenster gerade zeigt (für „Hilfe zu dieser
    /// Seite“ im Menü ⌘?). Setzt `ContentView`.
    var visiblePage: SidebarItem = .overview
    /// ICAO-Adresse, die die ADS-B-Seite auswählen soll.
    var aircraft: UInt32?

    /// Von der Startseite gewählt: die Seite startet den Empfang beim Erscheinen
    /// selbst (nachdem sie bei Bedarf in den HackRF-Modus gewechselt hat).
    var autoStart: SidebarItem?
    private var autoStartDate = Date.distantPast

    func open(_ page: SidebarItem, start: Bool) {
        autoStart = start ? page : nil
        autoStartDate = Date()
        self.page = page
    }

    /// `true` genau einmal, wenn `page` selbst starten soll – und nur kurz nach
    /// dem Klick (Moduswechsel braucht bis ≈ 20 s). Sonst startete eine Seite,
    /// deren Kachel man ohne Gerät angeklickt hatte, Stunden später überraschend.
    func takeAutoStart(_ page: SidebarItem) -> Bool {
        guard autoStart == page else { return false }
        autoStart = nil
        return Date().timeIntervalSince(autoStartDate) < 60
    }

    /// Frequenz, die die Radioseite beim Erscheinen übernimmt und abspielt
    /// (Belegungsmonitor, Links `portapack://radio/<MHz>`).
    struct RadioRequest: Equatable {
        var mhz: Double
        var mode: RadioMode
    }
    var radioRequest: RadioRequest?

    func openRadio(mhz: Double, mode: RadioMode) {
        radioRequest = RadioRequest(mhz: mhz, mode: mode)
        autoStart = nil
        page = .radio
    }

    func takeRadioRequest() -> RadioRequest? {
        defer { radioRequest = nil }
        return radioRequest
    }

    func showAircraft(_ icao: UInt32) {
        aircraft = icao
        page = .adsb
    }
}
