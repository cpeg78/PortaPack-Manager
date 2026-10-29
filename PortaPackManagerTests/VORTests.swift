import Foundation
import Testing
@testable import PortaPackManager

/// Reproduzierbares Rauschen (SplitMix64 + Box-Muller).
struct SplitMixNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / Double(1 << 53)
    }

    mutating func gaussian() -> Double {
        (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
    }
}

/// Synthetisches VOR-Signal als komplexes Basisband (48 kHz).
struct VORSignal {
    var radial: Double
    var doppler = false
    var offsetHz = 0.0
    /// Rauschen je Komponente relativ zur Trägeramplitude 0,5.
    var noise = 0.0
    var ident: String?
    var identUnit = 0.12
    var identPause = 3.0

    func baseband(seconds: Double, seed: UInt64 = 1) -> (re: [Float], im: [Float]) {
        let rate = VORDemodulator.basebandRate
        let count = Int(seconds * rate)
        var re = [Float](repeating: 0, count: count), im = [Float](repeating: 0, count: count)
        var rng = SplitMixNoise(seed: seed)
        let theta = radial * .pi / 180
        let omega = 2 * Double.pi * 30
        let keying = ident.map { identKeying($0) }
        for n in 0..<count {
            let t = Double(n) / rate
            let am: Double, fmPhase: Double
            if doppler {
                am = 0.3 * cos(omega * t)
                fmPhase = 2 * .pi * 9960 * t + 16 * sin(omega * t + theta)
            } else {
                am = 0.3 * cos(omega * t - theta)
                fmPhase = 2 * .pi * 9960 * t + 16 * sin(omega * t)
            }
            var a = 1 + am + 0.3 * cos(fmPhase)
            if let keying, keying(t) { a += 0.1 * cos(2 * .pi * 1020 * t) }
            a *= 0.5
            let p = 2 * Double.pi * offsetHz * t
            re[n] = Float(a * cos(p) + noise * rng.gaussian())
            im[n] = Float(a * sin(p) + noise * rng.gaussian())
        }
        return (re, im)
    }

    /// Ton an/aus über die Zeit: Kennung, dann `identPause` Sekunden Stille, wiederholt.
    func identKeying(_ text: String) -> (Double) -> Bool {
        let elements = MorseDecoder.elements(for: text, unit: identUnit)
        var spans: [(Double, Double)] = []
        var t = 0.5
        for e in elements {
            if e.on { spans.append((t, t + e.seconds)) }
            t += e.seconds
        }
        let period = t + identPause
        return { time in
            let local = time.truncatingRemainder(dividingBy: period)
            return spans.contains { local >= $0.0 && local < $0.1 }
        }
    }
}

@Suite("VOR")
struct VORTests {
    private func measure(_ signal: VORSignal, seconds: Double = 3) -> VORDemodulator.Reading? {
        let demod = VORDemodulator()
        let (re, im) = signal.baseband(seconds: seconds, seed: UInt64(signal.radial * 10 + 7))
        var start = 0
        while start < re.count {
            let end = min(re.count, start + 4800)
            _ = demod.processBaseband(re: Array(re[start..<end]), im: Array(im[start..<end]))
            start = end
        }
        return demod.reading()
    }

    @Test("Radial ±2° für viele Richtungen (CVOR)", arguments: [0.0, 17, 45, 90, 135, 180, 225, 270, 315, 359])
    func radials(_ radial: Double) throws {
        let reading = try #require(measure(VORSignal(radial: radial)))
        #expect(GeoNav.angleDifference(reading.radial, radial) <= 2, "gemessen \(reading.radial)° statt \(radial)°")
        #expect(abs(reading.amDepth - 0.3) < 0.05)
        #expect(abs(reading.subcarrierDepth - 0.3) < 0.05)
        #expect(abs(reading.deviationHz - 480) < 40)
    }

    @Test("Radial ±2° mit Rauschen und Frequenzversatz", arguments: [(30.0, 2_000.0), (200.0, -2_500.0), (300.0, 1_000.0)])
    func noisyOffset(_ value: (Double, Double)) throws {
        let signal = VORSignal(radial: value.0, offsetHz: value.1, noise: 0.05)
        let reading = try #require(measure(signal))
        #expect(GeoNav.angleDifference(reading.radial, value.0) <= 2, "gemessen \(reading.radial)° statt \(value.0)°")
    }

    @Test("DVOR: Rollen von AM und FM getauscht, gleiches Radial")
    func doppler() throws {
        for radial in [60.0, 250.0] {
            let reading = try #require(measure(VORSignal(radial: radial, doppler: true)))
            #expect(GeoNav.angleDifference(reading.radial, radial) <= 2, "DVOR \(reading.radial)° statt \(radial)°")
        }
    }

    @Test("Ganze Kette ab int8-IQ (2,4 MS/s, Versatz 240 kHz + 1,5 kHz)")
    func fullChain() throws {
        let rate = VORDemodulator.inputRate
        let seconds = 2.5
        let count = Int(seconds * rate)
        let radial = 123.0
        let theta = radial * .pi / 180
        var rng = SplitMixNoise(seed: 42)
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            var carrier = 0.0
            let step = 2 * Double.pi * (VORDemodulator.offset + 1_500) / rate
            for n in 0..<count {
                let t = Double(n) / rate
                let a = 40 * (1 + 0.3 * cos(2 * .pi * 30 * t - theta) + 0.3 * cos(2 * .pi * 9960 * t + 16 * sin(2 * .pi * 30 * t)))
                carrier += step
                if carrier > .pi { carrier -= 2 * .pi }
                p[2 * n] = Int8(max(-127, min(127, (a * cos(carrier) + 4 * rng.gaussian()).rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, (a * sin(carrier) + 4 * rng.gaussian()).rounded())))
            }
        }
        let demod = VORDemodulator()
        let block = 262_144
        var start = 0
        while start < data.count {
            _ = demod.process(data.subdata(in: start..<min(data.count, start + block)))
            start += block
        }
        let reading = try #require(demod.reading())
        #expect(GeoNav.angleDifference(reading.radial, radial) <= 2, "gemessen \(reading.radial)°")
    }

    @Test("Kennung im VOR-Signal wird gelesen")
    func identInSignal() {
        let signal = VORSignal(radial: 90, noise: 0.03, ident: "HAM")
        let demod = VORDemodulator()
        let (re, im) = signal.baseband(seconds: 14, seed: 5)
        var start = 0
        while start < re.count {
            let end = min(re.count, start + 4800)
            _ = demod.processBaseband(re: Array(re[start..<end]), im: Array(im[start..<end]))
            start = end
        }
        #expect(demod.morse.idents.contains("HAM"), "gelesen: \(demod.morse.idents)")
        #expect(demod.morse.confirmedIdent == "HAM")
    }
}

@Suite("Morse")
struct MorseTests {
    @Test("Kennungen aus Ton/Pause-Folgen", arguments: ["DLE", "HAM", "TGO", "EEE", "TTT", "MOT", "SPR", "BKD", "A1"])
    func decode(_ text: String) {
        #expect(MorseDecoder.decode(MorseDecoder.elements(for: text, unit: 0.13)) == text)
    }

    @Test("Ungleichmäßig getastet (±20 %)")
    func jitter() {
        var rng = SplitMixNoise(seed: 9)
        let elements = MorseDecoder.elements(for: "WRB", unit: 0.15).map {
            MorseDecoder.Element(on: $0.on, seconds: $0.seconds * (0.8 + 0.4 * rng.uniform()))
        }
        #expect(MorseDecoder.decode(elements) == "WRB")
    }

    @Test("Strom aus Pegelwerten mit Rauschen")
    func stream() {
        let decoder = MorseDecoder(rate: 100)
        var rng = SplitMixNoise(seed: 3)
        var levels: [Float] = []
        for _ in 0..<3 {
            levels += (0..<100).map { _ in Float(0.005 + 0.002 * rng.uniform()) }
            for e in MorseDecoder.elements(for: "NIK", unit: 0.12) {
                let n = Int((e.seconds * 100).rounded())
                levels += (0..<n).map { _ in Float((e.on ? 0.1 : 0.005) + 0.004 * rng.uniform()) }
            }
            levels += (0..<200).map { _ in Float(0.005 + 0.002 * rng.uniform()) }
        }
        decoder.feed(levels)
        #expect(decoder.idents == ["NIK", "NIK", "NIK"])
        #expect(decoder.confirmedIdent == "NIK")
    }
}

@Suite("Kreuzpeilung und Funkfeuer-Datenbank")
struct CrossBearingTests {
    @Test("Schnittpunkt zweier Radiale trifft den Standort")
    func intersection() throws {
        let me = (lat: 53.55, lon: 9.99)               // Hamburg
        let a = (lat: 53.68, lon: 10.25), b = (lat: 53.30, lon: 9.60)
        let ra = GeoMath.bearingDegrees(lat1: a.lat, lon1: a.lon, lat2: me.lat, lon2: me.lon)
        let rb = GeoMath.bearingDegrees(lat1: b.lat, lon1: b.lon, lat2: me.lat, lon2: me.lon)
        let fix = try #require(GeoNav.intersection(lat1: a.lat, lon1: a.lon, bearing1: ra, lat2: b.lat, lon2: b.lon, bearing2: rb))
        #expect(GeoMath.distanceKm(lat1: fix.lat, lon1: fix.lon, lat2: me.lat, lon2: me.lon) < 0.05)
    }

    @Test("Über die Missweisung: missweisende Radiale + Ost-Missweisung")
    func viaModel() throws {
        let me = (lat: 50.11, lon: 8.68)
        let nav1 = Navaid(ident: "AAA", name: "A", type: "VOR-DME", frequencyKHz: 114_200, latitude: 50.40, longitude: 8.30, country: "DE", declination: 2.5)
        let nav2 = Navaid(ident: "BBB", name: "B", type: "DVOR-DME", frequencyKHz: 115_350, latitude: 50.15, longitude: 9.40, country: "DE", declination: 3.0)
        func bearing(_ n: Navaid) -> VORBearing {
            let trueRadial = GeoMath.bearingDegrees(lat1: n.latitude, lon1: n.longitude, lat2: me.lat, lon2: me.lon)
            let magnetic = GeoNav.normalize(trueRadial - (n.declination ?? 0))
            return VORBearing(navaid: n, magnetic: magnetic, trueRadial: n.trueRadial(magnetic), spread: 1, date: Date())
        }
        let fix = try #require(VORModel.fix(from: [bearing(nav1), bearing(nav2)], homeLat: me.lat, homeLon: me.lon))
        #expect(try #require(fix.distanceToHomeKm) < 0.05)
        #expect(fix.cutAngle > 30)
    }

    @Test("Parallele Radiale: Schnitt erst am Pol – als Standort verworfen")
    func parallel() throws {
        // Zwei Meridiane treffen sich am Nordpol – mathematisch richtig, als Peilung unbrauchbar.
        let pole = try #require(GeoNav.intersection(lat1: 50, lon1: 8, bearing1: 0, lat2: 50, lon2: 9, bearing2: 0))
        #expect(pole.lat > 89.9)
        let a = Navaid(ident: "A", name: "", type: "VOR", frequencyKHz: 113_000, latitude: 50, longitude: 8, country: "DE", declination: 0)
        let b = Navaid(ident: "B", name: "", type: "VOR", frequencyKHz: 114_000, latitude: 50, longitude: 9, country: "DE", declination: 0)
        let bearings = [VORBearing(navaid: a, magnetic: 0, trueRadial: 0, spread: 1, date: Date()),
                        VORBearing(navaid: b, magnetic: 0, trueRadial: 0, spread: 1, date: Date())]
        #expect(VORModel.fix(from: bearings, homeLat: nil, homeLon: nil) == nil)
    }

    @Test("Ziel in Entfernung und Peilung")
    func destination() {
        let p = GeoNav.destination(lat: 52, lon: 10, bearing: 90, km: 100)
        #expect(abs(GeoMath.distanceKm(lat1: 52, lon1: 10, lat2: p.lat, lon2: p.lon) - 100) < 0.01)
        #expect(abs(GeoMath.bearingDegrees(lat1: 52, lon1: 10, lat2: p.lat, lon2: p.lon) - 90) < 0.01)
    }

    @Test("navaids.csv: nur VOR im VOR-Band, Anführungszeichen, Missweisung")
    func parse() {
        let csv = """
        "id","filename","ident","name","type","frequency_khz","latitude_deg","longitude_deg","elevation_ft","iso_country","dme_frequency_khz","dme_channel","dme_latitude_deg","dme_longitude_deg","dme_elevation_ft","slaved_variation_deg","magnetic_variation_deg","usageType","power","associated_airport"
        1,"Hamburg_VOR-DME_DE","HAM","Hamburg","VOR-DME",113100,53.68,10.20,90,"DE",,,,,,"1.9","3.4","BOTH","HIGH",
        2,"x","FFM","Frankfurt, Main","DVOR-DME",114200,50.05,8.63,,"DE",,,,,,,"2.8","BOTH","HIGH",
        3,"y","XY","Beacon","NDB",350,50,8,,"DE",,,,,,,,,,
        4,"z","TAC","Tacan","TACAN",1150,50,8,,"DE",,,,,,,,,,
        5,"w","LOC","Out of band","VOR",118500,50,8,,"DE",,,,,,,,,,
        """
        let list = NavaidCSV.parse(csv)
        #expect(list.map(\.ident) == ["HAM", "FFM"])
        #expect(list[0].declination == 1.9)        // slaved_variation hat Vorrang
        #expect(list[1].declination == 2.8)
        #expect(list[1].name == "Frankfurt, Main")
        #expect(list[1].isDoppler)
        #expect(list[0].mhz == 113.1)
        let near = NavaidCSV.nearest(list, lat: 53.55, lon: 9.99, count: 1)
        #expect(near.first?.navaid.ident == "HAM")
    }

    @Test("Güte: Sollwerte und Streuung")
    func quality() {
        let ok = VORDemodulator.Reading(radial: 10, amDepth: 0.3, subcarrierDepth: 0.3, deviationHz: 480, identDepth: 0.1, signalDB: -30)
        #expect(VORQuality.assess(ok, spread: 1) == .good)
        #expect(VORQuality.assess(ok, spread: 3) == .fair)
        #expect(VORQuality.assess(ok, spread: 20) == .poor)
        var noise = ok
        noise.amDepth = 0.01; noise.subcarrierDepth = 0.02
        #expect(VORQuality.assess(noise, spread: nil) == VORQuality.none)
    }
}

@Suite("VOR – Trägererkennung")
struct VORCarrierTests {
    @Test("Reines Rauschen gilt als „kein VOR-Signal“, kein Radial, keine Kennung")
    func noiseIsNoSignal() {
        let demod = VORDemodulator()
        var state: UInt64 = 42
        func g() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 11) / Double(1 << 53)) - 0.5
        }
        for _ in 0..<60 {   // 60 × 50 ms = 3 s
            let re = (0..<2400).map { _ in g() * 0.1 }, im = (0..<2400).map { _ in g() * 0.1 }
            _ = demod.processBaseband(re: re, im: im)
        }
        let reading = demod.reading()
        #expect((reading?.carrierFraction ?? 1) < 0.05)
        #expect(VORQuality.assess(reading, spread: nil) == .none)
    }
}

extension VORCarrierTests {
    @Test("Ein VOR mit 300 Hz Ablage zählt als Träger")
    func offsetCarrierCounts() {
        let demod = VORDemodulator()
        let rate = 48_000.0
        var t = 0.0
        for _ in 0..<60 {
            var re = [Float](repeating: 0, count: 2400), im = re
            for n in 0..<2400 {
                let a = 1 + 0.3 * cos(2 * .pi * 30 * t) + 0.3 * cos(2 * .pi * 9960 * t + 16 * sin(2 * .pi * 30 * t))
                let p = 2 * Double.pi * 300 * t
                re[n] = Float(a * cos(p)); im[n] = Float(a * sin(p))
                t += 1 / rate
            }
            _ = demod.processBaseband(re: re, im: im)
        }
        #expect((demod.reading()?.carrierFraction ?? 0) > 0.6)
    }
}
