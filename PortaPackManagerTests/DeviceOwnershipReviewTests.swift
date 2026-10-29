import Foundation
import Testing
@testable import PortaPackManager

/// Regressionstests zu den Funden des Reviews vom 28.10.2026 (Gerätebesitz,
/// Firmware/Gerät, Plan, Automatik, Nebenläufigkeit).
@Suite("Review 28.10.: Gerätebesitz und Automatik")
struct DeviceOwnershipReviewTests {
    // MARK: LTE (W2–W4, Y12)

    @Test("LTE: Übersteuerung nimmt je Band eine LNA-Stufe zurück, zu leiser Pegel hebt bis zur Obergrenze an")
    func lteLNAStep() {
        // Übersteuert → eine Stufe zurück.
        #expect(CellModel.nextLNA(current: 32, ceiling: 32, clipped: 0.02, rmsDBFS: -10) == 24)
        // Bei 0 bleibt es bei 0.
        #expect(CellModel.nextLNA(current: 0, ceiling: 32, clipped: 0.02, rmsDBFS: -10) == 0)
        // Zu leise → wieder hoch, aber nie über den Wert des Reglers.
        #expect(CellModel.nextLNA(current: 16, ceiling: 32, clipped: 0, rmsDBFS: -45) == 24)
        #expect(CellModel.nextLNA(current: 32, ceiling: 32, clipped: 0, rmsDBFS: -45) == 32)
        #expect(CellModel.nextLNA(current: 24, ceiling: 28, clipped: 0, rmsDBFS: -45) == 24)
        // Gut ausgesteuert → unverändert.
        #expect(CellModel.nextLNA(current: 24, ceiling: 32, clipped: 0.001, rmsDBFS: -25) == 24)
        // Regler unter die Rücknahme gezogen → der Regler gilt.
        #expect(CellModel.nextLNA(current: 32, ceiling: 16, clipped: 0, rmsDBFS: -25) == 16)
    }

    @Test("LTE: Sammler verwirft alles vor dem Umstimmen und danach die ersten Blöcke")
    func lteCollectorArming() {
        let collector = CellModel.Collector(bytes: 4)
        collector.handle(Data([1, 1]))          // vor dem Umstimmen: alte Frequenz/Rate
        collector.handle(Data([1, 1]))
        #expect(collector.result == nil)
        collector.arm(skipBlocks: 2)
        collector.handle(Data([2, 2]))          // womöglich noch alte Einstellung
        collector.handle(Data([2, 2]))
        #expect(collector.result == nil)
        collector.handle(Data([3, 3]))
        collector.handle(Data([4, 4]))
        #expect(collector.result == Data([3, 3, 4, 4]))
    }

    @Test("LTE: Regler gilt als Obergrenze je Band, Stoßempfang ist gekennzeichnet")
    @MainActor
    func lteBandLNA() {
        let model = CellModel()
        model.lnaGain = 24
        #expect(model.lna(forBand: 3) == 24)
        #expect(model.receivesInBursts)
        #expect(model.wantsAutoGain)    // die Automatik lässt ihn über `receivesInBursts` aus
    }

    // MARK: Plan (Y11, Nitpick „skipped verfällt“)

    @Test("Plan: übersprungene Termine verfallen nach zwei Tagen auch in einer laufenden Sitzung")
    func plannerSkippedExpires() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let ids = ["alt": now.addingTimeInterval(-2 * 86_400 - 1),
                   "frisch": now.addingTimeInterval(-3600)]
        let pruned = ReceptionPlanner.pruneSkipped(ids, now: now)
        #expect(Set(pruned.keys) == ["frisch"])
        #expect(pruned["frisch"] == ids["frisch"])   // Zeitpunkt bleibt erhalten
    }

    // MARK: Benachrichtigungen (Y7)

    @Test("ntfy-Sondenmeldung nennt keine Entfernung, die Mac-Mitteilung schon")
    func ntfyWithoutDistance() {
        let sighting = SondeHubTraffic.Sighting(serial: "X1234567", type: "RS41", frequencyMHz: 403.5,
                                                distanceKm: 87.4, altitude: 12_345)
        let text = Notifier.sondeRangeTexts(sighting)
        #expect(text.local.contains("87 km"))
        #expect(!text.remote.contains("87"))
        #expect(!text.remote.contains(" km,"))
        #expect(text.remote.contains("X1234567"))
        #expect(text.remote.contains("403.50") || text.remote.contains("403,50"))
    }

    // MARK: Automatik (Y10, Nitpick registry)

    @Test("Belegungsmonitor ist von der Verstärkungsautomatik ausgenommen")
    @MainActor
    func occupancyWithoutAutoGain() {
        let defaults = UserDefaults(suiteName: "DeviceOwnershipReviewTests")!
        let monitor = OccupancyMonitor(defaults: defaults)
        #expect(!monitor.wantsAutoGain)
        #expect(!monitor.receivesInBursts)
    }

    @Test("Optimierer-Verzeichnis hält Empfänger nur schwach und räumt verwaiste Einträge ab")
    @MainActor
    func optimizerRegistryPrunes() {
        final class Dummy {}
        let keep = Dummy()
        let optimizer = GainOptimizer.shared(for: keep)
        #expect(GainOptimizer.shared(for: keep) === optimizer)
        let before = GainOptimizer.registeredCount
        for _ in 0..<50 { _ = GainOptimizer.shared(for: Dummy()) }
        // Jeder neue Eintrag räumt die schon freigegebenen ab – kein Wachstum um 50.
        #expect(GainOptimizer.registeredCount <= before + 2)
        #expect(GainOptimizer.shared(for: keep) === optimizer)
    }

    // MARK: Gerät (W5, Nitpick Fortschritt)

    @Test("SD-Karte bereitstellen ist während einer Installation gesperrt")
    @MainActor
    func sdShareBlockedWhileBusy() async {
        let session = DeviceSession()
        session.busy = true
        session.busyReason = "Test-Installation"
        await session.shareSDCard()
        // Ohne Sperre hätte performExclusive Grund und busy überschrieben.
        #expect(session.busy)
        #expect(session.busyReason == "Test-Installation")
        #expect(session.mode == .disconnected)
    }

    @Test("Verspätete Fortschrittsmeldung überschreibt „Fertig“ nicht")
    @MainActor
    func lateProgressDoesNotOverwriteDone() async throws {
        let session = DeviceSession()
        let report = session.progressReporter()
        session.finishProgress(InstallProgress(phase: .done, fraction: 1, detail: "Fertig"))
        report(InstallProgress(phase: .flashing, fraction: 0.99, detail: "Schreibe …"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.installProgress.phase == .done)
        // Ein neuer Reporter wirkt wieder.
        let next = session.progressReporter()
        next(InstallProgress(phase: .downloading, detail: "neu"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.installProgress.phase == .downloading)
    }

    // MARK: Flugfunk (Y13)

    @Test("Flugfunk: Suchlauf-Statistik je Block wird richtig aufaddiert")
    func airbandActivityMerge() {
        var total = AirbandActivity(observedSeconds: 1, openSeconds: 0.5, transmissions: 1, bursts: 2, peakDB: 12)
        total.merge(AirbandActivity(observedSeconds: 0.25, openSeconds: 0.25, transmissions: 0, bursts: 1, peakDB: 9))
        total.merge(AirbandActivity(observedSeconds: 0.25, openSeconds: 0, transmissions: 1, bursts: 0, peakDB: 20))
        #expect(total.observedSeconds == 1.5)
        #expect(total.openSeconds == 0.75)
        #expect(total.transmissions == 2)
        #expect(total.bursts == 3)
        #expect(total.peakDB == 20)
    }

    @Test("Flugfunk: Ausschnittwechsel während der Auswertung verklemmt nicht und verliert keinen Spruch")
    func airbandConcurrentWindowChange() async {
        let receiver = AirbandReceiver(output: nil)
        receiver.lock.withLock {
            receiver.setWindow(AirbandWindow(center: 400, bins: 960))
            receiver.channels = [AirbandChannel(index: 500, name: "A")]
        }
        var data = Data(count: 2 * 131_072)
        data.withUnsafeMutableBytes { raw in
            for n in 0..<raw.count { raw[n] = UInt8(truncatingIfNeeded: (n * 37) & 0x0F) }
        }
        let block = data
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<30 { receiver.process(block) }
            }
            group.addTask {
                for k in 0..<30 {
                    receiver.lock.withLock {
                        receiver.setWindow(AirbandWindow(center: 400 + (k % 2) * 10, bins: 960))
                        _ = receiver.takeFinished()
                        _ = receiver.channelExcess
                    }
                }
            }
        }
        // Nach dem Wechsel ist der Zustand konsistent lesbar.
        let audible = receiver.lock.withLock { receiver.audible }
        #expect(audible == nil || audible == 500)
    }
}
