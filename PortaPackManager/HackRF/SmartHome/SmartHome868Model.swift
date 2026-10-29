import Foundation
import Observation

/// Verteilt Funkstöße auf die Dekoder der Funkarten.
enum SmartHome868Decoder {
    struct Config: Sendable {
        var radios: Set<SmartHomeRadio> = Set(SmartHomeRadio.allCases)
        /// wM-Bus: Ident-Nummer → AES-Schlüssel.
        var wmbusKeys: [String: [UInt8]] = [:]
        /// EnOcean: Sender-ID → Profil („A5-02-05“).
        var enoceanProfiles: [String: String] = [:]
    }

    static let channelRate = SmartHomeFrontEnd.channelRate

    static func decode(_ burst: SmartHomeBurst, config: Config) -> [SmartHomeFrame] {
        let length = burst.signal.count
        var frames: [SmartHomeFrame] = []
        switch burst.channel {
        case .srd868_3:
            // EnOcean-Telegramme sind kurz (≈ 1 ms), Homematic-Rahmen lang (≥ 15 ms).
            if config.radios.contains(.enocean), length < 20_000 {
                let bits = SmartHomeDemod.askBits(burst, samplesPerBit: channelRate / EnOcean.bitRate)
                frames += EnOcean.frames(inBits: bits).map { frame in
                    guard let profile = config.enoceanProfiles[frame.address], frame.bytes.first == 0xA5,
                          let reparsed = EnOcean.parse(frame.bytes, eep: profile) else { return frame }
                    return reparsed
                }
            }
            if config.radios.contains(.homematic), length > 4_000 {
                for bits in SmartHomeDemod.fskBits(burst, samplesPerBit: channelRate / Homematic.bitRate, cutoffHz: 50_000) {
                    frames += Homematic.frames(inBits: bits)
                    if !frames.isEmpty { break }
                }
            }
        case .zwave:
            guard config.radios.contains(.zwave), length > 800 else { break }
            for bits in SmartHomeDemod.fskBits(burst, samplesPerBit: channelRate / ZWave.Rate.r2.symbolRate, cutoffHz: 70_000) {
                frames += ZWave.frames(inBits: bits, rate: .r2)
                if !frames.isEmpty { break }
            }
            if frames.isEmpty, length > 3_000 {
                for chips in SmartHomeDemod.fskBits(burst, samplesPerBit: channelRate / ZWave.Rate.r1.symbolRate, cutoffHz: 70_000) {
                    frames += ZWave.frames(inBits: chips, rate: .r1)
                    if !frames.isEmpty { break }
                }
            }
        case .zwaveR3:
            guard config.radios.contains(.zwave), length > 300 else { break }
            for bits in SmartHomeDemod.fskBits(burst, samplesPerBit: channelRate / ZWave.Rate.r3.symbolRate, cutoffHz: 120_000) {
                frames += ZWave.frames(inBits: bits, rate: .r3)
                if !frames.isEmpty { break }
            }
        case .wmbus:
            guard config.radios.contains(.wmbus), length > 400 else { break }
            // fskBits liefert beide Polaritäten; WMBus prüft selbst beide – eine reicht.
            if let bits = SmartHomeDemod.fskBits(burst, samplesPerBit: channelRate / WMBus.chipRate).first {
                frames += WMBus.frames(inBits: bits, keys: config.wmbusKeys)
            }
        }
        return frames
    }
}

/// EnOcean-Profile je Sender, begrenzt: Anlerntelegramme kommen frei
/// fälschbar aus der Luft – ohne Grenze wüchse die Tabelle (und jede
/// Änderung wäre eine UserDefaults-Schreibung). Älteste fliegen zuerst.
struct EnOceanProfileBook: Equatable {
    static let defaultCapacity = 200
    private(set) var profiles: [String: String] = [:]
    /// Sender in Reihenfolge der letzten Änderung, ältester zuerst.
    private(set) var order: [String] = []
    let capacity: Int

    init(profiles: [String: String] = [:], order: [String] = [], capacity: Int = Self.defaultCapacity) {
        self.capacity = max(1, capacity)
        self.profiles = profiles
        // Gespeicherte Reihenfolge übernehmen, unbekannte Sender (ältere Stände) vorn einreihen.
        let known = order.filter { profiles[$0] != nil }
        var seen = Set(known)
        let missing = profiles.keys.sorted().filter { seen.insert($0).inserted }
        self.order = missing + known.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        trim()
    }

    subscript(id: String) -> String? { profiles[id] }

    /// Profil setzen (`nil` entfernt); `true`, wenn sich etwas geändert hat.
    @discardableResult
    mutating func set(_ eep: String?, for id: String) -> Bool {
        guard profiles[id] != eep else { return false }
        order.removeAll { $0 == id }
        profiles[id] = eep
        if eep != nil { order.append(id) }
        trim()
        return true
    }

    private mutating func trim() {
        guard order.count > capacity else { return }
        for id in order.prefix(order.count - capacity) { profiles[id] = nil }
        order.removeFirst(order.count - capacity)
    }
}

/// Smart-Home-Funk auf 868 MHz: Z-Wave, Homematic, EnOcean und Wireless
/// M-Bus gleichzeitig aus einem HackRF-Empfang (4 MS/s um 868,75 MHz).
/// Nur synthetisch geprüft, live unerprobt.
@MainActor
@Observable
final class SmartHome868Model {
    static let radiosKey = "smartHome868Radios"
    static let profilesKey = "smartHome868EnOceanProfiles"
    static let profileOrderKey = "smartHome868EnOceanProfileOrder"
    /// Gelernte Profile höchstens so oft speichern (s).
    static let profileWriteInterval: TimeInterval = 30

    var lnaGain = GainProfile.preset(.sensors).lna
    var vgaGain = GainProfile.preset(.sensors).vga
    var amplifier = GainProfile.preset(.sensors).amplifier
    var antennaPower = false

    /// Ausgewertete Funkarten (abgewählte kosten keine Rechenzeit).
    private(set) var radios: Set<SmartHomeRadio>
    private(set) var running = false
    private(set) var devices: [SmartHomeDevice] = []
    private(set) var receptions: [SmartHomeReception] = []
    private(set) var frameCount = 0
    private(set) var burstCount = 0
    private(set) var noiseDB: [SmartHomeChannel: Double] = [:]
    private(set) var error: String?
    private(set) var wmbusKeys: [WMBusKey] = WMBusKeyStore.load()
    var enoceanProfiles: [String: String] { profileBook.profiles }
    private var profileBook: EnOceanProfileBook
    @ObservationIgnored private var lastProfileWrite = Date.distantPast
    @ObservationIgnored private var profileWriteTask: Task<Void, Never>?

    private let shared = Shared()
    private var pollTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let frontEnd = SmartHomeFrontEnd()
        var config = SmartHome868Decoder.Config()
        var devices: [String: SmartHomeDevice] = [:]
        var receptions: [SmartHomeReception] = []
        var recent: [(key: [UInt8], date: Date)] = []
        var learnedProfiles: [String: String] = [:]
        var nextID = 0
        var bursts = 0
        var noise: [SmartHomeChannel: Double] = [:]

        /// Läuft auf dem Empfangsthread.
        func handle(_ block: Data) {
            let enabled = lock.withLock { Set(config.radios.flatMap(\.channels)) }
            frontEnd.enabled = enabled
            let bursts = frontEnd.process(block)
            var noise: [SmartHomeChannel: Double] = [:]
            for channel in enabled { noise[channel] = frontEnd.noiseDB(channel) }
            guard !bursts.isEmpty else {
                lock.withLock { self.noise = noise }
                return
            }
            let config = lock.withLock { self.config }
            let results = bursts.map { ($0, SmartHome868Decoder.decode($0, config: config)) }
            lock.withLock {
                self.noise = noise
                self.bursts += bursts.count
                for (burst, frames) in results {
                    for frame in frames { ingest(frame, burst: burst) }
                }
            }
        }

        func ingest(_ frame: SmartHomeFrame, burst: SmartHomeBurst) {
            // Wiederholungen (EnOcean schickt jedes Telegramm dreimal, Homematic
            // wiederholt ohne Antwort) innerhalb 0,5 s nur einmal zählen.
            recent.removeAll { burst.date.timeIntervalSince($0.date) > 0.5 }
            if recent.contains(where: { $0.key == frame.bytes }) { return }
            recent.append((frame.bytes, burst.date))
            if frame.radio == .enocean, let eep = frame.fields.first(where: { $0.name == "EEP" })?.value {
                learnedProfiles[frame.address] = eep
            }
            receptions.append(SmartHomeReception(id: nextID, date: burst.date, frequencyMHz: burst.channel.frequencyMHz,
                                                 rssiDB: burst.powerDB, snrDB: burst.snrDB, frame: frame))
            nextID += 1
            if receptions.count > 1000 { receptions.removeFirst(receptions.count - 1000) }
            let key = frame.deviceKey
            var device = devices[key] ?? SmartHomeDevice(id: key, radio: frame.radio, address: frame.address,
                                                         deviceType: frame.deviceType, lastSummary: frame.summary,
                                                         values: [], encrypted: frame.encrypted, rssiDB: burst.powerDB,
                                                         snrDB: burst.snrDB, firstSeen: burst.date, lastSeen: burst.date, count: 0)
            device.count += 1
            device.lastSeen = burst.date
            device.rssiDB = burst.powerDB
            device.snrDB = burst.snrDB
            device.lastSummary = frame.summary
            device.encrypted = frame.encrypted
            // Gerätetyp aus der Geräteinfo hat Vorrang vor Vermutungen.
            if !frame.deviceType.isEmpty {
                if device.deviceType.isEmpty || frame.deviceTypeFromInfo
                    || (frame.radio != .homematic && !frame.deviceTypeGuessed) {
                    device.deviceType = frame.deviceType
                }
            }
            for value in frame.values {
                if let index = device.values.firstIndex(where: { $0.name == value.name }) {
                    device.values[index] = value
                } else {
                    device.values.append(value)
                }
            }
            devices[key] = device
            if devices.count > 1000 {
                DevicePruning.prune(&devices, limit: 1000, maxAge: 86_400, now: burst.date) { $0.lastSeen }
            }
        }
    }

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.radiosKey)
        radios = stored.map { Set($0.compactMap(SmartHomeRadio.init(rawValue:))) } ?? Set(SmartHomeRadio.allCases)
        profileBook = EnOceanProfileBook(
            profiles: (UserDefaults.standard.dictionary(forKey: Self.profilesKey) as? [String: String]) ?? [:],
            order: UserDefaults.standard.stringArray(forKey: Self.profileOrderKey) ?? [])
        syncConfig()
    }

    private func syncConfig() {
        var keys: [String: [UInt8]] = [:]
        for entry in wmbusKeys { keys[entry.meterID] = entry.key }
        let config = SmartHome868Decoder.Config(radios: radios, wmbusKeys: keys, enoceanProfiles: enoceanProfiles)
        shared.lock.withLock { shared.config = config }
    }

    // MARK: - Empfang

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            shared.frontEnd.reset()
            try device.setSampleRate(UInt32(SmartHomeFrontEnd.inputRate))
            try device.setBasebandFilter(SmartHomeFrontEnd.basebandFilterHz)
            try device.setFrequency(UInt64(SmartHomeFrontEnd.centerHz))
            try applyGains()
            let shared = shared
            try device.startReceiving(owner: self) { block in shared.handle(block) }
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    self.poll()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func poll() {
        let (devices, receptions, nextID, bursts, noise, learned) = shared.lock.withLock {
            let learned = shared.learnedProfiles
            shared.learnedProfiles = [:]
            return (Array(shared.devices.values), shared.receptions, shared.nextID, shared.bursts, shared.noise, learned)
        }
        let sorted = devices.sorted { $0.lastSeen > $1.lastSeen }
        if sorted != self.devices {
            Self.reportToMQTT(sorted, previous: self.devices)
            self.devices = sorted
        }
        if nextID != frameCount {
            self.receptions = receptions.reversed()
            frameCount = nextID
        }
        burstCount = bursts
        noiseDB = noise
        // Aus Anlerntelegrammen gelernte EnOcean-Profile übernehmen.
        var changed = false
        for (id, eep) in learned where EnOcean.supportedProfiles.contains(eep) {
            if profileBook.set(eep, for: id) { changed = true }
        }
        if changed { storeProfiles(throttled: true) }
    }

    /// Neue oder geänderte Geräte an Home Assistant (nur wenn dort eingeschaltet).
    /// Verschlüsselte Geräte ohne Messwerte meldet die Brücke nicht (keine Werte).
    private static func reportToMQTT(_ devices: [SmartHomeDevice], previous: [SmartHomeDevice]) {
        let bridge = MQTTBridge.shared
        guard bridge.isEnabled(.smartHome868) else { return }
        let before = Dictionary(previous.map { ($0.id, $0.lastSeen) }, uniquingKeysWith: { a, _ in a })
        for device in devices where before[device.id] != device.lastSeen && !device.values.isEmpty {
            bridge.report(source: .smartHome868, deviceID: device.id, name: MQTTFeeds.name(of: device),
                          model: device.deviceType.isEmpty ? nil : device.deviceType,
                          values: MQTTFeeds.values(of: device), seen: device.lastSeen)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        device?.stopReceiving(owner: self)
        running = false
    }

    func applyGains() throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    func clear() {
        shared.lock.withLock {
            shared.devices = [:]
            shared.receptions = []
            shared.recent = []
        }
        devices = []
        receptions = []
    }

    // MARK: - Einstellungen

    func setRadio(_ radio: SmartHomeRadio, enabled: Bool) {
        if enabled { radios.insert(radio) } else { radios.remove(radio) }
        UserDefaults.standard.set(radios.map(\.rawValue).sorted(), forKey: Self.radiosKey)
        syncConfig()
    }

    /// Fügt einen Zählerschlüssel hinzu (oder ersetzt ihn). Meldet einen Fehlertext.
    func addKey(meterID: String, key: String, label: String) -> String? {
        guard let id = WMBusKeyStore.parseMeterID(meterID) else { return String(localized: "Die Zählernummer hat höchstens 8 Ziffern.") }
        guard let bytes = WMBusKeyStore.parseKey(key) else { return String(localized: "Der Schlüssel hat 32 Hex-Zeichen (16 Byte).") }
        var list = wmbusKeys.filter { $0.meterID != id }
        list.append(WMBusKey(meterID: id, key: bytes, label: label))
        list.sort { $0.meterID < $1.meterID }
        let status = WMBusKeyStore.save(list)
        guard status == errSecSuccess else { return String(localized: "Schlüssel konnte nicht gesichert werden (Schlüsselbund-Fehler \(status)).") }
        wmbusKeys = list
        syncConfig()
        return nil
    }

    func removeKey(_ meterID: String) {
        let list = wmbusKeys.filter { $0.meterID != meterID }
        guard WMBusKeyStore.save(list) == errSecSuccess else { return }
        wmbusKeys = list
        syncConfig()
    }

    /// EnOcean-Profil eines Senders festlegen (`nil`: Vorgabe A5-02-05).
    func setProfile(_ eep: String?, for senderID: String) {
        profileBook.set(eep, for: senderID)
        storeProfiles(throttled: false)
    }

    /// Dekoder sofort umstellen; gelernte Profile höchstens alle
    /// `profileWriteInterval` Sekunden in die UserDefaults schreiben.
    private func storeProfiles(throttled: Bool) {
        syncConfig()
        let wait = Self.profileWriteInterval - Date().timeIntervalSince(lastProfileWrite)
        guard throttled, wait > 0 else {
            writeProfiles()
            return
        }
        guard profileWriteTask == nil else { return }
        profileWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.writeProfiles()
        }
    }

    private func writeProfiles() {
        profileWriteTask?.cancel()
        profileWriteTask = nil
        lastProfileWrite = Date()
        UserDefaults.standard.set(profileBook.profiles, forKey: Self.profilesKey)
        UserDefaults.standard.set(profileBook.order, forKey: Self.profileOrderKey)
    }

    // MARK: - Messwerte

    /// Aktuelle Messwerte aller Geräte als flache Liste (für eine spätere
    /// Weitergabe, z. B. per MQTT): je Gerät und Messgröße der letzte Wert.
    var measurements: [SmartHomeMeasurement] {
        devices.flatMap { device in
            device.values.map {
                SmartHomeMeasurement(deviceID: device.id, radio: device.radio, address: device.address,
                                     name: $0.name, unit: $0.unit, value: $0.value, date: device.lastSeen)
            }
        }
    }
}

extension SmartHome868Model: GainTunable {
    var idleHint: String { String(localized: "Smart-Home-Geräte senden oft nur bei Änderungen oder alle paar Minuten, Funkzähler meist alle 15 s bis 15 min.") }
    var quality: GainQuality? { .count(frameCount) }
    func applyTunedGains(_ device: HackRFDevice?) throws { try applyGains() }
}
