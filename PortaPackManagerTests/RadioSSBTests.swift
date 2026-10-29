import AVFoundation
import Foundation
import Testing
@testable import PortaPackManager

/// SSB/CW, wählbare Filter und Tonaufnahme des Radios. Messwerte stehen in der
/// Testausgabe (`print`) und in `Docs/Erfahrungen/Rundfunk-UKW-DAB.md`.
@Suite("Radio: SSB, CW, Filter")
struct RadioSSBTests {
    /// Summe komplexer Töne (Ablage zur Wunschfrequenz in Hz, Amplitude in LSB)
    /// als int8-IQ bei 2,4 MS/s, mit ±0,5 LSB Zittern (sonst lägen
    /// Quantisierungs-Nebenlinien zufällig im Kanal).
    static func tones(_ list: [(offset: Double, amplitude: Double)], seconds: Double, shiftHz: Double = 0) -> Data {
        let rate = RadioDemodulator.inputRate
        let n = Int(seconds * rate)
        var data = Data(count: n * 2)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func dither() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) - 0.5
        }
        let steps = list.map { 2 * Double.pi * (RadioDemodulator.offset + shiftHz + $0.offset) / rate }
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for k in 0..<n {
                var i = 0.0, q = 0.0
                for (index, tone) in list.enumerated() {
                    let phase = (steps[index] * Double(k)).truncatingRemainder(dividingBy: 2 * .pi)
                    i += tone.amplitude * cos(phase)
                    q += tone.amplitude * sin(phase)
                }
                p[2 * k] = Int8(max(-127, min(127, (i + dither()).rounded())))
                p[2 * k + 1] = Int8(max(-127, min(127, (q + dither()).rounded())))
            }
        }
        return data
    }

    static func run(_ demod: RadioDemodulator, _ iq: Data) -> [Float] {
        var audio: [Float] = []
        let block = 262_144
        var offset = 0
        while offset < iq.count {
            audio += demod.process(iq.subdata(in: offset..<min(offset + block, iq.count))).left
            offset += block
        }
        return audio
    }

    static func demodulator(_ mode: RadioMode, bandwidth: Double? = nil) -> RadioDemodulator {
        let demod = RadioDemodulator()
        demod.mode = mode
        demod.bandwidthHz = bandwidth ?? mode.defaultBandwidthHz ?? 0
        demod.volume = 1
        return demod
    }

    /// Pegel eines Tons (dB, Hann-Fenster, Goertzel) nach 0,1 s Einschwingen.
    static func toneLevel(_ audio: [Float], _ frequency: Double) -> Double {
        let x = Array(audio.dropFirst(Int(0.1 * RadioDemodulator.audioRate)))
        let w = 2 * Double.pi * frequency / RadioDemodulator.audioRate
        var re = 0.0, im = 0.0
        for n in x.indices {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(x.count - 1))
            re += Double(x[n]) * hann * cos(w * Double(n))
            im -= Double(x[n]) * hann * sin(w * Double(n))
        }
        return 10 * log10(max((re * re + im * im) / Double(x.count * x.count), 1e-30))
    }

    /// Dominante Frequenz über Nulldurchgänge (nach Einschwingen).
    static func dominantFrequency(_ audio: [Float]) -> Double {
        let settled = Array(audio.dropFirst(audio.count / 4))
        var crossings = 0
        for k in 1..<settled.count where settled[k - 1] < 0 && settled[k] >= 0 { crossings += 1 }
        return Double(crossings) / (Double(settled.count) / RadioDemodulator.audioRate)
    }

    static func rms(_ audio: [Float]) -> Float {
        let x = audio.dropFirst(Int(0.1 * RadioDemodulator.audioRate))
        return (x.map { $0 * $0 }.reduce(0, +) / Float(max(1, x.count))).squareRoot()
    }

    /// Leistung im Kanal (dBFS, nach dem Kanal- bzw. Seitenbandfilter).
    static func channelLevel(_ mode: RadioMode, bandwidth: Double? = nil, offset: Double) -> Float {
        let demod = demodulator(mode, bandwidth: bandwidth)
        _ = run(demod, tones([(offset, 100)], seconds: 0.25))
        return demod.channelDB
    }

    // MARK: - Demodulation

    @Test("USB/LSB: Ton 1 kHz neben dem Träger klingt als 1 kHz")
    func sidebandTone() {
        for (mode, offset) in [(RadioMode.usb, 1_000.0), (.lsb, -1_000.0)] {
            let audio = Self.run(Self.demodulator(mode), Self.tones([(offset, 60)], seconds: 0.5))
            // Die Filter füllen sich einmalig beim Start (≈ 45 ms, Seitenbandfilter 511 Abgriffe bei 12 kHz).
            #expect(abs(Double(audio.count) - 0.5 * RadioDemodulator.audioRate) < 3_000, "\(mode): \(audio.count)")
            #expect(abs(Self.dominantFrequency(audio) - 1_000) < 10, "\(mode): \(Self.dominantFrequency(audio)) Hz")
            #expect(Self.rms(audio) > 0.3, "\(mode)")
        }
    }

    @Test("Zweiton: falsches Seitenband mindestens 40 dB gedämpft (USB und LSB)")
    func twoToneSidebandSuppression() {
        var lines: [String] = []
        for mode in [RadioMode.usb, .lsb] {
            let sign = mode == .usb ? 1.0 : -1.0
            // Gewollt: 1 kHz im richtigen Seitenband; ungewollt gleich stark 1,6 kHz im falschen.
            let audio = Self.run(Self.demodulator(mode), Self.tones([(sign * 1_000, 50), (-sign * 1_600, 50)], seconds: 0.6))
            let suppression = Self.toneLevel(audio, 1_000) - Self.toneLevel(audio, 1_600)
            lines.append(String(format: "%@ Zweiton: Gegenseitenband %.1f dB", mode.rawValue, suppression))
            #expect(suppression >= 40, "\(mode): \(suppression) dB")
        }
        // Spiegelfrequenz (genau gegenüber) über die Kanalleistung.
        for mode in [RadioMode.usb, .lsb] {
            let sign = mode == .usb ? 1.0 : -1.0
            let image = Self.channelLevel(mode, offset: sign * 1_000) - Self.channelLevel(mode, offset: -sign * 1_000)
            lines.append(String(format: "%@ Spiegel ±1 kHz: %.1f dB", mode.rawValue, image))
            #expect(image >= 40, "\(mode) Spiegel: \(image) dB")
        }
        print(lines.joined(separator: "\n"))
    }

    @Test("CW: Träger klingt in der BFO-Tonhöhe, 200 Hz daneben 200 Hz höher")
    func cwPitch() {
        let demod = Self.demodulator(.cw)
        #expect(abs(Self.dominantFrequency(Self.run(demod, Self.tones([(0, 60)], seconds: 0.5))) - 700) < 10)
        let above = Self.demodulator(.cw)
        #expect(abs(Self.dominantFrequency(Self.run(above, Self.tones([(200, 60)], seconds: 0.5))) - 900) < 10)
        let pitched = Self.demodulator(.cw)
        pitched.cwPitchHz = 600
        #expect(abs(Self.dominantFrequency(Self.run(pitched, Self.tones([(0, 60)], seconds: 0.5))) - 600) < 10)
    }

    @Test("Feinabstimmung: Restablage wird digital herausgemischt")
    func fineOffset() {
        let demod = Self.demodulator(.usb)
        demod.fineOffsetHz = 3_210
        let audio = Self.run(demod, Self.tones([(1_000, 60)], seconds: 0.5, shiftHz: 3_210))
        #expect(abs(Self.dominantFrequency(audio) - 1_000) < 10)
    }

    @Test("AGC: 34 dB schwächeres Signal klingt kaum leiser")
    func agc() {
        let strong = Self.rms(Self.run(Self.demodulator(.usb), Self.tones([(1_000, 100)], seconds: 0.5)))
        let weak = Self.rms(Self.run(Self.demodulator(.usb), Self.tones([(1_000, 2)], seconds: 0.5)))
        let difference = 20 * log10(strong / weak)
        print(String(format: "AGC: stark %.3f, schwach %.3f RMS (%.1f dB)", strong, weak, difference))
        #expect(abs(difference) < 3)
    }

    // MARK: - Filter

    @Test("Filterbreiten: Nachbarkanal ≥ 50 dB gedämpft, Durchlass eben (≤ 1 dB)")
    func filterWidths() {
        var lines: [String] = []
        func check(_ mode: RadioMode, _ bandwidth: Double, center: Double, pass: [Double], stop: [Double]) {
            let reference = Self.channelLevel(mode, bandwidth: bandwidth, offset: center)
            for offset in pass {
                let drop = reference - Self.channelLevel(mode, bandwidth: bandwidth, offset: offset)
                lines.append(String(format: "%@ %.0f Hz: Durchlass %+.0f Hz %.2f dB", mode.rawValue, bandwidth, offset, drop))
                #expect(abs(drop) < 1, "\(mode) \(bandwidth) Durchlass \(offset): \(drop) dB")
            }
            for offset in stop {
                let rejection = reference - Self.channelLevel(mode, bandwidth: bandwidth, offset: offset)
                lines.append(String(format: "%@ %.0f Hz: Nachbar %+.0f Hz %.1f dB", mode.rawValue, bandwidth, offset, rejection))
                #expect(rejection >= 50, "\(mode) \(bandwidth) Nachbar \(offset): \(rejection) dB")
            }
        }
        check(.am, 6_000, center: 0, pass: [1_500, -1_500], stop: [6_000, -6_000, 9_000])
        check(.am, 9_000, center: 0, pass: [2_500], stop: [9_000, -9_000])
        check(.nfm, 12_500, center: 0, pass: [3_500, -3_500], stop: [12_500, -12_500])
        check(.nfm, 6_250, center: 0, pass: [1_500], stop: [6_250, -6_250])
        check(.usb, 2_400, center: 1_500, pass: [600, 2_400], stop: [4_000, -1_500, -3_000])
        check(.usb, 1_800, center: 1_200, pass: [600, 1_800], stop: [3_300, -1_200])
        check(.lsb, 2_700, center: -1_650, pass: [-600, -2_600], stop: [-4_300, 1_650])
        check(.cw, 500, center: 0, pass: [100, -100], stop: [1_000, -1_000])
        check(.cw, 250, center: 0, pass: [40, -40], stop: [500, -500])
        print(lines.joined(separator: "\n"))
    }

    @Test("Betriebsarten: Rohwerte unverändert, Bandbreiten nur aus der Liste")
    func modes() {
        // Gespeichert in Favoriten – nie ändern.
        #expect(RadioMode.wfm.rawValue == "UKW (WFM)")
        #expect(RadioMode.nfm.rawValue == "Sprechfunk (NFM)")
        #expect(RadioMode.am.rawValue == "AM")
        #expect(RadioMode(rawValue: "USB") == .usb && RadioMode(rawValue: "LSB") == .lsb && RadioMode(rawValue: "CW") == .cw)
        for mode in RadioMode.allCases {
            if let standard = mode.defaultBandwidthHz { #expect(mode.bandwidthOptionsHz.contains(standard)) }
            #expect(mode.validBandwidth(123) == mode.defaultBandwidthHz)
            #expect(mode.stepOptionsKHz.contains(mode.defaultStepKHz) || mode == .nfm || mode == .am || mode == .wfm)
        }
        #expect(RadioMode.cw.validBandwidth(250) == 250)
        #expect(RadioMode.usb.validBandwidth(250) == 2_400)
        #expect(RadioMode.wfm.validBandwidth(10_000) == nil)
    }

    @Test("Abstimmung: SSB/CW im 10-kHz-Raster plus Restablage, sonst genau")
    func tuning() {
        let ssb = RadioTuning.plan(frequencyMHz: 144.30012, mode: .usb)
        #expect(ssb.hardwareHz % 10_000 == 0)
        #expect(abs(Double(ssb.hardwareHz) + RadioDemodulator.offset + ssb.fineOffsetHz - 144_300_120) < 0.5)
        #expect(abs(ssb.fineOffsetHz) <= 5_000)
        let fm = RadioTuning.plan(frequencyMHz: 99.2, mode: .wfm)
        #expect(fm.hardwareHz == 98_960_000 && fm.fineOffsetHz == 0)
        let low = RadioTuning.plan(frequencyMHz: 1.24, mode: .cw)
        #expect(low.hardwareHz >= 1_000_000)
        #expect(RadioTuning.fileFrequency(144.3, mode: .usb) == "144.30000")
    }
}

@Suite("Tonaufnahme")
struct AudioRecordingTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Tonaufnahme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("WAV: Kopf, verschachtelte 16-bit-Werte, Begrenzung; Mono als Mittelwert")
    func wav() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stereo = dir.appendingPathComponent("s.wav")
        let recorder = AudioFileRecorder(url: stereo, format: .wav, channels: 2)
        let left: [Float] = (0..<1_000).map { Float($0) / 1_000 }
        let right: [Float] = left.map { -$0 }
        recorder.append(left: left, right: right)
        recorder.append(left: [2], right: [-2])           // wird auf ±1 begrenzt
        recorder.finishAndWait()
        let data = try Data(contentsOf: stereo)
        #expect(data.count == 44 + 1_001 * 4)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        func u16(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
        func s16(_ at: Int) -> Int16 { Int16(bitPattern: u16(at)) }
        #expect(u32(4) == UInt32(data.count - 8))
        #expect(u16(22) == 2 && u32(24) == 48_000 && u16(34) == 16)
        #expect(u32(40) == 1_001 * 4)
        #expect(s16(44 + 500 * 4) == 16_384 && s16(44 + 500 * 4 + 2) == -16_384)
        #expect(s16(44 + 1_000 * 4) == 32_767 && s16(44 + 1_000 * 4 + 2) == -32_767)
        #expect(abs(recorder.seconds - 1_001 / 48_000) < 1e-9)

        let mono = dir.appendingPathComponent("m.wav")
        let monoRecorder = AudioFileRecorder(url: mono, format: .wav, channels: 1)
        monoRecorder.append(left: [0.5, 1], right: [0.0, 0])
        monoRecorder.finishAndWait()
        let monoData = try Data(contentsOf: mono)
        #expect(monoData.count == 44 + 4)
        #expect(Int16(bitPattern: UInt16(monoData[44]) | UInt16(monoData[45]) << 8) == 8_192)
    }

    @Test("WAV: Größengrenze beendet die Aufnahme mit Grund, Datei bleibt lesbar")
    func wavLimit() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("g.wav")
        let recorder = AudioFileRecorder(url: url, format: .wav, channels: 1, wavLimit: 100)
        recorder.append(left: [Float](repeating: 0.1, count: 40), right: [Float](repeating: 0.1, count: 40))
        recorder.append(left: [Float](repeating: 0.1, count: 40), right: [Float](repeating: 0.1, count: 40))
        recorder.finishAndWait()
        #expect(recorder.failure != nil)
        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + 80)
        #expect(UInt32(data[40]) | UInt32(data[41]) << 8 == 80)
    }

    @Test("AAC: m4a mit der richtigen Dauer und Kanalzahl")
    func aac() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.m4a")
        let recorder = AudioFileRecorder(url: url, format: .aac, channels: 2)
        let tone: [Float] = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        for start in stride(from: 0, to: tone.count, by: 4_800) {
            let part = Array(tone[start..<start + 4_800])
            recorder.append(left: part, right: part)
        }
        recorder.finishAndWait()
        #expect(recorder.failure == nil)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 2)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 1) < 0.05)
        #expect(recorder.bytesWritten > 1_000)
    }

    @Test("Dateinamen: Quelle, Zeit, Frequenz – ohne Doppelpunkt/Schrägstrich, Liste je Quelle")
    func names() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = AudioRecordingStore.fileName(source: "DAB+", detail: "AC/DC: Live", date: date, format: .aac)
        #expect(name.hasPrefix("DAB+ ") && name.hasSuffix(".m4a"))
        #expect(!name.contains(":") && !name.contains("/"))
        let first = AudioRecordingStore.newURL(source: "Radio", detail: "99.20 MHz UKW", format: .wav, date: date, in: dir)
        FileManager.default.createFile(atPath: first.path, contents: Data([1]))
        let second = AudioRecordingStore.newURL(source: "Radio", detail: "99.20 MHz UKW", format: .wav, date: date, in: dir)
        #expect(second != first)
        FileManager.default.createFile(atPath: second.path, contents: Data([1, 2]))
        let dab = AudioRecordingStore.newURL(source: "DAB+", detail: "Dlf", format: .aac, date: date, in: dir)
        FileManager.default.createFile(atPath: dab.path, contents: Data([1]))
        #expect(AudioRecordingStore.list(source: "Radio", in: dir).count == 2)
        #expect(AudioRecordingStore.list(source: "DAB+", in: dir).map(\.url.lastPathComponent) == [dab.lastPathComponent])
    }
}
