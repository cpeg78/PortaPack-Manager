import CoreLocation
import Foundation
import Observation

/// ADS-B-Empfang im HackRF-Modus: 2 MS/s auf 1090 MHz, Dekodierung in der App.
@MainActor
@Observable
final class ADSBModel {
    var lnaGain = GainProfile.preset(.adsb).lna
    var vgaGain = GainProfile.preset(.adsb).vga
    var amplifier = GainProfile.preset(.adsb).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne

    private(set) var running = false
    private(set) var aircraft: [Aircraft] = []
    /// Anzahl der Flugzeuge für Startseite und Zusammenfassungen – eigene Größe,
    /// damit Leser der Zahl nicht bei jeder Neuzuweisung von `aircraft` neu zeichnen.
    private(set) var aircraftCount = 0
    /// Was die Karte zeichnet – je Takt neu, nur Flugzeuge mit Position und
    /// Kontakt in den letzten `MapAircraft.holdSeconds`.
    private(set) var mapAircraft: [MapAircraft] = []
    private(set) var framesValid = 0
    private(set) var framesSeen = 0
    private(set) var messagesPerSecond = 0.0
    private(set) var noiseLevel = 0.0
    private(set) var error: String?
    private(set) var log: [ADSBMessage] = []

    private let shared = Shared()
    private var updateTask: Task<Void, Never>?

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let demod = ADSBDemodulator()
        var tracker = AircraftTracker()
        var recent: [ADSBMessage] = []
        var validCount = 0
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            try device.setSampleRate(ADSBDemodulator.sampleRate)
            try device.setFrequency(ADSBDemodulator.frequency)
            try applyGains(to: device)
            let shared = shared
            try device.startReceiving(owner: self) { block in
                let messages = shared.demod.process(block)
                guard !messages.isEmpty else { return }
                BeastFeeder.shared.send(messages)
                shared.lock.withLock {
                    for message in messages { shared.tracker.ingest(message) }
                    shared.recent.append(contentsOf: messages)
                    if shared.recent.count > 500 { shared.recent.removeFirst(shared.recent.count - 500) }
                    shared.validCount += messages.count
                }
            }
            running = true
            error = nil
            updateTask = Task { [weak self] in
                var lastValid = 0
                var lastDate = Date()
                var lastArchive = Date.distantPast
                var shownValid = -1
                var shownDate = Date.distantPast
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let (planes, recent, valid) = self.shared.lock.withLock {
                        // Nach einer Stunde ohne Meldung verfällt ein Flugzeug (im Archiv bleibt es).
                        if self.shared.tracker.aircraft.count > 300 {
                            self.shared.tracker.prune(before: Date().addingTimeInterval(-3600))
                        }
                        // Im Lock nur kopieren – der Empfangsthread wartet sonst aufs Sortieren.
                        return (Array(self.shared.tracker.aircraft.values), self.shared.recent, self.shared.validCount)
                    }
                    let tickDate = Date()
                    // Nur bei neuen Meldungen neu zuweisen (sonst zeichnete die Tabelle
                    // zweimal je Sekunde ohne Änderung neu); alle 5 s trotzdem, damit
                    // Flugzeuge ohne Kontakt grau werden und verschwinden.
                    // Jede Zuweisung an eine beobachtete Eigenschaft löst – auch bei gleichem
                    // Wert – Neuzeichnen und Fensterlayout aus (Review L2), deshalb überall
                    // nur bei Änderung.
                    let newMessages = valid != shownValid
                    if newMessages || tickDate.timeIntervalSince(shownDate) >= 5 {
                        shownDate = tickDate
                        self.aircraft = planes.sorted { $0.lastSeen > $1.lastSeen }
                        self.mapAircraft = self.aircraft.compactMap { MapAircraft($0, now: tickDate) }
                        if self.aircraftCount != planes.count { self.aircraftCount = planes.count }
                    }
                    if newMessages {
                        shownValid = valid
                        self.log = recent.suffix(200).reversed()
                    }
                    if tickDate.timeIntervalSince(lastArchive) >= 5 {
                        lastArchive = tickDate
                        self.archive(self.aircraft)
                        if MQTTBridge.shared.isEnabled(.adsb) {
                            MQTTBridge.shared.report(source: .adsb, deviceID: "receiver", name: "ADS-B-Empfang",
                                                     model: "1090 MHz", values: MQTTFeeds.adsbValues(
                                                        self.aircraft, messagesPerSecond: self.messagesPerSecond, now: tickDate))
                        }
                    }
                    if self.framesValid != valid { self.framesValid = valid }
                    let seen = self.shared.demod.framesSeen
                    if self.framesSeen != seen { self.framesSeen = seen }
                    let now = Date()
                    if now.timeIntervalSince(lastDate) >= 2 {
                        let rate = Double(valid - lastValid) / now.timeIntervalSince(lastDate)
                        if self.messagesPerSecond != rate { self.messagesPerSecond = rate }
                        lastValid = valid
                        lastDate = now
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop(on device: HackRFDevice?) {
        updateTask?.cancel()
        updateTask = nil
        device?.stopReceiving(owner: self)
        running = false
        TrafficArchive.adsb.save()
    }

    /// Alle Flugzeuge mit neuer Meldung ins Tagesarchiv (alle 5 s).
    private func archive(_ planes: [Aircraft]) {
        let updates = planes.map { plane in
            let info = AircraftDatabase.shared.info(for: plane.icao)
            let route = FlightRouteLookup.shared.route(for: plane.callsign)
            return SightingUpdate(
                key: plane.icaoHex, name: plane.callsign, registration: info?.registration, type: info?.typeText,
                operatorName: info?.operatorText,
                route: route.map { "\($0.origin.shortText) → \($0.destination.shortText)" },
                lastSeen: plane.lastSeen, messages: plane.messages, latitude: plane.latitude, longitude: plane.longitude,
                altitudeM: plane.altitude.map { Int((Double($0) * 0.3048).rounded()) },
                speed: plane.groundSpeed.map { $0 * 1.852 })
        }
        TrafficArchive.adsb.record(updates, home: TrafficArchive.home)
    }

    /// Eigener Standort für die örtliche Positionsdekodierung.
    func setReceiver(_ home: CLLocationCoordinate2D?) {
        shared.lock.withLock { shared.tracker.receiver = home.map { ($0.latitude, $0.longitude) } }
    }

    func applyGains(to device: HackRFDevice?) throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    func clear() {
        shared.lock.withLock {
            let receiver = shared.tracker.receiver
            shared.tracker = AircraftTracker()
            shared.tracker.receiver = receiver
            shared.recent.removeAll()
        }
        aircraft = []
        mapAircraft = []
        log = []
    }
}

/// Schnappschuss eines Flugzeugs für die Karte: nur, was gezeichnet wird,
/// und vergleichbar – die Kartenansicht überspringt so unveränderte Stände.
struct MapAircraft: MapTarget, Sendable {
    /// Ohne Kontakt so lange wird ein Flugzeug grau gezeichnet …
    static let staleSeconds = 60.0
    /// … und nach dieser Zeit nicht mehr auf der Karte (in der Tabelle bleibt es).
    static let holdSeconds = 15.0 * 60

    let id: UInt32
    let label: String
    let coordinate: CLLocationCoordinate2D
    /// Kurs in Grad, 0 = Norden.
    let heading: Double?
    let stale: Bool
    let trail: [CLLocationCoordinate2D]
    var symbol: MapSymbol { .plane }
    var symbolSize: Double { 22 }   // mit dunkler Kontur; 18 ging auf der Karte unter (30.10.2026)

    init?(_ plane: Aircraft, now: Date) {
        guard let lat = plane.latitude, let lon = plane.longitude else { return nil }
        let age = now.timeIntervalSince(plane.lastSeen)
        guard age < Self.holdSeconds else { return nil }
        id = plane.id
        label = plane.callsign ?? plane.icaoHex
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        heading = plane.track ?? 90
        stale = age > Self.staleSeconds
        trail = plane.trail.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Die Spur wächst nur am Ende (oder wird geleert) – Länge und letzter
    /// Punkt genügen zum Vergleich.
    static func == (a: MapAircraft, b: MapAircraft) -> Bool {
        a.id == b.id && a.label == b.label && a.heading == b.heading && a.stale == b.stale
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
            && a.trail.count == b.trail.count
            && a.trail.last?.latitude == b.trail.last?.latitude
            && a.trail.last?.longitude == b.trail.last?.longitude
    }
}
