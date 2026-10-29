import CoreLocation
import Foundation
import Testing
@testable import PortaPackManager

@Suite("Archiv der Sichtungen")
@MainActor
struct TrafficArchiveTests {

    private func update(_ key: String, _ date: Date, lat: Double, alt: Int = 1000) -> SightingUpdate {
        SightingUpdate(key: key, name: "TEST1", lastSeen: date, messages: 1, latitude: lat, longitude: 10, altitudeM: alt)
    }

    @Test func folgemeldungenErgebenEineSichtung() {
        let db = TestDatabase()
        defer { db.remove() }
        let archive = TrafficArchive(kind: .adsb, database: db.database)
        let start = Date(timeIntervalSince1970: 1_793_000_000)   // Tagesmitte, kein Datumswechsel
        archive.record([update("ABC", start, lat: 53.0)], home: (53.0, 10.0))
        archive.record([update("ABC", start.addingTimeInterval(60), lat: 53.1, alt: 5000)], home: (53.0, 10.0))
        archive.record([update("ABC", start.addingTimeInterval(60), lat: 53.1)], home: nil)   // nichts Neues
        let day = TrafficArchive.dayStamp(start)
        let list = archive.sightings(day: day)
        #expect(list.count == 1)
        #expect(list[0].maxAltitudeM == 5000)
        #expect(list[0].track.count == 2)
        #expect(list[0].minDistanceKm == 0)
    }

    @Test func lueckeUeberDreissigMinutenIstNeueSichtung() {
        let db = TestDatabase()
        defer { db.remove() }
        let archive = TrafficArchive(kind: .adsb, database: db.database)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        archive.record([update("ABC", start, lat: 53.0)], home: nil)
        archive.record([update("ABC", start.addingTimeInterval(31 * 60), lat: 53.0)], home: nil)
        #expect(archive.sightings(day: TrafficArchive.dayStamp(start)).count == 2)
    }

    @Test func nachNeustartGehtDieSichtungWeiter() async {
        let db = TestDatabase()
        defer { db.remove() }
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let first = TrafficArchive(kind: .adsb, database: db.database)
        first.record([update("ABC", start, lat: 53.0)], home: nil)
        first.save()
        await first.flush()   // geschrieben wird abseits des Main Actors
        let second = TrafficArchive(kind: .adsb, database: db.database)
        second.record([update("ABC", start.addingTimeInterval(120), lat: 53.2)], home: nil)
        let list = second.sightings(day: TrafficArchive.dayStamp(start))
        #expect(list.count == 1)
        #expect(list.first?.last == start.addingTimeInterval(120))
        #expect(list.first?.track.count == 2)
    }

    @Test("Flugzeuge und Schiffe bleiben getrennt; Tage, Kennung und Zeitraum")
    func artenUndAbfragen() async {
        let db = TestDatabase()
        defer { db.remove() }
        let adsb = TrafficArchive(kind: .adsb, database: db.database)
        let ais = TrafficArchive(kind: .ais, database: db.database)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        adsb.record([update("ABC", start, lat: 53.0)], home: nil)
        adsb.record([update("ABC", start.addingTimeInterval(86_400), lat: 53.0)], home: nil)
        ais.record([update("211000000", start, lat: 53.5)], home: nil)
        let days = await adsb.loadDays()
        #expect(days == [TrafficArchive.dayStamp(start.addingTimeInterval(86_400)), TrafficArchive.dayStamp(start)])
        #expect(await adsb.sightings(key: "ABC").count == 2)
        #expect(await adsb.sightings(days: nil).count == 2)
        #expect(await ais.sightings(days: nil).map(\.key) == ["211000000"])
        #expect(await adsb.sightings(since: start.addingTimeInterval(3600)).count == 1)
    }
}

@Suite("Daten teilen")
struct DataSharingTests {
    @Test func zieleWerdenGelesen() {
        let targets = NMEAFeeder.parseTargets("data.aishub.net:2345, 5.9.207.224:1234\nfalsch  host:0 :80 x:99999")
        #expect(targets.map { "\($0.host):\($0.port)" } == ["data.aishub.net:2345", "5.9.207.224:1234"])
    }
}

@Suite("Archiv: Anflüge und Richtungspfeile")
struct ArchiveApproachTests {
    @Test("Platzrunden: jeder Tiefpunkt nach dem Steigen zählt")
    func approaches() {
        // Start, drei Runden mit Touch-and-go, Landung.
        let alt: [Double] = [30, 300, 600, 700, 400, 60, 350, 650, 600, 200, 40, 500, 700, 300, 50]
        #expect(ArchiveSighting.approaches(alt) == 3)
        #expect(ArchiveSighting.approaches([11000, 10500, 9000]) == 0)   // Überflug
        #expect(ArchiveSighting.approaches([3000, 2000, 900, 400]) == 1) // Landeanflug
        #expect(ArchiveSighting.approaches([]) == 0)
    }

    @Test("Richtungspfeile zeigen in Flugrichtung und bleiben begrenzt")
    @MainActor func arrows() {
        let north = (0..<50).map { CLLocationCoordinate2D(latitude: 53 + Double($0) * 0.01, longitude: 10) }
        let marks = TrackArrow.marks(north, limit: 10)
        #expect(!marks.isEmpty && marks.count <= 10)
        #expect(marks.allSatisfy { abs($0.bearing) < 1 || abs($0.bearing - 360) < 1 })
        #expect(TrackArrow.marks([north[0]]).isEmpty)
    }
}
