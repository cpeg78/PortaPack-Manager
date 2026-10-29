import Foundation
import Testing
@testable import PortaPackManager

/// Review 29.10.2026: Empfangsplan, Rückkehr nach dem Termin, Umschalt-Rückfrage,
/// Eingaben, die abstürzen ließen. Nur reine Logik – kein Gerät, keine
/// UserDefaults und kein Schlüsselbund.
@Suite("Review 29.10.: Plan, Rückkehr, Eingaben")
struct ReviewPlanTests {

    // MARK: - Flugfunk-Eingabe

    @Test("Flugfunk: riesige Zahlen im Eingabefeld stürzen nicht ab")
    func airbandHugeNumbers() {
        for text in ["1e20", "-1e16", "1e16", "1e300", "-1e300", "9.3e15", "nan", "inf", "-inf", "99.999", "200.001", "0"] {
            #expect(AirbandGrid.index(parsing: text) == nil, "\(text)")
        }
        #expect(AirbandGrid.index(parsing: "118.000") == 0)
        #expect(AirbandGrid.index(parsing: "136.990") == AirbandGrid.count - 1)
        // Auch die Rasterfunktion selbst wandelt nichts Unsinniges in `Int`.
        #expect(!AirbandGrid.range.contains(AirbandGrid.index(nearestHz: 1e30)))
        #expect(!AirbandGrid.range.contains(AirbandGrid.index(nearestHz: -1e30)))
        #expect(!AirbandGrid.range.contains(AirbandGrid.index(nearestHz: .nan)))
        #expect(!AirbandGrid.range.contains(AirbandGrid.index(nearestHz: .infinity)))
    }

    // MARK: - Sondenfenster

    @Test("Sondenfenster: 30 min ohne Sonde zählen ab Aufnahmebeginn, nicht ab Fensterbeginn")
    func sondeNoShowFromRecordingStart() {
        let window = Date(timeIntervalSince1970: 1_800_000_000)
        let end = window.addingTimeInterval(7200)
        // Erst 35 min nach Fensterbeginn in Reichweite (bzw. App-Neustart, Wiederverbinden).
        let began = window.addingTimeInterval(35 * 60)
        let start = ReceptionPlanner.noShowStart(window: window, began: began)
        #expect(start == began)
        // Gleich im ersten Takt: nicht beenden (vorher: sofort „30 Minuten keine Sonde“).
        #expect(!ReceptionPlanner.endSondeEarly(heard: nil, now: began.addingTimeInterval(10), start: start, end: end))
        #expect(!ReceptionPlanner.endSondeEarly(heard: nil, now: began.addingTimeInterval(29 * 60), start: start, end: end))
        #expect(ReceptionPlanner.endSondeEarly(heard: nil, now: began.addingTimeInterval(30 * 60), start: start, end: end))
        // Ohne bekannten Beginn bzw. mit Beginn vor dem Fenster gilt der Fensterbeginn.
        #expect(ReceptionPlanner.noShowStart(window: window, began: nil) == window)
        #expect(ReceptionPlanner.noShowStart(window: window, began: window.addingTimeInterval(-60)) == window)
    }

    // MARK: - Rückkehr nach dem Termin

    private func describe(_ resume: PlanResume?) -> String {
        switch resume {
        case nil: "nichts"
        case .hub(let mode, let remote)?: "hub:\(mode.rawValue):\(remote)"
        case .local(let model)?: "local:\(type(of: model))"
        }
    }

    @Test("Rückkehr: Fernzugriffs-Empfänger vor Mac-Empfänger, sonst der Mac-Empfänger")
    func resumeChoice() {
        let local = NSObject()
        #expect(describe(PlanResume.choose(hub: (.adsb, true), local: local)) == "hub:adsb:true")
        #expect(describe(PlanResume.choose(hub: nil, local: local)) == "local:NSObject")
        #expect(describe(PlanResume.choose(hub: nil, local: nil)) == "nichts")
    }

    @Test("Rückkehr nur, wenn das Gerät frei ist oder schon dem gemerkten Empfänger gehört")
    func resumeAllowed() {
        let tv = NSObject(), radio = NSObject()
        #expect(PlanResume.allowed(occupant: nil, target: tv))
        #expect(PlanResume.allowed(occupant: nil, target: nil))
        #expect(PlanResume.allowed(occupant: tv, target: tv))
        // Der Nutzer hat inzwischen Radio gestartet – das bleibt.
        #expect(!PlanResume.allowed(occupant: radio, target: tv))
        #expect(!PlanResume.allowed(occupant: radio, target: nil))
    }

    @MainActor
    @Test("Mac-Empfänger lassen sich nach dem Termin neu starten (außer Aufnahme und Antennen-Check)")
    func restartableModels() {
        let store = ReceiverStore.shared
        let restartable: [AnyObject] = [store.spectrum, store.aprs, store.pager, store.flarm, store.ble,
                                        store.drones, store.meshtastic, store.lorawan, store.dcf77, store.gps]
        for model in restartable {
            #expect(model is ReceiverRestarting, "\(type(of: model)) fehlt ReceiverRestarting")
        }
        // Einmalige Vorgänge kommen nicht von selbst zurück.
        #expect(!(store.recorder is ReceiverRestarting))
        #expect(!(store.antennaCheck is ReceiverRestarting))
        // Empfänger von `RemoteHub` laufen über `resumeAfterPlan`, nicht hier.
        #expect(!(store.adsb is ReceiverRestarting))
    }

    // MARK: - Umschalt-Rückfrage

    @Test("Rückfrage: Konflikt beim Klick neu bestimmt – andere Lage heißt neu fragen")
    func sameSituation() {
        let ble = NSObject(), gps = NSObject()
        #expect(ReceiverConflict.plan(title: "Radiosonden").sameSituation(as: .plan(title: "Radiosonden")))
        #expect(!ReceiverConflict.plan(title: "Radiosonden").sameSituation(as: .plan(title: "ISS (40°)")))
        #expect(ReceiverConflict.remote(.adsb).sameSituation(as: .remote(.adsb)))
        #expect(!ReceiverConflict.remote(.adsb).sameSituation(as: .remote(.ais)))
        #expect(ReceiverConflict.local(owner: ble, name: "BLE").sameSituation(as: .local(owner: ble, name: "anders")))
        #expect(!ReceiverConflict.local(owner: ble, name: "BLE").sameSituation(as: .local(owner: gps, name: "BLE")))
        // Während die Rückfrage offen stand, begann ein Plan-Termin.
        #expect(!ReceiverConflict.plan(title: "Radiosonden").sameSituation(as: .local(owner: ble, name: "BLE")))
        #expect(!ReceiverConflict.local(owner: ble, name: "BLE").sameSituation(as: .plan(title: "Radiosonden")))
        #expect(!ReceiverConflict.remote(.adsb).sameSituation(as: .local(owner: ble, name: "BLE")))
    }

    // MARK: - Sonden: Bodenhöhe

    private static func fallingSonde(altitude: Double) -> Sonde {
        var report = SondeReport(kind: .rs41, serial: "X1234567", model: "RS41-SGP")
        report.latitude = 53; report.longitude = 9
        report.altitude = altitude
        report.verticalSpeed = -15
        report.groundSpeed = 10; report.heading = 90
        report.frequency = 402_500_000
        var tracker = SondeTracker()
        tracker.ingest(report, at: Date(timeIntervalSince1970: 1_800_000_000))
        return tracker.sorted[0]
    }

    @Test("Absurde Bodenhöhe bzw. Höhe: /api/sondes stürzt nicht ab")
    func absurdGroundAltitude() throws {
        #expect(Sonde.clampedGroundAltitude(-1e9) == -500)
        #expect(Sonde.clampedGroundAltitude(1e9) == 9000)
        #expect(Sonde.clampedGroundAltitude(.nan) == 100)
        #expect(Sonde.clampedGroundAltitude(250) == 250)
        let sonde = Self.fallingSonde(altitude: 30_000)
        for ground in [-1e9, -600_000, -1e16, .nan, .infinity, -.infinity, 1e9] {
            let list = RemoteSondes.list([sonde], home: nil, groundAltitude: ground)
            #expect((-500...9000).contains(list.groundAltitude))
            _ = try JSONEncoder().encode(list)
        }
        // Verstümmelte Höhe (≈ 10 000 km): keine Landeschätzung statt Absturz.
        let broken = Self.fallingSonde(altitude: 1e7)
        #expect(broken.landing(groundAltitude: 100) == nil)
        _ = try JSONEncoder().encode(RemoteSondes.list([broken], home: nil, groundAltitude: 100))
        // Normaler Sinkflug bekommt weiter eine Schätzung.
        #expect(sonde.landing(groundAltitude: 100) != nil)
    }

    // MARK: - Sondenarchiv: Löschen gegen Anhängen

    @Test("Sondenarchiv: Löschen verliert keine gleichzeitig angehängte Meldung")
    func deleteWhileAppending() async throws {
        let db = TestDatabase()
        defer { db.remove() }
        let database = db.database
        func report(_ serial: String) -> SondeReport {
            var r = SondeReport(kind: .rs41, serial: serial, model: "RS41-SGP")
            r.latitude = 53; r.longitude = 9; r.altitude = 1000; r.frequency = 402_500_000
            return r
        }
        SondeLog.append([report("DELETEME")], window: "w", database: database)
        let appends = 300
        async let writer: Void = Task.detached {
            for i in 0..<appends {
                SondeLog.append([report("KEEP1234")], window: "w", received: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)),
                                database: database)
                if i % 10 == 0 {
                    SondeLog.append([report("DELETEME")], window: "w", received: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                                    database: database)
                }
            }
        }.value
        async let remover: Void = Task.detached {
            for _ in 0..<60 { SondeArchive.delete(serial: "DELETEME", database: database) }
        }.value
        _ = await (writer, remover)
        await database.flush()
        SondeArchive.delete(serial: "DELETEME", database: database)
        #expect(SondeArchive.load(serial: "KEEP1234", database: database)?.samples.count == appends)
        #expect(SondeArchive.load(serial: "DELETEME", database: database) == nil)
    }

    // MARK: - Flash-Sperre

    @Test("Flash-Sperre: gehalten bleibt der Empfang auch zwischen zwei Zugriffen gesperrt")
    func flashLockHeld() {
        var lock = FlashLock()
        #expect(!lock.blocksReceiving)
        lock.held = true
        #expect(lock.blocksReceiving)
        let write = lock.beginAccess()       // Schreiben
        let second = lock.beginAccess()      // kein zweiter Zugriff gleichzeitig
        #expect(write && !second)
        lock.endAccess()
        #expect(lock.blocksReceiving)        // zwischen Schreiben und Rücklesen
        let read = lock.beginAccess()        // Rücklesen
        #expect(read)
        lock.endAccess()
        #expect(lock.blocksReceiving)        // Pause vor dem zweiten Versuch
        lock.held = false
        #expect(!lock.blocksReceiving)
    }
}
