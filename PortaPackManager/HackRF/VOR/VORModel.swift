import Foundation
import Observation

/// Gemessenes Radial eines Funkfeuers (für die Kreuzpeilung).
struct VORBearing: Identifiable, Equatable, Sendable {
    var navaid: Navaid
    /// Missweisend (wie angezeigt) und rechtweisend (für die Karte).
    var magnetic: Double
    var trueRadial: Double
    var spread: Double
    var date: Date
    var id: String { navaid.id }
}

/// Ergebnis der Kreuzpeilung.
struct VORFix: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var cutAngle: Double
    /// Entfernung zum eingetragenen Standort (km), falls bekannt.
    var distanceToHomeKm: Double?
}

/// Güte der Messung in Alltagssprache.
enum VORQuality: Equatable, Sendable {
    case none, poor, fair, good

    var text: String {
        switch self {
        case .none: String(localized: "kein VOR-Signal")
        case .poor: String(localized: "unbrauchbar")
        case .fair: String(localized: "mäßig")
        case .good: String(localized: "gut")
        }
    }

    /// Bewertung aus den Modulationsgraden (Soll je 0,3 bzw. Hub 480 Hz) und
    /// der Streuung der letzten Radiale.
    static let minCarrierFraction = 0.3

    static func assess(_ reading: VORDemodulator.Reading?, spread: Double?) -> VORQuality {
        guard let reading else { return .none }
        // Ohne Träger ist alles andere Rauschen (siehe `carrierFraction`).
        guard reading.carrierFraction >= VORQuality.minCarrierFraction else { return .none }
        let amOK = (0.12...0.5).contains(reading.amDepth)
        let subOK = (0.12...0.5).contains(reading.subcarrierDepth)
        let devOK = (300...650).contains(reading.deviationHz)
        guard subOK || amOK else { return .none }
        guard amOK, subOK, devOK else { return .poor }
        guard let spread else { return .fair }
        if spread <= 1.5 { return .good }
        if spread <= 5 { return .fair }
        return .poor
    }
}

/// VOR-Empfänger im HackRF-Modus.
@MainActor
@Observable
final class VORModel {
    var lnaGain = GainProfile.preset(.acars).lna
    var vgaGain = GainProfile.preset(.acars).vga
    var amplifier = GainProfile.preset(.acars).amplifier
    var antennaPower = false

    private(set) var running = false
    private(set) var error: String?
    private(set) var frequencyMHz: Double = UserDefaults.standard.object(forKey: "vorFrequencyMHz") as? Double ?? 113.0
    /// Ausgewähltes Funkfeuer (bestimmt Missweisung und Kennungsabgleich).
    private(set) var station: Navaid?

    private(set) var reading: VORDemodulator.Reading?
    /// Gemitteltes Radial (missweisend) über die letzten Messungen.
    private(set) var radial: Double?
    private(set) var spread: Double?
    private(set) var signalQuality: VORQuality = .none
    private(set) var ident: String?
    private(set) var lastIdents: [String] = []
    private(set) var identKeyed = false
    private(set) var signalDB: Double = -100
    private(set) var bearings: [VORBearing] = []

    var listen = false {
        didSet { if running { listen ? startAudio() : audio.stop() } }
    }
    var volume: Double = 0.5 {
        didSet { shared.lock.withLock { shared.demod.volume = Float(volume) } }
    }

    private let shared = Shared()
    private let audio = AudioOutput()
    private var pollTask: Task<Void, Never>?
    private var recent: [(date: Date, radial: Double)] = []
    private weak var device: HackRFDevice?

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let demod = VORDemodulator()
        var listen = false
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            let shared = shared
            let output = audio.buffer
            shared.lock.withLock {
                shared.demod.reset()
                shared.demod.volume = Float(volume)
                shared.listen = listen
            }
            try device.setSampleRate(UInt32(VORDemodulator.inputRate))
            try retune()
            try applyGains()
            if listen { try audio.start() }
            try device.startReceiving(owner: self) { block in
                let (sound, listen) = shared.lock.withLock { (shared.demod.process(block), shared.listen) }
                if listen { output.write(sound) }
            }
            running = true
            error = nil
            recent = []
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.poll()
                }
            }
        } catch {
            self.error = error.localizedDescription
            audio.stop()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        device?.stopReceiving(owner: self)
        audio.stop()
        running = false
    }

    private func startAudio() {
        shared.lock.withLock { shared.listen = true }
        do { try audio.start() } catch { self.error = error.localizedDescription }
    }

    /// Stimmt auf ein Funkfeuer ab.
    func select(_ navaid: Navaid) {
        station = navaid
        tune(to: navaid.mhz, keepStation: true)
    }

    func tune(to mhz: Double, keepStation: Bool = false) {
        let clamped = max(108.0, min(117.95, (mhz * 20).rounded() / 20))   // 50-kHz-Raster
        frequencyMHz = clamped
        UserDefaults.standard.set(clamped, forKey: "vorFrequencyMHz")
        if !keepStation, let station, abs(station.mhz - clamped) > 0.001 { self.station = nil }
        recent = []
        radial = nil
        spread = nil
        reading = nil
        ident = nil
        lastIdents = []
        guard running, let device, device.isReceiving(for: self) else { return }
        do {
            try retune()
            shared.lock.withLock { shared.demod.reset() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func retune() throws {
        guard let device else { return }
        try device.setFrequency(UInt64(frequencyMHz * 1_000_000 - VORDemodulator.offset))
    }

    private func poll() {
        let (reading, idents, confirmed, keyed, signal) = shared.lock.withLock {
            (shared.demod.reading(), shared.demod.morse.idents, shared.demod.morse.confirmedIdent,
             shared.demod.morse.keyed, shared.demod.signalDB)
        }
        shared.lock.withLock { shared.listen = listen }
        self.reading = reading
        let carrier = (reading?.carrierFraction ?? 0) >= VORQuality.minCarrierFraction
        // Kennung nur mit Träger – sonst „liest“ der Morse-Dekoder Rauschen (live „E“).
        lastIdents = carrier ? idents : []
        ident = carrier ? (confirmed ?? idents.last) : nil
        identKeyed = keyed
        signalDB = Double(signal)
        let now = Date()
        if let reading, carrier, (0.1...0.6).contains(reading.subcarrierDepth), (0.1...0.6).contains(reading.amDepth) {
            recent.append((now, reading.radial))
        }
        recent.removeAll { now.timeIntervalSince($0.date) > 10 }
        if recent.count >= 3 {
            let mean = Self.circularMean(recent.map(\.radial))
            radial = mean
            spread = recent.map { GeoNav.angleDifference($0.radial, mean) }.max()
        } else {
            radial = nil
            spread = nil
        }
        signalQuality = VORQuality.assess(reading, spread: spread)
        // Gute Messungen eines bekannten Funkfeuers für die Kreuzpeilung merken.
        if let station, let radial, let spread, signalQuality == .good || signalQuality == .fair {
            let bearing = VORBearing(navaid: station, magnetic: radial, trueRadial: station.trueRadial(radial),
                                     spread: spread, date: now)
            bearings.removeAll { $0.id == station.id }
            bearings.insert(bearing, at: 0)
        }
    }

    /// Kennung passt zum ausgewählten Funkfeuer?
    var identMatches: Bool? {
        guard let ident, let station else { return nil }
        return ident.replacingOccurrences(of: " ", with: "") == station.ident.uppercased()
    }

    func removeBearing(_ bearing: VORBearing) {
        bearings.removeAll { $0.id == bearing.id }
    }

    func clearBearings() { bearings = [] }

    /// Kreuzpeilung aus den beiden jüngsten Radialen verschiedener Funkfeuer.
    func fix(homeLat: Double?, homeLon: Double?) -> VORFix? {
        Self.fix(from: bearings, homeLat: homeLat, homeLon: homeLon)
    }

    nonisolated static func fix(from bearings: [VORBearing], homeLat: Double?, homeLon: Double?) -> VORFix? {
        guard bearings.count >= 2 else { return nil }
        let a = bearings[0], b = bearings[1]
        guard let point = GeoNav.intersection(lat1: a.navaid.latitude, lon1: a.navaid.longitude, bearing1: a.trueRadial,
                                              lat2: b.navaid.latitude, lon2: b.navaid.longitude, bearing2: b.trueRadial) else { return nil }
        // VORs reichen am Boden selten über 300 km – ein Schnitt weit draußen
        // (fast parallele Radiale treffen sich erst am Pol) ist kein Standort.
        let maxKm = 500.0
        guard GeoMath.distanceKm(lat1: point.lat, lon1: point.lon, lat2: a.navaid.latitude, lon2: a.navaid.longitude) <= maxKm,
              GeoMath.distanceKm(lat1: point.lat, lon1: point.lon, lat2: b.navaid.latitude, lon2: b.navaid.longitude) <= maxKm
        else { return nil }
        let cut = GeoNav.cutAngle(fixLat: point.lat, fixLon: point.lon, lat1: a.navaid.latitude, lon1: a.navaid.longitude,
                                  lat2: b.navaid.latitude, lon2: b.navaid.longitude)
        var distance: Double?
        if let homeLat, let homeLon {
            distance = GeoMath.distanceKm(lat1: point.lat, lon1: point.lon, lat2: homeLat, lon2: homeLon)
        }
        return VORFix(latitude: point.lat, longitude: point.lon, cutAngle: cut, distanceToHomeKm: distance)
    }

    nonisolated static func circularMean(_ degrees: [Double]) -> Double {
        let s = degrees.reduce(0) { $0 + sin($1 * .pi / 180) }
        let c = degrees.reduce(0) { $0 + cos($1 * .pi / 180) }
        return GeoNav.normalize(atan2(s, c) * 180 / .pi)
    }

    func applyGains() throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }
}

extension VORModel: GainTunable {
    /// Ein VOR sendet ständig – optimiert wird nur der Pegel.
    var quality: GainQuality? { nil }
    var idleHint: String { String(localized: "Funkfeuer reichen am Boden oft nur 30–80 km weit. Wähle ein näheres oder setz die Antenne höher.") }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}
