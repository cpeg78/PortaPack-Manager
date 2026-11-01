import Foundation
import Testing
@testable import PortaPackManager

@Suite("Flugfunk")
struct AirbandTests {
    /// Komplexes Basisband bei `rate`: je Eintrag AM-Träger auf Kanalablage
    /// (in 25/3 kHz) mit Ton, dazu Rauschen.
    private func baseband(count: Int, rate: Double, carriers: [(offset: Int, tone: Double, amplitude: Double)],
                          noise: Double, seed: UInt64) -> (re: [Float], im: [Float]) {
        var re = [Float](repeating: 0, count: count), im = [Float](repeating: 0, count: count)
        var rng = SplitMixNoise(seed: seed)
        for n in 0..<count {
            let t = Double(n) / rate
            var r = noise * rng.gaussian(), i = noise * rng.gaussian()
            for c in carriers {
                let a = c.amplitude * (1 + 0.8 * sin(2 * .pi * c.tone * t))
                let p = 2 * Double.pi * Double(c.offset) * AirbandGrid.spacingHz * t
                r += a * cos(p)
                i += a * sin(p)
            }
            re[n] = Float(r)
            im[n] = Float(i)
        }
        return (re, im)
    }

    private func dominantFrequency(_ x: [Float], rate: Double) -> Double {
        let settled = Array(x.dropFirst(x.count / 4))
        let mean = settled.reduce(0, +) / Float(settled.count)
        var crossings = 0
        for k in 1..<settled.count where settled[k - 1] - mean < 0 && settled[k] - mean >= 0 { crossings += 1 }
        return Double(crossings) / (Double(settled.count) / rate)
    }

    private func powerDB(_ re: [Float], _ im: [Float]) -> Double {
        let p = zip(re, im).reduce(0.0) { $0 + Double($1.0 * $1.0 + $1.1 * $1.1) } / Double(max(re.count, 1))
        return 10 * log10(max(p, 1e-20))
    }

    @Test("Filterbank: Ton auf Kanal X kommt nur aus Kanal X")
    func isolation() {
        let channelizer = AirbandChannelizer()
        let (re, im) = baseband(count: 1_600_000, rate: channelizer.sampleRate,
                                carriers: [(37, 400, 0.2), (-120, 1000, 0.2)], noise: 0.0005, seed: 1)
        let select = [37, -120, 38, 36, -119, 200, 0].map { channelizer.binIndex(offset: $0) }
        let out = channelizer.process(re: re, im: im, select: select)
        #expect(out.frames > 3000)
        let levels = (0..<select.count).map { powerDB(out.selectedRe[$0], out.selectedIm[$0]) }
        // Nutzkanäle laut, Nachbarn und ferne Kanäle mindestens 40 dB leiser.
        for quiet in 2..<select.count {
            #expect(levels[0] - levels[quiet] > 40, "Kanal \(quiet): \(levels)")
            #expect(levels[1] - levels[quiet] > 40, "Kanal \(quiet): \(levels)")
        }
        // Die Hüllkurve trägt den richtigen Ton.
        func envelope(_ k: Int) -> [Float] { zip(out.selectedRe[k], out.selectedIm[k]).map { ($0 * $0 + $1 * $1).squareRoot() } }
        #expect(abs(dominantFrequency(envelope(0), rate: channelizer.outputRate) - 400) < 15)
        #expect(abs(dominantFrequency(envelope(1), rate: channelizer.outputRate) - 1000) < 25)
    }

    @Test("Filterbank 16 MS/s: 1920 Kanäle, gleiche Kanalbreite")
    func wide() {
        let channelizer = AirbandChannelizer(sampleRate: 16_000_000, bins: 1920, hop: 1000)
        #expect(channelizer.outputRate == 16_000)
        let (re, im) = baseband(count: 800_000, rate: 16_000_000, carriers: [(-700, 600, 0.2)], noise: 0.0005, seed: 2)
        let select = [-700, -699, 700].map { channelizer.binIndex(offset: $0) }
        let out = channelizer.process(re: re, im: im, select: select)
        let levels = (0..<3).map { powerDB(out.selectedRe[$0], out.selectedIm[$0]) }
        #expect(levels[0] - levels[1] > 40)
        #expect(levels[0] - levels[2] > 40)
    }

    @Test("Rauschsperre: öffnet bei Signal, Nachlauf, schließt")
    func squelch() {
        var s = ChannelSquelch()
        let block = 0.016
        for _ in 0..<100 { s.gate(s.update(powerDB: -60, seconds: block, thresholdDB: 8), seconds: block) }
        #expect(!s.open)
        // Ein einzelner Block (Tastklick, Einschwingen) öffnet nicht, zwei schon.
        s.gate(s.update(powerDB: -45, seconds: block, thresholdDB: 8), seconds: block)
        #expect(!s.open)
        s.gate(s.update(powerDB: -45, seconds: block, thresholdDB: 8), seconds: block)
        #expect(s.open)
        #expect(abs(s.excessDB - 15) < 1)
        // Nach Spruchende noch 0,4 s offen, dann zu.
        var openBlocks = 0
        for _ in 0..<60 {
            s.gate(s.update(powerDB: -60, seconds: block, thresholdDB: 8), seconds: block)
            if s.open { openBlocks += 1 }
        }
        #expect((24...25).contains(openBlocks))   // 0,4 s Nachlauf bei 16-ms-Blöcken
        // Unter der Schwelle (5 dB < 8 dB) bleibt sie zu.
        s.gate(s.update(powerDB: -55, seconds: block, thresholdDB: 8), seconds: block)
        #expect(!s.open)
    }

    @Test("Dauerträger hebt den Boden – Sperre schließt nach einer Weile")
    func carrier() {
        var s = ChannelSquelch()
        for _ in 0..<50 { s.gate(s.update(powerDB: -60, seconds: 0.1, thresholdDB: 8), seconds: 0.1) }
        for _ in 0..<1200 { s.gate(s.update(powerDB: -40, seconds: 0.1, thresholdDB: 8), seconds: 0.1) }
        #expect(!s.open)
    }

    @Test("Übersprechen eines sehr starken Nachbarn zählt nicht")
    func leakage() {
        #expect(ChannelSquelch.isLeakage(excess: 10, neighborExcess: 60))
        #expect(!ChannelSquelch.isLeakage(excess: 20, neighborExcess: 40))
    }

    @Test("Auswahl: Vorrang, laufender Spruch, Halten, Sperre")
    func selector() {
        typealias C = AirbandSelector.Candidate
        let a = C(index: 10, excessDB: 12, priority: false, locked: false)
        let b = C(index: 20, excessDB: 25, priority: false, locked: false)
        let emergency = C(index: AirbandChannel.emergencyIndex, excessDB: 9, priority: true, locked: false)
        let locked = C(index: 30, excessDB: 40, priority: false, locked: true)
        #expect(AirbandSelector.choose(open: [a, b], current: nil, hold: nil) == 20)          // lautester
        #expect(AirbandSelector.choose(open: [a, b], current: 10, hold: nil) == 10)           // nicht unterbrechen
        #expect(AirbandSelector.choose(open: [a, b, emergency], current: 10, hold: nil) == emergency.index)
        #expect(AirbandSelector.choose(open: [a, locked], current: nil, hold: nil) == 10)     // gesperrt nie
        #expect(AirbandSelector.choose(open: [b], current: nil, hold: 10) == 10)              // gehalten
        #expect(AirbandSelector.choose(open: [], current: 10, hold: nil) == nil)
    }

    @Test("Raster und Kanalnamen (8,33 und 25 kHz)")
    func grid() {
        #expect(AirbandGrid.count == 2280)
        #expect(AirbandGrid.channelName(0) == "118.000")
        #expect(AirbandGrid.channelName(1) == "118.010")
        #expect(AirbandGrid.channelName(2) == "118.015")
        #expect(AirbandGrid.channelName(3) == "118.025")
        #expect(AirbandGrid.index(parsing: "118.005") == 0)
        #expect(AirbandGrid.index(parsing: "118,010") == 1)
        #expect(AirbandGrid.index(parsing: "118.00833") == 1)
        #expect(AirbandGrid.index(parsing: "121.5") == AirbandChannel.emergencyIndex)
        #expect(abs(AirbandGrid.mhz(AirbandChannel.emergencyIndex) - 121.5) < 1e-9)
        #expect(AirbandGrid.index(parsing: "132.130") == AirbandGrid.index(nearestHz: 132_125_000))
        #expect(AirbandGrid.index(parsing: "118.020") == nil)   // kein gültiger Kanalname
        #expect(AirbandGrid.index(parsing: "140") == nil)
        #expect(AirbandGrid.index(parsing: "abc") == nil)
        // Rückweg: Name → Index → Name
        for index in [0, 1, 2, 3, 100, 1234, 2279] {
            #expect(AirbandGrid.index(parsing: AirbandGrid.channelName(index)) == index)
        }
    }

    @Test("Ausschnitt: deckt die Liste ab, Notfrequenz hat Vorrang, kein Kanal auf DC")
    func window() {
        let channels = [118.1, 118.5, 121.5, 135.0].map { AirbandChannel(index: AirbandGrid.index(parsing: "\($0)")!, name: "", priority: $0 == 121.5) }
        let w = AirbandWindow.best(for: channels, bins: 960)
        #expect(w.covers(AirbandChannel.emergencyIndex))
        #expect(w.covers(channels[0].index) && w.covers(channels[1].index))
        #expect(!w.covers(channels[3].index))       // 135 MHz liegt 17 MHz entfernt
        #expect(!channels.contains { $0.index == w.center })
        let wide = AirbandWindow.best(for: channels, bins: 1920)
        #expect(wide.covers(channels[2].index))
        // 16 MHz nur, wenn es mehr Listenkanäle abdeckt (sonst halbe Rechenlast).
        let near = Array(channels.prefix(3))
        #expect(!AirbandModel.needsWide(near, allowed: true))
        #expect(AirbandModel.needsWide(near + [AirbandChannel(index: AirbandGrid.index(parsing: "126.0")!, name: "")], allowed: true))
        #expect(!AirbandModel.needsWide(channels + [AirbandChannel(index: AirbandGrid.index(parsing: "124.0")!, name: "")], allowed: false))
        // Suchlauf deckt das Band ab (mit beiden Versätzen auch die Mitten).
        var covered = Set<Int>()
        for shift in 0..<2 { for w in AirbandWindow.sweep(bins: 960, shift: shift) { covered.formUnion(AirbandGrid.range.filter(w.covers)) } }
        #expect(covered.count == AirbandGrid.count)
    }

    /// int8-IQ-Block (8 MS/s, 15 ms – Träger und Ton passen ganzzahlig hinein,
    /// Töne deshalb Vielfache von 200 Hz; sonst springt die Phase an der Blockgrenze).
    private func block(carriers: [(offset: Int, tone: Double, amplitude: Double)], seed: UInt64) -> Data {
        let (re, im) = baseband(count: 120_000, rate: 8_000_000, carriers: carriers, noise: 2, seed: seed)
        var data = Data(count: re.count * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            for n in re.indices {
                p[2 * n] = Int8(max(-127, min(127, re[n].rounded())))
                p[2 * n + 1] = Int8(max(-127, min(127, im[n].rounded())))
            }
        }
        return data
    }

    @Test("Empfänger: Spruch auf Kanal A wird hörbar und landet im Verlauf, B bleibt still")
    func receiver() throws {
        let buffer = AudioRingBuffer(capacity: 48_000 * 4)
        let receiver = AirbandReceiver(output: buffer)
        let a = AirbandChannel(index: 500, name: "A"), b = AirbandChannel(index: 520, name: "B")
        receiver.lock.withLock {
            receiver.setWindow(AirbandWindow(center: 400, bins: 960))
            receiver.channels = [a, b]
            receiver.recordAudio = true
        }
        let quiet = block(carriers: [], seed: 1)
        let talk = block(carriers: [(100, 400, 30)], seed: 2)
        var now = Date(timeIntervalSince1970: 1_000_000)
        func feed(_ data: Data, blocks: Int) {
            for _ in 0..<blocks {
                receiver.process(data, now: now)
                now += 0.015
            }
        }
        feed(quiet, blocks: 40)                  // 0,6 s Boden lernen
        #expect(receiver.lock.withLock { receiver.audible } == nil)
        feed(talk, blocks: 80)                   // 1,2 s Spruch auf A
        let (audible, open) = receiver.lock.withLock { (receiver.audible, receiver.channelOpen) }
        #expect(audible == a.index)
        #expect(open == [a.index])
        feed(quiet, blocks: 60)                  // 0,9 s Stille → Spruch endet
        let done = receiver.lock.withLock { receiver.takeFinished() }
        #expect(done.count == 1)
        let item = try #require(done.first)
        #expect(item.0.index == a.index)
        #expect(item.0.name == "A")
        #expect(abs(item.0.duration - 1.2) < 0.1, "Dauer \(item.0.duration)")
        let samples = try #require(item.1)
        // Mitschnitt mit 16 kHz trägt den 400-Hz-Ton.
        let audio = samples.map { Float($0) / 32_000 }
        #expect(abs(dominantFrequency(audio, rate: 16_000) - 400) < 20)
        #expect(abs(Double(audio.count) / 16_000 - item.0.duration) < 0.05)   // ohne Nachlauf
        #expect(receiver.lock.withLock { receiver.audible } == nil)
    }

    @Test("Suchlauf zählt Verkehr je Kanal")
    func finder() {
        let receiver = AirbandReceiver(output: nil)
        receiver.lock.withLock {
            receiver.setWindow(AirbandWindow(center: 400, bins: 960))
            receiver.finderActive = true
        }
        let quiet = block(carriers: [], seed: 3)
        let talk = block(carriers: [(-50, 600, 30)], seed: 4)
        let blip = block(carriers: [(-80, 600, 30)], seed: 5)
        var now = Date()
        // 1,2 s Spruch auf −50, dazu ein Stoß von 0,3 s auf −80 (kein Spruch).
        let sequence = [Data](repeating: quiet, count: 30) + [Data](repeating: talk, count: 80)
            + [Data](repeating: quiet, count: 40) + [Data](repeating: blip, count: 20) + [Data](repeating: quiet, count: 40)
        for data in sequence {
            receiver.process(data, now: now)
            now += 0.015
        }
        let activity = receiver.lock.withLock { receiver.activity }
        let hits = activity.filter { $0.value.transmissions > 0 }
        #expect(hits.keys.contains(350))
        #expect(hits[350]?.transmissions == 1)
        #expect(hits.count <= 3, "Fehlauslösungen: \(hits.keys.sorted())")
        // Der kurze Stoß öffnete die Sperre, zählt aber nicht als Spruch.
        #expect((activity[320]?.bursts ?? 0) >= 1)
        #expect((activity[320]?.transmissions ?? 0) == 0)
    }

    @Test("Verlauf: WAV-Kopf und Kürzen mit Löschen der Mitschnitte")
    func log() async throws {
        let db = TestDatabase()
        defer { db.remove() }
        let folder = db.folder.appendingPathComponent("Flugfunk")
        let log = AirbandLog(folder: folder, database: db.database)
        let wav = AirbandLog.wav([0, 1000, -1000], rate: 16_000)
        #expect(wav.count == 44 + 6)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        var first = AirbandTransmission(start: Date(timeIntervalSince1970: 0), duration: 1, index: 420, name: "Not", peakDB: 20)
        // Eine halbe Sekunde Ton – AAC braucht ein paar Rahmen.
        first.recording = log.writeRecording((0..<8000).map { Int16(8000 * sin(Double($0) * 0.3)) }, for: first)
        let name = try #require(first.recording)
        #expect(FileManager.default.fileExists(atPath: log.recordingURL(name).path))
        #expect(name.hasSuffix(".m4a"))
        log.insert([first])
        var list = log.merge([first], into: [])
        let many = (1...AirbandLog.limit).map { AirbandTransmission(start: Date(timeIntervalSince1970: Double($0)), duration: 1, index: 1, name: "", peakDB: 1) }
        log.insert(many)
        list = log.merge(many, into: list)
        #expect(list.count == AirbandLog.limit)
        #expect(!list.contains { $0.id == first.id })
        #expect(!FileManager.default.fileExists(atPath: log.recordingURL(name).path))
        // In der Datenbank bleibt der herausgefallene Eintrag – ohne Mitschnitt.
        await db.database.flush()
        #expect(log.load().count == AirbandLog.limit)
        let all = try db.database.sync { try $0.recentTransmissions(limit: 5000) }
        #expect(all.count == AirbandLog.limit + 1)
        #expect(all.first { $0.id == first.id }?.recording == nil)
        // Löschen eines Eintrags und des ganzen Verlaufs.
        log.delete(list[0])
        await db.database.flush()
        #expect(try db.database.sync { try $0.recentTransmissions(limit: 5000) }.count == AirbandLog.limit)
        log.deleteAll(list)
        #expect(await log.loadRecent().isEmpty)
    }
}

@Suite("Flugfunk – Spracherkennung")
struct AirbandVoiceTests {
    /// Sprachähnlich: Summe aus Tönen 300–2500 Hz mit Silbenrhythmus (4 Hz), Modulationsgrad ~0,4.
    static func speech(seconds: Double) -> [Float] {
        let n = Int(seconds * 16_000)
        return (0..<n).map { i in
            let t = Double(i) / 16_000
            let syllable = 0.5 + 0.5 * sin(2 * .pi * 4 * t)
            let tones = sin(2 * .pi * 450 * t) + 0.7 * sin(2 * .pi * 1_100 * t + 1) + 0.5 * sin(2 * .pi * 2_300 * t + 2)
            return Float(0.18 * syllable * tones)
        }
    }

    static func noise(seconds: Double, rms: Float, seed: UInt64 = 7) -> [Float] {
        var state = seed
        return (0..<Int(seconds * 16_000)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(state >> 40) / Float(1 << 24)
            return (u - 0.5) * rms * 3.46
        }
    }

    @Test("Sprache wird erkannt, auch mit etwas Rauschen")
    func speechDetected() {
        var d = AirbandVoiceDetector()
        let s = Self.speech(seconds: 2), n = Self.noise(seconds: 2, rms: 0.05)
        d.feed(zip(s, n).map { $0 + $1 })
        #expect(d.isSpeech)
        #expect(AirbandReceiver.counts(seconds: 2, voice: d, speechOnly: true))
    }

    @Test("Rauschen und leerer Träger sind keine Sprache")
    func noiseAndCarrierRejected() {
        var noise = AirbandVoiceDetector()
        noise.feed(Self.noise(seconds: 2, rms: 0.3))
        #expect(!noise.isSpeech)
        var carrier = AirbandVoiceDetector()
        carrier.feed(Self.noise(seconds: 2, rms: 0.005))
        #expect(!carrier.isSpeech)
    }

    @Test("Kurze Öffnungen zählen nicht, ohne Filter ab 0,5 s")
    func shortBursts() {
        var d = AirbandVoiceDetector()
        d.feed(Self.speech(seconds: 0.7))
        #expect(!AirbandReceiver.counts(seconds: 0.7, voice: d, speechOnly: true))
        #expect(AirbandReceiver.counts(seconds: 0.7, voice: d, speechOnly: false))
        #expect(!AirbandReceiver.counts(seconds: 0.3, voice: d, speechOnly: false))
    }
}
