import Testing
@testable import PortaPackManager

@Suite("GPS-Bahn und Positionslösung")
struct GPSPositionTests {

    /// PRN 8 aus brdc0010.22n (IGS-Broadcast, 01.01.2022 00:00 GPS-Zeit), TGD hier 0.
    static let prn8 = GPSEphemeris(
        prn: 8, weekNumber: 2190 % 1024, iodc: 103, iode: 103, tgd: 0, toc: 518_400,
        af0: -0.503170304000e-04, af1: -0.147792889038e-11, af2: 0,
        crs: 0.810000000000e+02, deltaN: 0.467733768703e-08, m0: 0.168739859998e+01,
        cuc: 0.443309545517e-05, e: 0.704693282023e-02, cus: 0.532716512680e-06,
        sqrtA: 0.515370576859e+04, toe: 518_400, cic: 0.102445483208e-06,
        omega0: -0.211607141071e+01, cis: 0.162050127983e-06, i0: 0.965195865813,
        crc: 0.369906250000e+03, omega: 0.718345061612e-01, omegaDot: -0.852678374620e-08,
        idot: 0.557166065346e-10)

    /// Vergleichswerte: RTKLIB `eph2pos` (Formeln 1:1 übernommen) und
    /// gps-sdr-sim `satpos` stimmen auf 0,1 mm überein.
    @Test("Satellitenposition und -uhr wie RTKLIB eph2pos", arguments: [
        (518_400.0, SIMD3(15_042_354.0988, -4_693_969.7134, 21_409_592.2014), -5.033304262469707e-05),
        (522_000.0, SIMD3(20_939_689.5623, 1_856_346.4090, 16_418_137.0176), -5.033522227178737e-05),
        (513_000.0, SIMD3(8_425_047.2695, -17_353_105.1105, 18_089_471.5085), -5.032174198524065e-05),
    ])
    func satellitenposition(t: Double, expected: SIMD3<Double>, clock: Double) {
        let p = Self.prn8.position(at: t)
        let d = p - expected
        #expect((d * d).sum().squareRoot() < 0.001)
        #expect(abs(Self.prn8.clockBias(at: t) - clock) < 1e-14)
    }

    @Test("ECEF ↔ geodätisch")
    func koordinaten() {
        let r = GPSGeo.ecef(lat: 52.520008 * .pi / 180, lon: 13.404954 * .pi / 180, height: 50)
        // gps-sdr-sim gibt für diesen Ort 3783274.7, 901648.9, 5038259.3 aus.
        #expect(abs(r.x - 3_783_274.7) < 0.1 && abs(r.y - 901_648.9) < 0.1 && abs(r.z - 5_038_259.3) < 0.1)
        let g = GPSGeo.geodetic(r)
        #expect(abs(g.lat * 180 / .pi - 52.520008) < 1e-9)
        #expect(abs(g.height - 50) < 1e-3)
    }

    @Test("Troposphäre im Zenit ≈ 2,4 m, flach deutlich mehr")
    func troposphaere() {
        let zenith = GPSGeo.troposphere(lat: 0.9, height: 50, elevation: .pi / 2)
        #expect(zenith > 2.2 && zenith < 2.6)
        let low = GPSGeo.troposphere(lat: 0.9, height: 50, elevation: 10 * .pi / 180)
        #expect(low > 12 && low < 16)
    }

    /// Pseudodistanzen aus einer bekannten Position (inkl. Uhrfehler,
    /// Satellitenuhr, Troposphäre, Ionosphäre, Erddrehung) → Lösung < 1 m.
    @Test("PVT aus synthetischen Pseudodistanzen trifft auf < 1 m")
    func pvt() {
        let lat = 48.137154, lon = 11.576124, h = 519.0
        let rx = GPSGeo.ecef(lat: lat * .pi / 180, lon: lon * .pi / 180, height: h)
        let t = 302_400.0 + 1234.5
        let ion = GPSIonoUTC(alpha: [0.1211e-7, -0.7451e-8, -0.5960e-7, 0.1192e-6],
                             beta: [0.1167e6, -0.2458e6, -0.6554e5, 0.1114e7])
        let ephs = GPSTestConstellation.visible(rx: rx, t: t, week: 2440, minElevation: 5, count: 8)
        #expect(ephs.count >= 6)
        let sim = GPSSignalSimulator(rx: rx, startTime: t, ephemerides: ephs, firstSubframeStart: (t / 30).rounded(.up) * 30,
                                     duration: 1, troposphere: true, iono: ion)
        let clockError = 0.0123          // Empfängeruhr 12,3 ms vor
        let receive = t + clockError
        let obs = ephs.map { eph -> GPSObservation in
            let tr = sim.truth(prn: eph.prn, sample: 0)
            return GPSObservation(prn: eph.prn, transmitTime: tr.transmitTime, dopplerHz: tr.dopplerHz)
        }
        let dict = Dictionary(uniqueKeysWithValues: ephs.map { ($0.prn, $0) })
        let sol = GPSSolver.solve(obs, ephemerides: dict, iono: ion, receiveTime: receive)
        #expect(sol != nil)
        guard let sol else { return }
        let err = sol.ecef - rx
        #expect((err * err).sum().squareRoot() < 1.0, "Fehler \((err * err).sum().squareRoot()) m")
        #expect(abs(sol.gpsTime - t) < 1e-8)
        #expect(sol.pdop > 1 && sol.pdop < 6)
        #expect(sol.hdop <= sol.pdop)
        #expect(abs(sol.latitude - lat) < 1e-5 && abs(sol.height - h) < 1)
        // Stillstand: Geschwindigkeit aus Doppler ≈ 0.
        #expect((sol.speed ?? 99) < 0.1)
    }

    @Test("Volle GPS-Woche aus 10 Bit")
    func woche() {
        let ref = GPSTime.utc(week: 2440, tow: 0, leapSeconds: 0)
        #expect(GPSTime.fullWeek(2440 % 1024, near: ref) == 2440)
        #expect(GPSTime.fullWeek(1023, near: ref) == 2047)
    }
}
