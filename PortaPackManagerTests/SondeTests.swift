import Foundation
import Testing
@testable import PortaPackManager

/// Erzeugt Testsignale: RS41- und DFM-Rahmen, deren Bits und FSK-IQ.
enum SondeSignal {
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func bit() -> UInt8 { UInt8(next() & 1) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    static func put16(_ v: Int, _ out: inout [UInt8]) { out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func put32(_ v: Int32, _ out: inout [UInt8]) {
        let u = UInt32(bitPattern: v)
        out += [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8(u >> 24)]
    }

    /// Block: Kennung, Länge, Daten, CRC (LE).
    static func block(_ id: UInt8, _ data: [UInt8]) -> [UInt8] {
        let crc = RS41.crc16(data[...])
        return [id, UInt8(data.count)] + data + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    /// Entwürfelter RS41-Standardrahmen (320 Byte) mit Parität.
    static func rs41Frame(serial: String, number: Int, lat: Double, lon: Double, alt: Double,
                          north: Double, east: Double, up: Double, week: Int, tow: Int) -> [UInt8] {
        var frame = RS41.header + [UInt8](repeating: 0, count: 48)   // Kopf + Parität
        frame.append(0x0F)                                              // 0x38: Standardrahmen
        var status: [UInt8] = []
        put16(number, &status)
        status += Array(serial.utf8.prefix(8))
        status.append(29)                                                // 2,9 V
        status += [UInt8](repeating: 0, count: 40 - status.count)
        frame += block(0x79, status)
        frame += block(0x7A, [UInt8](repeating: 0, count: 42))
        var info: [UInt8] = []
        put16(week, &info)
        put32(Int32(tow), &info)
        info += [UInt8](repeating: 0, count: 30 - info.count)
        frame += block(0x7C, info)
        frame += block(0x7D, [UInt8](repeating: 0, count: 0x59))
        let p = SondeGeodesy.ecef(lat: lat, lon: lon, alt: alt)
        // NEU → ECEF
        let phi = lat * .pi / 180, lam = lon * .pi / 180
        let vx = -north * sin(phi) * cos(lam) - east * sin(lam) + up * cos(phi) * cos(lam)
        let vy = -north * sin(phi) * sin(lam) + east * cos(lam) + up * cos(phi) * sin(lam)
        let vz = north * cos(phi) + up * sin(phi)
        var gps: [UInt8] = []
        for v in [p.x, p.y, p.z] { put32(Int32((v * 100).rounded()), &gps) }
        for v in [vx, vy, vz] { put16(Int(Int16((v * 100).rounded())), &gps) }
        gps += [9, 0, 0]
        frame += block(0x7B, gps)
        frame += block(0x76, [UInt8](repeating: 0, count: 0x11))
        precondition(frame.count == RS41.standardLength)
        var padded = frame + [UInt8](repeating: 0, count: RS41.extendedLength - frame.count)
        RS41.addParity(&padded)
        return Array(padded[0..<RS41.standardLength])
    }

    /// Gesendete Bits: verwürfelt, LSB zuerst.
    static func rs41Bits(_ frame: [UInt8]) -> [UInt8] {
        var raw = frame
        RS41.applyMask(&raw)
        return raw.flatMap { byte in (0..<8).map { (byte >> $0) & 1 } }
    }

    /// DFM-Rahmen als Halbbits (Kopf + Manchester).
    static func dfmFrame(conf: [UInt8], dat1: [UInt8], dat2: [UInt8]) -> [UInt8] {
        let bits = DFMDecoder.encodeBlock(conf, words: 7) + DFMDecoder.encodeBlock(dat1, words: 13)
            + DFMDecoder.encodeBlock(dat2, words: 13)
        return DFMDecoder.rawHeader + bits.flatMap { $0 == 0 ? [1, 0] : [0, 1] as [UInt8] }
    }

    static func nibbles(_ value: Int, bits: Int) -> [UInt8] {
        (0..<bits).map { UInt8((value >> (bits - 1 - $0)) & 1) }
    }

    /// Datenblock (52 Bit): 48 Bit Nutzdaten + Kennung.
    static func dat(_ id: Int, _ a: Int, _ b: Int) -> [UInt8] {
        nibbles(a, bits: 32) + nibbles(b & 0xFFFF, bits: 16) + nibbles(id, bits: 4)
    }

    /// Konfigurationsblock: Kanal 0xA, 0xC, 16 Bit Seriennummernhälfte, Hälfte.
    static func conf(half: Int, value: Int) -> [UInt8] {
        nibbles(0xA, bits: 4) + nibbles(0xC, bits: 4) + nibbles(value, bits: 16) + nibbles(half, bits: 4)
    }

    /// DFM-Folge: Seriennummer 123456 und Position, Modus 2.
    static func dfmChips(lat: Double, lon: Double, alt: Double) -> [UInt8] {
        let serial = 123_456
        let frames: [[UInt8]] = [
            dfmFrame(conf: conf(half: 0, value: serial >> 16), dat1: nibbles(0, bits: 16) + nibbles(2, bits: 8) + nibbles(7, bits: 8) + [UInt8](repeating: 0, count: 16) + nibbles(0, bits: 4),
                     dat2: dat(1, 0, 12_000)),
            dfmFrame(conf: conf(half: 1, value: serial & 0xFFFF), dat1: dat(2, Int(lat * 1e7), 850), dat2: dat(3, Int(lon * 1e7), 27_000)),
            dfmFrame(conf: conf(half: 0, value: serial >> 16), dat1: dat(4, Int(alt * 100), 520), dat2: dat(5, 4700, 0)),
        ]
        return frames.flatMap { $0 }
    }

    /// FSK mit weich gefilterten Übergängen (gleitendes Mittel über ein Symbol).
    static func frequencies(symbols: [UInt8], rate: Double, symbolRate: Double, deviation: Double) -> [Double] {
        let sps = rate / symbolRate
        let count = Int(Double(symbols.count) * sps)
        var raw = [Double](repeating: 0, count: count)
        for n in 0..<count {
            let s = min(symbols.count - 1, Int(Double(n) / sps))
            raw[n] = symbols[s] == 1 ? deviation : -deviation
        }
        let width = max(1, Int(sps))
        var out = raw
        var sum = 0.0
        for n in 0..<count {
            sum += raw[n]
            if n >= width { sum -= raw[n - width] }
            out[n] = sum / Double(min(n + 1, width))
        }
        return out
    }

    /// Summiert Sender (Frequenzverläufe auf Versätzen) zu int8-IQ mit Rauschen.
    static func iq(rate: Double, length: Int, senders: [(offset: Double, start: Int, freq: [Double], amplitude: Double)],
                   noise: Double, seed: UInt64) -> Data {
        var rng = Random(state: seed)
        var re = [Double](repeating: 0, count: length)
        var im = [Double](repeating: 0, count: length)
        for sender in senders {
            var phase = 0.0
            for (k, f) in sender.freq.enumerated() {
                let n = sender.start + k
                guard n < length else { break }
                phase += 2 * .pi * (sender.offset + f) / rate
                if phase > .pi { phase -= 2 * .pi }
                re[n] += sender.amplitude * cos(phase)
                im[n] += sender.amplitude * sin(phase)
            }
        }
        var data = Data(count: length * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<length {
                let nr = (rng.unit() - 0.5) * 2 * noise, ni = (rng.unit() - 0.5) * 2 * noise
                p[2 * n] = Int8(max(-127, min(127, (re[n] + nr).rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, (im[n] + ni).rounded())))
            }
        }
        return data
    }
}

@Suite("Radiosonden")
struct SondeTests {
    @Test("Festhalten übernimmt einen Kanal wenige kHz daneben statt ihn zu verdoppeln")
    func pinMergesNearbyChannel() {
        let receiver = SondeReceiver()
        receiver.pin(404_101_000)
        receiver.pin(404_100_150)        // SondeHub-Frequenz derselben Sonde
        #expect(receiver.activeChannels.count == 1)
        receiver.pin(402_500_000)
        #expect(receiver.activeChannels.count == 2)
        receiver.unpin(404_100_000)
        #expect(receiver.activeChannels.map(\.frequency) == [402_500_000])
    }

    @Test("CRC-16 der RS41 ist CCITT-FALSE")
    func crc() {
        #expect(RS41.crc16(Array("123456789".utf8)[...]) == 0x29B1)
    }

    @Test("Gesendeter Kopf entspricht dem entwürfelten Kopf mit Maske")
    func headerMask() {
        var raw = RS41.rawHeader
        RS41.applyMask(&raw)
        #expect(raw == RS41.header)
    }

    @Test("Reed-Solomon korrigiert bis zu 12 Fehler je Codewort")
    func reedSolomon() {
        var rng = SondeSignal.Random(state: 7)
        let data = (0..<RS41ReedSolomon.dataLength).map { _ in UInt8(rng.next() & 0xFF) }
        let clean = RS41ReedSolomon.parity(for: data) + data
        var copy = clean
        #expect(RS41ReedSolomon.decode(&copy) == 0)
        for errors in [1, 5, 12] {
            var broken = clean
            var used = Set<Int>()
            while used.count < errors { used.insert(Int(rng.next() % 255)) }
            for position in used { broken[position] ^= UInt8(1 + rng.next() % 255) }
            #expect(RS41ReedSolomon.decode(&broken) == errors)
            #expect(broken == clean)
        }
    }

    @Test("ECEF und WGS84 rechnen hin und zurück")
    func geodesy() {
        let equator = SondeGeodesy.geodetic(x: SondeGeodesy.a, y: 0, z: 0)
        #expect(abs(equator.lat) < 1e-9 && abs(equator.lon) < 1e-9 && abs(equator.alt) < 1e-3)
        let p = SondeGeodesy.ecef(lat: 48.137, lon: 11.575, alt: 30_000)
        let back = SondeGeodesy.geodetic(x: p.x, y: p.y, z: p.z)
        #expect(abs(back.lat - 48.137) < 1e-7)
        #expect(abs(back.lon - 11.575) < 1e-7)
        #expect(abs(back.alt - 30_000) < 0.01)
    }

    @Test("RS41-Rahmen liefert Seriennummer, Position, Steigen und GPS-Zeit")
    func rs41Parse() throws {
        let frame = SondeSignal.rs41Frame(serial: "V1234567", number: 4711, lat: 52.21, lon: 14.12, alt: 12_345,
                                          north: 3, east: 4, up: 5.2, week: 2390, tow: 345_600_000)
        var calibration: [String: RS41.Calibration] = [:]
        let report = try #require(RS41.parse(frame, calibration: &calibration))
        #expect(report.serial == "V1234567")
        #expect(report.frame == 4711)
        #expect(abs(report.latitude! - 52.21) < 1e-6)
        #expect(abs(report.longitude! - 14.12) < 1e-6)
        #expect(abs(report.altitude! - 12_345) < 0.05)
        #expect(abs(report.verticalSpeed! - 5.2) < 0.02)
        #expect(abs(report.groundSpeed! - 5) < 0.02)
        #expect(abs(report.heading! - 53.13) < 0.2)
        #expect(report.satellites == 9)
        #expect(report.batteryVolts == 2.9)
        let expected = SondeGPSTime.date(week: 2390, milliseconds: 345_600_000)
        #expect(report.gpsTime == expected)
    }

    @Test("Bitstrom mit Bytefehlern: Reed-Solomon rettet den Rahmen")
    func rs41BitsWithErrors() throws {
        var frame = SondeSignal.rs41Frame(serial: "S2210012", number: 1, lat: 50.1, lon: 8.6, alt: 900,
                                          north: 0, east: 0, up: 5, week: 2390, tow: 1000)
        // Zehn Bytes in Nutz- und Paritätsbereich verfälschen (nach dem Kopf).
        for position in [20, 60, 61, 100, 150, 200, 201, 250, 290, 310] { frame[position] ^= 0x5A }
        var rng = SondeSignal.Random(state: 3)
        let bits = (0..<300).map { _ in rng.bit() } + SondeSignal.rs41Bits(frame) + (0..<100).map { _ in rng.bit() }
        let decoder = RS41Decoder()
        let reports = decoder.process(bits: bits)
        let report = try #require(reports.first)
        #expect(report.serial == "S2210012")
        #expect(abs(report.altitude! - 900) < 0.05)
        #expect(decoder.framesCorrected == 1)
        // Umgekehrte Polarität wird ebenfalls erkannt.
        let inverted = RS41Decoder().process(bits: bits.map { $0 ^ 1 })
        #expect(inverted.first?.serial == "S2210012")
    }

    @Test("Hamming(8,4) der DFM korrigiert einen Bitfehler je Wort")
    func dfmHamming() throws {
        var rng = SondeSignal.Random(state: 11)
        let data = (0..<52).map { _ in rng.bit() }
        var bits = DFMDecoder.encodeBlock(data, words: 13)
        // Je Wort ein Fehler: Wort i liegt nach dem Verschränken an i, i+13, …
        for word in 0..<13 { bits[13 * Int(rng.next() % 8) + word] ^= 1 }
        #expect(try #require(DFMDecoder.decodeBlock(bits, words: 13)) == data)
    }

    @Test("DFM-Folge liefert Seriennummer und Position")
    func dfmFrames() throws {
        var rng = SondeSignal.Random(state: 5)
        let chips = (0..<200).map { _ in rng.bit() } + SondeSignal.dfmChips(lat: 51.5, lon: 7.25, alt: 4321)
        let reports = DFMDecoder().process(chips: chips)
        let report = try #require(reports.last)
        #expect(report.serial == "123456")
        #expect(report.model == "DFM-09")
        #expect(abs(report.latitude! - 51.5) < 1e-6)
        #expect(abs(report.longitude! - 7.25) < 1e-6)
        #expect(abs(report.altitude! - 4321) < 0.01)
        #expect(abs(report.verticalSpeed! - 5.2) < 0.01)
    }

    @Test("Kanal demoduliert RS41-GFSK mit Ablage und Rauschen")
    func channelRS41() throws {
        let rate = 400_000.0
        let frame = SondeSignal.rs41Frame(serial: "T9876543", number: 9, lat: 53.0, lon: 10.0, alt: 15_000,
                                          north: -10, east: 20, up: -12, week: 2390, tow: 5000)
        var rng = SondeSignal.Random(state: 9)
        let symbols = (0..<400).map { _ in rng.bit() } + SondeSignal.rs41Bits(frame) + (0..<200).map { _ in rng.bit() }
        let freq = SondeSignal.frequencies(symbols: symbols, rate: rate, symbolRate: RS41.baudRate, deviation: 2400)
        // Sender 600 Hz neben dem Kanalraster.
        let iq = SondeSignal.iq(rate: rate, length: freq.count, senders: [(30_600, 0, freq, 40)], noise: 25, seed: 1)
        let channel = SondeChannel(offset: 30_000, inputRate: rate)
        var re = [Float](), im = [Float]()
        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<(iq.count / 2) { re.append(Float(p[2 * n]) / 128); im.append(Float(p[2 * n + 1]) / 128) }
        }
        var reports: [SondeReport] = []
        var start = 0
        while start < re.count {
            let end = min(start + 65_536, re.count)
            reports += channel.process(re: Array(re[start..<end]), im: Array(im[start..<end]))
            start = end
        }
        let report = try #require(reports.first)
        #expect(report.serial == "T9876543")
        #expect(abs(report.verticalSpeed! + 12) < 0.02)
    }

    @Test("Breitbandempfang findet und dekodiert RS41 und DFM gleichzeitig")
    func receiverBothTypes() throws {
        let rate = Double(SondeReceiver.sampleRate)
        let length = Int(rate * 1.3)
        var rng = SondeSignal.Random(state: 21)

        // RS41 bei +1,234 MHz: Füllbits, Rahmen ab 0,62 s.
        let frame = SondeSignal.rs41Frame(serial: "U5554443", number: 2, lat: 49.0, lon: 9.0, alt: 22_000,
                                          north: 1, east: 2, up: 4.8, week: 2390, tow: 9000)
        let lead = Int(0.62 * RS41.baudRate)
        let rsSymbols = (0..<lead).map { _ in rng.bit() } + SondeSignal.rs41Bits(frame) + (0..<400).map { _ in rng.bit() }
        let rsFreq = SondeSignal.frequencies(symbols: rsSymbols, rate: rate, symbolRate: RS41.baudRate, deviation: 2400)

        // DFM bei −2,1 MHz: durchgehend Rahmen.
        let dfm = SondeSignal.dfmChips(lat: 48.5, lon: 9.5, alt: 3000)
        let dfmSymbols = Array((0..<4).map { _ in dfm }.joined())
        let dfmFreq = SondeSignal.frequencies(symbols: dfmSymbols, rate: rate, symbolRate: DFMDecoder.chipRate, deviation: 3000)

        let iq = SondeSignal.iq(rate: rate, length: length,
                                senders: [(1_234_000, 0, rsFreq, 30), (-2_100_000, 0, dfmFreq, 30)], noise: 12, seed: 2)
        let receiver = SondeReceiver()
        let block = 262_144
        var offset = 0
        while offset < iq.count {
            receiver.process(iq.subdata(in: offset..<min(offset + block, iq.count)))
            offset += block
        }
        let channels = receiver.activeChannels.map(\.frequency)
        #expect(channels.contains { abs($0 - 404_234_000) <= 2000 })
        #expect(channels.contains { abs($0 - 400_900_000) <= 2000 })
        let reports = receiver.takeReports()
        let rs = try #require(reports.first { $0.kind == .rs41 })
        #expect(rs.serial == "U5554443")
        #expect(abs(rs.altitude! - 22_000) < 0.05)
        #expect(abs(rs.frequency - 404_234_000) <= 2000)
        let df = try #require(reports.last { $0.kind == .dfm })
        #expect(df.serial == "123456")
        #expect(abs(df.latitude! - 48.5) < 1e-6)
    }

    @Test("Trägersuche übergeht schmale Störlinien")
    func carrierDetection() {
        var spectrum = [Float](repeating: -90, count: 8192)
        for k in 5000...5006 { spectrum[k] = -60 }   // Sonde, 7 Bins
        spectrum[3000] = -40                          // Störlinie, 1 Bin
        let found = SondeReceiver.carriers(in: spectrum, sampleRate: 10_000_000, threshold: 8)
        #expect(found.count == 1)
        let expected = (5003.0 - 4096) * 10_000_000 / 8192
        #expect(abs(found[0] - expected) < 100)
    }

    @Test("Verfolgung erkennt das Platzen und schätzt eine Landung")
    func trackerAndLanding() throws {
        var tracker = SondeTracker()
        var report = SondeReport(kind: .rs41, serial: "V1", model: "RS41")
        report.latitude = 52; report.longitude = 13; report.altitude = 30_000; report.verticalSpeed = 5
        tracker.ingest(report)
        report.altitude = 28_000; report.verticalSpeed = -20; report.groundSpeed = 10; report.heading = 90
        tracker.ingest(report)
        let sonde = try #require(tracker.sorted.first)
        #expect(sonde.burst)
        #expect(sonde.trail.count == 2)
        let landing = try #require(sonde.landing(groundAltitude: 100))
        // Restzeit liegt über der linearen Schätzung (27,9 km bei 20 m/s ≈ 1395 s).
        #expect(landing.seconds > 1395 && landing.seconds < 6000)
        #expect(landing.lon > 13 && abs(landing.lat - 52) < 0.01)
    }

    @Test("Dauerstörer: ab Werk leer, eingetragene Bereiche werden übergangen")
    func blockedCarriers() {
        let list = SondeBlockList(persistent: false)
        #expect(list.isFactory && list.current.isEmpty)
        #expect(!list.contains(403_910_000))
        #expect(list.contains(400_000_000))                    // unter dem Sondenband nie
        list.set([400_655_000...400_675_000, 403_903_000...403_920_000, 404_625_000...404_650_000])
        for mhz in [399.920, 400.000, 400.667, 403.906, 403.917, 404.637] {
            #expect(list.contains(mhz * 1e6), "\(mhz)")
        }
        for mhz in [402.500, 403.900, 404.100, 404.500, 404.600, 405.700] {
            #expect(!list.contains(mhz * 1e6), "\(mhz)")
        }
        list.set([])
        #expect(!list.contains(403_910_000))
        #expect(list.contains(400_000_000))
        list.set([403_000_000...403_010_000])
        #expect(list.contains(403_005_000))
        list.resetToFactory()
        #expect(list.isFactory)
    }

    @Test("Dauerstörer: Eingabe in MHz und gespeicherte Form")
    func blockListParsing() throws {
        #expect(SondeBlockList.parseMHz("403,903–403,920") == 403_903_000...403_920_000)
        #expect(SondeBlockList.parseMHz(" 403.920 - 403.903 MHz") == 403_903_000...403_920_000)
        let single = try #require(SondeBlockList.parseMHz("404,637"))
        #expect(abs(single.lowerBound - 404_632_000) < 1 && abs(single.upperBound - 404_642_000) < 1)
        #expect(SondeBlockList.parseMHz("433,92") == nil)
        #expect(SondeBlockList.parseMHz("abc") == nil)
        #expect(SondeBlockList.parseMHz("403,9–x") == nil)
        let ranges: [ClosedRange<Double>] = [400_655_000...400_675_000, 403_903_000...403_920_000]
        let lines = ranges.map(SondeBlockList.format)
        #expect(lines.first == "400655000-400675000")
        #expect(SondeBlockList.parse(lines: lines + ["kaputt", "5-1"]) == ranges)
    }

    // MARK: - Bitfehlerrate des Kanals (Simulation)

    /// RS41-ähnliches GFSK (BT 0,5, ±2,4 kHz, 4800 Bd) bei 400 kS/s mit
    /// komplexem Gaußrauschen für das gegebene Eb/N0, Träger bei `offset` Hz.
    static func gfsk(bits: [UInt8], ebn0: Double, offset: Double, seed: UInt64) -> (re: [Float], im: [Float]) {
        let rate = 400_000.0, baud = RS41.baudRate, sps = rate / baud
        let count = Int(Double(bits.count) * sps)
        let nrz = (0..<count).map { bits[min(bits.count - 1, Int(Double($0) / sps))] == 1 ? 1.0 : -1.0 }
        let sigma = (log(2.0)).squareRoot() / (2 * .pi * 0.5) * sps
        let span = Int(3 * sps)
        var kernel = (-span...span).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var rng = SondeSignal.Random(state: seed)
        func gauss() -> Double {
            let u = max(rng.unit(), 1e-300), v = rng.unit()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        let amplitude = 0.1
        let noise = (amplitude * amplitude * rate / (baud * 2 * pow(10, ebn0 / 10))).squareRoot()
        var re = [Float](repeating: 0, count: count), im = re
        var phase = 0.0
        for n in 0..<count {
            var shaped = 0.0
            for (k, w) in kernel.enumerated() {
                let i = n + k - span
                if i >= 0, i < count { shaped += w * nrz[i] }
            }
            phase += 2 * .pi * (2400 * shaped + offset) / rate
            re[n] = Float(amplitude * cos(phase) + noise * gauss())
            im[n] = Float(amplitude * sin(phase) + noise * gauss())
        }
        return (re, im)
    }

    /// Bitfehlerrate mit blockweiser Ausrichtung (250 Bit, ±6 Bit Schlupf
    /// zulässig); die ersten 300 Bit dienen dem Einschwingen.
    static func bitErrorRate(sent: [UInt8], received: [UInt8]) -> Double {
        var lag = 0, errors = 0, counted = 0, k = 300
        while k + 250 < sent.count - 50 {
            var best = Int.max, bestLag = lag
            for l in (lag - 6)...(lag + 6) {
                var e = 0
                for q in k..<(k + 250) {
                    let j = q + l
                    if j < 0 || j >= received.count || received[j] != sent[q] { e += 1 }
                }
                if e < best { best = e; bestLag = l }
            }
            lag = bestLag; errors += best; counted += 250; k += 250
        }
        return Double(errors) / Double(counted)
    }

    @Test("Kanal: Bitfehlerrate RS41 über Eb/N0 – neu (AFC, 6-kHz-Filter, Symbolmittel) gegen alt")
    func bitErrorRateRS41() {
        var rng = SondeSignal.Random(state: 42)
        let bits = (0..<5000).map { _ in rng.bit() }
        let sps = SondeChannel.channelRate / RS41.baudRate
        var table: [String] = []
        for offset in [500.0, 3000.0] {
            for ebn0 in [8.0, 10.0, 12.0] {
                let (re, im) = Self.gfsk(bits: bits, ebn0: ebn0, offset: offset, seed: UInt64(ebn0 * 10 + offset))
                let channel = SondeChannel(offset: 0, inputRate: 400_000)
                let legacy = LegacySondeChannel(inputRate: 400_000)
                let slicer = SondeSlicer(samplesPerSymbol: sps)
                var newSoft: [Float] = [], oldSoft: [Float] = []
                var start = 0
                while start < re.count {
                    let end = min(start + 65_536, re.count)
                    newSoft += channel.demodulate(re: Array(re[start..<end]), im: Array(im[start..<end]))
                    oldSoft += legacy.demodulate(re: Array(re[start..<end]), im: Array(im[start..<end]))
                    start = end
                }
                let new = Self.bitErrorRate(sent: bits, received: slicer.process(newSoft))
                let old = Self.bitErrorRate(sent: bits, received: LegacySondeChannel.slice(oldSoft, samplesPerSymbol: sps))
                table.append(String(format: "Ablage %4.0f Hz, Eb/N0 %2.0f dB: alt %.4f, neu %.4f", offset, ebn0, old, new))
                #expect(new <= old + 0.002, "\(table.last!)")
                if ebn0 == 10 { #expect(new < 0.05 && old > 0.1, "\(table.last!)") }
                if ebn0 == 12 { #expect(new < 0.01, "\(table.last!)") }
            }
        }
        print(table.joined(separator: "\n"))
    }

    @Test("Sonde genau auf der Bandmitte (403,000 MHz) wird gefunden, ein Gleichanteil allein nicht")
    func carrierAtCenter() throws {
        let rate = Double(SondeReceiver.sampleRate)
        var rng = SondeSignal.Random(state: 31)
        let frame = SondeSignal.rs41Frame(serial: "M4030000", number: 3, lat: 52.0, lon: 10.0, alt: 8000,
                                          north: 1, east: 1, up: 5, week: 2390, tow: 7000)
        let lead = Int(0.62 * RS41.baudRate)
        let symbols = (0..<lead).map { _ in rng.bit() } + SondeSignal.rs41Bits(frame) + (0..<400).map { _ in rng.bit() }
        let freq = SondeSignal.frequencies(symbols: symbols, rate: rate, symbolRate: RS41.baudRate, deviation: 2400)
        var iq = SondeSignal.iq(rate: rate, length: Int(rate * 1.3), senders: [(0, 0, freq, 30)], noise: 12, seed: 4)
        // HackRF-Gleichanteil (Oszillator-Durchgriff) obendrauf.
        iq.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<(p.count / 2) { p[2 * n] = Int8(clamping: Int(p[2 * n]) + 9); p[2 * n + 1] = Int8(clamping: Int(p[2 * n + 1]) - 6) }
        }
        let receiver = SondeReceiver()
        let block = 262_144
        var offset = 0
        while offset < iq.count {
            receiver.process(iq.subdata(in: offset..<min(offset + block, iq.count)))
            offset += block
        }
        // Vorher: Träger in ±1,5 kHz um die Mitte verworfen – kein Kanal, keine Meldung.
        #expect(receiver.activeChannels.contains { abs($0.frequency - 403_000_000) <= 2000 })
        let report = try #require(receiver.takeReports().first { $0.kind == .rs41 })
        #expect(report.serial == "M4030000")

        // Nur Rauschen + Gleichanteil: kein Kanal an der Mitte.
        var dcOnly = SondeSignal.iq(rate: rate, length: Int(rate * 1.0), senders: [], noise: 12, seed: 5)
        dcOnly.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in 0..<(p.count / 2) { p[2 * n] = Int8(clamping: Int(p[2 * n]) + 9); p[2 * n + 1] = Int8(clamping: Int(p[2 * n + 1]) - 6) }
        }
        let quiet = SondeReceiver()
        offset = 0
        while offset < dcOnly.count {
            quiet.process(dcOnly.subdata(in: offset..<min(offset + block, dcOnly.count)))
            offset += block
        }
        #expect(quiet.activeChannels.isEmpty, "\(quiet.activeChannels.map(\.frequency))")
    }

    @Test("Basisbandfilter: Drohnen-BLE wie die BLE-Seite 0,75·fs; FLARM war schon richtig")
    func basebandFilters() {
        // `setSampleRate` stellt ≈ 0,75·fs ein. Drohnen setzten danach 8 MHz (volle Rate).
        #expect(HackRFDevice.basebandFilter(for: UInt32(BLEDemodulator.inputRate * 0.75)) == 6_000_000)
        #expect(HackRFDevice.basebandFilter(for: UInt32(BLEDemodulator.inputRate)) == 8_000_000)
        // FLARM (2 MS/s): beide Wege ergeben das kleinste Filter, 1,75 MHz – der Review-Fund trifft hier nicht zu.
        #expect(HackRFDevice.basebandFilter(for: UInt32(FLARMDemodulator.inputRate)) == 1_750_000)
        #expect(HackRFDevice.basebandFilter(for: UInt32(FLARMDemodulator.inputRate * 0.75)) == 1_750_000)
    }
}
