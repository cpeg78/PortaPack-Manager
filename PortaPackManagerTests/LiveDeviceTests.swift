import Foundation
import Testing
@testable import PortaPackManager

/// Live-Prüfungen am angeschlossenen HackRF (App vorher beenden, Gerät im
/// HackRF-Modus). Nur mit `TEST_RUNNER_LIVE_DEVICE=1`, sonst übersprungen:
/// `TEST_RUNNER_LIVE_DEVICE=1 xcodebuild test … -configuration Release ENABLE_TESTABILITY=YES "-only-testing:PortaPackManagerTests/LiveDeviceTests"`
@MainActor
@Suite("Live am Gerät", .serialized, .enabled(if: ProcessInfo.processInfo.environment["LIVE_DEVICE"] == "1"))
struct LiveDeviceTests {
    private func open() throws -> HackRFDevice {
        let device = try HackRFDevice.openFirst()
        return device
    }

    private func wait(_ seconds: Double, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(250)) }
    }

    @Test("Automatik nimmt Übersteuerung zurück (ADS-B, alles auf Anschlag)")
    func autoGain() async throws {
        let device = try open()
        defer { device.close() }
        let session = DeviceSession()
        session.hackRF = device
        // Der Testwirt ist die App selbst – ihre Einstellungen danach wiederherstellen.
        let wasEnabled = AutoGain.shared.enabled
        defer { AutoGain.shared.enabled = wasEnabled }
        AutoGain.shared.enabled = true
        AutoGain.shared.bootstrap(session: session)
        let model = ADSBModel()
        model.lnaGain = 40; model.vgaGain = 62; model.amplifier = true
        model.start(on: device)
        #expect(model.running)
        try await Task.sleep(for: .seconds(4))
        print("LIVE autoGain vorher: \(String(describing: device.inputLevels))")
        await wait(40) { !model.amplifier && model.lnaGain < 40 && (device.inputLevels?.clipped ?? 1) < 0.001 }
        print("LIVE autoGain nachher: LNA \(model.lnaGain) VGA \(model.vgaGain) Vorverstärker \(model.amplifier) Pegel \(String(describing: device.inputLevels)) Notiz: \(AutoGain.shared.note(for: model) ?? "–")")
        model.stop(on: device)
        #expect(!model.amplifier)
    }

    @Test("Signal optimieren an ADS-B")
    func optimizer() async throws {
        let device = try open()
        defer { device.close() }
        let wasEnabled = AutoGain.shared.enabled
        defer { AutoGain.shared.enabled = wasEnabled }
        AutoGain.shared.enabled = false
        let model = ADSBModel()
        let preset = GainProfile.preset(.adsb)
        model.lnaGain = preset.lna; model.vgaGain = preset.vga; model.amplifier = preset.amplifier
        model.start(on: device)
        try await Task.sleep(for: .seconds(3))
        let optimizer = GainOptimizer()
        optimizer.run(model, device: device)
        await wait(120) { !optimizer.active }
        print("LIVE optimizer: \(optimizer.result ?? "–") · Meldungen \(model.framesValid)")
        model.stop(on: device)
        #expect(optimizer.result != nil)
    }

    @Test("Quarzabgleich am stärksten UKW-Sender")
    func calibration() async throws {
        let device = try open()
        defer { device.close() }
        let before = HackRFDevice.frequencyCorrectionPPM
        let radio = RadioModel()
        radio.volume = 0
        let text = await radio.calibrateAutomatically(on: device)
        let after = HackRFDevice.frequencyCorrectionPPM
        print("LIVE calibration: \(text) · vorher \(before) ppm, nachher \(after) ppm")
        if abs(after) > 40 { HackRFDevice.frequencyCorrectionPPM = before }   // unplausibel – zurück
        #expect(abs(after) <= 40)
    }

    @Test("Antennen-Check")
    func antennaCheck() async throws {
        let device = try open()
        defer { device.close() }
        let previous = UserDefaults.standard.data(forKey: "antennaCheckResult")
        defer { UserDefaults.standard.set(previous, forKey: "antennaCheckResult") }
        let model = AntennaCheckModel()
        model.start(on: device)
        try await Task.sleep(for: .seconds(1))
        await wait(240) { !model.running }
        print("LIVE antenna error: \(model.error ?? "–")")
        let result = try #require(model.result)
        for m in result.measurements { print("LIVE antenna \(m)") }
        let s = AntennaCheck.summary(result.measurements)
        print("LIVE antenna summary: gut \(s.good) knapp \(s.marginal) schwach \(s.weak) übersteuert \(s.overloaded) keine Aussage \(s.noInformation)")
        for a in s.advice { print("LIVE antenna advice: \(a)") }
    }
}
