import Foundation
import Testing
@testable import PortaPackManager

@Suite("Bluetooth LE")
struct BLETests {
    // MARK: - Pakete bauen

    private let address: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0xC6]   // zufällig, fest

    /// ADV_NONCONN_IND (TxAdd = zufällig) mit den angegebenen AD-Strukturen.
    private func advertising(_ fields: [[UInt8]], type: UInt8 = 2) -> [UInt8] {
        let data = fields.flatMap { [UInt8($0.count)] + $0 }
        return [0x40 | type, UInt8(6 + data.count)] + address + data
    }

    /// Bits in Sendereihenfolge: Präambel, Zugriffsadresse, PDU + CRC gewhitet.
    private func airBits(_ pdu: [UInt8], channel: Int) -> [UInt8] {
        let body = BLELink.whiten(pdu + BLELink.crcBytes(pdu), channel: channel)
        return BLELink.syncBits + body.flatMap { byte in (0..<8).map { (byte >> UInt8($0)) & 1 } }
    }

    /// GFSK (BT 0,5, Hub 250 kHz) bei 8 MS/s, 2 MHz über der HackRF-Mitte,
    /// mit Trägerablage und etwas Rauschen.
    private func iq(_ bursts: [(bits: [UInt8], gapBits: Int)], carrierHz: Double = 0, amplitude: Double = 60) -> Data {
        let spb = 8
        var nrz: [Double] = []
        for burst in bursts {
            nrz += Array(repeating: 0, count: burst.gapBits * spb)
            nrz += burst.bits.flatMap { Array(repeating: $0 == 1 ? 1.0 : -1.0, count: spb) }
        }
        nrz += Array(repeating: 0, count: 600 * spb)
        // Gaußfilter, normiert auf Summe 1.
        let sigma = (log(2.0).squareRoot() / (2 * .pi * 0.5)) * Double(spb)
        let half = 2 * spb
        var kernel = (-half...half).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var seed: UInt32 = 4711
        func noise() -> Double {
            seed = seed &* 1_103_515_245 &+ 12345
            return Double(Int(seed >> 16) % 9 - 4)
        }
        let on: [Bool] = {
            var flags: [Bool] = []
            for burst in bursts {
                flags += Array(repeating: false, count: burst.gapBits * spb)
                flags += Array(repeating: true, count: burst.bits.count * spb)
            }
            return flags + Array(repeating: false, count: 600 * spb)
        }()
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
                phase += 2 * .pi * (BLEDemodulator.offset + carrierHz + 250_000 * shaped) / BLEDemodulator.inputRate
                let a = on[n] ? amplitude : 0
                p[2 * n] = Int8(max(-127, min(127, (a * cos(phase) + noise()).rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, (a * sin(phase) + noise()).rounded())))
            }
        }
        return data
    }

    private func run(_ data: Data, channel: Int) -> (packets: [BLEPacket], demod: BLEDemodulator) {
        let demod = BLEDemodulator()
        var packets: [BLEPacket] = []
        var start = 0
        while start < data.count {
            let end = min(start + 262_144, data.count)
            packets += demod.process(data.subdata(in: start..<end), channel: channel)
            start = end
        }
        // Leerlauf hinterher, damit auch das letzte Paket ausgewertet wird.
        packets += demod.process(Data(count: 262_144), channel: channel)
        return (packets, demod)
    }

    // MARK: - Bitebene

    @Test("Whitening ist seine eigene Umkehrung und hängt vom Kanal ab")
    func whitening() {
        let bytes: [UInt8] = Array(0..<40)
        #expect(BLELink.whiten(BLELink.whiten(bytes, channel: 37), channel: 37) == bytes)
        #expect(BLELink.whiten(bytes, channel: 37) != BLELink.whiten(bytes, channel: 38))
        // Kanal 37: Folge des LFSR (x⁷ + x⁴ + 1, Start 1·100101) – erste Bytes
        // auf Nullen angewandt.
        #expect(BLELink.whiten([0, 0], channel: 37) == [0x8D, 0xD2])
    }

    @Test("CRC-24 über Kopf und Daten, Präambel passt zur Zugriffsadresse")
    func crcAndSync() {
        let pdu = advertising([[0x01, 0x06]])
        let crc = BLELink.crcBytes(pdu)
        #expect(crc.count == 3)
        var broken = pdu
        broken[4] ^= 0x10
        #expect(BLELink.crcBytes(broken) != crc)
        // 0xAA LSB zuerst, letztes Präambelbit ≠ erstes Adressbit.
        #expect(Array(BLELink.syncBits.prefix(8)) == [0, 1, 0, 1, 0, 1, 0, 1])
        #expect(BLELink.syncBits[7] != BLELink.syncBits[8])
    }

    // MARK: - Ende zu Ende

    @Test("Demodulator findet Pakete auch mit Trägerablage")
    func demodulator() throws {
        let first = advertising([[0x01, 0x06], [0x09] + Array("Thermo".utf8)])
        let second = advertising([[0xFF, 0x4C, 0x00, 0x12, 0x19, 0x10] + Array(repeating: 0xAB, count: 24)])
        let signal = iq([(airBits(first, channel: 38), 2000), (airBits(second, channel: 38), 3000)], carrierHz: 60_000)
        let (packets, demod) = run(signal, channel: 38)
        #expect(packets.count == 2)
        let packet = try #require(packets.first)
        #expect(packet.pdu == first)
        #expect(packet.channel == 38)
        #expect(abs(packet.offsetKHz - 60) < 15)
        #expect(packets.last?.pdu == second)
        #expect(demod.crcErrors == 0)
    }

    @Test("Whitening eines anderen Kanals wird erkannt")
    func otherChannel() {
        let pdu = advertising([[0x01, 0x06]])
        let (packets, _) = run(iq([(airBits(pdu, channel: 39), 1500)]), channel: 37)
        #expect(packets.map(\.channel) == [39])
        #expect(packets.first?.pdu == pdu)
    }

    @Test("Rauschen allein liefert keine Pakete")
    func noiseOnly() {
        let (packets, _) = run(iq([([], 40_000)], amplitude: 0), channel: 37)
        #expect(packets.isEmpty)
    }

    // MARK: - Werbedaten

    @Test("PDU wird zerlegt: Adresse, Name, Hersteller")
    func parse() throws {
        let pdu = advertising([[0x01, 0x06], [0x09] + Array("Küche".utf8), [0x0A, 0xF8], [0xFF, 0x59, 0x00, 0x01]], type: 0)
        let ad = try #require(BLEAdvertisement.parse(pdu))
        #expect(ad.type == .advInd)
        #expect(ad.address?.string == "C6:55:44:33:22:11")
        #expect(ad.address?.kind == "zufällig, fest")
        #expect(ad.address?.rotates == false)
        #expect(ad.name == "Küche")
        #expect(ad.txPower == -8)
        #expect(ad.manufacturer?.company == 0x0059)
    }

    @Test("Scan-Anfrage: Scanner und Ziel")
    func scanRequest() throws {
        let pdu: [UInt8] = [0xC3, 12, 1, 2, 3, 4, 5, 0x46, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]
        let ad = try #require(BLEAdvertisement.parse(pdu))
        #expect(ad.type == .scanReq)
        #expect(ad.address?.string == "46:05:04:03:02:01")
        #expect(ad.address?.rotates == true)
        #expect(ad.target?.string == "66:55:44:33:22:11")
    }

    private func values(_ result: BLEInterpreter.Result) -> [String: String] {
        Dictionary(result.readings.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("RuuviTag Format 5 (Prüfwerte von Ruuvi)")
    func ruuvi() throws {
        let raw: [UInt8] = [0x05, 0x12, 0xFC, 0x53, 0x94, 0xC3, 0x7C, 0x00, 0x04, 0xFF, 0xFC, 0x04, 0x0C,
                            0xAC, 0x36, 0x42, 0x00, 0xCD, 0xCB, 0xB8, 0x33, 0x4C, 0x88, 0x4F]
        let result = try #require(BLEInterpreter.manufacturer(0x0499, raw))
        let v = values(result)
        #expect(result.kind == "RuuviTag")
        #expect(v["Temperatur"] == "24.30 °C")
        #expect(v["Feuchte"] == "53.5 %")
        #expect(v["Luftdruck"] == "1000.44 hPa")
        #expect(v["Batteriespannung"] == "2.977 V")
        #expect(v["Bewegungen"] == "66")
    }

    @Test("Govee H5075")
    func govee() throws {
        let result = try #require(BLEInterpreter.manufacturer(0xEC88, [0x00, 0x03, 0x51, 0x9E, 0x64, 0x00]))
        let v = values(result)
        #expect(v["Temperatur"] == "21.70 °C")
        #expect(v["Feuchte"] == "50.2 %")
        #expect(v["Batterie"] == "100 %")
    }

    @Test("BTHome v2 (Beispiel von bthome.io)")
    func bthome() {
        let result = BLEInterpreter.bthome([0x40, 0x02, 0xC4, 0x09, 0x03, 0xBF, 0x13, 0x21, 0x01])
        let v = values(result)
        #expect(v["Temperatur"] == "25.00 °C")
        #expect(v["Feuchte"] == "50.55 %")
        #expect(v["Bewegung"] == "ja")
        #expect(BLEInterpreter.bthome([0x41, 0x00]).kind == "BTHome (verschlüsselt)")
    }

    @Test("Xiaomi-Thermometer mit pvvx- und ATC-Firmware")
    func xiaomi() throws {
        let pvvx: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0xA4, 0x2E, 0x08, 0xFC, 0x12, 0x86, 0x0B, 0x55, 0x07, 0x04]
        let v = values(try #require(BLEInterpreter.serviceData(0x181A, pvvx)))
        #expect(v["Temperatur"] == "20.94 °C")
        #expect(v["Feuchte"] == "48.6 %")
        #expect(v["Batterie"] == "85 %")
        #expect(v["Batteriespannung"] == "2.950 V")

        let atc: [UInt8] = [0xA4, 0xC1, 0x38, 0x01, 0x02, 0x03, 0x00, 0xD2, 0x37, 0x5A, 0x0B, 0xB8, 0x01]
        let a = values(try #require(BLEInterpreter.serviceData(0x181A, atc)))
        #expect(a["Temperatur"] == "21.00 °C")
        #expect(a["Feuchte"] == "55.0 %")
        #expect(a["Batterie"] == "90 %")
    }

    @Test("iBeacon und Eddystone-URL")
    func beacons() throws {
        let uuid: [UInt8] = Array(0x10...0x1F)
        let beacon = try #require(BLEInterpreter.manufacturer(0x004C, [0x02, 0x15] + uuid + [0x00, 0x01, 0x00, 0x2A, 0xC5]))
        let v = values(beacon)
        #expect(beacon.kind == "iBeacon")
        #expect(v["UUID"] == "10111213-1415-1617-1819-1A1B1C1D1E1F")
        #expect(v["Major/Minor"] == "1 / 42")
        #expect(v["Pegel in 1 m"] == "-59 dBm")

        let url = try #require(BLEInterpreter.serviceData(0xFEAA, [0x10, 0xEB, 0x03] + Array("ruu".utf8) + [0x2E] + Array("vi".utf8) + [0x00]))
        #expect(values(url)["URL"] == "https://ruu.vi.com/")
    }
}
