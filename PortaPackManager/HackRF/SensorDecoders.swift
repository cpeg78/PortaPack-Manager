import Foundation

/// Ein dekodierter Sensorwert. Felder, die das Modell nicht liefert, sind `nil`.
struct SensorReading: Sendable, Equatable {
    var model: String
    var id: String
    var channel: Int?
    var batteryOK: Bool?
    var temperatureC: Double?
    var humidity: Int?
    var windAverageMS: Double?
    var windGustMS: Double?
    var windDirection: Double?
    var rainMM: Double?
    var uvIndex: Double?
    var lightLux: Double?
    /// Weitere Werte (Feuchte im Boden, CO₂ …) als Klartext.
    var extra: [String: String] = [:]
    /// Wie die Nachricht abgesichert ist: „CRC“, „Prüfsumme“ oder „keine“.
    var integrity: String

    /// Kennung eines Sensors über Pakete hinweg.
    var key: String { "\(model)|\(id)|\(channel.map(String.init) ?? "-")" }

    /// Anzeigename eines Zusatzwerts. Die Schlüssel in `extra` bleiben deutsch,
    /// weil MQTT (`MQTTFeeds.extraValue`) und die Handy-Seite sie als Kennung nutzen.
    static func extraLabel(_ key: String) -> String {
        switch key {
        case "Untertyp": String(localized: "Untertyp")
        case "Taste": String(localized: "Taste")
        case "Test": String(localized: "Test")
        case "Rohdaten": String(localized: "Rohdaten")
        case "Länge": String(localized: "Länge")
        case "Sensortyp": String(localized: "Sensortyp")
        case "Bodenfeuchte": String(localized: "Bodenfeuchte")
        case "Neustart": String(localized: "Neustart")
        case "Globetemperatur": String(localized: "Globetemperatur")
        case "Formaldehyd": String(localized: "Formaldehyd")
        case "VOC-Stufe": String(localized: "VOC-Stufe")
        case "Neue Batterie": String(localized: "Neue Batterie")
        default: key
        }
    }
}

/// Die Dekoder. Jeder ist ein Nachbau des gleichnamigen rtl_433-Dekoders:
/// Slicer-Parameter, Prüfungen und Feldaufteilung stammen von dort
/// (`src/devices/*.c`). Die Bit-Funktionen sind öffentlich, damit die
/// Tests sie direkt mit Bitfolgen aus rtl_433 füttern können.
enum SensorDecoders {
    struct Decoder: Sendable {
        let name: String
        let modulation: SensorPulseTrain.Modulation
        let run: @Sendable (SensorPulseTrain) -> [SensorReading]
    }

    static let all: [Decoder] = [
        Decoder(name: "Nexus / FreeTec NC-7345 / TFA 30.3209", modulation: .ook) { train in
            SensorSlicer.ppm(train, short: 1000, long: 2000, gapLimit: 3000, reset: 5000).compactMap(nexus)
        },
        Decoder(name: "Prologue / ThermoPro TX2", modulation: .ook) { train in
            SensorSlicer.ppm(train, short: 2000, long: 4000, gapLimit: 7000, reset: 10_000).compactMap(prologue)
        },
        Decoder(name: "inFactory / nor-tec / FreeTec NC-3982", modulation: .ook) { train in
            SensorSlicer.ppm(train, short: 2000, long: 4000, reset: 5000, sync: 500, tolerance: 750).compactMap(inFactory)
        },
        // Deckt mit denselben Grenzen auch TX141W/TX145wsdth (256/500/748 µs) ab.
        Decoder(name: "LaCrosse TX141 / TX141W / TFA 30.3221", modulation: .ook) { train in
            SensorSlicer.pwm(train, short: 208, long: 417, sync: 833, gapLimit: 625, reset: 1700).compactMap(lacrosseTX141)
        },
        Decoder(name: "Bresser 5-in-1", modulation: .fsk) { train in
            bothPolarities(SensorSlicer.pcm(train, bitWidth: 124, reset: 25_000), bresser5in1)
        },
        Decoder(name: "Bresser 6-in-1 / 7-in-1 innen / Thermo-Hygro 7 Kanal", modulation: .fsk) { train in
            bothPolarities(SensorSlicer.pcm(train, bitWidth: 124, reset: 25_000), bresser6in1)
        },
        Decoder(name: "Bresser 7-in-1 / Luftgüte", modulation: .fsk) { train in
            bothPolarities(SensorSlicer.pcm(train, bitWidth: 124, reset: 25_000), bresser7in1)
        },
        Decoder(name: "LaCrosse TX29-IT / TFA 30.3159.IT", modulation: .fsk) { train in
            bothPolarities(SensorSlicer.pcm(train, bitWidth: 55, reset: 4000)) { lacrosseIT($0, model: "LaCrosse-TX29IT") }
        },
        Decoder(name: "LaCrosse TX35DTH-IT / TFA 30.3155", modulation: .fsk) { train in
            bothPolarities(SensorSlicer.pcm(train, bitWidth: 105, reset: 4000)) { lacrosseIT($0, model: "LaCrosse-TX35DTHIT") }
        },
        // Reifendruck (TPMS) auf 433,92 MHz, FSK differentiell-Manchester. Rahmung
        // und CRC nach rtl_433; Druck/Temperatur sind geräteabhängig und werden
        // hier bewusst NICHT gedeutet (nur ID, Rohbytes, CRC – belegbar ohne
        // echte Aufnahme). Siehe tpmsCRC8.
        Decoder(name: "TPMS (Toyota / generisch, FSK)", modulation: .fsk) { train in
            // Front-End ungewiss ohne echte Aufnahme: NRZ (52 µs) und Manchester
            // (26 µs Halbbit) probieren – das CRC verwirft Fehlschnitte.
            var buffers = SensorSlicer.pcm(train, bitWidth: 52, reset: 2000)
            buffers.append(SensorAnalyzer.manchester(train, halfBit: 26, reset: 2000))
            return buffers.compactMap(tpms)
        },
    ]

    /// Alle passenden Dekoder auf ein Paket anwenden; doppelte Treffer
    /// (Wiederholungen, mehrere Dekoder derselben Familie) zusammenfassen.
    static func decode(_ train: SensorPulseTrain) -> [SensorReading] {
        var readings: [SensorReading] = []
        for decoder in all where decoder.modulation == train.modulation {
            for reading in decoder.run(train) where !readings.contains(reading) {
                readings.append(reading)
            }
        }
        return readings
    }

    /// FSK-Polarität ist je Hersteller verschieden – beide versuchen.
    private static func bothPolarities(_ buffers: [SensorBitBuffer],
                                       _ decode: (SensorBitBuffer) -> SensorReading?) -> [SensorReading] {
        buffers.compactMap { decode($0) ?? decode($0.inverted()) }
    }

    // MARK: - Nexus (rtl_433 `nexus.c`)

    /// 36 Bit, mindestens 3 gleiche Wiederholungen:
    /// `[id:8] [Batt:1 Test:1 Kanal:2] [Temp:12, ×0,1 °C, signed] [1111] [Feuchte:8]`.
    static func nexus(_ bits: SensorBitBuffer) -> SensorReading? {
        guard let r = bits.repeatedRow(minRepeats: 3, minBits: 36), bits.rows[r].count <= 37 else { return nil }
        let b = bits.rows[r].bytes + [0, 0, 0, 0, 0]
        guard b[3] & 0xF0 == 0xF0 else { return nil }
        if (b[0] == 0 && b[2] == 0 && b[3] == 0) || (b[0] == 0xFF && b[2] == 0xFF && b[3] == 0xFF) { return nil }
        guard b[1] & 0x30 != 0x30 else { return nil }
        // Gleiches Layout wie Rubicson/Solight TE44, dort ist das letzte Byte
        // eine CRC – passt sie, ist es kein Nexus.
        let crcInput = [b[0], b[1], b[2], b[3] & 0xF0, (b[3] & 0x0F) << 4 | (b[4] & 0xF0) >> 4]
        guard SensorChecksum.crc8(crcInput, polynomial: 0x31, initial: 0x6C) != 0 else { return nil }
        let tempRaw = Int16(bitPattern: UInt16(b[1]) << 12 | UInt16(b[2]) << 4) >> 4
        let humidity = Int((b[3] & 0x0F) << 4 | b[4] >> 4)
        guard humidity == 0 || humidity <= 100 else { return nil }
        return SensorReading(model: humidity == 0 ? "Nexus-T" : "Nexus-TH",
                             id: String(b[0]),
                             channel: Int((b[1] & 0x30) >> 4) + 1,
                             batteryOK: b[1] & 0x80 != 0,
                             temperatureC: Double(tempRaw) / 10,
                             humidity: humidity == 0 ? nil : humidity,
                             integrity: String(localized: "keine"))
    }

    // MARK: - Prologue (rtl_433 `prologue.c`)

    /// 36 Bit, mindestens 4 Wiederholungen:
    /// `[Typ:4 = 5|9] [id:8] [Batt:1 Taste:1 Kanal:2] [Temp:12] [Feuchte:8, 0xCC = keine]`.
    static func prologue(_ bits: SensorBitBuffer) -> SensorReading? {
        if let first = bits.rows.first, first.count <= 8 && first.count != 0 { return nil }
        guard let r = bits.repeatedRow(minRepeats: 4, minBits: 36), bits.rows[r].count <= 37 else { return nil }
        let b = bits.rows[r].bytes + [0, 0, 0, 0, 0]
        guard b[0] & 0xF0 == 0x90 || b[0] & 0xF0 == 0x50 else { return nil }
        let id = Int(b[0] & 0x0F) << 4 | Int(b[1] & 0xF0) >> 4
        let tempRaw = Int16(bitPattern: UInt16(b[2]) << 8 | UInt16(b[3] & 0xF0)) >> 4
        let humidity = Int((b[3] & 0x0F) << 4 | b[4] >> 4)
        var reading = SensorReading(model: "Prologue-TH", id: String(id),
                                    channel: Int(b[1] & 0x03) + 1,
                                    batteryOK: b[1] & 0x08 != 0,
                                    temperatureC: Double(tempRaw) / 10,
                                    humidity: humidity == 0xCC ? nil : humidity,
                                    integrity: String(localized: "keine"))
        reading.extra["Untertyp"] = String(b[0] >> 4)
        if b[1] & 0x04 != 0 { reading.extra["Taste"] = String(localized: "gedrückt") }
        return reading
    }

    // MARK: - inFactory (rtl_433 `infactory.c`)

    /// 40 Bit: `[id:8] [CRC4] [Taste:1 Batt:1 ?:2] [Temp:12, °F ×0,1 +90] [Feuchte:BCD 8] [?:2 Kanal:2]`.
    static func inFactory(_ bits: SensorBitBuffer) -> SensorReading? {
        guard let row = bits.rows.first, [40, 41, 42].contains(row.count) else { return nil }
        let b = row.bytes + [0]
        let channel = Int(b[4] & 0x03)
        guard channel != 0 else { return nil }
        // CRC-4: Kanalbits stehen bei der Berechnung an der CRC-Stelle.
        var message = Array(b[0..<5])
        let received = message[1] >> 4
        message[1] = (message[1] & 0x0F) | (message[4] & 0x0F) << 4
        let crc = SensorChecksum.crc4(Array(message[0..<4]), polynomial: 0x13, initial: 0) ^ (message[4] >> 4)
        guard crc == received else { return nil }
        let tempRaw = Int(b[2]) << 4 | Int(b[3] >> 4)
        let humidity = Int(b[3] & 0x0F) * 10 + Int(b[4] >> 4)
        let fahrenheit = Double(tempRaw - 900) / 10
        guard humidity <= 100, fahrenheit >= -40, fahrenheit <= 158 else { return nil }
        var reading = SensorReading(model: "inFactory-TH", id: String(b[0]), channel: channel,
                                    batteryOK: (b[1] >> 2) & 1 == 0,
                                    temperatureC: ((fahrenheit - 32) * 5 / 9 * 10).rounded() / 10,
                                    humidity: humidity, integrity: "CRC")
        if (b[1] >> 3) & 1 != 0 { reading.extra["Taste"] = String(localized: "gedrückt") }
        return reading
    }

    // MARK: - LaCrosse TX141 (rtl_433 `lacrosse_tx141x.c`)

    /// PWM, invertiert. Länge bestimmt das Modell: 32 (TX141B), 33 (Bv3),
    /// 37 (Bv2), 40/41 (TH-Bv2 mit LFSR-Digest), 65 (TX141W, CRC-8).
    static func lacrosseTX141(_ raw: SensorBitBuffer) -> SensorReading? {
        let bits = raw.inverted()
        var r = bits.repeatedRow(minRepeats: bits.rows.count > 5 ? 5 : 3, minBits: 32)
        if r == nil { r = bits.repeatedRow(minRepeats: 2, minBits: 64) }
        if r == nil && bits.rows.count <= 4 {
            r = bits.rows.indices.first { row in
                let current = bits.rows[row]
                guard current.count == 40 || current.count == 41 else { return false }
                return SensorChecksum.lfsrDigest8Reflect(Array(current.bytes[0..<4]), generator: 0x31, key: 0xF4) == current.bytes[4]
            }
        }
        guard let r else { return nil }
        let length = bits.rows[r].count
        let b = bits.rows[r].bytes + [UInt8](repeating: 0, count: 9)

        if length >= 64 {
            guard b[0] >> 3 == 0x01 else { return nil }
            guard SensorChecksum.crc8(Array(b[0..<8]), polynomial: 0x31, initial: 0) == 0 else { return nil }
            let id = String(format: "%05x", Int(b[0] & 0x07) << 16 | Int(b[1]) << 8 | Int(b[2]))
            let type = b[3] & 0x0F
            let tempRaw = Int(b[4]) << 4 | Int(b[5] >> 4)
            let second = Int(b[5] & 0x0F) << 8 | Int(b[6])
            var reading = SensorReading(model: "LaCrosse-TX141W", id: id, channel: Int((b[3] & 0x30) >> 4),
                                        batteryOK: b[3] >> 7 == 0, integrity: "CRC")
            switch type {
            case 1:
                reading.temperatureC = Double(tempRaw - 500) / 10
                reading.humidity = second
            case 2:
                reading.windAverageMS = Double(tempRaw) / 10 / 3.6
                reading.windDirection = Double(second)
            default:
                return nil
            }
            return reading
        }
        guard length <= 41 else { return nil }
        if length >= 41 && bits.rows.count > 12 { return nil }
        let isTH = length >= 40
        let model = isTH ? "LaCrosse-TX141THBv2"
            : length >= 37 ? "LaCrosse-TX141Bv2"
            : length == 32 ? "LaCrosse-TX141B" : "LaCrosse-TX141Bv3"
        let batteryLow = isTH ? b[1] >> 7 == 1 : b[1] >> 7 == 0
        let tempC = Double(Int(b[1] & 0x0F) << 8 | Int(b[2]) - 500) / 10
        let humidity = isTH ? Int(b[3]) : 0
        guard b[0] != 0, !(isTH && (humidity == 0 || humidity > 100)), tempC >= -40, tempC <= 140 else { return nil }
        if isTH {
            guard SensorChecksum.lfsrDigest8Reflect(Array(b[0..<4]), generator: 0x31, key: 0xF4) == b[4] else { return nil }
        }
        var reading = SensorReading(model: model, id: String(format: "%02x", b[0]),
                                    channel: length == 32 ? nil : Int((b[1] & 0x30) >> 4),
                                    batteryOK: !batteryLow, temperatureC: tempC,
                                    humidity: isTH ? humidity : nil,
                                    integrity: isTH ? "CRC" : "keine")
        if b[1] & 0x40 != 0 { reading.extra["Test"] = String(localized: "ja") }
        return reading
    }

    // MARK: - Bresser (rtl_433 `bresser_5in1.c`, `bresser_6in1.c`, `bresser_7in1.c`)

    private static func bcd(_ byte: UInt8) -> Int { Int(byte >> 4) * 10 + Int(byte & 0x0F) }

    // MARK: - TPMS (Reifendruck)

    /// TPMS-Rahmen: nach der Synchronisation CRC-8 (Poly 0x07) über die
    /// Nutzbytes. Geprüft werden zwei verbreitete Längen (Toyota 8+1,
    /// generisch 9+1); ein Treffer liefert Sensor-ID (erste 4 Byte) und die
    /// Rohbytes. **Druck und Temperatur werden nicht gedeutet** – deren
    /// Skalierung ist je Hersteller verschieden und hier nicht gegen echte
    /// Aufnahmen geprüft; das CRC schützt vor Fehltreffern im Rauschen.
    static func tpms(_ bits: SensorBitBuffer) -> SensorReading? {
        guard bits.rows.count == 1 else { return nil }
        // Toyota-Präambel (rtl_433 tpms_toyota): differentiell-Manchester,
        // Sync 0x19 ... hier über die CRC-Suche statt fester Präambel.
        let row = bits.rows[0]
        guard row.count >= 72 else { return nil }
        for length in [9, 8, 10] {
            // Alle Byte-Ausrichtungen durchsuchen, an denen das CRC über die
            // ersten (length-1) Bytes dem letzten Byte entspricht.
            let total = length * 8
            var offset = 0
            while offset + total <= row.count {
                let bytes = bits.extract(row: 0, from: offset, bits: total)
                let data = Array(bytes.dropLast())
                if SensorChecksum.crc8(data, polynomial: 0x07, initial: 0x80) == bytes.last
                    || SensorChecksum.crc8(data, polynomial: 0x07, initial: 0x00) == bytes.last,
                   bytes.contains(where: { $0 != 0 }), bytes.contains(where: { $0 != 0xFF }) {
                    let id = data.prefix(4).map { String(format: "%02x", $0) }.joined()
                    var reading = SensorReading(model: "TPMS", id: id, integrity: "CRC")
                    reading.extra["Rohdaten"] = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    reading.extra["Länge"] = "\(length) Byte"
                    return reading
                }
                offset += 8
            }
        }
        return nil
    }

    /// Nutzdaten hinter der Präambel (`aaaa…2dd4`), sonst `nil`.
    private static func payload(_ bits: SensorBitBuffer, preamble: [UInt8], bytes: Int, minimum: Int? = nil) -> [UInt8]? {
        guard bits.rows.count == 1,
              let start = bits.search(row: 0, pattern: preamble, bits: preamble.count * 8) else { return nil }
        let begin = start + preamble.count * 8
        let available = bits.rows[0].count - begin
        guard available >= (minimum ?? bytes * 8) else { return nil }
        return bits.extract(row: 0, from: begin, bits: bytes * 8)
    }

    /// 26 Byte nach `aaaaaa2dd4`; die ersten 13 sind die invertierten letzten 13.
    static func bresser5in1(_ bits: SensorBitBuffer) -> SensorReading? {
        guard let first = bits.rows.first, first.count >= 248,
              let msg = payload(bits, preamble: [0xAA, 0xAA, 0xAA, 0x2D, 0xD4], bytes: 26, minimum: 25 * 8 + 1) else { return nil }
        return bresser5in1(message: msg)
    }

    static func bresser5in1(message msg: [UInt8]) -> SensorReading? {
        guard msg.count >= 26 else { return nil }
        for col in 0..<13 where msg[col] ^ msg[col + 13] != 0xFF { return nil }
        let tempOK = msg[20] & 0x0F <= 9
        var tempRaw = Int(msg[20] & 0x0F) + Int(msg[20] >> 4) * 10 + Int(msg[21] & 0x0F) * 100
        if msg[25] & 0x0F != 0 { tempRaw = -tempRaw }
        let humidityOK = msg[22] & 0x0F <= 9
        let gustRaw = Int(msg[17] & 0x0F) << 8 + Int(msg[16])
        let windRaw = Int(msg[18] & 0x0F) + Int(msg[18] >> 4) * 10 + Int(msg[19] & 0x0F) * 100
        var rain = Double(Int(msg[23] & 0x0F) + Int(msg[23] >> 4) * 10 + Int(msg[24] & 0x0F) * 100 + Int(msg[24] >> 4) * 1000) / 10
        let sensorType = msg[15] & 0x7F
        let batteryOK = msg[25] & 0x80 == 0
        if (0x39...0x3B).contains(sensorType) {
            rain *= 2.5
            return SensorReading(model: "Bresser-ProRainGauge", id: String(msg[14]), batteryOK: batteryOK,
                                 temperatureC: tempOK ? Double(tempRaw) / 10 : nil, rainMM: rain, integrity: String(localized: "Prüfsumme"))
        }
        return SensorReading(model: "Bresser-5in1", id: String(msg[14]), batteryOK: batteryOK,
                             temperatureC: tempOK ? Double(tempRaw) / 10 : nil,
                             humidity: humidityOK ? bcd(msg[22]) : nil,
                             windAverageMS: Double(windRaw) / 10, windGustMS: Double(gustRaw) / 10,
                             windDirection: Double(msg[17] >> 4) * 22.5, rainMM: rain, integrity: String(localized: "Prüfsumme"))
    }

    /// 18 Byte nach `aaaa2dd4`: LFSR-16-Digest (0x8810/0x5412) und Summe 0xFF.
    static func bresser6in1(_ bits: SensorBitBuffer) -> SensorReading? {
        guard let first = bits.rows.first, first.count >= 160,
              let msg = payload(bits, preamble: [0xAA, 0xAA, 0x2D, 0xD4], bytes: 18) else { return nil }
        return bresser6in1(message: msg)
    }

    static func bresser6in1(message original: [UInt8]) -> SensorReading? {
        guard original.count >= 18 else { return nil }
        var msg = original
        let digest = SensorChecksum.lfsrDigest16(Array(msg[2..<17]), generator: 0x8810, key: 0x5412)
        guard UInt16(msg[0]) << 8 | UInt16(msg[1]) == digest else { return nil }
        guard SensorChecksum.addBytes(Array(msg[2..<18])) & 0xFF == 0xFF else { return nil }
        let id = UInt32(msg[2]) << 24 | UInt32(msg[3]) << 16 | UInt32(msg[4]) << 8 | UInt32(msg[5])
        let sensorType = Int(msg[6] >> 4)
        let channel = Int(msg[6] & 0x07)
        let battery = (msg[13] >> 1) & 1 == 1
        let tempOK = msg[12] <= 0x99 && msg[13] & 0xF0 <= 0x90
        let tempRaw = Int(msg[12] >> 4) * 100 + Int(msg[12] & 0x0F) * 10 + Int(msg[13] >> 4)
        var tempC = Double(tempRaw) / 10
        if (msg[13] >> 3) & 1 == 1 { tempC = Double(tempRaw - 1000) / 10 }
        if tempC < -50 { tempC = -Double(tempRaw) / 10 }
        let humidity = bcd(msg[14])
        let notUV15 = ~msg[15], notUV16 = ~msg[16]
        var uvOK = msg[16] & 0x0F == 0 && notUV15 <= 0x99 && notUV16 & 0xF0 <= 0x90
        let uvRaw = Int(notUV15 >> 4) * 100 + Int(notUV15 & 0x0F) * 10 + Int(notUV16 >> 4)
        msg[7] ^= 0xFF; msg[8] ^= 0xFF; msg[9] ^= 0xFF
        var windOK = msg[7] <= 0x99 && msg[8] <= 0x99 && msg[9] <= 0x99
        let gust = Int(msg[7] >> 4) * 100 + Int(msg[7] & 0x0F) * 10 + Int(msg[8] >> 4)
        let average = Int(msg[9] >> 4) * 100 + Int(msg[9] & 0x0F) * 10 + Int(msg[8] & 0x0F)
        let direction = Int(msg[10] >> 4) * 100 + Int(msg[10] & 0x0F) * 10 + Int(msg[11] >> 4)
        msg[12] ^= 0xFF; msg[13] ^= 0xFF; msg[14] ^= 0xFF
        let rainOK = msg[16] & 1 == 1
        let rainRaw = Int(msg[12] >> 4) * 100_000 + Int(msg[12] & 0x0F) * 10_000 + Int(msg[13] >> 4) * 1000
            + Int(msg[13] & 0x0F) * 100 + Int(msg[14] >> 4) * 10 + Int(msg[14] & 0x0F)
        if sensorType == 2 || sensorType == 4 { windOK = false; uvOK = false }
        let moistureMap = [0, 7, 13, 20, 27, 33, 40, 47, 53, 60, 67, 73, 80, 87, 93, 99]
        let moisture = sensorType == 4 && tempOK && (1...16).contains(humidity) ? moistureMap[humidity - 1] : nil

        var reading = SensorReading(model: "Bresser-6in1", id: String(format: "%08x", id), channel: channel,
                                    batteryOK: rainOK ? nil : battery,
                                    temperatureC: tempOK ? tempC : nil,
                                    humidity: tempOK && moisture == nil ? humidity : nil,
                                    windAverageMS: windOK ? Double(average) / 10 : nil,
                                    windGustMS: windOK ? Double(gust) / 10 : nil,
                                    windDirection: windOK ? Double(direction) : nil,
                                    rainMM: rainOK ? Double(rainRaw) / 10 : nil,
                                    uvIndex: uvOK ? Double(uvRaw) / 10 : nil,
                                    integrity: "CRC")
        reading.extra["Sensortyp"] = String(sensorType)
        if let moisture { reading.extra["Bodenfeuchte"] = "\(moisture) %" }
        return reading
    }

    /// 25 Byte nach `aaaaaa2dd4`, mit 0xAA geweißt; LFSR-16-Digest
    /// (0x8810/0xBA95, Endwert XOR 0x6DF1).
    static func bresser7in1(_ bits: SensorBitBuffer) -> SensorReading? {
        guard let first = bits.rows.first, first.count >= 160,
              let msg = payload(bits, preamble: [0xAA, 0xAA, 0xAA, 0x2D, 0xD4], bytes: 25, minimum: 21 * 8 + 1) else { return nil }
        return bresser7in1(message: msg)
    }

    static func bresser7in1(message raw: [UInt8]) -> SensorReading? {
        guard raw.count >= 25, raw[21] != 0 else { return nil }
        let sensorType = Int(raw[6] >> 4)
        let notStartup = (raw[6] & 0x08) >> 3
        let channel = Int(raw[6] & 0x07)
        let msg = raw.map { $0 ^ 0xAA }
        let digest = SensorChecksum.lfsrDigest16(Array(msg[2..<25]), generator: 0x8810, key: 0xBA95)
        guard (UInt16(msg[0]) << 8 | UInt16(msg[1])) ^ digest == 0x6DF1 else { return nil }
        let id = String(Int(msg[2]) << 8 | Int(msg[3]))
        let batteryLow = msg[15] & 0x06 == 0x06
        var reading = SensorReading(model: "Bresser-7in1", id: id, batteryOK: !batteryLow, integrity: "CRC")
        if notStartup == 0 { reading.extra["Neustart"] = String(localized: "ja") }
        switch sensorType {
        case 1, 12, 13:
            let direction = Int(msg[4] >> 4) * 100 + Int(msg[4] & 0x0F) * 10 + Int(msg[5] >> 4)
            let gust = Int(msg[7] >> 4) * 100 + Int(msg[7] & 0x0F) * 10 + Int(msg[8] >> 4)
            let average = Int(msg[8] & 0x0F) * 100 + Int(msg[9] >> 4) * 10 + Int(msg[9] & 0x0F)
            let rain = Int(msg[10] >> 4) * 100_000 + Int(msg[10] & 0x0F) * 10_000 + Int(msg[11] >> 4) * 1000
                + Int(msg[11] & 0x0F) * 100 + Int(msg[12] >> 4) * 10 + Int(msg[12] & 0x0F)
            let tempRaw = Int(msg[14] >> 4) * 100 + Int(msg[14] & 0x0F) * 10 + Int(msg[15] >> 4)
            let light = Int(msg[17] >> 4) * 100_000 + Int(msg[17] & 0x0F) * 10_000 + Int(msg[18] >> 4) * 1000
                + Int(msg[18] & 0x0F) * 100 + Int(msg[19] >> 4) * 10 + Int(msg[19] & 0x0F)
            let uv = Int(msg[20] >> 4) * 100 + Int(msg[20] & 0x0F) * 10 + Int(msg[21] >> 4)
            reading.temperatureC = tempRaw > 600 ? Double(tempRaw - 1000) / 10 : Double(tempRaw) / 10
            reading.humidity = bcd(msg[16])
            reading.rainMM = Double(rain) / 10
            if sensorType != 12 {
                reading.windGustMS = Double(gust) / 10
                reading.windAverageMS = Double(average) / 10
                reading.windDirection = Double(direction)
                reading.lightLux = Double(light)
                reading.uvIndex = Double(uv) / 10
            }
            if sensorType == 13, msg[23] >> 4 < 10 {
                let globe = Double(msg[22] >> 4) * 10 + Double(msg[22] & 0x0F) + Double(msg[23] >> 4) / 10
                reading.extra["Globetemperatur"] = String(format: "%.1f °C", globe)
            }
        case 8:
            reading.model = "Bresser-Air-PM"
            reading.channel = channel
            if msg[10] & 0x0F != 0x0F {
                let pm25 = Int(msg[10] & 0x0F) * 1000 + Int(msg[11] >> 4) * 100 + Int(msg[11] & 0x0F) * 10 + Int(msg[12] >> 4)
                reading.extra["PM2,5"] = "\(pm25) µg/m³"
            }
            if msg[12] & 0x0F != 0x0F {
                let pm10 = Int(msg[12] & 0x0F) * 1000 + Int(msg[13] >> 4) * 100 + Int(msg[13] & 0x0F) * 10 + Int(msg[14] >> 4)
                reading.extra["PM10"] = "\(pm10) µg/m³"
            }
        case 10:
            reading.model = "Bresser-CO2"
            reading.channel = channel
            if msg[5] & 0x0F != 0x0F {
                reading.extra["CO₂"] = "\(Int(msg[4] >> 4) * 1000 + Int(msg[4] & 0x0F) * 100 + bcd(msg[5])) ppm"
            }
        case 11:
            reading.model = "Bresser-HCHO-VOC"
            reading.channel = channel
            if msg[5] & 0x0F != 0x0F {
                reading.extra["Formaldehyd"] = "\(Int(msg[4] >> 4) * 1000 + Int(msg[4] & 0x0F) * 100 + bcd(msg[5])) ppb"
            }
            if msg[22] & 0x0F != 0x0F { reading.extra["VOC-Stufe"] = String(msg[22] & 0x0F) }
        default:
            return nil
        }
        return reading
    }

    // MARK: - LaCrosse IT+ (rtl_433 `lacrosse_tx35.c`)

    /// Sucht `a2dd49` (Präambelrest, Sync 2dd4, Modell 9) und liest 5 Byte:
    /// `[9:4 id:6 neu:1 ?:1 Temp:BCD 12, +40 °C] [schwach:1 Feuchte:7] [CRC-8 0x31]`.
    static func lacrosseIT(_ bits: SensorBitBuffer, model: String) -> SensorReading? {
        for row in bits.rows.indices {
            guard let start = bits.search(row: row, pattern: [0xA2, 0xDD, 0x49], bits: 24),
                  start + 20 + 40 <= bits.rows[row].count else { continue }
            let b = bits.extract(row: row, from: start + 20, bits: 40)
            guard SensorChecksum.crc8(Array(b[0..<4]), polynomial: 0x31, initial: 0) == b[4] else { continue }
            var id = Int(b[0] & 0x0F) << 2 | Int(b[1] >> 6)
            let temp = 10 * Double(b[1] & 0x0F) + Double(b[2] >> 4) + 0.1 * Double(b[2] & 0x0F) - 40
            let humidity = Int(b[3] & 0x7F)
            let noHumidity = humidity == 0x6A || humidity == 0x7D
            if humidity == 0x7D { id += 0x40 }
            var reading = SensorReading(model: model, id: String(id), batteryOK: b[3] >> 7 == 0,
                                        temperatureC: (temp * 10).rounded() / 10,
                                        humidity: noHumidity ? nil : humidity, integrity: "CRC")
            if (b[1] >> 5) & 1 == 1 { reading.extra["Neue Batterie"] = String(localized: "ja") }
            return reading
        }
        return nil
    }
}
