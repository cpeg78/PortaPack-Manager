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
    var encrypted = false
    /// Mittenfrequenz des Kanals in Hz (setzt der Empfänger).
    var frequency: Double = 0
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
        var measurements: [UInt32]?
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
                    calibration[report.serial] = cal
                }
                statusOK = !report.serial.isEmpty
            case .measurement where length >= 36:
                measurements = (0..<12).map { k in
                    UInt32(data[3 * k]) | UInt32(data[3 * k + 1]) << 8 | UInt32(data[3 * k + 2]) << 16
                }
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
        if let measurements, let cal = calibration[report.serial] {
            applyMeasurements(measurements, calibration: cal, to: &report)
        }
        return report
    }

    /// Temperatur (Platin-Widerstand) und eine empirische Feuchte – nur,
    /// wenn die nötigen Kalibrierfragmente vorliegen (rs41mod: `get_T`,
    /// `get_RHemp`). Die Feuchte ist eine Näherung ohne Druckkorrektur.
    static func applyMeasurements(_ meas: [UInt32], calibration cal: Calibration, to report: inout SondeReport) {
        guard cal.has(3...6) else { return }
        let rf1 = cal.float(at: 61), rf2 = cal.float(at: 65)
        let co = [cal.float(at: 77), cal.float(at: 81), cal.float(at: 85)]
        let calT = [cal.float(at: 89), cal.float(at: 93), cal.float(at: 97)]
        func temperature(_ f: UInt32, _ f1: UInt32, _ f2: UInt32) -> Float? {
            guard f2 != f1, rf2 != rf1 else { return nil }
            let g = Float(Int64(f2) - Int64(f1)) / (rf2 - rf1)
            let rb = (Float(f1) * rf2 - Float(f2) * rf1) / Float(Int64(f2) - Int64(f1))
            let rc = Float(f) / g - rb
            let r = rc * calT[0]
            return (co[0] + co[1] * r + co[2] * r * r + calT[1]) * (1 + calT[2])
        }
        guard let t = temperature(meas[0], meas[1], meas[2]), t > -100, t < 60 else { return }
        report.temperature = Double(t)
        guard cal.has(7...7), meas[5] != meas[4] else { return }
        let calH0 = cal.float(at: 117)
        guard calH0 != 0 else { return }
        let fh = (Float(meas[3]) - Float(meas[4])) / (Float(meas[5]) - Float(meas[4]))
        var rh = 100 * ((350 / calH0) * fh - 7.5)
        rh += -t / 5.5
        if t < -20 { rh *= 1 + (-20 - t) / 100 }
        if t < -40 { rh *= 1 + (-40 - t) / 120 }
        report.humidity = Double(min(100, max(0, rh)))
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
