import Foundation
import Observation

/// Ein gesehenes LoRaWAN-Gerät, zusammengefasst über DevAddr (bzw. DevEUI bei Join).
struct LoRaWANDevice: Identifiable, Sendable, Equatable {
    var id: String
    var devAddr: UInt32?
    var devEUI: UInt64?
    var label: String?
    var lastFCnt: UInt16?
    var frames = 0
    var lastSummary = ""
    var lastPayload: [UInt8]?
    var snrDB = 0.0
    var rssiDB = 0.0
    var hasKeys = false
    var lastSeen: Date

    var address: String {
        if let devAddr { return String(format: "%08X", devAddr) }
        if let devEUI { return String(format: "%016llX", devEUI) }
        return id
    }
}

/// Eine Protokollzeile.
struct LoRaWANLogLine: Identifiable, Sendable {
    let id: Int
    let date: Date
    let channelMHz: Double
    let sf: Int
    let snrDB: Double
    let frame: LoRaWANFrame
}

/// LoRaWAN-Empfang (EU868) über den LoRa-PHY. Hört die drei Standard-Uplink-
/// Kanäle im Wechsel bei einem wählbaren Spreizfaktor; Datenrahmen eigener
/// Geräte (Sitzungsschlüssel hinterlegt) werden entschlüsselt und die MIC
/// geprüft. Nur synthetisch getestet, live unerprobt.
@MainActor
@Observable
final class LoRaWANModel {
    /// EU868-Uplink-Kanäle (Standard-Dreiergruppe aller Netze).
    static let channelsMHz = [868.1, 868.3, 868.5]

    /// 7–12 fest, 0 = alle gleichzeitig (ein Demodulator je Spreizfaktor, je
    /// ≈ 1 % eines Kerns). Vorgabe „alle“ – welchen ein Sensor nutzt, weiß
    /// kein Einsteiger, und LoRaWAN-Netze wählen ihn je Gerät nach Abstand.
    var spreadingFactor = 0
    var dwell = 2.0
    var lnaGain = GainProfile.preset(.meshtastic).lna
    var vgaGain = GainProfile.preset(.meshtastic).vga
    var amplifier = GainProfile.preset(.meshtastic).amplifier
    var antennaPower = false

    private(set) var running = false
    private(set) var channelMHz = 868.1
    private(set) var devices: [LoRaWANDevice] = []
    private(set) var log: [LoRaWANLogLine] = []
    private(set) var frameCount = 0
    private(set) var decryptedCount = 0
    private(set) var noiseDB = -100.0
    private(set) var error: String?
    private(set) var sessions: [LoRaWANSession] = LoRaWANKeyStore.load()

    private let shared = Shared()
    private var pollTask: Task<Void, Never>?
    private var hopTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var demods: [(sf: Int, demod: LoRaDemodulator)] = []
        var sessions: [UInt32: LoRaWANSession] = [:]
        var channelMHz = 868.1
        var devices: [String: LoRaWANDevice] = [:]
        var log: [LoRaWANLogLine] = []
        var count = 0
        var decrypted = 0
        var noiseDB = -100.0

        func handle(_ block: Data) {
            // Referenzen unter Lock holen: `tune` tauscht sie auf dem Main Actor (wie Meshtastic).
            let demods = lock.withLock { self.demods }
            let found = demods.flatMap { entry in entry.demod.process(block).map { (entry.sf, $0) } }
            let noise = demods.first?.demod.noiseDB ?? -100
            guard !found.isEmpty else {
                lock.withLock { noiseDB = noise }
                return
            }
            let (sessions, channel) = lock.withLock { (self.sessions, channelMHz) }
            lock.withLock {
                noiseDB = noise
                for (sf, phy) in found {
                    guard phy.crcValid != false else { continue }
                    guard let frame = LoRaWANParser.parse(phy.payload, sessions: sessions) else { continue }
                    count += 1
                    if frame.decrypted != nil { decrypted += 1 }
                    log.append(LoRaWANLogLine(id: count, date: phy.date, channelMHz: channel, sf: sf,
                                              snrDB: phy.snrDB, frame: frame))
                    if log.count > 1000 { log.removeFirst(log.count - 1000) }
                    ingest(frame, phy: phy, channel: channel)
                }
            }
        }

        private func ingest(_ frame: LoRaWANFrame, phy: LoRaFrame, channel: Double) {
            let key: String
            if let devAddr = frame.devAddr { key = String(format: "A%08X", devAddr) }
            else if let devEUI = frame.devEUI { key = String(format: "E%016llX", devEUI) }
            else { return }
            var device = devices[key] ?? LoRaWANDevice(id: key, devAddr: frame.devAddr, devEUI: frame.devEUI, lastSeen: phy.date)
            device.frames += 1
            device.lastFCnt = frame.fCnt ?? device.lastFCnt
            device.lastSummary = frame.summary
            if let decrypted = frame.decrypted { device.lastPayload = decrypted }
            device.hasKeys = frame.devAddr.map { sessions[$0] != nil } ?? false
            device.label = frame.devAddr.flatMap { sessions[$0]?.label } ?? device.label
            device.snrDB = phy.snrDB
            device.rssiDB = phy.levelDB
            device.lastSeen = phy.date
            devices[key] = device
            // DevAddr/DevEUI kommen aus der Luft – Liste begrenzen.
            DevicePruning.prune(&devices, limit: 2000, maxAge: 3600, now: phy.date) { $0.lastSeen }
        }
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        self.device = device
        running = true
        error = nil
        applySessions()
        do {
            try device.setSampleRate(UInt32(LoRaDemodulator.inputRate))
            try applyGains()
            try tune(to: Self.channelsMHz[0])
            let shared = shared
            try device.startReceiving(owner: self) { shared.handle($0) }
        } catch {
            self.error = error.localizedDescription
            running = false
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.poll()
            }
        }
        hopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.dwell))
                guard !Task.isCancelled, self.running else { return }
                let channels = Self.channelsMHz
                let next = channels[((channels.firstIndex(of: self.channelMHz) ?? 0) + 1) % channels.count]
                guard self.device?.isReceiving(for: self) == true else {
                    self.stop()
                    self.error = HackRFError.takenOver.localizedDescription
                    return
                }
                self.device?.stopReceiving(owner: self)
                do {
                    try self.tune(to: next)
                    let shared = self.shared
                    try self.device?.startReceiving(owner: self) { shared.handle($0) }
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        hopTask?.cancel(); hopTask = nil
        device?.stopReceiving(owner: self)
        running = false
    }

    private func tune(to mhz: Double) throws {
        channelMHz = mhz
        let center = mhz * 1_000_000
        let factors = spreadingFactor == 0 ? Array(7...12) : [spreadingFactor]
        let demods = factors.map { sf in
            (sf: sf, demod: LoRaDemodulator(parameters: LoRaParameters(spreadingFactor: sf, bandwidth: 125_000, syncWord: 0x34),
                                            centerFrequency: center))
        }
        shared.lock.withLock { shared.demods = demods; shared.channelMHz = mhz }
        try device?.setFrequency(UInt64(center - LoRaDemodulator.offset))
    }

    func spreadingFactorChanged() {
        guard running else { return }
        do { try tune(to: channelMHz) } catch { self.error = error.localizedDescription }
    }

    private func poll() {
        let (devices, log, count, decrypted, noise) = shared.lock.withLock {
            (Array(shared.devices.values), shared.log, shared.count, shared.decrypted, shared.noiseDB)
        }
        if count != frameCount {
            self.devices = devices.sorted { $0.lastSeen > $1.lastSeen }
            self.log = log.reversed()
            frameCount = count
            decryptedCount = decrypted
        }
        noiseDB = noise
    }

    // MARK: Sitzungsschlüssel

    private func applySessions() {
        let map = Dictionary(sessions.map { ($0.devAddr, $0) }, uniquingKeysWith: { _, b in b })
        shared.lock.withLock { shared.sessions = map }
    }

    /// Sitzung (ABP) hinzufügen. Liefert eine Fehlermeldung bei ungültiger Eingabe.
    @discardableResult
    func addSession(devAddr: String, nwkSKey: String, appSKey: String, label: String) -> String? {
        guard let addr = LoRaWANKeyStore.parseDevAddr(devAddr) else { return String(localized: "DevAddr: 8 Hex-Zeichen erwartet.") }
        guard let nwk = LoRaWANKeyStore.parseKey(nwkSKey) else { return String(localized: "NwkSKey: 32 Hex-Zeichen erwartet.") }
        guard let app = LoRaWANKeyStore.parseKey(appSKey) else { return String(localized: "AppSKey: 32 Hex-Zeichen erwartet.") }
        sessions.removeAll { $0.devAddr == addr }
        sessions.append(LoRaWANSession(devAddr: addr, nwkSKey: nwk, appSKey: app,
                                       label: label.trimmingCharacters(in: .whitespaces).isEmpty ? nil : label))
        LoRaWANKeyStore.save(sessions)
        applySessions()
        return nil
    }

    func removeSession(_ session: LoRaWANSession) {
        sessions.removeAll { $0.devAddr == session.devAddr }
        LoRaWANKeyStore.save(sessions)
        applySessions()
    }

    func clear() {
        shared.lock.withLock { shared.devices = [:]; shared.log = [] }
        devices = []
        log = []
    }

    func applyGains() throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    func applyGainsQuietly() { do { try applyGains() } catch { self.error = error.localizedDescription } }
}
