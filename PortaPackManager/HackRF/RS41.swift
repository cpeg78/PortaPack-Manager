import Foundation

/// Eine dekodierte Meldung einer Radiosonde – gemeinsam für alle Typen.
struct SondeReport: Sendable, Equatable {
    enum Kind: String, Sendable { case rs41 = "RS41", dfm = "DFM" }

    var kind: Kind
    var serial: String
    var model: String
    var frame: Int?
    var latitude: Double?
    var longitude: Double?
    /// Höhe in Metern (RS41: über dem WGS84-Ellipsoid, DFM je nach Modus).
    var altitude: Double?
    /// Horizontalgeschwindigkeit in m/s, Kurs in Grad, Steigrate in m/s.
    var groundSpeed: Double?
    var heading: Double?
    var verticalSpeed: Double?
    var satellites: Int?
    var gpsTime: Date?
    var batteryVolts: Double?
    var temperature: Double?
    var humidity: Double?
    /// Luftdruck in hPa – nur RS41-SGP mit Drucksensor.
    var pressure: Double?
    /// Temperatur des beheizten Feuchtesensors (°C, RS41).
    var humiditySensorTemperature: Double?
    /// Feuchte nach dem Herstellerverfahren (Sensortemperatur, Druck) statt der
    /// empirischen Näherung.
    var humidityCorrected = false
    /// Aus dem Kalibrierblock (RS41), sobald das jeweilige Fragment da war.
    var configuration = SondeConfiguration()
    /// Zusatzinstrumente (RS41 XDATA, z. B. Ozonsonde).
    var instruments: [SondeInstrument] = []
    /// Zellstrom der ersten Ozonzelle (µA), für Archiv und Profil.
    var ozoneCurrent: Double? { instruments.lazy.compactMap(\.cellCurrent).first }
    var encrypted = false
    /// Mittenfrequenz des Kanals in Hz (setzt der Empfänger).
    var frequency: Double = 0
}

/// Einstellungen, die eine RS41 über ihre Kalibrierfragmente verteilt meldet
/// (rs41mod: `get_Calconf`). Jedes Feld nur, wenn das Fragment empfangen ist.
struct SondeConfiguration: Sendable, Equatable {
    /// Modell, z. B. „RS41-SG“, „RS41-SGP“ (mit Drucksensor).
    var subtype: String?
    /// Hauptplatine, z. B. „RSM414“.
    var mainboard: String?
    /// Eingestellte Sendefrequenz (MHz).
    var frequencyMHz: Double?
    var firmware: Int?
    /// Abschaltung nach Platzen aktiv (burst kill).
    var burstKill: Bool?
    /// Eingestellte Abschaltzeit nach dem Start (s), 0xFFFF = keine.
    var killTimer: Int?
    /// Laufender Abschalt-Countdown (s) – nur gültig, wenn Abschaltung aktiv.
    var countdown: Int?

    /// Abschalt-Countdown, wenn die Sonde wirklich abschalten wird.
    var activeCountdown: Int? {
        guard let countdown, countdown != 0xFFFF, countdown > 0,
              burstKill == true || (killTimer.map { $0 != 0xFFFF } ?? false) else { return nil }
        return countdown
    }
}

/// Ein Zusatzinstrument an der Sonde (RS41 XDATA; rs41mod: `prn_aux_IDx..`).
struct SondeInstrument: Sendable, Equatable {
    /// Instrumentenkennung (0x01 Ozon ECC, 0x05 OIF411, 0x08 CFH …).
    var id: Int
    var number: Int
    /// Zellstrom der Ozonzelle (µA) – proportional zum Ozon-Partialdruck.
    var cellCurrent: Double?
    var pumpTemperature: Double?
    /// Pumpenstrom (mA).
    var pumpCurrent: Double?
    var batteryVolts: Double?
    /// Seriennummer des Instruments (OIF411-Kennungsmeldung).
    var serial: String?

    var name: String {
        switch id {
        case 0x01: String(localized: "Ozonsonde (ECC)")
        case 0x05: String(localized: "Ozonsonde (OIF411)")
        case 0x08: String(localized: "Frostpunkt-Hygrometer (CFH)")
        default: String(localized: "Zusatzinstrument 0x\(String(format: "%02X", id))")
        }
    }

    /// Neue Meldung über die alte legen: Messwerte ersetzen, die Seriennummer
    /// (eigene Kennungsmeldung des OIF411) bleibt.
    static func merge(_ old: [SondeInstrument], with new: [SondeInstrument]) -> [SondeInstrument] {
        var result = old
        for instrument in new {
            guard let i = result.firstIndex(where: { $0.id == instrument.id && $0.number == instrument.number }) else {
                result.append(instrument)
                continue
            }
            if instrument.serial != nil { result[i].serial = instrument.serial }
            if instrument.cellCurrent != nil || instrument.pumpTemperature != nil {
                let serial = result[i].serial
                result[i] = instrument
                result[i].serial = instrument.serial ?? serial
            }
        }
        return result
    }

    /// Instrumente aus dem XDATA-Text (Hex-Ziffern, mehrere durch „#“ getrennt).
    static func parse(_ xdata: String) -> [SondeInstrument] {
        xdata.split(separator: "#").compactMap { part in
            let hex = Array(part)
            func value(_ offset: Int, _ count: Int) -> Int? {
                guard offset + count <= hex.count else { return nil }
                return Int(String(hex[offset..<(offset + count)]), radix: 16)
            }
            guard let id = value(0, 2), let number = value(2, 2) else { return nil }
            var instrument = SondeInstrument(id: id, number: number)
            switch id {
            case 0x01:
                guard let cell = value(4, 4), let pump = value(8, 4), let ipump = value(12, 2), let vbat = value(14, 2) else { return nil }
                instrument.cellCurrent = Double(cell) / 1000
                instrument.pumpTemperature = Double(Int16(truncatingIfNeeded: pump)) / 100
                instrument.pumpCurrent = Double(ipump)
                instrument.batteryVolts = Double(vbat) / 10
            case 0x05:
                if hex.count > 20, hex[20] == "I" {
                    // Kennungsmeldung: Seriennummer statt Messwerten.
                    instrument.serial = String(hex[4..<12])
                } else {
                    guard let pump = value(4, 4), let cell = value(8, 5), let vbat = value(13, 2),
                          let ipump = value(15, 3) else { return nil }
                    instrument.pumpTemperature = Double(Int16(truncatingIfNeeded: pump)) / 100
                    instrument.cellCurrent = Double(cell) / 10000
                    instrument.batteryVolts = Double(vbat) / 10
                    instrument.pumpCurrent = Double(ipump)
                }
            default:
                break
            }
            return instrument
        }
    }
}

// MARK: - Erdellipsoid

/// Umrechnung ECEF ↔ WGS84 (Breite/Länge/Ellipsoidhöhe).
enum SondeGeodesy {
    static let a = 6_378_137.0
    static let b = 6_356_752.314_245_18
    static let e2 = (a * a - b * b) / (a * a)
    static let ee2 = (a * a - b * b) / (b * b)

    /// Bowring-Näherung, wie in rs41mod; Fehler im Millimeterbereich.
    static func geodetic(x: Double, y: Double, z: Double) -> (lat: Double, lon: Double, alt: Double) {
        let lon = atan2(y, x)
        let p = (x * x + y * y).squareRoot()
        let t = atan2(z * a, p * b)
        let st = sin(t), ct = cos(t)
        let phi = atan2(z + ee2 * b * st * st * st, p - e2 * a * ct * ct * ct)
        let r = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let alt = p / cos(phi) - r
        return (phi * 180 / .pi, lon * 180 / .pi, alt)
    }

    static func ecef(lat: Double, lon: Double, alt: Double) -> (x: Double, y: Double, z: Double) {
        let phi = lat * .pi / 180, lam = lon * .pi / 180
        let r = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        return ((r + alt) * cos(phi) * cos(lam),
                (r + alt) * cos(phi) * sin(lam),
                (r * (1 - e2) + alt) * sin(phi))
    }

    /// ECEF-Geschwindigkeit → Nord/Ost/Oben am Ort `lat`/`lon`.
    static func neu(vx: Double, vy: Double, vz: Double, lat: Double, lon: Double) -> (north: Double, east: Double, up: Double) {
        let phi = lat * .pi / 180, lam = lon * .pi / 180
        let north = -vx * sin(phi) * cos(lam) - vy * sin(phi) * sin(lam) + vz * cos(phi)
        let east = -vx * sin(lam) + vy * cos(lam)
        let up = vx * cos(phi) * cos(lam) + vy * cos(phi) * sin(lam) + vz * sin(phi)
        return (north, east, up)
    }
}

/// GPS-Zeit → Datum (UTC). Schaltsekunden: 18 s seit 2017.
enum SondeGPSTime {
    static let epoch = Date(timeIntervalSince1970: 315_964_800)   // 06.01.1980
    static let leapSeconds = 18.0

    static func date(week: Int, milliseconds: Int) -> Date {
        epoch.addingTimeInterval(Double(week) * 604_800 + Double(milliseconds) / 1000 - leapSeconds)
    }
}

// MARK: - RS41

/// Vaisala RS41: GFSK 4800 Bd, Rahmen zu 320 (oder 518) Byte, LSB zuerst,
/// mit einer 64-Byte-Maske verwürfelt. Aufbau nach rs1729/RS (`rs41mod.c`).
enum RS41 {
    static let baudRate = 4800.0
    static let standardLength = 320
    static let extendedLength = 518
    static let headerLength = 8

    /// Kopf nach dem Entwürfeln.
    static let header: [UInt8] = [0x86, 0x35, 0xF4, 0x40, 0x93, 0xDF, 0x1A, 0x60]
    /// Kopf, wie er gesendet wird (= `header` XOR `mask`).
    static let rawHeader: [UInt8] = [0x10, 0xB6, 0xCA, 0x11, 0x22, 0x96, 0x12, 0xF8]

    static let mask: [UInt8] = [
        0x96, 0x83, 0x3E, 0x51, 0xB1, 0x49, 0x08, 0x98, 0x32, 0x05, 0x59, 0x0E, 0xF9, 0x44, 0xC6, 0x26,
        0x21, 0x60, 0xC2, 0xEA, 0x79, 0x5D, 0x6D, 0xA1, 0x54, 0x69, 0x47, 0x0C, 0xDC, 0xE8, 0x5C, 0xF1,
        0xF7, 0x76, 0x82, 0x7F, 0x07, 0x99, 0xA2, 0x2C, 0x93, 0x7C, 0x30, 0x63, 0xF5, 0x10, 0x2E, 0x61,
        0xD0, 0xBC, 0xB4, 0xB6, 0x06, 0xAA, 0xF4, 0x23, 0x78, 0x6E, 0x3B, 0xAE, 0xBF, 0x7B, 0x4C, 0xC1,
    ]

    /// Lage im Rahmen.
    static let frameTypePosition = 0x38
    static let firstBlock = 0x39
    static let parityPosition = 8
    static let messagePosition = 56

    /// Blockkennungen (erstes Byte jedes Blocks).
    enum Block: UInt8 {
        case status = 0x79, measurement = 0x7A, gpsPosition = 0x7B, gpsInfo = 0x7C, gpsRaw = 0x7D
        case aux = 0x7E, padding = 0x76, sgmTU = 0x7F, encrypted = 0x80
    }

    /// CRC-16/CCITT-FALSE (Polynom 0x1021, Start 0xFFFF), wie im Rahmen.
    static func crc16(_ data: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// Verwürfeln und Entwürfeln sind dieselbe Operation.
    static func applyMask(_ bytes: inout [UInt8]) {
        for i in bytes.indices { bytes[i] ^= mask[i % mask.count] }
    }

    /// 0x0F: Standardrahmen, 0xF0: verlängert. Mehrheitsentscheid über die
    /// Bits, damit ein einzelner Bitfehler die Länge nicht verfälscht.
    static func isExtended(_ frame: [UInt8]) -> Bool {
        let b = frame[frameTypePosition]
        var score = 0
        for i in 0..<4 { score += Int((b >> i) & 1) - Int((b >> (i + 4)) & 1) }
        return score < 0
    }

    // MARK: Reed-Solomon

    /// Zwei verschränkte RS(255,231)-Codewörter: Paritäten bei 8…55, Nutzdaten
    /// ab 56 abwechselnd auf beide verteilt, Rest mit Nullen aufgefüllt.
    /// Korrigiert `frame` (entwürfelt, volle Länge) an Ort und Stelle.
    /// Liefert die Zahl korrigierter Bytes oder `nil`, wenn ein Wort nicht
    /// korrigierbar war.
    @discardableResult
    static func correct(_ frame: inout [UInt8]) -> Int? {
        let length = frame.count
        var total = 0
        var ok = true
        for word in 0..<2 {
            var cw = [UInt8](repeating: 0, count: 255)
            for i in 0..<RS41ReedSolomon.parity { cw[i] = frame[parityPosition + word * RS41ReedSolomon.parity + i] }
            for i in 0..<RS41ReedSolomon.dataLength {
                let pos = messagePosition + 2 * i + word
                if pos < length { cw[RS41ReedSolomon.parity + i] = frame[pos] }
            }
            guard let fixed = RS41ReedSolomon.decode(&cw) else { ok = false; continue }
            total += fixed
            for i in 0..<RS41ReedSolomon.parity { frame[parityPosition + word * RS41ReedSolomon.parity + i] = cw[i] }
            for i in 0..<RS41ReedSolomon.dataLength {
                let pos = messagePosition + 2 * i + word
                if pos < length { frame[pos] = cw[RS41ReedSolomon.parity + i] }
            }
        }
        return ok ? total : nil
    }

    /// Setzt die Paritätsbytes (für Tests und den Rahmenbau).
    static func addParity(_ frame: inout [UInt8]) {
        for word in 0..<2 {
            var data = [UInt8](repeating: 0, count: RS41ReedSolomon.dataLength)
            for i in 0..<RS41ReedSolomon.dataLength {
                let pos = messagePosition + 2 * i + word
                if pos < frame.count { data[i] = frame[pos] }
            }
            let parity = RS41ReedSolomon.parity(for: data)
            for i in 0..<RS41ReedSolomon.parity { frame[parityPosition + word * RS41ReedSolomon.parity + i] = parity[i] }
        }
    }

    // MARK: Auswertung

    /// Kalibrierdaten sammeln sich über 51 Rahmen (je 16 Byte).
    struct Calibration: Sendable {
        var bytes = [UInt8](repeating: 0, count: 51 * 16)
        var received = [Bool](repeating: false, count: 51)
        /// Rahmennummer, mit der das Countdown-Fragment (0x32) zuletzt kam – es
        /// kommt nur alle 51 Rahmen, dazwischen wird weitergezählt.
        var countdownFrame: Int?

        func has(_ fragments: ClosedRange<Int>) -> Bool { fragments.allSatisfy { received[$0] } }

        func float(at offset: Int) -> Float {
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
    }

    /// Seriennummer nur aus Großbuchstaben A–Z und Ziffern, 1…8 Zeichen.
    static func isValidSerial(_ serial: String) -> Bool {
        !serial.isEmpty && serial.utf8.count <= 8
            && serial.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
    }

    /// Wertet einen entwürfelten, korrigierten Rahmen aus. Nur Blöcke mit
    /// gültiger CRC fließen ein; ohne gültigen Statusblock gibt es kein Ergebnis.
    static func parse(_ frame: [UInt8], calibration: inout [String: Calibration]) -> SondeReport? {
        var report = SondeReport(kind: .rs41, serial: "", model: "RS41")
        var measurements: [UInt8]?
        var xdata: [String] = []
        var pos = firstBlock
        var statusOK = false
        while pos + 4 <= frame.count {
            let id = frame[pos]
            let length = Int(frame[pos + 1])
            let end = pos + 2 + length
            guard end + 2 <= frame.count else { break }
            let stored = UInt16(frame[end]) | UInt16(frame[end + 1]) << 8
            guard crc16(frame[(pos + 2)..<end]) == stored else {
                pos = end + 2
                // Nach einem kaputten Block bleibt die Kette meist intakt –
                // aber nur, wenn die Länge stimmt. Bei unbekannter Kennung abbrechen.
                if Block(rawValue: id) == nil { break }
                continue
            }
            let data = Array(frame[(pos + 2)..<end])
            switch Block(rawValue: id) {
            case .status where length >= 40:
                report.frame = Int(u16(data, 0))
                let idBytes = data[2..<10]
                let serial = String(decoding: idBytes.prefix { $0 != 0 }, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                // Echte Seriennummern bestehen nur aus A–Z und 0–9. Alles andere
                // (`;`, `=`, Steuerzeichen …) würde Protokoll-CSV und Export
                // verfälschen – solche Rahmen verwerfen (Review Y6).
                guard isValidSerial(serial) else { return nil }
                report.serial = serial
                report.batteryVolts = Double(data[10]) / 10
                // Kalibrierfragment: Zähler bei 0x52, 16 Byte danach.
                let counter = Int(data[0x52 - 0x3B])
                if counter < 51, !report.serial.isEmpty {
                    var cal = calibration[report.serial] ?? Calibration()
                    for i in 0..<16 { cal.bytes[counter * 16 + i] = data[0x53 - 0x3B + i] }
                    cal.received[counter] = true
                    if counter == 0x32 { cal.countdownFrame = report.frame }
                    calibration[report.serial] = cal
                }
                statusOK = !report.serial.isEmpty
            case .measurement where length >= 36:
                measurements = data
            case .aux where length >= 2:
                // Erstes Byte ist ein Zähler, danach ASCII (Hex-Ziffern).
                xdata.append(String(decoding: data.dropFirst().filter { $0 > 0x1E && $0 < 0x7F }, as: UTF8.self))
            case .gpsInfo where length >= 6:
                let week = Int(u16(data, 0))
                let tow = Int(u32(data, 2))
                if week > 1000 { report.gpsTime = SondeGPSTime.date(week: week, milliseconds: tow) }
            case .gpsPosition where length >= 19:
                let x = Double(Int32(bitPattern: u32(data, 0))) / 100
                let y = Double(Int32(bitPattern: u32(data, 4))) / 100
                let z = Double(Int32(bitPattern: u32(data, 8))) / 100
                let vx = Double(Int16(bitPattern: u16(data, 12))) / 100
                let vy = Double(Int16(bitPattern: u16(data, 14))) / 100
                let vz = Double(Int16(bitPattern: u16(data, 16))) / 100
                let g = SondeGeodesy.geodetic(x: x, y: y, z: z)
                // ECEF (0,0,0) ohne GPS-Lösung ergibt unsinnige Höhen.
                if g.alt > -1000, g.alt < 80_000 {
                    report.latitude = g.lat
                    report.longitude = g.lon
                    report.altitude = g.alt
                    let v = SondeGeodesy.neu(vx: vx, vy: vy, vz: vz, lat: g.lat, lon: g.lon)
                    report.groundSpeed = (v.north * v.north + v.east * v.east).squareRoot()
                    var heading = atan2(v.east, v.north) * 180 / .pi
                    if heading < 0 { heading += 360 }
                    report.heading = heading
                    report.verticalSpeed = v.up
                }
                report.satellites = Int(data[18])
            case .encrypted:
                report.encrypted = true
                report.model = "RS41-SGM"
            default:
                break
            }
            pos = end + 2
        }
        guard statusOK else { return nil }
        if let cal = calibration[report.serial] {
            report.configuration = configuration(cal, frame: report.frame)
            if report.encrypted { report.configuration.subtype = "RS41-SGM" }
            if let measurements { applyMeasurements(measurements, calibration: cal, to: &report) }
        }
        if !xdata.isEmpty { report.instruments = SondeInstrument.parse(xdata.joined(separator: "#")) }
        return report
    }

    /// Einstellungen aus den Kalibrierfragmenten (Lage wie rs41mod `get_Calconf`;
    /// Fragment n liegt bei `bytes[16 n …]`).
    static func configuration(_ cal: Calibration, frame: Int? = nil) -> SondeConfiguration {
        var c = SondeConfiguration()
        let b = cal.bytes
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func text(_ range: Range<Int>) -> String? {
            let chars = b[range].prefix { $0 >= 0x20 && $0 < 0x7F }
            let value = String(decoding: chars, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        if cal.received[0x00] {
            // 400 MHz + 40 kHz × Byte 3, die oberen zwei Bits von Byte 2 in 10-kHz-Schritten.
            c.frequencyMHz = (400_000 + Double(40 * Int(b[3]) + (Int(b[2] & 0xC0) * 10) / 64)) / 1000
        }
        if cal.received[0x01] { c.firmware = u16(0x10 + 5) }
        if cal.received[0x02] {
            c.burstKill = b[0x20 + 0x0B] != 0
            c.killTimer = u16(0x20 + 7)
        }
        if cal.received[0x32] {
            var countdown = u16(0x320)
            // Ein Rahmen je Sekunde: seit dem Fragment vergangene Rahmen abziehen.
            if countdown != 0xFFFF, let frame, let at = cal.countdownFrame {
                let elapsed = (frame - at + 65536) % 65536
                if elapsed < 120 { countdown = max(countdown - elapsed, 0) }
            }
            c.countdown = countdown
        }
        if cal.received[0x21] {
            var subtype = text(0x218..<0x220)
            // Ein neuntes Zeichen („RS41-SGPE“) steht im nächsten Fragment.
            if let first = subtype, first.count == 8, cal.received[0x22], b[0x220] >= 0x20, b[0x220] < 0x7F {
                subtype = first + String(UnicodeScalar(b[0x220]))
            }
            c.subtype = subtype
        }
        if cal.received[0x22] { c.mainboard = text(0x222..<0x22A) }
        return c
    }

    /// Temperatur (Platin-Widerstand), Temperatur des Feuchtesensors, Luftdruck
    /// (nur SGP) und Feuchte – jeweils nur, wenn die nötigen Kalibrierfragmente
    /// vorliegen (rs41mod: `get_T`, `get_P`, `get_RH2adv`, `get_RHemp`). Die
    /// Feuchte rechnet nach dem Herstellerverfahren mit Sensortemperatur und Druck
    /// (ohne Drucksensor: Normatmosphäre zur GPS-Höhe); fehlen dafür Fragmente,
    /// bleibt es bei der empirischen Näherung.
    static func applyMeasurements(_ data: [UInt8], calibration cal: Calibration, to report: inout SondeReport) {
        guard data.count >= 36, cal.has(3...6) else { return }
        let meas: [UInt32] = (0..<12).map { (k: Int) -> UInt32 in
            let low = UInt32(data[3 * k]), middle = UInt32(data[3 * k + 1]), high = UInt32(data[3 * k + 2])
            return low | middle << 8 | high << 16
        }
        let rf1 = cal.float(at: 61), rf2 = cal.float(at: 65)
        func temperature(_ f: UInt32, _ f1: UInt32, _ f2: UInt32, co: [Float], calT: [Float]) -> Float? {
            guard f2 != f1, rf2 != rf1 else { return nil }
            let g = Float(Int64(f2) - Int64(f1)) / (rf2 - rf1)
            let rb = (Float(f1) * rf2 - Float(f2) * rf1) / Float(Int64(f2) - Int64(f1))
            let rc = Float(f) / g - rb
            let r = rc * calT[0]
            return (co[0] + co[1] * r + co[2] * r * r + calT[1]) * (1 + calT[2])
        }
        let co1 = [cal.float(at: 77), cal.float(at: 81), cal.float(at: 85)]
        let calT1 = [cal.float(at: 89), cal.float(at: 93), cal.float(at: 97)]
        guard let t = temperature(meas[0], meas[1], meas[2], co: co1, calT: calT1), t > -100, t < 60 else { return }
        report.temperature = Double(t)

        // Feuchtesensor-Temperatur: Fragmente 0x12/0x13.
        var th: Float?
        if cal.has(0x12...0x13) {
            let co2 = [cal.float(at: 293), cal.float(at: 297), cal.float(at: 301)]
            let calT2 = [cal.float(at: 305), cal.float(at: 309), cal.float(at: 313)]
            if let value = temperature(meas[6], meas[7], meas[8], co: co2, calT: calT2), value > -100, value < 80 {
                th = value
                report.humiditySensorTemperature = Double(value)
            }
        }

        // Luftdruck: nur, wenn die Sonde sich als „…P“ (RS41-SGP) meldet.
        if data.count >= 40, cal.has(0x21...0x21), cal.bytes[0x21F] == UInt8(ascii: "P"), cal.has(0x25...0x2A),
           let p = pressure(meas[9], meas[10], meas[11], fx: Int(Int16(bitPattern: UInt16(data[38]) | UInt16(data[39]) << 8)),
                            cal: cal), p > 0.5, p < 1100 {
            report.pressure = Double(p)
        }

        guard cal.has(7...7), meas[5] != meas[4] else { return }
        if let th, cal.has(7...0x12), cal.has(0x2A...0x2E) {
            let p = report.pressure ?? report.altitude.map(standardPressure) ?? -1
            if let rh = correctedHumidity(meas[3], meas[4], meas[5], t: Double(t), th: Double(th), p: p, cal: cal) {
                report.humidity = rh
                report.humidityCorrected = true
                return
            }
        }
        let calH0 = cal.float(at: 117)
        guard calH0 != 0 else { return }
        let f: Float = Float(meas[3]), f1: Float = Float(meas[4]), f2: Float = Float(meas[5])
        let fh: Float = (f - f1) / (f2 - f1)
        var rh = 100 * ((350 / calH0) * fh - 7.5)
        rh += -t / 5.5
        if t < -20 { rh *= 1 + (-20 - t) / 100 }
        if t < -40 { rh *= 1 + (-40 - t) / 120 }
        report.humidity = Double(min(100, max(0, rh)))
    }

    /// Luftdruck (hPa) des RS41-SGP, Polynom 6 × 4 über Kalibrierkoeffizienten
    /// (rs41mod `get_P`, nach DF9DQ).
    static func pressure(_ f: UInt32, _ f1: UInt32, _ f2: UInt32, fx: Int, cal: Calibration) -> Double? {
        guard f1 != f2, f1 != f else { return nil }
        var c = [Double](repeating: 0, count: 25)
        let layout: [(index: Int, offset: Int)] = [
            (0, 606), (4, 610), (8, 614), (12, 618), (16, 622), (20, 626), (24, 630),
            (1, 634), (5, 638), (9, 642), (13, 646), (2, 650), (6, 654), (10, 658), (14, 662),
            (3, 666), (7, 670), (11, 674),
        ]
        for entry in layout { c[entry.index] = Double(cal.float(at: entry.offset)) }
        let a0 = c[24] / (Double(Int64(f) - Int64(f1)) / Double(Int64(f2) - Int64(f1)))
        let a1 = Double(fx) * 0.01
        var p = 0.0, a0j = 1.0
        for j in 0..<6 {
            var a1k = 1.0
            for k in 0..<4 {
                p += a0j * a1k * c[j * 4 + k]
                a1k *= a1
            }
            a0j *= a0
        }
        return p.isFinite ? p : nil
    }

    /// Normatmosphäre: Druck (hPa) zur Höhe (m) – für die Feuchtekorrektur ohne Drucksensor.
    static func standardPressure(_ h: Double) -> Double {
        let gMR = 9.80665 * 0.0289644 / 8.31446
        let (pb, tb, lb, hb): (Double, Double, Double, Double) =
            h > 32000 ? (8.6802, 228.65, 0.0028, 32000)
            : h > 20000 ? (54.7489, 216.65, 0.001, 20000)
            : h > 11000 ? (226.321, 216.65, 0, 11000)
            : (1013.25, 288.15, -0.0065, 0)
        return lb == 0 ? pb * exp(-gMR * (h - hb) / tb) : pb * pow(1 + lb * (h - hb) / tb, -gMR / lb)
    }

    /// Sättigungsdampfdruck über Wasser (Hyland und Wexler, Pa).
    static func vaporSaturation(_ celsius: Double) -> Double {
        let t = celsius + 273.15
        return exp(-5800.2206 / t + 1.3914993 + 6.5459673 * log(t) - 4.8640239e-2 * t
                   + 4.1764768e-5 * t * t - 1.4452093e-8 * t * t * t)
    }

    /// Feuchte nach dem Herstellerverfahren (rs41mod `get_RH2adv`, nach DF9DQ):
    /// Kapazität → Feuchte am beheizten Sensor über eine 7 × 6-Matrix, mit
    /// Druckkorrektur, dann auf die Lufttemperatur umgerechnet.
    static func correctedHumidity(_ f: UInt32, _ f1: UInt32, _ f2: UInt32, t: Double, th: Double, p: Double,
                                  cal: Calibration) -> Double? {
        let calH0 = Double(cal.float(at: 117)), calH1 = Double(cal.float(at: 121))
        let cf1 = Double(cal.float(at: 69)), cf2 = Double(cal.float(at: 73))
        guard calH0 != 0, f2 != f1 else { return nil }
        let cfh = Double(Int64(f) - Int64(f1)) / Double(Int64(f2) - Int64(f1))
        let capacity = cf1 + (cf2 - cf1) * cfh
        var cp = (capacity / calH0 - 1) * calH1
        let tp = (th - 20) / 180
        var b = [Double](repeating: 1, count: 6)
        for k in 1..<6 { b[k] = b[k - 1] * tp }
        if p > 0 {
            let bar = p / 1000
            let corHp = (0..<3).map { Double(cal.float(at: 678 + 4 * $0)) }
            let corHt = (0..<12).map { Double(cal.float(at: 698 + 4 * $0)) }
            var cpj = 1.0, correction = 0.0
            for j in 0..<3 {
                let bp = corHp[j] * (bar / (1 + corHp[j] * bar) - cpj / (1 + corHp[j]))
                cpj *= cp
                var bt = 0.0
                for k in 0..<4 { bt += corHt[4 * j + k] * b[k] }
                correction += bp * bt
            }
            cp -= correction
        }
        var rh = 0.0, aj = 1.0
        for j in 0..<7 {
            for k in 0..<6 { rh += aj * b[k] * Double(cal.float(at: 125 + 4 * (6 * j + k))) }
            aj *= cp
        }
        if p <= 0, t < -40 { rh += (t + 40) / 12 }
        rh *= vaporSaturation(th) / vaporSaturation(t)
        guard rh.isFinite else { return nil }
        return min(100, max(0, rh))
    }

    private static func u16(_ d: [UInt8], _ i: Int) -> UInt16 { UInt16(d[i]) | UInt16(d[i + 1]) << 8 }
    private static func u32(_ d: [UInt8], _ i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
}

// MARK: - Reed-Solomon RS(255,231) über GF(2⁸), Polynom 0x11D, Nullstellen α⁰…α²³

/// Codewort `cw[j]` ist der Koeffizient von Xʲ; Parität in `cw[0..<24]`,
/// Nutzdaten in `cw[24..<255]` (wie `bch_ecc_mod.c`).
enum RS41ReedSolomon {
    static let parity = 24
    static let dataLength = 231

    private static let tables: (exp: [UInt8], log: [Int]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0, b != 0 else { return 0 }
        return tables.exp[tables.log[Int(a)] + tables.log[Int(b)]]
    }

    private static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0 else { return 0 }
        return tables.exp[(tables.log[Int(a)] - tables.log[Int(b)] + 255) % 255]
    }

    private static func power(_ i: Int) -> UInt8 { tables.exp[((i % 255) + 255) % 255] }

    /// Generator g(X) = ∏ (X − αⁱ), i = 0…23; Koeffizienten aufsteigend.
    private static let generator: [UInt8] = {
        var g: [UInt8] = [1]
        for i in 0..<parity {
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for j in g.indices {
                next[j + 1] ^= g[j]               // X · g
                next[j] ^= mul(g[j], power(i))    // αⁱ · g (− = + in GF(2⁸))
            }
            g = next
        }
        return g
    }()

    /// Paritätsbytes zu 231 Nutzbytes: Rest von m(X)·X²⁴ geteilt durch g(X).
    static func parity(for data: [UInt8]) -> [UInt8] {
        var remainder = [UInt8](repeating: 0, count: parity)
        // Höchster Koeffizient zuerst: cw[254] … cw[24].
        for j in stride(from: dataLength - 1, through: 0, by: -1) {
            let feedback = data[j] ^ remainder[parity - 1]
            for k in stride(from: parity - 1, to: 0, by: -1) {
                remainder[k] = remainder[k - 1] ^ mul(feedback, generator[k])
            }
            remainder[0] = mul(feedback, generator[0])
        }
        return remainder
    }

    /// Berlekamp-Massey, Chien-Suche, Forney. Liefert die Zahl korrigierter
    /// Symbole (0 = fehlerfrei) oder `nil`, wenn mehr als 12 Fehler vorliegen.
    static func decode(_ cw: inout [UInt8]) -> Int? {
        // Syndrome S_i = c(αⁱ)
        var syndromes = [UInt8](repeating: 0, count: parity)
        var clean = true
        for i in 0..<parity {
            var s: UInt8 = 0
            for j in stride(from: 254, through: 0, by: -1) { s = mul(s, power(i)) ^ cw[j] }
            syndromes[i] = s
            if s != 0 { clean = false }
        }
        if clean { return 0 }

        // Berlekamp-Massey → Fehlerortungspolynom Λ(X)
        var lambda: [UInt8] = [1] + [UInt8](repeating: 0, count: parity)
        var previous: [UInt8] = [1] + [UInt8](repeating: 0, count: parity)
        var l = 0, m = 1
        var b: UInt8 = 1
        for n in 0..<parity {
            var d = syndromes[n]
            if l > 0 { for i in 1...l { d ^= mul(lambda[i], syndromes[n - i]) } }
            if d == 0 {
                m += 1
            } else if 2 * l <= n {
                let saved = lambda
                let coef = div(d, b)
                for i in 0..<(parity + 1 - m) { lambda[i + m] ^= mul(coef, previous[i]) }
                l = n + 1 - l
                previous = saved
                b = d
                m = 1
            } else {
                let coef = div(d, b)
                for i in 0..<(parity + 1 - m) { lambda[i + m] ^= mul(coef, previous[i]) }
                m += 1
            }
        }
        guard l <= parity / 2 else { return nil }

        // Chien-Suche: Nullstellen von Λ bei X = α^(−j) ⇒ Fehler an Stelle j.
        var positions: [Int] = []
        for j in 0..<255 {
            var sum: UInt8 = 0
            let x = power(-j)
            var xp: UInt8 = 1
            for i in 0...l {
                sum ^= mul(lambda[i], xp)
                xp = mul(xp, x)
            }
            if sum == 0 { positions.append(j) }
        }
        guard positions.count == l else { return nil }

        // Ω(X) = S(X)·Λ(X) mod X²⁴
        var omega = [UInt8](repeating: 0, count: parity)
        for i in 0..<parity {
            var v: UInt8 = 0
            for k in 0...min(i, l) { v ^= mul(lambda[k], syndromes[i - k]) }
            omega[i] = v
        }
        // Forney (erste Nullstelle b = 0): e_j = X_j · Ω(X_j⁻¹) / Λ'(X_j⁻¹)
        for j in positions {
            let xInv = power(-j)
            var num: UInt8 = 0
            var xp: UInt8 = 1
            for i in 0..<parity {
                num ^= mul(omega[i], xp)
                xp = mul(xp, xInv)
            }
            // Ableitung in GF(2): Λ'(X) = Σ λ_i·X^(i−1) über ungerade i.
            var den: UInt8 = 0
            for i in stride(from: 1, through: l, by: 2) { den ^= mul(lambda[i], power(-j * (i - 1))) }
            guard den != 0 else { return nil }
            let value = mul(power(j), div(num, den))
            cw[j] ^= value
        }
        return positions.count
    }
}
