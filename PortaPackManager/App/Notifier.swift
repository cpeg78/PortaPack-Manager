import Foundation
import Observation
import os
import UserNotifications

/// Benachrichtigungen über Ereignisse, die man sonst verpasst: Wetterballon in
/// Reichweite oder empfangen, Satellitenüberflug in Kürze, Ergebnis eines
/// geplanten Termins, Gerät getrennt. Zwei Wege, beide aus als Vorgabe:
///
/// - **Mitteilungen am Mac** (UserNotifications).
/// - **ntfy** aufs Handy: ein HTTPS-POST an `<server>/<thema>`; die ntfy-App
///   abonniert dasselbe Thema. Web-Push aus der Fernzugriffsseite geht nicht –
///   iOS verlangt dafür HTTPS, der Fernzugriff läuft über HTTP/Tailscale.
///   Hinaus gehen nur die Meldungstexte; das Thema ist zufällig erzeugt und
///   damit das einzige Geheimnis. Die Texte enthalten keine Koordinaten und
///   auch keine Entfernungen: Sondenpositionen sind auf SondeHub öffentlich,
///   aus zwei, drei Meldungen „Sonde X in N km“ ließe sich der Standort
///   errechnen (Review 28.10.2026, Y7). Die Mitteilung am Mac nennt die
///   Entfernung weiter – sie verlässt den Rechner nicht.
@MainActor
@Observable
final class Notifier {
    static let shared = Notifier()

    var macEnabled = UserDefaults.standard.bool(forKey: "notifyMac") {
        didSet {
            UserDefaults.standard.set(macEnabled, forKey: "notifyMac")
            if macEnabled { requestMacPermission() }
        }
    }
    var ntfyEnabled = UserDefaults.standard.bool(forKey: "notifyNtfy") {
        didSet {
            UserDefaults.standard.set(ntfyEnabled, forKey: "notifyNtfy")
            if ntfyEnabled, ntfyTopic.isEmpty { ntfyTopic = Self.randomTopic() }
        }
    }
    var ntfyServer = UserDefaults.standard.string(forKey: "notifyNtfyServer") ?? "https://ntfy.sh" {
        didSet { UserDefaults.standard.set(ntfyServer, forKey: "notifyNtfyServer") }
    }
    var ntfyTopic = UserDefaults.standard.string(forKey: "notifyNtfyTopic") ?? "" {
        didSet { UserDefaults.standard.set(ntfyTopic, forKey: "notifyNtfyTopic") }
    }
    var notifySondes = UserDefaults.standard.object(forKey: "notifySondes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifySondes, forKey: "notifySondes") }
    }
    var notifyPasses = UserDefaults.standard.object(forKey: "notifyPasses") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyPasses, forKey: "notifyPasses") }
    }
    var notifyPlan = UserDefaults.standard.object(forKey: "notifyPlan") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyPlan, forKey: "notifyPlan") }
    }
    var notifyProblems = UserDefaults.standard.object(forKey: "notifyProblems") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyProblems, forKey: "notifyProblems") }
    }
    var notifyDSC = UserDefaults.standard.object(forKey: "notifyDSC") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyDSC, forKey: "notifyDSC") }
    }

    /// Letzte Zustellung oder Fehler, für die Einstellungen.
    private(set) var lastResult: String?

    /// Schon gemeldete Ereignisse (je Schlüssel einmal am Tag) – gespeichert,
    /// sonst kamen nach jedem Neustart dieselben Meldungen erneut.
    @ObservationIgnored private var sent: [String: Date] = (UserDefaults.standard.dictionary(forKey: "notifySent") as? [String: Date]) ?? [:] {
        didSet { UserDefaults.standard.set(sent, forKey: "notifySent") }
    }
    @ObservationIgnored private weak var session: DeviceSession?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var deviceMissingSince: Date?
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Benachrichtigung")

    var anyEnabled: Bool { macEnabled || (ntfyEnabled && !ntfyTopic.isEmpty) }

    /// Adresse, die man in der ntfy-App abonniert.
    var subscribeURL: String { ntfyServer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + ntfyTopic }

    func bootstrap(session: DeviceSession) {
        self.session = session
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.tick()
            }
        }
    }

    // MARK: Ereignisse

    /// Neue Sonden in Reichweite laut SondeHub (je Seriennummer einmal am Tag).
    func sondesInRange(_ sightings: [SondeHubTraffic.Sighting]) {
        guard notifySondes else { return }
        for s in sightings {
            let text = Self.sondeRangeTexts(s)
            post(key: "range-\(s.serial)", title: String(localized: "Wetterballon in Reichweite"), body: text.local, remoteBody: text.remote)
        }
    }

    /// Texte zu einer Sonde in Reichweite: `local` (Mac) mit Entfernung,
    /// `remote` (ntfy) ohne – siehe Kopfkommentar.
    nonisolated static func sondeRangeTexts(_ s: SondeHubTraffic.Sighting) -> (local: String, remote: String) {
        let km = Int(s.distanceKm.rounded())
        let height = (s.altitude / 1000).formatted(.number.precision(.fractionLength(1)))
        guard let frequency = s.frequencyMHz else {
            return (String(localized: "\(s.serial) in \(km) km, \(height) km hoch"),
                    String(localized: "\(s.serial) in Reichweite, \(height) km hoch"))
        }
        let mhz = frequency.formatted(.number.precision(.fractionLength(2)))
        return (String(localized: "\(s.serial) in \(km) km, \(height) km hoch, \(mhz) MHz"),
                String(localized: "\(s.serial) in Reichweite, \(height) km hoch, \(mhz) MHz"))
    }

    /// Eine Sonde wurde selbst dekodiert.
    func sondeReceived(_ serial: String) {
        guard notifySondes else { return }
        post(key: "rx-\(serial)", title: String(localized: "Wetterballon empfangen"), body: String(localized: "\(serial) wird gerade empfangen."))
    }

    /// Ergebnis eines geplanten Termins (Satellit, Sondenfenster).
    func planFinished(_ title: String, result: String) {
        guard notifyPlan else { return }
        post(key: "plan-\(title)-\(Int(Date().timeIntervalSince1970 / 60))", title: title, body: result)
    }

    /// Seefunk-Notruf (DSC) empfangen – Notruf, Bestätigung oder Relais. Ohne
    /// MMSI und Position: die gehen nicht an ntfy (Inhalte nicht weitergeben).
    func dscDistress(kind: String, nature: String?, key: String) {
        guard notifyDSC else { return }
        let body = nature.map { String(localized: "\(kind) auf Kanal 70 empfangen: \($0). Mehr auf der Seite „Seefunk-Notruf (DSC)“.") }
            ?? String(localized: "\(kind) auf Kanal 70 empfangen. Mehr auf der Seite „Seefunk-Notruf (DSC)“.")
        post(key: "dsc-\(key)", title: String(localized: "Seefunk-Notruf (DSC)"), body: body)
    }

    func testMessage() {
        post(key: "test-\(Date().timeIntervalSince1970)", title: "PortaPack Manager", body: String(localized: "Testnachricht – Benachrichtigungen kommen an."))
    }

    private func tick() {
        let now = Date()
        // Überflug in den nächsten 10 Minuten (nur solche, die der Plan aufnimmt).
        let planner = ReceptionPlanner.shared
        if notifyPasses {
            for pass in planner.passes where pass.maxElevation >= planner.minElevation {
                let lead = pass.start.timeIntervalSince(now)
                guard lead > 0, lead <= 600 else { continue }
                post(key: "pass-\(pass.id)", title: String(localized: "Satellit kommt"),
                     body: String(localized: "\(pass.satellite.name) ab \(pass.start.formatted(date: .omitted, time: .shortened)), bis \(Int(pass.maxElevation))° hoch."))
            }
        }
        // Gerät weg, während aus der Ferne oder per Plan empfangen werden soll.
        if notifyProblems, let session {
            let wanted = RemoteHub.shared.remoteMode != nil || planner.status != nil
            if wanted, session.hackRF == nil, session.device == nil {
                deviceMissingSince = deviceMissingSince ?? now
                if now.timeIntervalSince(deviceMissingSince!) >= 120 {
                    post(key: "device-\(Int(deviceMissingSince!.timeIntervalSince1970))", title: String(localized: "Empfang unterbrochen"),
                         body: String(localized: "Der HackRF ist seit zwei Minuten nicht erreichbar – prüf Kabel und Stromversorgung."))
                }
            } else {
                deviceMissingSince = nil
            }
        }
        sent = sent.filter { now.timeIntervalSince($0.value) < 86_400 }
    }

    // MARK: Zustellung

    /// `remoteBody`: abweichender Text für ntfy (verlässt den Mac), sonst `body`.
    private func post(key: String, title: String, body: String, remoteBody: String? = nil) {
        guard anyEnabled, sent[key] == nil else { return }
        sent[key] = Date()
        Self.log.notice("\(title, privacy: .public): \(body, privacy: .public)")
        if macEnabled {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
        // JSON an die Wurzel des Servers: Titel mit Umlauten gehen als Kopfzeile nicht sicher.
        if ntfyEnabled, !ntfyTopic.isEmpty,
           let url = URL(string: ntfyServer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
           let payload = try? JSONSerialization.data(withJSONObject: ["topic": ntfyTopic, "title": title, "message": remoteBody ?? body]) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("PortaPackManager/1.0 (+https://github.com/cpeg78)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            Task { [weak self] in
                do {
                    let (_, response) = try await URLSession.shared.limitedData(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self?.lastResult = code == 200 ? String(localized: "Zuletzt gesendet: \(title)") : String(localized: "ntfy antwortet mit Fehler \(code).")
                } catch {
                    self?.lastResult = "ntfy: \(error.localizedDescription)"
                }
            }
        }
    }

    private func requestMacPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                if !granted { Notifier.shared.lastResult = String(localized: "Mitteilungen am Mac sind nicht erlaubt – erlaube sie in den Systemeinstellungen unter „Mitteilungen“.") }
            }
        }
    }

    static func randomTopic() -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyz23456789")
        return "portapack-" + String((0..<16).map { _ in letters.randomElement()! })
    }
}
