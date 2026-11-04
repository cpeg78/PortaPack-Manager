import Testing
@testable import PortaPackManager

@Suite("Flugzeugart für das Kartensymbol")
struct AircraftClassTests {
    @Test("ADS-B-Kategorie hat Vorrang vor der Datenbank")
    func emitterFirst() {
        let a320 = AircraftInfo(typeCode: "A320")
        #expect(AircraftClass.of(emitter: 4 << 3 | 7, info: a320) == .helicopter)
        #expect(AircraftClass.of(emitter: 4 << 3 | 5, info: nil) == .heavy)
        #expect(AircraftClass.of(emitter: 4 << 3 | 1, info: nil) == .light)
        #expect(AircraftClass.of(emitter: 3 << 3 | 1, info: nil) == .glider)
        #expect(AircraftClass.of(emitter: 4 << 3 | 3, info: nil) == .medium)
    }

    @Test("Ohne Kategorie: Datenbankkategorie, dann Typcode")
    func database() {
        // D-HVBY, Bundespolizei – der Hubschrauber vom 03.11.2026.
        #expect(AircraftClass.of(emitter: nil, info: AircraftInfo(typeCode: "EC35", manufacturer: "Eurocopter")) == .helicopter)
        #expect(AircraftClass.of(emitter: nil, info: AircraftInfo(typeCode: "B77W")) == .heavy)
        #expect(AircraftClass.of(emitter: nil, info: AircraftInfo(typeCode: "A388")) == .heavy)
        #expect(AircraftClass.of(emitter: nil, info: AircraftInfo(typeCode: "C172")) == .light)
        #expect(AircraftClass.of(emitter: nil, info: AircraftInfo(typeCode: "GLID")) == .glider)
        #expect(AircraftClass.of(emitter: nil, info: AircraftInfo(typeCode: "A20N")) == .medium)
        #expect(AircraftClass.of(emitter: nil, info: AircraftInfo(typeCode: "B738", category: "Rotorcraft")) == .helicopter)
        #expect(AircraftClass.of(emitter: nil, info: nil) == .medium)
    }

    @Test("Tracker merkt sich die Kategorie aus der Kennungsmeldung")
    func trackerStoresEmitter() {
        var tracker = AircraftTracker()
        tracker.ingest(ADSBMessage(icao: 0x3E0A46, downlinkFormat: 17, typeCode: 4,
                                   content: .identification(callsign: "BPO", category: 7), raw: [], date: .now))
        #expect(tracker.aircraft[0x3E0A46]?.emitter == 4 << 3 | 7)
    }
}
