import Foundation
import Observation

/// Ein Bluetooth-LE-Gerät, zusammengefasst über seine Werbepakete.
struct BLEDevice: Identifiable, Sendable, Equatable {
    let address: BLEAddress
    var name: String?
    var kind: String?
    var company: String?
    var readings: [BLEReading]
    var fields: [BLEADField]
    var lastType: BLEAdvertisement.PDUType
    var connectable: Bool
    var channels: Set<Int>
    var count: Int
    var rssiDB: Double
    var firstSeen: Date
    var lastSeen: Date

    var id: BLEAddress { address }
}

/// Eine Zeile im Paketprotokoll.
struct BLELogLine: Identifiable, Sendable {
    let id: Int
    let packet: BLEPacket
    let advertisement: BLEAdvertisement?

    var hex: String { packet.pdu.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// Bluetooth LE im HackRF-Modus: Werbepakete auf den Kanälen 37–39.
@MainActor
@Observable
final class BLEModel {
    enum ChannelChoice: Hashable, CaseIterable, Identifiable {
        case fixed37, fixed38, fixed39, hop
        var id: Self { self }
        var title: String {
            switch self {
            case .fixed37: "37 (2402 MHz)"
            case .fixed38: "38 (2426 MHz)"
            case .fixed39: "39 (2480 MHz)"
            case .hop: String(localized: "Alle drei im Wechsel")
            }
        }
        var channel: Int? {
            switch self {
            case .fixed37: 37
            case .fixed38: 38
            case .fixed39: 39
            case .hop: nil
            }
        }
    }

    var choice: ChannelChoice = .fixed37
    var lnaGain = GainProfile.preset(.ble).lna
    var vgaGain = GainProfile.preset(.ble).vga
    var amplifier = GainProfile.preset(.ble).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne
    /// Scan-Anfragen und Verbindungsaufbau im Protokoll zeigen.
    var showRequests = true

    private(set) var running = false
    private(set) var channel = 37
    private(set) var devices: [BLEDevice] = []
    private(set) var log: [BLELogLine] = []
    private(set) var packetCount = 0
    private(set) var crcErrors = 0
    private(set) var noiseDB = -100.0
    private(set) var error: String?

    private let shared = Shared()
    private var pollTask: Task<Void, Never>?
    private var hopTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let demod = BLEDemodulator()
        var channel = 37
        var devices: [BLEAddress: BLEDevice] = [:]
        var log: [BLELogLine] = []
        var count = 0
        var crcErrors = 0
        var noiseDB = -100.0

        /// Läuft auf dem Empfangsthread.
        func handle(_ block: Data) {
            let channel = lock.withLock { self.channel }
            let packets = demod.process(block, channel: channel)
            let errors = demod.crcErrors, noise = demod.noiseDB
            let parsed = packets.map { ($0, BLEAdvertisement.parse($0.pdu)) }
            lock.withLock {
                crcErrors = errors
                noiseDB = noise
                for (packet, ad) in parsed {
                    count += 1
                    log.append(BLELogLine(id: count, packet: packet, advertisement: ad))
                    if let ad { ingest(ad, packet) }
                }
                if log.count > 1000 { log.removeFirst(log.count - 1000) }
            }
        }

        private func ingest(_ ad: BLEAdvertisement, _ packet: BLEPacket) {
            // Nur Werbende zählen als Gerät, nicht Scanner und Initiatoren.
            guard let address = ad.address, ![.scanReq, .connectInd].contains(ad.type) else { return }
            let info = BLEInterpreter.interpret(ad)
            let company = ad.manufacturer.flatMap { BLEInterpreter.companyNames[$0.company] }
            if var device = devices[address] {
                device.name = ad.name ?? device.name
                device.kind = info.kind ?? device.kind
                device.company = company ?? device.company
                if !info.readings.isEmpty { device.readings = info.readings }
                if !ad.fields.isEmpty { device.fields = merge(device.fields, ad.fields) }
                device.lastType = ad.type
                if ad.type == .advInd { device.connectable = true }
                device.channels.insert(packet.channel)
                device.count += 1
                device.rssiDB = 0.7 * device.rssiDB + 0.3 * packet.rssiDB
                device.lastSeen = packet.date
                devices[address] = device
            } else {
                // Zufallsadressen wechseln etwa alle 15 min – nach Stunden wären es
                // Zehntausende, die alle 500 ms sortiert werden. Ab 2000 Geräten
                // fällt weg, was seit 30 min nichts gesendet hat.
                if devices.count >= 2000 {
                    let cutoff = packet.date.addingTimeInterval(-1800)
                    devices = devices.filter { $0.value.lastSeen >= cutoff }
                }
                devices[address] = BLEDevice(address: address, name: ad.name, kind: info.kind, company: company,
                                             readings: info.readings, fields: ad.fields, lastType: ad.type,
                                             connectable: ad.type == .advInd, channels: [packet.channel], count: 1,
                                             rssiDB: packet.rssiDB, firstSeen: packet.date, lastSeen: packet.date)
            }
        }

        /// Werbung und Scan-Antwort tragen verschiedene Felder – beide behalten.
        private func merge(_ old: [BLEADField], _ new: [BLEADField]) -> [BLEADField] {
            let types = Set(new.map(\.type))
            return old.filter { !types.contains($0.type) } + new
        }
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        do {
            self.device = device
            shared.demod.reset()
            try device.setSampleRate(UInt32(BLEDemodulator.inputRate))
            try tune(choice.channel ?? 37)
            try applyGains()
            let shared = shared
            try device.startReceiving(owner: self) { block in shared.handle(block) }
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let (devices, log, count, errors, noise) = self.shared.lock.withLock {
                        (Array(self.shared.devices.values), self.shared.log, self.shared.count,
                         self.shared.crcErrors, self.shared.noiseDB)
                    }
                    if count != self.packetCount {
                        self.devices = devices.sorted { $0.lastSeen > $1.lastSeen }
                        self.log = log.reversed()
                        self.packetCount = count
                    }
                    self.crcErrors = errors
                    self.noiseDB = noise
                }
            }
            updateHopping()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        hopTask?.cancel()
        hopTask = nil
        device?.stopReceiving(owner: self)
        running = false
    }

    /// Kanalwahl geändert: fest einstellen oder Wechsel starten.
    func choiceChanged() {
        guard running else { return }
        if let fixed = choice.channel {
            do { try tune(fixed) } catch { self.error = error.localizedDescription }
        }
        updateHopping()
    }

    private func updateHopping() {
        hopTask?.cancel()
        hopTask = nil
        guard choice == .hop else { return }
        hopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.running else { return }
                guard self.device?.isReceiving(for: self) == true else {
                    self.stop()
                    self.error = HackRFError.takenOver.localizedDescription
                    return
                }
                let channels = BLELink.advertisingChannels
                let next = channels[((channels.firstIndex(of: self.channel) ?? 0) + 1) % channels.count]
                do { try self.tune(next) } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func tune(_ channel: Int) throws {
        self.channel = channel
        shared.lock.withLock { shared.channel = channel }
        guard let device else { return }
        try device.setFrequency(UInt64(BLELink.frequencyMHz(channel: channel) * 1_000_000 - BLEDemodulator.offset))
    }

    func applyGains() throws {
        guard let device else { return }
        try device.setLNAGain(Int(lnaGain))
        try device.setVGAGain(Int(vgaGain))
        try device.setAmplifier(amplifier)
        try device.setAntennaPower(antennaPower)
    }

    func applyGainsQuietly() {
        do { try applyGains() } catch { self.error = error.localizedDescription }
    }

    func clear() {
        shared.lock.withLock {
            shared.devices = [:]
            shared.log = []
        }
        devices = []
        log = []
    }
}
