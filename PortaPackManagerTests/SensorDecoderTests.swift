import Foundation
import Testing
@testable import PortaPackManager

/// Bitzeilen stammen aus den rtl_433-Testaufnahmen (`merbanan/rtl_433_tests`),
/// mit dieser App demoduliert; die erwarteten Werte aus den zugehörigen
/// `.json`-Dateien von rtl_433.
@Suite("Funksensoren: Dekoder")
struct SensorDecoderTests {
    private func rows(_ row: String, times: Int) -> SensorBitBuffer {
        .parse(Array(repeating: row, count: times).joined(separator: " "))
    }

    private func bytes(_ hex: String) -> [UInt8] {
        let chars = Array(hex)
        return stride(from: 0, to: chars.count - 1, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! }
    }

    @Test("Hexdarstellung hin und zurück")
    func parseRoundTrip() {
        let buffer = SensorBitBuffer.parse("{36}b510bef470 {5}f8")
        #expect(buffer.rows.count == 2)
        #expect(buffer.rows[0].hex == "{36}b510bef470")
        #expect(buffer.rows[1].hex == "{5}f8")
        #expect(buffer.inverted().rows[1].hex == "{5}00")
        #expect(buffer.search(row: 0, pattern: [0x10, 0xBE], bits: 16) == 8)
    }

    @Test("Nexus-TH aus einer Aufnahme (tests/nexus/01)")
    func nexusTH() throws {
        let reading = try #require(SensorDecoders.nexus(rows("{36}b510bef470", times: 12)))
        #expect(reading.model == "Nexus-TH")
        #expect(reading.id == "181")
        #expect(reading.channel == 2)
        #expect(reading.batteryOK == false)
        #expect(reading.temperatureC == 19.0)
        #expect(reading.humidity == 71)
    }

    @Test("Nexus-T: Technoline TX9116 (tests/nexus/02)")
    func nexusT() throws {
        let reading = try #require(SensorDecoders.nexus(rows("{36}b780f9f000", times: 12)))
        #expect(reading.model == "Nexus-T")
        #expect(reading.id == "183")
        #expect(reading.channel == 1)
        #expect(reading.batteryOK == true)
        #expect(reading.temperatureC == 24.9)
        #expect(reading.humidity == nil)
    }

    @Test("Nexus braucht drei gleiche Wiederholungen")
    func nexusRepeats() {
        #expect(SensorDecoders.nexus(rows("{36}b510bef470", times: 2)) == nil)
    }

    @Test("Prologue nach Formatbeschreibung")
    func prologue() throws {
        // Typ 9, ID 0x5A, Batterie gut, Kanal 2, 21,3 °C, 47 %
        let reading = try #require(SensorDecoders.prologue(rows("{36}95a90d52f0", times: 5)))
        #expect(reading.model == "Prologue-TH")
        #expect(reading.id == "90")
        #expect(reading.channel == 2)
        #expect(reading.batteryOK == true)
        #expect(reading.temperatureC == 21.3)
        #expect(reading.humidity == 47)
    }

    @Test("inFactory mit CRC-4 (tests/infactory_PV-8796-675)")
    func inFactory() throws {
        let reading = try #require(SensorDecoders.inFactory(.parse("{40}0f305ce761")))
        #expect(reading.id == "15")
        #expect(reading.channel == 1)
        #expect(reading.temperatureC == 14.8)       // 58,6 °F
        #expect(reading.humidity == 76)
        #expect(SensorDecoders.inFactory(.parse("{40}0f305ce771")) == nil)
    }

    @Test("LaCrosse TX141-Bv2, -Bv3 und TX141W")
    func lacrosseTX141() throws {
        let bv2 = try #require(SensorDecoders.lacrosseTX141(rows("{37}8a6d42e338", times: 12)))
        #expect(bv2.model == "LaCrosse-TX141Bv2")
        #expect(bv2.id == "75")                      // 117
        #expect(bv2.channel == 1)
        #expect(bv2.temperatureC == 20.1)
        #expect(bv2.batteryOK == true)

        let bv3 = try #require(SensorDecoders.lacrosseTX141(rows("{33}de6d403680", times: 4)))
        #expect(bv3.model == "LaCrosse-TX141Bv3")
        #expect(bv3.id == "21")                      // 33
        #expect(bv3.temperatureC == 20.3)

        let w = try #require(SensorDecoders.lacrosseTX141(.parse("{1}80 " + Array(repeating: "{65}f6a9befedc8faeb780", count: 6).joined(separator: " "))))
        #expect(w.model == "LaCrosse-TX141W")
        #expect(w.id == "15641")                     // 87617
        #expect(w.temperatureC == 6.7)
        #expect(w.humidity == 81)
    }

    @Test("LaCrosse TX141TH-Bv2: eine Zeile mit gültigem Digest genügt (rtl_433 #2206)")
    func lacrosseTX141TH() throws {
        let reading = try #require(SensorDecoders.lacrosseTX141(.parse("{41}18eed3f56180 {41}19eed3f56180 {41}18eed2f56180 {41}18eed3f46180")))
        #expect(reading.model == "LaCrosse-TX141THBv2")
        #expect(reading.id == "e7")                  // 231
        #expect(reading.channel == 1)
        #expect(reading.temperatureC == -20.0)
        #expect(reading.humidity == 10)
        #expect(reading.integrity == "CRC")
    }

    @Test("Bresser 5-in-1 aus einer Aufnahme (tests/bresser_5in1/01)")
    func bresser5in1() throws {
        let reading = try #require(SensorDecoders.bresser5in1(.parse("{287}00555555555516ea7544bff097eff7bfffb6fdff7f8abb400f6810084000490200800000")))
        #expect(reading.id == "118")
        #expect(reading.temperatureC == 8.0)
        #expect(reading.humidity == 92)
        #expect(reading.windGustMS == 3.0)
        #expect(reading.windAverageMS == 2.0)
        #expect(reading.windDirection == 292.5)
        #expect(reading.rainMM == 10.4)

        let second = try #require(SensorDecoders.bresser5in1(.parse("{286}00aaaaaaaaaa2dd4e9897febffdcef86ff6dfbfeff167680140023107900920401000000")))
        #expect(second.temperatureC == 7.9)
        #expect(second.windAverageMS == 2.3)
    }

    @Test("Bresser 5-in-1: Beispiele aus der rtl_433-Beschreibung")
    func bresser5in1Examples() throws {
        let strong = try #require(SensorDecoders.bresser5in1(message: bytes("e3fd7f897e8aed68feaf9bfdff1c0280768175129701506402000000")))
        #expect(strong.windGustMS == 37.4)
        #expect(strong.windAverageMS == 27.5)
        let cold = try #require(SensorDecoders.bresser5in1(message: bytes("eda1ffff1fffef8fffd6dfff77125e0000e00010700029200088000")))
        #expect(cold.temperatureC == -7.0)
        #expect(cold.batteryOK == false)
        var broken = bytes("e3fd7f897e8aed68feaf9bfdff1c0280768175129701506402000000")
        broken[3] ^= 1
        #expect(SensorDecoders.bresser5in1(message: broken) == nil)
    }

    @Test("Bresser 6-in-1 aus Aufnahmen (tests/bresser_6in1/01)")
    func bresser6in1() throws {
        let reading = try #require(SensorDecoders.bresser6in1(.parse("{204}d55555555516ea2f550c4001618c7d47fd93b408c240fff83900")))
        #expect(reading.id == "188002c3")            // 411042499
        #expect(reading.channel == 0)
        #expect(reading.batteryOK == false)
        #expect(reading.temperatureC == 11.8)
        #expect(reading.humidity == 81)
        #expect(reading.windGustMS == 5.7)
        #expect(reading.windAverageMS == 4.0)
        #expect(reading.windDirection == 276)
        #expect(reading.uvIndex == 0)

        let wind = try #require(SensorDecoders.bresser6in1(.parse("{207}555555555516ea140f0c4001618c7ddbfe132c7fffffff80b0fe")))
        #expect(wind.windGustMS == 4.4)
        #expect(wind.windAverageMS == 3.8)
        #expect(wind.windDirection == 265)
        #expect(wind.rainMM == 0)
        #expect(wind.temperatureC == nil)

        // ein gekipptes Bit fällt beim Digest auf
        #expect(SensorDecoders.bresser6in1(.parse("{204}d55555555516ea2f550c4001618c7d47fd93b408c241fff83900")) == nil)
    }

    @Test("Bresser 7-in-1 und Luftgütesensoren: Beispiele aus der rtl_433-Beschreibung")
    func bresser7in1() throws {
        let weather = try #require(SensorDecoders.bresser7in1(message: bytes("9a59b4a5a3da10aaaaaaaaaaaaaa8bdac8afea28a8caaaaaaa")))
        #expect(weather.lightLux == 54_082)          // „54.0 klx UV=2.6“
        #expect(weather.uvIndex == 2.6)
        #expect(weather.temperatureC == 21.7)

        let co2 = try #require(SensorDecoders.bresser7in1(message: bytes("dab6d782acd9a1ad9aad9aad9aaaaaaaaaaaaaaaaae99aaaaa00")))
        #expect(co2.model == "Bresser-CO2")
        #expect(co2.extra["CO₂"] == "673 ppm")

        let voc = try #require(SensorDecoders.bresser7in1(message: bytes("3f2dc4a5aaafb1aaa8aaa8aaa8aaaaaaaaaaaaaaaae9feaaaa00")))
        #expect(voc.extra["Formaldehyd"] == "5 ppb")
        #expect(voc.extra["VOC-Stufe"] == "4")
    }

    @Test("LaCrosse IT+: TX29 und TX35 (tests/lacrosse/tx29-it_tx35dth-it)")
    func lacrosseIT() throws {
        let tx29 = try #require(SensorDecoders.lacrosseIT(.parse("{64}aa2dd49284486aec"), model: "LaCrosse-TX29IT"))
        #expect(tx29.id == "10")
        #expect(tx29.temperatureC == 4.8)
        #expect(tx29.humidity == nil)
        #expect(tx29.extra["Neue Batterie"] == nil)

        let fresh = try #require(SensorDecoders.lacrosseIT(.parse("{64}aa2dd492a6386a22"), model: "LaCrosse-TX29IT"))
        #expect(fresh.temperatureC == 23.8)
        #expect(fresh.extra["Neue Batterie"] == "ja")

        let tx35 = try #require(SensorDecoders.lacrosseIT(.parse("{80}aaaaaa2dd496a6412250"), model: "LaCrosse-TX35DTHIT"))
        #expect(tx35.id == "26")
        #expect(tx35.temperatureC == 24.1)
        #expect(tx35.humidity == 34)

        #expect(SensorDecoders.lacrosseIT(.parse("{80}aaaaaa2dd496a6412251"), model: "LaCrosse-TX35DTHIT") == nil)
    }

    @Test("Prüfsummen wie rtl_433")
    func checksums() {
        // TX29-Beispiel aus lacrosse_tx35.c: CRC-8 (0x31) über 4 Byte = 0xEC
        #expect(SensorChecksum.crc8([0x92, 0x84, 0x48, 0x6A], polynomial: 0x31, initial: 0) == 0xEC)
        // TX141TH-Digest der Testzeile (invertiert): e7 11 2c 0a → 9e
        #expect(SensorChecksum.lfsrDigest8Reflect([0xE7, 0x11, 0x2C, 0x0A], generator: 0x31, key: 0xF4) == 0x9E)
        // Bresser 6-in-1: LFSR-16-Digest 0x5eaa
        let msg: [UInt8] = [0x5E, 0xAA, 0x18, 0x80, 0x02, 0xC3, 0x18, 0xFA, 0x8F, 0xFB, 0x27, 0x68, 0x11, 0x84, 0x81, 0xFF, 0xF0, 0x72]
        #expect(SensorChecksum.lfsrDigest16(Array(msg[2..<17]), generator: 0x8810, key: 0x5412) == 0x5EAA)
        #expect(SensorChecksum.addBytes(Array(msg[2..<18])) & 0xFF == 0xFF)
    }
}

@Suite("Funksensoren: Slicer und Pulsanalyse")
struct SensorSlicerTests {
    /// PPM wie Nexus: Puls 500 µs, Pause 1000 (0) / 2000 (1), Sync 4000.
    private func ppmTrain(_ bits: [UInt8], repeats: Int) -> SensorPulseTrain {
        var pulses: [Int] = [], gaps: [Int] = []
        for _ in 0..<repeats {
            for bit in bits {
                pulses.append(500)
                gaps.append(bit == 1 ? 2000 : 1000)
            }
            pulses.append(500)
            gaps.append(4000)
        }
        gaps[gaps.count - 1] = 20_000
        return SensorPulseTrain(modulation: .ook, pulses: pulses, gaps: gaps)
    }

    private func bits(_ hex: String, count: Int) -> [UInt8] {
        SensorBitBuffer.parse("{\(count)}\(hex)").rows[0].bytes.flatMap { byte in (0..<8).map { (byte >> (7 - UInt8($0))) & 1 } }.prefix(count).map { $0 }
    }

    @Test("PPM-Slicer trennt Wiederholungen an der Sync-Pause")
    func ppm() {
        let train = ppmTrain(bits("b510bef470", count: 36), repeats: 4)
        let buffers = SensorSlicer.ppm(train, short: 1000, long: 2000, gapLimit: 3000, reset: 5000)
        #expect(buffers.count == 1)
        #expect(buffers[0].rows.filter { $0.count == 36 }.count == 4)
        #expect(buffers[0].rows[0].hex == "{36}b510bef470")
    }

    @Test("PCM-Slicer gleicht Bitzeit und Puls/Pausen-Versatz aus")
    func pcmFit() {
        // Bitfolge mit langen Läufen, Bitzeit 122 statt 124 µs, Pulse +2, Pausen −18 µs
        let pattern: [UInt8] = [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1]
        var pulses: [Int] = [], gaps: [Int] = []
        var index = 0
        while index < pattern.count {
            var ones = 0
            while index < pattern.count && pattern[index] == 1 { ones += 1; index += 1 }
            var zeros = 0
            while index < pattern.count && pattern[index] == 0 { zeros += 1; index += 1 }
            pulses.append(ones * 122 + 2)
            gaps.append(zeros == 0 ? 0 : zeros * 122 - 18)
        }
        let buffers = SensorSlicer.pcm(SensorPulseTrain(modulation: .fsk, pulses: pulses, gaps: gaps), bitWidth: 124, reset: 25_000)
        let row = buffers[0].rows[0]
        #expect((0..<row.count).map { row.bit($0) } == pattern)
    }

    @Test("Pulsanalyse erkennt PPM, PWM und NRZ")
    func analyzer() {
        let ppm = SensorAnalyzer.analyze(ppmTrain(bits("b510bef470", count: 36), repeats: 3))
        #expect(ppm.coding == .ppm)
        #expect(ppm.shortWidth == 1000)
        #expect(ppm.longWidth == 2000)
        #expect(ppm.rows.first == "{36}b510bef470")

        // PWM mit fester Periode 625 µs: 1 = 208/417, 0 = 417/208
        let pwmBits = bits("8a6d42e338", count: 37)
        let pwm = SensorAnalyzer.analyze(SensorPulseTrain(
            modulation: .ook,
            pulses: pwmBits.map { $0 == 1 ? 208 : 417 },
            gaps: pwmBits.enumerated().map { $0.offset == pwmBits.count - 1 ? 10_000 : ($0.element == 1 ? 417 : 208) }))
        #expect(pwm.coding == .pwmFixedPeriod)
        #expect(pwm.rows.first == "{37}8a6d42e338")

        // NRZ: Läufe von 1–3 Bit à 100 µs
        let nrz = SensorAnalyzer.analyze(SensorPulseTrain(
            modulation: .fsk,
            pulses: [100, 200, 300, 100, 200, 300, 100, 100],
            gaps: [100, 300, 200, 100, 200, 300, 100, 1000]))
        #expect(nrz.coding == .pcm)
        #expect(nrz.shortWidth == 100)
    }
    @Test("TPMS: CRC-geprüfte Rahmung liefert ID und Rohbytes (eigener Vektor)")
    func tpms() throws {
        // 9-Byte-Rahmen (8 Daten + CRC-8/0x07 init 0x80). ID = erste 4 Byte.
        var data: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x20, 0x4A, 0x18, 0x03]
        let crc = SensorChecksum.crc8(data, polynomial: 0x07, initial: 0x80)
        data.append(crc)
        let bitString = "{72}" + data.map { String(format: "%02x", $0) }.joined()
        let reading = try #require(SensorDecoders.tpms(.parse(bitString)))
        #expect(reading.model == "TPMS")
        #expect(reading.id == "12345678")
        #expect(reading.integrity == "CRC")
        #expect(reading.extra["Länge"] == "9 Byte")
        // Falsches CRC → kein Treffer.
        data[8] ^= 1
        #expect(SensorDecoders.tpms(.parse("{72}" + data.map { String(format: "%02x", $0) }.joined())) == nil)
    }

}
