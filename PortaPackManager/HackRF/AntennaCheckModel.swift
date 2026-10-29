import Foundation
import Observation
import os

/// Führt den Antennen-Check durch: Band für Band mit der Verstärkung der
/// jeweiligen Seite messen, auswerten, speichern. Eigener Besitzer des
/// Empfangs; übernimmt eine andere Seite den HackRF, endet der Check mit
/// `HackRFError.takenOver`, statt sich das Gerät zurückzuholen.
@MainActor
@Observable
final class AntennaCheckModel {
    private static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Antennen-Check")
    static let antennaPowerKey = "antennaCheckAntennaPower"

    private(set) var running = false
    private(set) var progress = 0.0
    private(set) var step = ""
    private(set) var result: AntennaCheckResult?
    private(set) var error: String?
    /// Bereits gemessene Bänder des laufenden Checks.
    private(set) var partial: [AntennaBandMeasurement] = []

    var antennaPower: Bool {
        didSet { UserDefaults.standard.set(antennaPower, forKey: Self.antennaPowerKey) }
    }

    private var task: Task<Void, Never>?

    init() {
        antennaPower = UserDefaults.standard.bool(forKey: Self.antennaPowerKey)
        result = AntennaCheckResult.load()
    }

    func start(on device: HackRFDevice) {
        guard !running else { return }
        if let reason = DeviceArbiter.blocker(session: RemoteHub.shared.session) {
            error = String(localized: "\(reason) Prüf danach noch einmal.")
            return
        }
        running = true
        error = nil
        progress = 0
        partial = []
        step = String(localized: "Bereite vor …")
        // Über `DeviceArbiter.borrow`: Plan pausiert, Fernzugriff bzw. laufende
        // Empfänger angehalten und nach dem Check wieder gestartet.
        let external = GainProfile.externalAmplifier
        let power = antennaPower
        task = Task { [weak self] in
            guard let self else { return }
            await DeviceArbiter.borrow { () -> (result: Void, takenOver: Bool) in
                let takenOver = await self.runMeasurement(on: device, external: external, power: power)
                self.step = takenOver ? "" : String(localized: "Starte den vorherigen Empfang wieder …")
                return ((), takenOver)
            }
            self.step = ""
        }
    }

    /// Misst, speichert das Ergebnis; liefert, ob das Gerät übernommen wurde.
    private func runMeasurement(on device: HackRFDevice, external: Bool, power: Bool) async -> Bool {
            var takenOver = false
            do {
                try await self.measure(on: device, external: external, power: power)
            } catch HackRFError.takenOver {
                takenOver = true
                self.error = String(localized: "Ein anderer Empfänger hat den HackRF übernommen – Check abgebrochen.")
            } catch is CancellationError {
                self.step = String(localized: "Abgebrochen")
            } catch {
                self.error = error.localizedDescription
            }
            if !takenOver { device.stopReceiving(owner: self) }
            if !self.partial.isEmpty {
                let result = AntennaCheckResult(date: Date(), externalAmplifier: external, antennaPower: power,
                                                measurements: self.partial,
                                                complete: self.partial.count == AntennaBand.allCases.count)
                result.save()
                self.result = result
            }
            self.running = false
            self.task = nil
            return takenOver
    }

    func cancel() {
        task?.cancel()
    }

    private func measure(on device: HackRFDevice, external: Bool, power: Bool) async throws {
        let accumulator = AntennaCheckAccumulator()
        let total = AntennaBand.totalSeconds
        var elapsed = 0.0
        try device.setSampleRate(AntennaCheck.sampleRate)
        try device.setAntennaPower(power)
        try device.startReceiving(owner: self) { accumulator.process($0) }
        for band in AntennaBand.allCases {
            let preset = GainProfile.preset(band.receiver, externalAmplifier: external)
            var windows: [AntennaWindowSpectrum] = []
            var gain = preset
            var reduced = false
            for (index, center) in band.centersMHz.enumerated() {
                try Task.checkCancellation()
                guard device.isReceiving(for: self) else { throw HackRFError.takenOver }
                step = band.centersMHz.count > 1
                    ? "\(band.title) (\(index + 1)/\(band.centersMHz.count)) …"
                    : "\(band.title) …"
                try device.setLNAGain(Int(gain.lna))
                try device.setVGAGain(Int(gain.vga))
                try device.setAmplifier(gain.amplifier)
                try device.setFrequency(UInt64(center * 1_000_000))
                try await Task.sleep(for: .seconds(AntennaCheck.settleSeconds))
                elapsed += AntennaCheck.settleSeconds
                // Übersteuert die Vorgabe der Seite (das 20-MHz-Fenster fasst mehr
                // starke Sender als die Seite selbst), wie die Automatik eine Stufe
                // zurück – live 27.10.2026: DAB+ 70 %, Flugfunk und Sonden 6 % am Anschlag.
                for _ in 0..<5 {
                    device.beginLevelMeasurement()
                    try await Task.sleep(for: .milliseconds(400))
                    elapsed += 0.4
                    guard let levels = device.measuredLevels()?.levels, levels.clipped >= AntennaCheck.overloadedFraction else { break }
                    if gain.amplifier { gain.amplifier = false }
                    else if gain.lna >= 8 { gain.lna -= 8 }
                    else if gain.vga >= 6 { gain.vga -= 6 }
                    else { break }
                    reduced = true
                    try device.setLNAGain(Int(gain.lna))
                    try device.setVGAGain(Int(gain.vga))
                    try device.setAmplifier(gain.amplifier)
                    try await Task.sleep(for: .milliseconds(200))
                }
                accumulator.reset(burstChannel: band.burstChannelMHz.map { ($0.lowerBound - center)...($0.upperBound - center) })
                device.beginLevelMeasurement()
                let steps = max(1, Int(band.dwellSeconds / 0.1))
                for _ in 0..<steps {
                    try await Task.sleep(for: .milliseconds(100))
                    guard device.isReceiving(for: self) else { throw HackRFError.takenOver }
                    elapsed += 0.1
                    progress = min(1, elapsed / total)
                }
                let levels = device.measuredLevels()?.levels ?? device.inputLevels ?? HackRFDevice.InputLevels()
                windows.append(accumulator.snapshot(centerMHz: center, clipped: levels.clipped, rmsDBFS: levels.rmsDBFS))
            }
            let snapshot = windows
            var measurement = await Task.detached { AntennaCheck.analyze(band: band, windows: snapshot) }.value
            if reduced { measurement.reducedGain = "LNA \(Int(gain.lna))/VGA \(Int(gain.vga))" }
            partial.append(measurement)
            Self.log.info("\(band.title, privacy: .public): Boden \(measurement.floorDBFS, format: .fixed(precision: 1)) dBFS, stärkstes Signal \(measurement.strongest, format: .fixed(precision: 1)) dB, Anschlag \(measurement.clipped * 100, format: .fixed(precision: 2)) %")
        }
        progress = 1
        step = String(localized: "Fertig")
    }
}
