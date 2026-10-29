import Foundation
import Testing
@testable import PortaPackManager

/// Absicherungen aus dem Code-Review vom 27.10.2026.
@Suite("Review-Korrekturen")
struct ReviewFixTests {
    typealias Preset = GainProfile.Preset

    @Test("Automatik: drei Takte Übersteuerung → eine Stufe zurück, danach nicht wieder hoch")
    func autoGainStep() {
        var step = AutoGainStep()
        let clipped = HackRFDevice.InputLevels(rmsDBFS: -10, peakDBFS: 0, clipped: 0.05)
        let quiet = HackRFDevice.InputLevels(rmsDBFS: -50, peakDBFS: -40, clipped: 0)
        #expect(step.next(.init(lna: 32, vga: 30, amplifier: true), levels: clipped, clipTicks: 2, raiseAllowed: true) == nil)
        let off = step.next(.init(lna: 32, vga: 30, amplifier: true), levels: clipped, clipTicks: 3, raiseAllowed: true)
        #expect(off?.0 == Preset(lna: 32, vga: 30, amplifier: false))
        let lower = step.next(.init(lna: 32, vga: 30, amplifier: false), levels: clipped, clipTicks: 3, raiseAllowed: true)
        #expect(lower?.0.lna == 24 && step.lnaCeiling == 24)
        // Zu leise: LNA darf die gesperrte Stufe nicht wieder erreichen – dann VGA.
        let up = step.next(.init(lna: 24, vga: 30, amplifier: false), levels: quiet, clipTicks: 0, raiseAllowed: true)
        #expect(up?.0 == Preset(lna: 24, vga: 34, amplifier: false))
        // Nach einem Handeingriff nicht von selbst hochdrehen, zurücknehmen schon.
        #expect(step.next(.init(lna: 8, vga: 20, amplifier: false), levels: quiet, clipTicks: 0, raiseAllowed: false) == nil)
        #expect(step.next(.init(lna: 8, vga: 20, amplifier: false), levels: clipped, clipTicks: 3, raiseAllowed: false) != nil)
    }

    @Test("Fernzugriff: Schlüsselvergleich")
    func token() {
        #expect(RemoteHub.matches("abc123def456", "abc123def456"))
        #expect(!RemoteHub.matches("abc123def457", "abc123def456"))
        #expect(!RemoteHub.matches("abc", "abc123def456"))
        #expect(!RemoteHub.matches(nil, "abc123def456"))
        #expect(!RemoteHub.matches("", ""))
    }

    @Test("CSV: Funkfelder gequotet, Formeln entschärft")
    func csv() {
        #expect(TrafficArchive.csvField("MAERSK") == "\"MAERSK\"")
        #expect(TrafficArchive.csvField("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(TrafficArchive.csvField("-5") == "\"'-5\"")
        #expect(TrafficArchive.csvField("a;b") == "\"a;b\"")
    }

    @Test("Fotolinks: nur HTTPS und erwartete Hosts")
    func links() {
        let hosts = ["planespotters.net"]
        #expect(URL(string: "https://www.planespotters.net/photo/1")!.isSafeWebLink(hosts: hosts))
        #expect(!URL(string: "javascript:alert(1)")!.isSafeWebLink(hosts: hosts))
        #expect(!URL(string: "file:///etc/passwd")!.isSafeWebLink(hosts: hosts))
        #expect(!URL(string: "http://www.planespotters.net/")!.isSafeWebLink(hosts: hosts))
        #expect(!URL(string: "https://planespotters.net.evil.com/")!.isSafeWebLink(hosts: hosts))
    }

    @Test("Selbststart von der Startseite verfällt nicht sofort, gilt aber nur einmal")
    @MainActor
    func autoStart() {
        let nav = AppNavigation.shared
        nav.open(.adsb, start: true)
        #expect(!nav.takeAutoStart(.ais))
        #expect(nav.takeAutoStart(.adsb))
        #expect(!nav.takeAutoStart(.adsb))
        nav.open(.ais, start: false)
        #expect(!nav.takeAutoStart(.ais))
        nav.page = nil
    }
}
