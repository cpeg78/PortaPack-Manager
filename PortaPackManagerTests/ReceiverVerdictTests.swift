import Foundation
import Observation
import Testing
@testable import PortaPackManager

@MainActor
@Suite("Statuszeile in Alltagssprache")
struct ReceiverVerdictTests {
    @Observable
    final class Fake: GainTunable {
        var lnaGain = 24.0
        var vgaGain = 20.0
        var amplifier = false
        var antennaPower = false
        var running = true
        var quality: GainQuality?
        var counter: Int? = 0
        var lock = false
        func applyTunedGains(_ device: HackRFDevice?) throws {}
        var activity: Int? { counter }
        var idleHint: String { "Tipp." }
        var needsLock: Bool { lock }
    }

    private let fine = HackRFDevice.InputLevels(rmsDBFS: -25, peakDBFS: -10, clipped: 0)

    @Test("Gestoppt, übersteuert, leise")
    func basics() {
        let model = Fake(), tracker = ActivityTracker()
        model.running = false
        #expect(ReceiverVerdict.make(model: model, levels: nil, tracker: tracker, autoGain: true).tone == .idle)
        model.running = true
        let clipped = HackRFDevice.InputLevels(rmsDBFS: -8, peakDBFS: 0, clipped: 0.05)
        #expect(ReceiverVerdict.make(model: model, levels: clipped, tracker: tracker, autoGain: true).tone == .bad)
    }

    @Test("Meldungen: läuft, dann Minuten ohne Fund mit Rat")
    func counts() {
        let model = Fake(), tracker = ActivityTracker()
        tracker.reset()
        let start = Date()
        #expect(ReceiverVerdict.make(model: model, levels: fine, tracker: tracker, autoGain: true, now: start).tone == .searching)
        let later = start.addingTimeInterval(300)
        let quiet = ReceiverVerdict.make(model: model, levels: fine, tracker: tracker, autoGain: true, now: later)
        #expect(quiet.text.contains("Seit 5 min") && quiet.text.contains("Tipp."))
        let weak = ReceiverVerdict.make(model: model, levels: .init(rmsDBFS: -50, peakDBFS: -40, clipped: 0),
                                        tracker: tracker, autoGain: true, now: later)
        #expect(weak.tone == .weak && weak.text.contains("Antenne"))
        model.counter = 5
        tracker.sample(activity: 5, quality: nil)
        tracker.sample(activity: 9, quality: nil)
        #expect(ReceiverVerdict.make(model: model, levels: fine, tracker: tracker, autoGain: true).tone == .good)
    }

    @Test("Einrasten: suchen, dann kein Signal; Blockanteil")
    func lock() {
        let model = Fake(), tracker = ActivityTracker()
        model.lock = true
        model.counter = nil
        tracker.reset()
        #expect(ReceiverVerdict.make(model: model, levels: fine, tracker: tracker, autoGain: true).tone == .searching)
        let late = ReceiverVerdict.make(model: model, levels: fine, tracker: tracker, autoGain: true, now: Date().addingTimeInterval(60))
        #expect(late.text.hasPrefix("Kein Signal gefunden"))
        tracker.sample(activity: nil, quality: .ratio(good: 0, bad: 0))
        tracker.sample(activity: nil, quality: .ratio(good: 30, bad: 70))
        let poor = ReceiverVerdict.make(model: model, levels: fine, tracker: tracker, autoGain: true)
        #expect(poor.tone == .weak && poor.text.contains("30 %"))
    }

    @Test("Gerät gehört einer anderen Seite oder ist abgerissen")
    func occupied() {
        let model = Fake(), tracker = ActivityTracker()
        let other = ReceiverVerdict.make(model: model, levels: nil, tracker: tracker, autoGain: true, occupant: "Radio")
        #expect(other.tone == .weak && other.text.contains("für Radio"))
        let gone = ReceiverVerdict.make(model: model, levels: nil, tracker: tracker, autoGain: true, occupant: "")
        #expect(gone.text.contains("abgerissen"))
    }
}
