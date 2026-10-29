import Testing
@testable import PortaPackManager

@Suite("GPS-C/A-Code")
struct GPSCACodeTests {

    /// Die ersten 10 Chips jedes PRN müssen den Oktal-Prüfwerten aus
    /// IS-GPS-200 entsprechen – das belegt Anzapfung und LFSR-Logik.
    @Test("Erste 10 Chips treffen die IS-GPS-200-Prüfwerte")
    func ersteZehnChips() {
        for prn in 1...GPSCACode.prnCount {
            let code = GPSCACode.code(prn: prn)
            var value = 0
            for k in 0..<10 { value = value << 1 | code[k] }   // b0 ist höchstes Bit
            let expected = GPSCACode.firstTenChipsOctal[prn - 1] & 0x3FF
            #expect(value == expected, "PRN \(prn): \(value) statt \(expected)")
        }
    }

    @Test("Code ist 1023 Chips lang und ausgeglichen")
    func laengeUndBalance() {
        let code = GPSCACode.code(prn: 1)
        #expect(code.count == 1023)
        // Ein ausgeglichener Gold-Code hat 512 Einsen und 511 Nullen.
        let ones = code.reduce(0, +)
        #expect(ones == 512)
    }

    @Test("Verschiedene PRN sind nahezu unkorreliert")
    func kreuzkorrelation() {
        let a = GPSCACode.code(prn: 1).map { $0 == 0 ? 1 : -1 }
        let b = GPSCACode.code(prn: 2).map { $0 == 0 ? 1 : -1 }
        let corr = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        // Gold-Codes: Kreuzkorrelation ∈ {-65, -1, 63}, also klein gegen 1023.
        #expect(abs(corr) <= 65)
    }

    @Test("Auf Abtastwerte gestreckter Code ist ±1")
    func gestreckt() {
        let s = GPSCACode.sampled(prn: 5, samples: 2048)
        #expect(s.count == 2048)
        #expect(s.allSatisfy { $0 == 1 || $0 == -1 })
    }
}
