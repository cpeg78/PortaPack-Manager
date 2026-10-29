import Foundation
import Testing
@testable import PortaPackManager

/// SSTV-Sender für die Tests: Bild → Tonfrequenzen (mit VIS-Kopf) → FM.
enum SSTVTestSignal {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// Weiches Testbild: Verläufe in allen Kanälen, große Farbflächen (scharfe
    /// Kanten verwischt jeder SSTV-Empfänger um einen Bildpunkt).
    static func image(_ mode: SSTVMode) -> [[RGB]] {
        let w = Double(mode.width), h = Double(mode.height)
        return (0..<mode.height).map { y in
            (0..<mode.width).map { x in
                let fx = Double(x) / w, fy = Double(y) / h
                return (r: 30 + 200 * fx,
                        g: 30 + 200 * fy,
                        b: 128 + 90 * sin(2 * .pi * (fx + fy)))
            }
        }
    }

    /// Tonfrequenz je Abtastwert. `clock` > 1: der Sender ist langsamer (alle
    /// Dauern gestreckt) – erzeugt Schräglauf. `toneOffset`: alle Töne versetzt.
    static func tones(_ mode: SSTVMode, image: [[RGB]], rate: Double = 48_000, clock: Double = 1,
                      toneOffset: Double = 0, lines: Int? = nil, leadSilence: Double = 0.4) -> [Double] {
        var out: [Double] = []
        var t = 0.0       // Sollzeit in Abtastwerten (gebrochen)
        func emit(_ f: Double, _ seconds: Double) {
            t += seconds * rate * clock
            while Double(out.count) < t { out.append(f + toneOffset) }
        }
        // Vorlauf: Rauschen erzeugt erst das FM-Rauschen; hier einfach 1500 Hz.
        emit(1500, leadSilence)
        // VIS: Vorton, Pause, Vorton, Startbit, 7 Bits (LSB zuerst), Parität, Stoppbit.
        emit(1900, 0.3); emit(1200, 0.01); emit(1900, 0.3); emit(1200, 0.03)
        var parity = 0
        for k in 0..<7 {
            let bit = (mode.vis >> k) & 1
            parity ^= bit
            emit(bit == 1 ? 1100 : 1300, 0.03)
        }
        emit(parity == 1 ? 1100 : 1300, 0.03)
        emit(1200, 0.03)
        for segment in mode.leadIn {
            if case .tone(let f, let d) = segment { emit(f, d) }
        }
        let width = mode.width
        for n in 0..<(lines ?? mode.transmittedLines) {
            for segment in mode.segments(line: n) {
                switch segment {
                case .tone(let f, let d):
                    emit(f, d)
                case .scan(let channel, let d):
                    let values = scanValues(mode, image: image, line: n, channel: channel)
                    for x in 0..<width { emit(SSTVMode.frequency(value: values[x]), d / Double(width)) }
                }
            }
        }
        emit(1500, 0.3)
        return out
    }

    private static func scanValues(_ mode: SSTVMode, image: [[RGB]], line n: Int, channel: SSTVMode.Channel) -> [Double] {
        let width = mode.width
        func ycc(_ row: Int, _ x: Int) -> (y: Double, cr: Double, cb: Double) {
            let p = image[min(row, mode.height - 1)][x]
            return SSTVMode.ycc(r: p.r, g: p.g, b: p.b)
        }
        return (0..<width).map { x in
            switch (mode.family, channel) {
            case (_, .r): image[n][x].r
            case (_, .g): image[n][x].g
            case (_, .b): image[n][x].b
            case (.pd, .y): ycc(2 * n, x).y
            case (.pd, .y2): ycc(2 * n + 1, x).y
            case (.pd, .cr): (ycc(2 * n, x).cr + ycc(2 * n + 1, x).cr) / 2
            case (.pd, .cb): (ycc(2 * n, x).cb + ycc(2 * n + 1, x).cb) / 2
            case (_, .y): ycc(n, x).y
            // Robot 36: gerade Zeilen tragen R−Y, ungerade B−Y (je Zeilenpaar gemittelt).
            case (_, .cr): (ycc(n, x).cr + ycc(n + 1, x).cr) / 2
            case (_, .cb): (ycc(n - 1, x).cb + ycc(n, x).cb) / 2
            case (_, .y2): 0
            }
        }
    }

    /// FM (Hub ±`deviation`) mit Trägerablage und Rauschen, Kanalfilter ±8 kHz
    /// wie in `SatChannelizer`, Diskriminator (rad/Wert). `noise` ist die
    /// Rauschamplitude je Komponente bei 48 kHz (Träger 1).
    static func discriminator(_ tones: [Double], rate: Double = 48_000, deviation: Double = 3_000,
                              carrierOffset: Double = 0, noise: Double = 0, seed: UInt64 = 3) -> [Float] {
        var rng = TestSignals.Noise(state: seed)
        var audioPhase = 0.0, carrierPhase = 0.0
        var re = [Float](repeating: 0, count: tones.count)
        var im = [Float](repeating: 0, count: tones.count)
        for n in tones.indices {
            audioPhase += 2 * .pi * tones[n] / rate
            if audioPhase > 2 * .pi { audioPhase -= 2 * .pi }
            carrierPhase += 2 * .pi * (carrierOffset + deviation * sin(audioPhase)) / rate
            if carrierPhase > 2 * .pi { carrierPhase -= 2 * .pi } else if carrierPhase < -2 * .pi { carrierPhase += 2 * .pi }
            var r = cos(carrierPhase), i = sin(carrierPhase)
            if noise > 0 { r += noise * rng.gaussian(); i += noise * rng.gaussian() }
            re[n] = Float(r); im[n] = Float(i)
        }
        var hRe: [Float] = [], hIm: [Float] = []
        let filter = RadioDemodulator.lowpass(taps: 63, cutoff: 8_000, rate: rate)
        let (fRe, fIm) = RadioDemodulator.decimateComplex(re, im, history: &hRe, &hIm, filter: filter, factor: 1)
        var out = [Float](repeating: 0, count: fRe.count)
        var lastRe: Float = 1, lastIm: Float = 0
        for n in fRe.indices {
            out[n] = atan2f(fIm[n] * lastRe - fRe[n] * lastIm, fRe[n] * lastRe + fIm[n] * lastIm)
            lastRe = fRe[n]; lastIm = fIm[n]
        }
        return out
    }

    static func decode(_ audio: [Float]) -> (images: [SSTVImage], decoder: SSTVDecoder) {
        let decoder = SSTVDecoder()
        var images: [SSTVImage] = []
        var k = 0
        while k < audio.count {
            let end = min(k + 4_800, audio.count)
            decoder.process(Array(audio[k..<end]))
            images += decoder.takeFinished()
            k = end
        }
        return (images, decoder)
    }

    /// Mittlere absolute Abweichung (0…255) über die ersten `rows` Zeilen.
    static func meanError(_ decoded: SSTVImage, _ source: [[RGB]], rows: Int? = nil) -> Double {
        var sum = 0.0, count = 0
        for y in 0..<(rows ?? decoded.height) {
            for x in 0..<decoded.width {
                let p = decoded.pixel(row: y, x: x), s = source[y][x]
                sum += abs(Double(p.0) - s.r) + abs(Double(p.1) - s.g) + abs(Double(p.2) - s.b)
                count += 3
            }
        }
        return sum / Double(count)
    }

    /// Wie `meanError`, aber über 4×4-Blockmittel – Rauschen mittelt sich weg,
    /// Verschiebungen (Schräglauf, falsche Zeilenlage) bleiben sichtbar.
    static func blockError(_ decoded: SSTVImage, _ source: [[RGB]]) -> Double {
        var sum = 0.0, count = 0
        for by in stride(from: 0, to: decoded.height - 3, by: 4) {
            for bx in stride(from: 0, to: decoded.width - 3, by: 4) {
                var d = (0.0, 0.0, 0.0), s = (0.0, 0.0, 0.0)
                for y in by..<by + 4 {
                    for x in bx..<bx + 4 {
                        let p = decoded.pixel(row: y, x: x), q = source[y][x]
                        d.0 += Double(p.0); d.1 += Double(p.1); d.2 += Double(p.2)
                        s.0 += q.r; s.1 += q.g; s.2 += q.b
                    }
                }
                sum += (abs(d.0 - s.0) + abs(d.1 - s.1) + abs(d.2 - s.2)) / 16
                count += 3
            }
        }
        return sum / Double(count)
    }
}

@Suite("SSTV")
struct SSTVTests {
    @Test("Zeilendauern der Betriebsarten stimmen mit der Norm überein")
    func lineDurations() {
        let expected: [SSTVMode: Double] = [
            .martinM1: 446.446, .martinM2: 226.798, .scottieS1: 428.22, .scottieS2: 277.692,
            .robot36: 150, .pd50: 388.16, .pd90: 703.04, .pd120: 508.48, .pd180: 754.24,
        ]
        for mode in SSTVMode.allCases {
            #expect(abs(mode.lineDuration * 1000 - expected[mode]!) < 0.01, "\(mode.title)")
        }
        // Gesamtdauern grob: PD120 ≈ 126 s, PD180 ≈ 187 s, Robot 36 = 36 s.
        #expect(abs(SSTVMode.pd120.duration - 126.1) < 0.2)
        #expect(abs(SSTVMode.pd180.duration - 187.05) < 0.2)
        #expect(abs(SSTVMode.robot36.duration - 36) < 0.01)
    }

    @Test("YCbCr-Rundreise ist verlustarm")
    func colorRoundTrip() {
        for (r, g, b) in [(0.0, 0.0, 0.0), (255.0, 255.0, 255.0), (200.0, 30.0, 90.0), (20.0, 180.0, 240.0)] {
            let c = SSTVMode.ycc(r: r, g: g, b: b)
            let back = SSTVMode.rgb(y: c.y, cr: c.cr, cb: c.cb)
            #expect(abs(Double(back.0) - r) <= 1 && abs(Double(back.1) - g) <= 1 && abs(Double(back.2) - b) <= 1)
        }
    }

    /// Je Betriebsart: Bild senden (FM, Trägerablage, Rauschen, Taktfehler) und
    /// zurückdekodieren.
    @Test("Bild kommt über FM mit Ablage, Rauschen und Schräglauf zurück", arguments: SSTVMode.allCases)
    func roundTrip(mode: SSTVMode) throws {
        let source = SSTVTestSignal.image(mode)
        // Taktfehler wechselnd ±700 ppm – ohne Schräglaufkorrektur wäre das Bild
        // am Ende um viele Bildpunkte verschoben.
        let ppm = mode.rawValue % 2 == 0 ? 700.0 : -700.0
        let tones = SSTVTestSignal.tones(mode, image: source, clock: 1 + ppm * 1e-6)
        // Rauschen 0,15 je Komponente bei 48 kHz ≈ 18 dB Träger/Rauschen im
        // 16-kHz-Kanal; Trägerablage 1,8 kHz (Rest-Doppler).
        let audio = SSTVTestSignal.discriminator(tones, carrierOffset: 1_800, noise: 0.15)
        let (images, _) = SSTVTestSignal.decode(audio)
        try #require(images.count == 1, "\(mode.title): \(images.count) Bilder")
        let image = images[0]
        #expect(image.mode == mode)
        #expect(image.complete)
        #expect(image.rows == mode.height)
        // Je Bildpunkt rauscht es bei den schnellen Arten (PD120: 0,19 ms je
        // Punkt) merklich; im Blockmittel muss das Bild stimmen.
        let error = SSTVTestSignal.meanError(image, source)
        let block = SSTVTestSignal.blockError(image, source)
        #expect(error < 16, "\(mode.title): mittlere Abweichung \(error)")
        #expect(block < 5, "\(mode.title): Abweichung der 4×4-Blöcke \(block)")
        #expect(abs(image.clockPPM - ppm) < 100, "\(mode.title): Takt \(image.clockPPM) statt \(ppm) ppm")
    }

    @Test("Versetzte Töne (Sender verstimmt) werden über den Vorton ausgeglichen")
    func toneOffset() throws {
        let mode = SSTVMode.robot36
        let source = SSTVTestSignal.image(mode)
        let tones = SSTVTestSignal.tones(mode, image: source, toneOffset: 60)
        let (images, _) = SSTVTestSignal.decode(SSTVTestSignal.discriminator(tones, noise: 0.1))
        let image = try #require(images.first)
        #expect(SSTVTestSignal.blockError(image, source) < 5)
    }

    @Test("Abgebrochene Übertragung liefert ein Teilbild")
    func partialImage() throws {
        let mode = SSTVMode.martinM2
        let source = SSTVTestSignal.image(mode)
        // Nur 100 Zeilen, danach Rauschen ohne Träger.
        var audio = SSTVTestSignal.discriminator(SSTVTestSignal.tones(mode, image: source, lines: 100), noise: 0.1)
        audio += SSTVTestSignal.discriminator([Double](repeating: 0, count: 48_000 * 12), deviation: 0, noise: 3, seed: 11)
        let (images, _) = SSTVTestSignal.decode(audio)
        let image = try #require(images.first)
        #expect(!image.complete)
        #expect(abs(image.rows - 100) <= 2, "Zeilen \(image.rows)")
        #expect(SSTVTestSignal.meanError(image, source, rows: 95) < 16)
    }

    @Test("Aus Rauschen entsteht kein Bild")
    func noiseOnly() {
        let audio = SSTVTestSignal.discriminator([Double](repeating: 0, count: 48_000 * 30), deviation: 0, noise: 2, seed: 5)
        let (images, decoder) = SSTVTestSignal.decode(audio)
        #expect(images.isEmpty)
        #expect(decoder.status.mode == nil)
    }
}
