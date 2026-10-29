import Foundation
import Testing
@testable import PortaPackManager

@Suite("IQ-Aufnahme")
struct RecorderTests {
    @Test("Recorder schreibt Blöcke und meldet die Bytezahl")
    func writesBlocks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iq-\(UUID().uuidString).c8")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = IQRecorder()
        try recorder.start(url: url)
        recorder.write(Data([1, 2, 3, 4]))
        recorder.write(Data([5, 6]))
        #expect(recorder.bytesWritten == 6)
        #expect(recorder.stop() == 6)
        #expect(recorder.failure == nil)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4, 5, 6]))
    }

    @Test("Nicht anlegbare Datei wirft statt still nichts aufzunehmen")
    func startThrowsOnBadPath() {
        let url = URL(fileURLWithPath: "/nicht/vorhanden/\(UUID().uuidString).c8")
        #expect(throws: (any Error).self) { try IQRecorder().start(url: url) }
    }

    @Test("Passende ADS-B-Aufnahme ohne Hinweis, falsche Rate mit Hinweis")
    @MainActor
    func adsbMismatch() {
        let ok = IQRecording(name: "a", centerHz: 1_090_000_000, sampleRate: 2_000_000, date: Date(), byteCount: 2)
        #expect(RecorderModel.mismatch(ok, for: .adsb) == nil)
        let wrongRate = IQRecording(name: "b", centerHz: 1_090_000_000, sampleRate: 2_048_000, date: Date(), byteCount: 2)
        #expect(RecorderModel.mismatch(wrongRate, for: .adsb) != nil)
        #expect(RecorderModel.mismatch(wrongRate, for: .spectrum) == nil)
    }

    @Test("GPS-Aufnahme mit falscher Mitte bekommt einen Hinweis")
    @MainActor
    func gpsMismatch() {
        let ok = IQRecording(name: "c", centerHz: 1_575_420_000, sampleRate: 2_048_000, date: Date(), byteCount: 2)
        #expect(RecorderModel.mismatch(ok, for: .gps) == nil)
        let wrongCenter = IQRecording(name: "d", centerHz: 1_090_000_000, sampleRate: 2_048_000, date: Date(), byteCount: 2)
        #expect(RecorderModel.mismatch(wrongCenter, for: .gps) != nil)
    }

    // MARK: - Fernsehen und DAB+

    @Test("Vorlage „DVB-T2-Kanal“ stellt Rate, Mitte und Filter wie die Fernsehseite ein")
    @MainActor
    func tvPreset() throws {
        let model = RecorderModel()
        model.tvChannel = TVChannel(number: 23)
        model.applyTVPreset()
        #expect(UInt32((model.sampleRateMHz * 1_000_000).rounded()) == UInt32(T2FrontEnd.inputRate.rounded()))
        #expect(UInt32((model.sampleRateMHz * 1_000_000).rounded()) == 18_285_714)
        // Wie TVModel.start: Kanalmitte + fs/4 (abgeschnitten wie dort).
        #expect(UInt64((model.centerMHz * 1_000_000).rounded()) == TVChannel(number: 23).frequency + UInt64(T2FrontEnd.tuningOffset))
        #expect(UInt64((model.centerMHz * 1_000_000).rounded()) == 494_571_428)
        #expect(model.basebandFilterHz == 20_000_000)
        #expect(model.analysis == .tv)
        // 36,6 MB/s.
        #expect(abs(model.bytesPerSecond - 36_571_428.6) < 1)
        // Andere Rate: Filter wieder automatisch.
        model.sampleRateMHz = 10
        #expect(model.basebandFilterHz == nil)
    }

    @Test("Vorlage „DAB-Block“ stellt 8,192 MS/s und die Blockmitte ein")
    @MainActor
    func dabPreset() throws {
        let model = RecorderModel()
        model.dabChannel = try #require(DABChannel.named("5C"))
        model.applyDABPreset()
        #expect(UInt32((model.sampleRateMHz * 1_000_000).rounded()) == DABFrontEnd.inputRate)
        #expect(UInt64((model.centerMHz * 1_000_000).rounded()) == 178_352_000)
        #expect(model.basebandFilterHz == nil)
        #expect(model.analysis == .dab)
    }

    @Test("Fernseh- und DAB-Aufnahmen: passende ohne Hinweis, falsche Rate oder Mitte mit Hinweis")
    @MainActor
    func tvAndDABMismatch() {
        let tv = IQRecording(name: "t", centerHz: 494_571_428, sampleRate: 18_285_714, date: Date(), byteCount: 2)
        #expect(RecorderModel.mismatch(tv, for: .tv) == nil)
        #expect(IQPreset.tvChannel(center: tv.centerHz)?.number == 23)
        let tvCenterOnChannel = IQRecording(name: "u", centerHz: 490_000_000, sampleRate: 18_285_714, date: Date(), byteCount: 2)
        #expect(RecorderModel.mismatch(tvCenterOnChannel, for: .tv) != nil)
        let tvWrongRate = IQRecording(name: "v", centerHz: 494_571_428, sampleRate: 20_000_000, date: Date(), byteCount: 2)
        #expect(RecorderModel.mismatch(tvWrongRate, for: .tv) != nil)
        let dab = IQRecording(name: "w", centerHz: 178_352_000, sampleRate: 8_192_000, date: Date(), byteCount: 2)
        #expect(RecorderModel.mismatch(dab, for: .dab) == nil)
        #expect(IQPreset.dabChannel(center: dab.centerHz)?.name == "5C")
        #expect(RecorderModel.mismatch(dab, for: .tv) != nil)
        let dabOff = IQRecording(name: "x", centerHz: 179_000_000, sampleRate: 8_192_000, date: Date(), byteCount: 2)
        #expect(RecorderModel.mismatch(dabOff, for: .dab) != nil)
    }

    @Test("Höchstdauer der Aufnahme aus freiem Platz und Datenrate")
    func durationText() {
        #expect(RecorderView.durationText(45) == "45 s")
        #expect(RecorderView.durationText(750) == "12 min 30 s")
        #expect(RecorderView.durationText(7500) == "2 h 05 min")
    }

    /// Simulierte K23-Rahmen als .c8-Datei, abgespielt wie eine Aufnahme.
    @Test("DVB-T2-Aufnahme offline: Betriebsart, Blöcke und Dienst werden erkannt")
    func tvOffline() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t2-\(UUID().uuidString).c8")
        defer { try? FileManager.default.removeItem(at: url) }
        let transmitter = T2TestTransmitter(seed: 3)
        var parameters = T2TestChannel.Parameters()
        parameters.snrDB = 25
        let channel = T2TestChannel(parameters, occupiedFraction: transmitter.occupiedFraction)
        var frame = transmitter.frame()
        channel.calibrate(re: frame.re, im: frame.im)
        var data = channel.silence(samples: 100_000)
        for index in 0..<3 {
            data += channel.process(re: frame.re, im: frame.im)
            if index < 2 { frame = transmitter.frame() }
        }
        data += channel.silence(samples: 20_000)
        try data.write(to: url)

        let decoder = TVOfflineDecoder()
        IQPlayer().play(url: url, handler: { decoder.process($0) }, progress: { _ in }, isCancelled: { false })
        let channel23 = IQPreset.tvChannel(center: 494_571_428)
        let result = decoder.result(channel: channel23)
        #expect(result.status.locked)
        #expect(result.modeDescription == "16K erw. · 19/128 · PP2")
        #expect(result.plpDescription?.contains("64-QAM 1/2") == true)
        #expect(result.status.blocksGood >= 102 && result.status.blocksBad == 0)
        #expect(result.status.snr > 18)
        let service = try #require(result.services.first { $0.id == T2TestTransmitter.programNumber })
        #expect(service.name == T2TestTransmitter.serviceName)
        #expect(service.provider == T2TestTransmitter.serviceProvider)
        #expect(result.channel?.number == 23)
    }

    /// DAB-Rahmen (2,048 MS/s) auf 8,192 MS/s hochgetastet und als int8 abgelegt – wie vom HackRF.
    @Test("DAB-Aufnahme offline: Ensemble und Dienst werden gelesen")
    func dabOffline() throws {
        let fic = DABTestTransmitter.ficBits(DABTestTransmitter.exampleFIBs())
        let frames = (0..<12).map { _ in fic + [UInt8](repeating: 0, count: 72 * DABMode.bitsPerSymbol) }
        let signal = DABTestTransmitter.frames(frames, frequencyOffset: 1_234, noise: 0.05, seed: 5)
        // ×4: Nullen einfügen und tiefpassfiltern.
        let filter = RadioDemodulator.lowpass(taps: 95, cutoff: 900_000, rate: 8_192_000)
        let n = signal.re.count * 4
        var upRe = [Float](repeating: 0, count: n + filter.count), upIm = upRe
        for i in signal.re.indices { upRe[4 * i] = signal.re[i] * 4; upIm[4 * i] = signal.im[i] * 4 }
        var peak: Float = 0
        var outRe = [Float](repeating: 0, count: n), outIm = outRe
        for t in 0..<n {
            var r: Float = 0, m: Float = 0
            // Nur jeder vierte Eingang ist ungleich null.
            var k = t % 4
            while k < filter.count {
                let source = t - k
                if source >= 0 { r += filter[k] * upRe[source]; m += filter[k] * upIm[source] }
                k += 4
            }
            outRe[t] = r; outIm[t] = m
            peak = max(peak, abs(r), abs(m))
        }
        let gain = 100 / peak
        var bytes = [Int8](repeating: 0, count: 2 * n)
        for t in 0..<n {
            bytes[2 * t] = Int8((outRe[t] * gain).rounded())
            bytes[2 * t + 1] = Int8((outIm[t] * gain).rounded())
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dab-\(UUID().uuidString).c8")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.withUnsafeBufferPointer { try Data(buffer: $0).write(to: url) }

        let decoder = DABOfflineDecoder()
        IQPlayer().play(url: url, handler: { decoder.process($0) }, progress: { _ in }, isCancelled: { false })
        let result = decoder.result(channel: IQPreset.dabChannel(center: 178_352_000))
        #expect(result.status.synchronized)
        #expect(result.status.ensemble.label == "Test-Mux", "Rahmen \(result.status.framesDecoded), FIC \(result.status.ficQuality), SNR \(result.status.snr), Ablage \(result.status.frequencyOffset)")
        let service = try #require(result.services.first)
        #expect(service.label == "Radio Eins")
        #expect(service.kind == .dabPlus && service.bitrate == 48)
        #expect(result.channel?.name == "5C")
    }
}
