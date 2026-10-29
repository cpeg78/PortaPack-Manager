import Foundation
import Testing
@testable import PortaPackManager

@Suite("Drohnen-Kennung (Remote ID)")
struct RemoteIDTests {
    /// Erzeugt mit der Referenz opendroneid-core-c (`opendroneid.c`,
    /// Eingaben wie in deren `test/test_inout.c`) – Byte für Byte.
    enum Reference {
        static let basicID = bytes("02223132333435363738393031323334353637383930000000")
        static let location = bytes("122624160B42BF241B6ED1B4B69808AC0870086B53150E0200")
        /// Wie `location`, aber 100 m/s (Multiplikator), Kurs 90°, −3,5 m/s.
        static let locationFast = bytes("12255A30F942BF241B6ED1B4B69808AC0870086B53150E0200")
        static let auth0 = bytes("22100128003FAB013132333435363738393031323334353637")
        static let selfID = bytes("320044726F6E65735255533A205265616C2045737461746500")
        static let system = bytes("4204A6BF241BD2D1B4B62300073209230824F907003FAB0100")
        static let operatorID = bytes("52003938373635343332313030313233343536373839000000")

        static func bytes(_ hex: String) -> [UInt8] {
            stride(from: 0, to: hex.count, by: 2).map { i in
                let start = hex.index(hex.startIndex, offsetBy: i)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
        }
    }

    private func single(_ bytes: [UInt8]) throws -> RemoteID.Message {
        let messages = RemoteID.decode(bytes)
        try #require(messages.count == 1)
        return messages[0]
    }

    // MARK: - Referenzvektoren dekodieren

    @Test("Basic ID: Registrierung und Multikopter")
    func basicID() throws {
        guard case .basicID(let basic) = try single(Reference.basicID) else { Issue.record("falscher Typ"); return }
        #expect(basic.idType == 2)
        #expect(basic.uaType == 2)
        #expect(basic.uasID == "12345678901234567890")
        #expect(basic.uaTypeName == "Hubschrauber/Multikopter")
    }

    @Test("Position: Skalierungen wie in opendroneid.c")
    func location() throws {
        guard case .location(let loc) = try single(Reference.location) else { Issue.record("falscher Typ"); return }
        #expect(loc.status == 2)
        #expect(loc.heightOverGround)
        // 215,7° → 36 + E/W-Bit (180) = 216°
        #expect(loc.direction == 216)
        // 5,4 m/s → 22 · 0,25 = 5,5 m/s
        #expect(loc.speed == 5.5)
        // 5,25 m/s → round(10,5) = 11 · 0,5 = 5,5 m/s
        #expect(loc.verticalSpeed == 5.5)
        #expect(abs(loc.latitude! - 45.539309) < 1e-9)
        #expect(abs(loc.longitude! - -122.966389) < 1e-9)
        #expect(loc.altitudeBaro == 100)
        #expect(loc.altitudeGeo == 110)
        #expect(loc.height == 80)
        #expect(loc.horizontalAccuracyMeters == 3)    // 2,5 m → Stufe „< 3 m“
        #expect(loc.verticalAccuracyMeters == 1)
        #expect(loc.baroAccuracyMeters == 3)
        #expect(loc.speedAccuracyMeters == 1)
        #expect(loc.timestampAccuracy == 2)            // 0,2 s
        #expect(loc.timestamp == 360.5)                // 360,52 s → 3605 Zehntel
    }

    @Test("Position: Geschwindigkeit mit Multiplikator, Kurs ohne E/W-Bit, Sinken")
    func locationFast() throws {
        guard case .location(let loc) = try single(Reference.locationFast) else { Issue.record("falscher Typ"); return }
        #expect(loc.speed == 99.75)        // Referenz liefert ebenfalls 99,75
        #expect(loc.direction == 90)
        #expect(loc.verticalSpeed == -3.5)
    }

    @Test("System: Pilotposition, Gebiet und EU-Klasse")
    func system() throws {
        guard case .system(let sys) = try single(Reference.system) else { Issue.record("falscher Typ"); return }
        #expect(sys.operatorLocationType == 0)
        #expect(sys.classificationType == 1)
        #expect(abs(sys.operatorLatitude! - 45.539319) < 1e-9)
        #expect(abs(sys.operatorLongitude! - -122.966379) < 1e-9)
        #expect(sys.areaCount == 35)
        #expect(sys.areaRadius == 70)       // 75 m → 7 · 10
        #expect(sys.areaCeiling == 177)     // 176,9 → 2354 · 0,5 − 1000
        #expect(sys.areaFloor == 41.5)
        #expect(sys.categoryEU == 2)
        #expect(sys.classEU == 4)
        #expect(sys.euClassification == "Kategorie speziell, C3")
        #expect(sys.operatorAltitude == 20.5)
        #expect(sys.timestamp == RemoteID.epoch.addingTimeInterval(28_000_000))
    }

    @Test("Self-ID, Betreiber-ID und Auth-Seite 0")
    func textMessages() throws {
        guard case .selfID(let selfID) = try single(Reference.selfID) else { Issue.record("falscher Typ"); return }
        #expect(selfID.text == "DronesRUS: Real Estate")
        guard case .operatorID(let op) = try single(Reference.operatorID) else { Issue.record("falscher Typ"); return }
        #expect(op.id == "98765432100123456789")
        guard case .auth(let auth) = try single(Reference.auth0) else { Issue.record("falscher Typ"); return }
        #expect(auth.authType == 1)
        #expect(auth.page == 0)
        #expect(auth.lastPageIndex == 1)
        #expect(auth.length == 40)
    }

    // MARK: - Kodieren = Referenz

    @Test("Kodierer erzeugt dieselben Bytes wie opendroneid-core-c")
    func encoderMatchesReference() {
        #expect(RemoteIDEncoder.basicID(idType: 2, uaType: 2, id: "12345678901234567890") == Reference.basicID)
        #expect(RemoteIDEncoder.location(status: 2, direction: 215.7, speed: 5.4, verticalSpeed: 5.25,
                                         latitude: 45.539309, longitude: -122.966389, altitudeBaro: 100,
                                         altitudeGeo: 110, heightOverGround: true, height: 80,
                                         horizontalAccuracy: 11, verticalAccuracy: 6, baroAccuracy: 5,
                                         speedAccuracy: 3, timestampAccuracy: 2, timestamp: 360.52) == Reference.location)
        #expect(RemoteIDEncoder.location(status: 2, direction: 90, speed: 100, verticalSpeed: -3.5,
                                         latitude: 45.539309, longitude: -122.966389, altitudeBaro: 100,
                                         altitudeGeo: 110, heightOverGround: true, height: 80,
                                         horizontalAccuracy: 11, verticalAccuracy: 6, baroAccuracy: 5,
                                         speedAccuracy: 3, timestampAccuracy: 2, timestamp: 360.52) == Reference.locationFast)
        #expect(RemoteIDEncoder.selfID(text: "DronesRUS: Real Estate") == Reference.selfID)
        #expect(RemoteIDEncoder.system(locationType: 0, classificationType: 1, latitude: 45.539319,
                                       longitude: -122.966379, areaCount: 35, areaRadius: 75, areaCeiling: 176.9,
                                       areaFloor: 41.7, categoryEU: 2, classEU: 4, operatorAltitude: 20.5,
                                       timestamp: 28_000_000) == Reference.system)
        #expect(RemoteIDEncoder.operatorID(id: "98765432100123456789") == Reference.operatorID)
    }

    @Test("Unbekannte Werte: Höhe 0, Kurs 361, Tempo 255, Zeit 0xFFFF")
    func invalidValues() throws {
        var bytes = RemoteIDEncoder.location(status: 0, direction: 361, speed: 255, verticalSpeed: 63,
                                             latitude: 0, longitude: 0, altitudeBaro: -1000, altitudeGeo: -1000,
                                             heightOverGround: false, height: -1000, timestamp: 0)
        bytes[21] = 0xFF
        bytes[22] = 0xFF
        guard case .location(let loc) = try single(bytes) else { Issue.record("falscher Typ"); return }
        #expect(loc.direction == nil)
        #expect(loc.speed == nil)
        #expect(loc.verticalSpeed == nil)
        #expect(loc.latitude == nil)
        #expect(loc.altitudeGeo == nil)
        #expect(loc.height == nil)
        #expect(loc.timestamp == nil)
        #expect(loc.horizontalAccuracyMeters == nil)
    }

    @Test("Message Pack mit drei Nachrichten")
    func messagePack() {
        let pack = RemoteIDEncoder.pack([Reference.basicID, Reference.location, Reference.operatorID])
        #expect(Array(pack.prefix(3)) == [0xF2, 0x19, 0x03])   // wie encodeMessagePack
        let messages = RemoteID.decode(pack)
        #expect(messages.map(\.type) == [.basicID, .location, .operatorID])
    }

    // MARK: - Werbepaket

    private let address: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0xC6]

    private func advertisingPDU(_ message: [UInt8], counter: UInt8) -> [UInt8] {
        // Die Remote-ID-Struktur füllt die 31 Byte der Legacy-Werbung allein (keine Flags).
        let ad = RemoteIDEncoder.adStructure(message, counter: counter)
        return [0x42, UInt8(6 + ad.count)] + address + ad    // ADV_NONCONN_IND, zufällige Adresse
    }

    @Test("Dienstdaten 0xFFFA mit App-Code 0x0D werden erkannt, andere nicht")
    func serviceDataParsing() throws {
        let pdu = advertisingPDU(Reference.location, counter: 7)
        #expect(pdu.count == 2 + 6 + 31)   // genau die 37 Byte Nutzlast der Legacy-Werbung
        let ad = try #require(BLEAdvertisement.parse(pdu))
        let frame = try #require(RemoteID.parse(ad))
        #expect(frame.counter == 7)
        #expect(frame.messages.first?.type == .location)

        var wrongCode = pdu
        wrongCode[2 + 6 + 4] = 0x0C
        #expect(BLEAdvertisement.parse(wrongCode).flatMap(RemoteID.parse) == nil)
    }

    @Test("Tracker führt Nachrichten einer Adresse zu einer Drohne zusammen")
    func tracker() throws {
        var tracker = DroneTracker()
        let address = BLEAddress(bytes: address, random: true)
        let date = Date()
        for (index, message) in [Reference.basicID, Reference.location, Reference.system, Reference.operatorID,
                                 Reference.selfID, Reference.locationFast].enumerated() {
            let frame = try #require(RemoteID.parseServiceData([RemoteID.appCode, UInt8(index)] + message))
            tracker.ingest(frame, address: address, rssiDB: -40, date: date.addingTimeInterval(Double(index)))
        }
        let drone = try #require(tracker.sorted.first)
        #expect(tracker.sorted.count == 1)
        #expect(drone.uasID == "12345678901234567890")
        #expect(drone.location?.speed == 99.75)
        #expect(drone.system?.areaCount == 35)
        #expect(drone.operatorID?.id == "98765432100123456789")
        #expect(drone.selfID?.text == "DronesRUS: Real Estate")
        #expect(drone.trail.count == 1)          // gleiche Position nur einmal
        #expect(drone.messageCount == 6)
    }

    // MARK: - Über die Luft (GFSK, BLE-Demodulator)

    /// Bits in Sendereihenfolge wie in den BLE-Tests.
    private func airBits(_ pdu: [UInt8], channel: Int) -> [UInt8] {
        let body = BLELink.whiten(pdu + BLELink.crcBytes(pdu), channel: channel)
        return BLELink.syncBits + body.flatMap { byte in (0..<8).map { (byte >> UInt8($0)) & 1 } }
    }

    /// GFSK (BT 0,5, Hub 250 kHz) bei 8 MS/s, 2 MHz über der HackRF-Mitte, mit Rauschen.
    private func iq(_ bursts: [[UInt8]], gapBits: Int = 300, amplitude: Double = 50) -> Data {
        let spb = 8
        var nrz: [Double] = [], on: [Bool] = []
        for bits in bursts {
            nrz += Array(repeating: 0, count: gapBits * spb)
            on += Array(repeating: false, count: gapBits * spb)
            nrz += bits.flatMap { Array(repeating: $0 == 1 ? 1.0 : -1.0, count: spb) }
            on += Array(repeating: true, count: bits.count * spb)
        }
        nrz += Array(repeating: 0, count: 600 * spb)
        on += Array(repeating: false, count: 600 * spb)
        let sigma = (log(2.0).squareRoot() / (2 * .pi * 0.5)) * Double(spb)
        let half = 2 * spb
        var kernel = (-half...half).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var seed: UInt32 = 1234
        func noise() -> Double {
            seed = seed &* 1_103_515_245 &+ 12345
            return Double(Int(seed >> 16) % 9 - 4)
        }
        var data = Data(count: nrz.count * 2)
        var phase = 0.0
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<nrz.count {
                var shaped = 0.0
                for (k, weight) in kernel.enumerated() {
                    let index = n + k - half
                    if index >= 0, index < nrz.count { shaped += weight * nrz[index] }
                }
                phase += 2 * .pi * (BLEDemodulator.offset + 250_000 * shaped) / BLEDemodulator.inputRate
                let a = on[n] ? amplitude : 0
                p[2 * n] = Int8(max(-127, min(127, (a * cos(phase) + noise()).rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, (a * sin(phase) + noise()).rounded())))
            }
        }
        return data
    }

    @Test("Remote ID über GFSK und BLE-Demodulator bis zur Drohne")
    func overTheAir() throws {
        let channel = 37
        let messages = [Reference.basicID, Reference.location, Reference.system, Reference.operatorID]
        let bursts = messages.enumerated().map { airBits(advertisingPDU($1, counter: UInt8($0)), channel: channel) }
        let data = iq(bursts)
        let demod = BLEDemodulator()
        var packets: [BLEPacket] = []
        var start = 0
        while start < data.count {
            let end = min(start + 262_144, data.count)
            packets += demod.process(data.subdata(in: start..<end), channel: channel)
            start = end
        }
        packets += demod.process(Data(count: 65_536), channel: channel)
        var tracker = DroneTracker()
        for packet in packets {
            guard let ad = BLEAdvertisement.parse(packet.pdu), let sender = ad.address,
                  let frame = RemoteID.parse(ad) else { continue }
            tracker.ingest(frame, address: sender, rssiDB: packet.rssiDB, date: packet.date)
        }
        let drone = try #require(tracker.sorted.first)
        #expect(drone.messageCount == 4)
        #expect(drone.uasID == "12345678901234567890")
        #expect(abs((drone.latitude ?? 0) - 45.539309) < 1e-9)
        #expect(drone.system?.operatorLatitude != nil)
    }
}

@Suite("Remote ID über WLAN-Beacon")
struct RemoteIDBeaconTests {
    @Test("Herstellerelement FA:0B:BC/0D mit Message Pack wird gefunden")
    func beacon() throws {
        // Basic ID: Typ 0, ID-Art 1 (Seriennummer), UA-Typ 2, Text.
        var basic: [UInt8] = [0x02, 0x12] + Array("1581F5FKD229400002".utf8)
        basic += [UInt8](repeating: 0, count: 25 - basic.count)
        let pack: [UInt8] = [0xF2, 25, 1] + basic
        let vendor: [UInt8] = [0xFA, 0x0B, 0xBC, 0x0D, 7] + pack
        let ies: [UInt8] = [0x00, 4] + Array("TEST".utf8) + [0xDD, UInt8(vendor.count)] + vendor + [0x03, 1, 6]
        let frame = try #require(RemoteID.parseBeaconElements(ies))
        #expect(frame.counter == 7)
        guard case let .basicID(id)? = frame.messages.first else { Issue.record("keine Basic ID"); return }
        #expect(id.uasID == "1581F5FKD229400002")
        #expect(RemoteID.parseBeaconElements([0x00, 4] + Array("TEST".utf8)) == nil)
    }
}
