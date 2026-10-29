import CoreWLAN
import Foundation
import Observation

/// Eine empfangene Remote-ID-Nachricht im Protokoll.
struct DroneLogLine: Identifiable, Sendable {
    let id: Int
    let date: Date
    let address: BLEAddress
    /// Empfangsweg, z. B. „HackRF BLE 37“, „HackRF WLAN 6 NAN“, „Mac-WLAN“.
    let source: String
    let channel: Int
    let rssiDB: Double
    let counter: UInt8
    let message: RemoteID.Message
}

/// Ein Schritt des HackRF-Empfangsplans: Bluetooth-Werbekanal oder WLAN-Kanal.
enum DroneRadioStep: Hashable, Sendable {
    case ble(Int)
    case wlan(Int)

    var title: String {
        switch self {
        case let .ble(channel): "BLE \(channel)"
        case let .wlan(channel): "WLAN \(channel)"
        }
    }
}

/// Drohnen-Kennung (Remote ID) im HackRF-Modus über alle Wege, die der Mac
/// und der HackRF hergeben:
/// - HackRF, Bluetooth LE 4.x: Werbepakete auf 37/38/39 (`BLEDemodulator`).
/// - HackRF, WLAN: 802.11-Rahmen bei 20 MS/s (`WLANReceiver`) auf Kanal 6
///   (2,4 GHz) bzw. 149 (5 GHz) – Beacons (ASTM und französische Kennung)
///   und NAN-Service-Discovery-Rahmen, die kein Betriebssystem herausgibt.
/// - WLAN des Mac: Beacons über CoreWLAN (alle Kanäle, alle 3 s).
/// - Bluetooth des Mac: Werbung über CoreBluetooth (alle drei Kanäle zugleich).
/// Der HackRF wechselt zwischen den gewählten Schritten im Takt `dwell`.
/// Nicht erfasst: Bluetooth 5 Long Range (codierte PHY – Apples Stack
/// empfängt sie nicht, und der HackRF kann dem AuxPtr nicht binnen 0,3 ms
/// auf den Sekundärkanal folgen).
@MainActor
@Observable
final class DroneModel {
    var choice: BLEModel.ChannelChoice = .fixed37
    var lnaGain = GainProfile.preset(.drones).lna
    var vgaGain = GainProfile.preset(.drones).vga
    var amplifier = GainProfile.preset(.drones).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne
    /// HackRF: Bluetooth-Werbekanäle.
    var useBLE = true
    /// HackRF: WLAN-Kanal 6 (2,4 GHz) – NAN und Beacons.
    var useWLAN24 = true
    /// HackRF: WLAN-Kanal 149 (5 GHz).
    var useWLAN5 = false
    /// Wi-Fi-Beacons über das WLAN des Mac mitsuchen.
    var useWiFi = true
    /// Bluetooth-Werbung über das Bluetooth des Mac.
    var useMacBluetooth = true
    /// Verweildauer je HackRF-Schritt in Sekunden.
    var dwell = 2.0

    private(set) var running = false
    private(set) var step: DroneRadioStep?
    private(set) var wifiScans = 0
    private(set) var wifiFrames = 0
    private(set) var wifiError: String?
    private(set) var macBluetoothFrames = 0
    private(set) var macBluetoothError: String?
    private(set) var channel = 37
    private(set) var drones: [Drone] = []
    private(set) var log: [DroneLogLine] = []
    private(set) var packetCount = 0
    private(set) var wlanFrames = 0
    private(set) var wlanRemoteID = 0
    private(set) var nanFrames = 0
    private(set) var messageCount = 0
    private(set) var noiseDB = -100.0
    private(set) var error: String?

    private let shared = Shared()
    private let macBluetooth = MacBluetoothScanner()
    private var pollTask: Task<Void, Never>?
    private var hopTask: Task<Void, Never>?
    private var wifiTask: Task<Void, Never>?
    private weak var device: HackRFDevice?

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        let ble = BLEDemodulator()
        let wlan = WLANReceiver()
        var step: DroneRadioStep = .ble(37)
        var tracker = DroneTracker()
        var log: [DroneLogLine] = []
        var packets = 0
        var wlanFrames = 0
        var wlanRemoteID = 0
        var nanFrames = 0
        var macBluetoothFrames = 0
        var messages = 0
        var noiseDB = -100.0

        /// Läuft auf dem Empfangsthread.
        func handle(_ block: Data) {
            switch lock.withLock({ step }) {
            case let .ble(channel): handleBLE(block, channel: channel)
            case let .wlan(channel): handleWLAN(block, channel: channel)
            }
        }

        private func handleBLE(_ block: Data, channel: Int) {
            let packets = ble.process(block, channel: channel)
            let noise = ble.noiseDB
            let frames = packets.compactMap { packet -> (BLEPacket, BLEAddress, RemoteID.Frame)? in
                guard let ad = BLEAdvertisement.parse(packet.pdu), let address = ad.address,
                      let frame = RemoteID.parse(ad) else { return nil }
                return (packet, address, frame)
            }
            lock.withLock {
                self.packets += packets.count
                noiseDB = noise
                for (packet, address, frame) in frames {
                    ingest(frame, address: address, rssiDB: packet.rssiDB, date: packet.date,
                           source: "HackRF BLE \(packet.channel)", channel: packet.channel)
                }
            }
        }

        private func handleWLAN(_ block: Data, channel: Int) {
            let packets = wlan.process(block)
            let noise = wlan.noiseDB
            var found: [(WLANPacket, BLEAddress, RemoteID.Frame, RemoteID.WLANTransport)] = []
            var nan = 0
            for packet in packets {
                guard let frame = WLANFrame.parse(packet.mpdu) else { continue }
                if frame.nanAttributes != nil { nan += 1 }
                guard let parsed = RemoteID.parse(frame) else { continue }
                found.append((packet, BLEAddress(bytes: frame.address2.reversed(), random: false), parsed.frame, parsed.transport))
            }
            lock.withLock {
                wlanFrames += packets.count
                nanFrames += nan
                noiseDB = noise
                for (packet, address, frame, transport) in found {
                    wlanRemoteID += 1
                    ingest(frame, address: address, rssiDB: packet.rssiDB, date: packet.date,
                           source: "HackRF WLAN \(channel) \(transport.rawValue)", channel: channel)
                }
            }
        }

        /// Unter `lock` aufrufen.
        func ingest(_ frame: RemoteID.Frame, address: BLEAddress, rssiDB: Double, date: Date, source: String, channel: Int) {
            tracker.ingest(frame, address: address, rssiDB: rssiDB, date: date)
            for message in frame.messages {
                messages += 1
                log.append(DroneLogLine(id: messages, date: date, address: address, source: source, channel: channel,
                                        rssiDB: rssiDB, counter: frame.counter, message: message))
            }
            if log.count > 1000 { log.removeFirst(log.count - 1000) }
        }
    }

    /// Schritte des HackRF-Plans aus den gewählten Quellen.
    var plan: [DroneRadioStep] {
        var steps: [DroneRadioStep] = []
        if useBLE {
            steps += (choice.channel.map { [$0] } ?? BLELink.advertisingChannels).map { DroneRadioStep.ble($0) }
        }
        if useWLAN24 { steps.append(.wlan(6)) }
        if useWLAN5 { steps.append(.wlan(149)) }
        return steps
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        self.device = device
        running = true
        error = nil
        if let first = plan.first {
            switchTo(first)
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.poll()
            }
        }
        updateHopping()
        updateWiFi()
        updateMacBluetooth()
    }

    private func poll() {
        let (drones, log, packets, wlanFrames, wlanRemoteID, nan, mac, messages, noise) = shared.lock.withLock {
            (shared.tracker.sorted, shared.log, shared.packets, shared.wlanFrames, shared.wlanRemoteID,
             shared.nanFrames, shared.macBluetoothFrames, shared.messages, shared.noiseDB)
        }
        if messages != messageCount {
            self.drones = drones
            self.log = log.reversed()
            messageCount = messages
        }
        packetCount = packets
        self.wlanFrames = wlanFrames
        self.wlanRemoteID = wlanRemoteID
        nanFrames = nan
        macBluetoothFrames = mac
        noiseDB = noise
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        wifiTask?.cancel()
        wifiTask = nil
        hopTask?.cancel()
        hopTask = nil
        macBluetooth.stop()
        device?.stopReceiving(owner: self)
        step = nil
        running = false
    }

    /// Kanalwahl oder Quellen geändert: Plan neu aufsetzen.
    func choiceChanged() { updateHopping() }

    func sourcesChanged() {
        updateHopping()
        updateWiFi()
        updateMacBluetooth()
    }

    /// HackRF auf einen Schritt stellen: Empfang anhalten, Rate/Filter/Frequenz
    /// setzen, wieder starten (BLE 8 MS/s, WLAN 20 MS/s).
    private func switchTo(_ step: DroneRadioStep) {
        guard let device else { return }
        device.stopReceiving(owner: self)
        do {
            shared.lock.withLock { shared.step = step }
            switch step {
            case let .ble(channel):
                // `setSampleRate` stellt das Basisbandfilter auf ≈ 0,75·fs (6 MHz, wie die
                // BLE-Seite). Früher hier 8 MHz = volle Abtastrate: Signale knapp unter
                // und über fs/2 falteten kaum gedämpft ins Band (Review 29.10.2026).
                try device.setSampleRate(UInt32(BLEDemodulator.inputRate))
                try device.setFrequency(UInt64(BLELink.frequencyMHz(channel: channel) * 1_000_000 - BLEDemodulator.offset))
                self.channel = channel
            case let .wlan(channel):
                try device.setSampleRate(UInt32(WLANReceiver.sampleRate))
                try device.setBasebandFilter(20_000_000)
                try device.setFrequency(UInt64(WLANReceiver.frequencyMHz(channel: channel) * 1_000_000))
                self.channel = channel
            }
            try applyGains()
            shared.ble.reset()
            shared.wlan.reset()
            let shared = shared
            try device.startReceiving(owner: self) { shared.handle($0) }
            self.step = step
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func updateHopping() {
        hopTask?.cancel()
        hopTask = nil
        guard running else { return }
        let steps = plan
        guard !steps.isEmpty else {
            device?.stopReceiving(owner: self)
            step = nil
            return
        }
        if step.map({ !steps.contains($0) }) ?? true { switchTo(steps[0]) }
        guard steps.count > 1 else { return }
        hopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.dwell))
                guard !Task.isCancelled else { return }
                let steps = self.plan
                guard let current = self.step, let index = steps.firstIndex(of: current) else { continue }
                // Hat der Plan oder der Fernzugriff das Gerät übernommen, nicht
                // zurückholen – sonst bräche jeder Termin nach 2 s ab.
                guard self.device?.isReceiving(for: self) == true else {
                    self.stop()
                    self.error = HackRFError.takenOver.localizedDescription
                    return
                }
                self.switchTo(steps[(index + 1) % steps.count])
            }
        }
    }

    /// Bluetooth des Mac ein- oder ausschalten (läuft nur bei laufendem Empfang).
    /// Ohne Dienstfilter suchen: Remote-ID-Werbung trägt nur Dienstdaten,
    /// keine Dienstliste, auf die CoreBluetooth filtern könnte.
    func updateMacBluetooth() {
        guard running, useMacBluetooth else {
            macBluetooth.stop()
            macBluetoothError = nil
            return
        }
        let shared = shared
        macBluetooth.start(services: nil, state: { [weak self] state in
            let text = MacBluetoothScanner.stateDescription(state)
            Task { @MainActor in self?.macBluetoothError = text }
        }, handler: { ad in
            guard let data = ad.serviceData[RemoteID.serviceUUID], let frame = RemoteID.parseServiceData(data) else { return }
            shared.lock.withLock {
                shared.macBluetoothFrames += 1
                shared.ingest(frame, address: ad.address, rssiDB: ad.rssiDB, date: Date(), source: "Mac-Bluetooth", channel: 0)
            }
        })
    }

    /// Wi-Fi-Suche ein- oder ausschalten (läuft nur bei laufendem Empfang).
    func updateWiFi() {
        wifiTask?.cancel()
        wifiTask = nil
        guard running, useWiFi else { return }
        wifiTask = Task { [weak self] in
            // Ohne Ortungserlaubnis liefert macOS keine BSSIDs und Elemente.
            _ = try? await LocationProvider.shared.currentLocation()
            while !Task.isCancelled {
                let result = await Task.detached { () -> Result<[(String, Int, Int, [UInt8])], Error> in
                    guard let interface = CWWiFiClient.shared().interface() else {
                        return .failure(WiFiModel.WiFiError.noInterface)
                    }
                    do {
                        let networks = try interface.scanForNetworks(withName: nil, includeHidden: true)
                        return .success(networks.compactMap { n in
                            guard let ies = n.informationElementData, let bssid = n.bssid else { return nil }
                            return (bssid, n.wlanChannel?.channelNumber ?? 0, n.rssiValue, [UInt8](ies))
                        })
                    } catch {
                        return .failure(error)
                    }
                }.value
                guard let self, !Task.isCancelled else { return }
                switch result {
                case let .success(beacons):
                    self.wifiScans += 1
                    self.wifiError = nil
                    self.ingestBeacons(beacons)
                case let .failure(error):
                    self.wifiError = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func ingestBeacons(_ beacons: [(bssid: String, channel: Int, rssi: Int, ies: [UInt8])]) {
        let date = Date()
        let frames = beacons.compactMap { beacon -> (BLEAddress, Int, Int, RemoteID.Frame, String)? in
            let parsed: (RemoteID.Frame, String)?
            if let frame = RemoteID.parseBeaconElements(beacon.ies) { parsed = (frame, "Mac-WLAN") }
            else if let french = FrenchDroneID.parse(elements: beacon.ies) { parsed = (french.frame, "Mac-WLAN (FR)") }
            else { parsed = nil }
            guard let parsed else { return nil }
            let (frame, source) = parsed
            let octets = beacon.bssid.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            guard octets.count == 6 else { return nil }
            return (BLEAddress(bytes: octets.reversed(), random: false), beacon.channel, beacon.rssi, frame, source)
        }
        guard !frames.isEmpty else { return }
        wifiFrames += frames.count
        shared.lock.withLock {
            for (address, channel, rssi, frame, source) in frames {
                shared.ingest(frame, address: address, rssiDB: Double(rssi), date: date, source: source, channel: channel)
            }
        }
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
            shared.tracker = DroneTracker()
            shared.log = []
        }
        drones = []
        log = []
    }
}
