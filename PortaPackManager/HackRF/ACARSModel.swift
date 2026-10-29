import Foundation
import Observation

/// ACARS im HackRF-Modus: 2 MS/s um die gewählten VHF-Kanäle, mehrere
/// Kanäle gleichzeitig, Dekodierung in der App.
@MainActor
@Observable
final class ACARSModel {
    /// ACARS auf 131 MHz (MSK) oder VDL Mode 2 auf 136,725–136,975 MHz (D8PSK).
    /// In Europa läuft der meiste Datenfunk über VDL2 (Fund 26.10.2026: abends
    /// in 2 min 0 ACARS-Blöcke, aber 40 VDL2-Rahmen von 9 Flugzeugen).
    enum Band: String, CaseIterable, Identifiable, Sendable {
        case vdl2 = "VDL2 (136,9 MHz)"
        case acars = "ACARS (131 MHz)"
        var id: String { rawValue }
        /// Anzeigename (der Rohwert bleibt als gespeicherter Schlüssel unverändert).
        var title: String {
            switch self {
            case .vdl2: String(localized: "VDL2 (136,9 MHz)")
            case .acars: String(localized: "ACARS (131 MHz)")
            }
        }
    }
    var band = Band(rawValue: UserDefaults.standard.string(forKey: "acarsBand") ?? "") ?? .vdl2 {
        didSet {
            UserDefaults.standard.set(band.rawValue, forKey: "acarsBand")
            guard band != oldValue, running, let device else { return }
            stop()
            start(on: device)
        }
    }
    var selectedMHz: Set<Double> = Set(ACARSPlan.defaultMHz)
    var lnaGain = GainProfile.preset(.acars).lna
    var vgaGain = GainProfile.preset(.acars).vga
    var amplifier = GainProfile.preset(.acars).amplifier
    var antennaPower = false     // Bias-Tee für aktive Antenne

    private(set) var running = false
    private(set) var messages: [ACARSMessage] = []
    private(set) var blocksSeen = 0
    private(set) var crcErrors = 0
    private(set) var channelPowerDB: [Double: Float] = [:]
    private(set) var activePlan: ACARSPlan.Result?
    /// VDL2: alle Rahmen, Flugzeuge (ICAO-Adressen), Bursts mit FEC-Fehler.
    private(set) var vdl2Frames = 0
    private(set) var vdl2Aircraft = 0
    private(set) var vdl2FECErrors = 0
    private(set) var error: String?

    private let shared = Shared()
    private var pollTask: Task<Void, Never>?
    private(set) var lastCount = 0
    private weak var device: HackRFDevice?

    /// Plan für die aktuelle Auswahl (welche Kanäle ins Fenster passen).
    var plan: ACARSPlan.Result? { ACARSPlan.plan(Array(selectedMHz)) }

    /// Zwischen Empfangsthread und Oberfläche geteilt.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var receiver: ACARSReceiver?
        var vdl2: VDL2Receiver?
        var vdl2Frames = 0
        var vdl2Aircraft: Set<UInt32> = []
        var vdl2FECErrors = 0
        var reassembler = ACARSReassembler()

        /// Nachricht einreihen – Fortsetzungsblöcke ersetzen den schon
        /// gemeldeten ersten Teil (gleiche ID), die Liste bleibt sortiert.
        func ingest(_ raw: ACARSMessage, now: Date) {
            var message = raw
            message.date = now
            let (merged, replaces) = reassembler.add(message, now: now)
            if let replaces, let index = messages.lastIndex(where: { $0.id == replaces }) {
                var kept = merged
                kept.id = replaces
                messages[index] = kept
                count += 1                                   // Änderung sichtbar machen
            } else {
                count += 1
                var fresh = merged
                fresh.id = count
                messages.append(fresh)
            }
            if messages.count > 2000 { messages.removeFirst(messages.count - 2000) }
        }
        var messages: [ACARSMessage] = []
        var count = 0
        var blocksSeen = 0
        var crcErrors = 0
        var powers: [Float] = []

        /// Läuft auf dem Empfangsthread.
        func handle(_ block: Data) {
            if let vdl2 = lock.withLock({ self.vdl2 }) {
                handleVDL2(block, vdl2)
                return
            }
            guard let receiver = lock.withLock({ self.receiver }) else { return }
            let found = receiver.process(block)
            let blocks = receiver.blocksSeen, errors = receiver.crcErrors
            let powers = receiver.channelizer.channelPowerDB
            let now = Date()
            lock.withLock {
                blocksSeen = blocks
                crcErrors = errors
                self.powers = powers
                for message in found { ingest(message, now: now) }
            }
        }

        /// VDL2: ACARS-Inhalte landen in derselben Liste; übrige Rahmen
        /// (Quittungen, XID, ATN) zählen nur mit.
        func handleVDL2(_ block: Data, _ receiver: VDL2Receiver) {
            let frames = receiver.process(block)
            let powers = receiver.channelizer.channelPowerDB
            let fec = receiver.badBursts
            let now = Date()
            lock.withLock {
                self.powers = powers
                vdl2FECErrors = fec
                vdl2Frames += frames.count
                for frame in frames {
                    if let address = frame.aircraftAddress { vdl2Aircraft.insert(address) }
                    if var message = frame.acars {
                        message.corrected = frame.corrected
                        message.icao = frame.aircraftAddress
                        ingest(message, now: now)
                    } else if let atn = frame.atn, let icao = frame.aircraftAddress, atn.kind == .cpdlc || atn.kind == .cm {
                        var message = ACARSMessage(frequencyMHz: frame.frequencyMHz, levelDB: frame.levelDB, corrected: frame.corrected,
                                                   mode: "2", registration: String(format: "%06X", icao), acknowledge: " ",
                                                   label: atn.kind == .cpdlc ? "CPDLC" : "CM", blockID: frame.sourceType == .aircraft ? "0" : nil,
                                                   text: atn.summary, continued: false, icao: icao)
                        message.details = atn.rows.map { [$0.name, $0.value] } + [[String(localized: "Schichten"), atn.layers]]
                        ingest(message, now: now)
                    } else if let x25 = frame.x25, let icao = frame.aircraftAddress, !x25.hasPrefix("X.25 Empfangsbereit"),
                              frame.atn?.isTransportAck != true {
                        let x25 = frame.atn.map { "\($0.summary) [\($0.layers)]" } ?? x25
                        let message = ACARSMessage(frequencyMHz: frame.frequencyMHz, levelDB: frame.levelDB, corrected: frame.corrected,
                                                   mode: "2", registration: String(format: "%06X", icao), acknowledge: " ",
                                                   label: "ATN", blockID: frame.sourceType == .aircraft ? "0" : nil, text: x25,
                                                   continued: false, icao: icao)
                        ingest(message, now: now)
                    } else if let location = frame.location, let icao = frame.aircraftAddress {
                        // Verbindungsaufbau mit Position: als eigene Zeile zeigen.
                        let position = ACARSInterpreter.coordinates(location.latitude, location.longitude)
                        let meters = Int(Double(location.altitudeFt) * 0.3048)
                        var text = String(localized: "Position \(position), Höhe \(location.altitudeFt) ft (≈ \(meters) m)")
                        if let airport = frame.destinationAirport { text = String(localized: "\(text), Ziel \(airport)") }
                        let message = ACARSMessage(frequencyMHz: frame.frequencyMHz, levelDB: frame.levelDB, corrected: frame.corrected,
                                                   mode: "2", registration: String(format: "%06X", icao), acknowledge: " ",
                                                   label: "XID", blockID: "0", text: text, continued: false, icao: icao)
                        ingest(message, now: now)
                    }
                }
            }
        }
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        if band == .vdl2 {
            startVDL2(on: device)
            return
        }
        guard let plan else {
            error = String(localized: "Wähle mindestens einen Kanal.")
            return
        }
        do {
            self.device = device
            let receiver = ACARSReceiver(plan: plan)
            shared.lock.withLock {
                shared.receiver = receiver
                shared.vdl2 = nil
                shared.blocksSeen = 0
                shared.crcErrors = 0
                shared.powers = []
            }
            try device.setSampleRate(UInt32(ACARSChannelizer.inputRate))
            try device.setFrequency(UInt64(plan.centerHz))
            try applyGains()
            let shared = shared
            try device.startReceiving(owner: self) { block in shared.handle(block) }
            activePlan = plan
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let shared = self.shared
                    let (messages, count, blocks, errors, levels) = shared.lock.withLock {
                        (shared.messages, shared.count, shared.blocksSeen, shared.crcErrors, shared.powers)
                    }
                    if count != self.lastCount { self.lastCount = count; self.messages = messages.reversed() }
                    // Nur bei Änderung zuweisen – jede Zuweisung zeichnet neu (Review L2).
                    if self.blocksSeen != blocks { self.blocksSeen = blocks }
                    if self.crcErrors != errors { self.crcErrors = errors }
                    var powers: [Double: Float] = [:]
                    for (index, mhz) in plan.active.enumerated() where index < levels.count {
                        powers[mhz] = levels[index]
                    }
                    if powers != self.channelPowerDB { self.channelPowerDB = powers }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startVDL2(on device: HackRFDevice) {
        do {
            self.device = device
            let receiver = VDL2Receiver()
            shared.lock.withLock {
                shared.receiver = nil
                shared.vdl2 = receiver
                shared.blocksSeen = 0
                shared.crcErrors = 0
                shared.powers = []
            }
            try device.setSampleRate(UInt32(VDL2Channelizer.inputRate))
            try device.setFrequency(UInt64(VDL2Receiver.centerHz))
            try applyGains()
            let shared = shared
            try device.startReceiving(owner: self) { block in shared.handle(block) }
            activePlan = nil
            running = true
            error = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let shared = self.shared
                    let (messages, count, frames, aircraft, fec, levels) = shared.lock.withLock {
                        (shared.messages, shared.count, shared.vdl2Frames, shared.vdl2Aircraft.count, shared.vdl2FECErrors, shared.powers)
                    }
                    if count != self.lastCount {
                        self.lastCount = count
                        self.messages = messages.reversed().map { m in
                            guard ["XID", "ATN", "CPDLC", "CM"].contains(m.label), let icao = m.icao,
                                  let registration = AircraftDatabase.shared.info(for: icao)?.registration, !registration.isEmpty
                            else { return m }
                            var named = m
                            named.registration = registration
                            return named
                        }
                    }
                    if self.vdl2Frames != frames { self.vdl2Frames = frames }
                    if self.vdl2Aircraft != aircraft { self.vdl2Aircraft = aircraft }
                    if self.vdl2FECErrors != fec { self.vdl2FECErrors = fec }
                    var powers: [Double: Float] = [:]
                    for (index, mhz) in VDL2Receiver.channelsMHz.enumerated() where index < levels.count { powers[mhz] = levels[index] }
                    if powers != self.channelPowerDB { self.channelPowerDB = powers }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        device?.stopReceiving(owner: self)
        running = false
        activePlan = nil
    }

    /// Kanalauswahl geändert: bei laufendem Empfang neu aufsetzen.
    func selectionChanged() {
        guard running, let device else { return }
        stop()
        start(on: device)
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
            shared.messages = []
            shared.vdl2Frames = 0
            shared.vdl2Aircraft = []
            shared.vdl2FECErrors = 0
            shared.reassembler = ACARSReassembler()
        }
        messages = []
        lastCount = 0
        vdl2Frames = 0; vdl2Aircraft = 0; vdl2FECErrors = 0
    }
}
