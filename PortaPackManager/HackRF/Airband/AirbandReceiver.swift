import Accelerate
import Foundation

/// Eine abgeschlossene Übertragung (ein Funkspruch) auf einem Listenkanal.
struct AirbandTransmission: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var start: Date
    var duration: Double
    var index: Int
    var name: String
    /// Höchster Abstand zum Rauschboden in dB.
    var peakDB: Float
    /// Dateiname des Mitschnitts (WAV), falls aufgezeichnet.
    var recording: String?
    /// Rohtext der Spracherkennung (`AirbandTranscription`) – im Archiv per
    /// Volltextsuche durchsuchbar. Aufbereitet wird nur für die Anzeige.
    var transcript: String?
    var transcriptLanguage: String?
    var transcriptConfidence: Double?
    /// Im Spruch erkanntes Rufzeichen eines ADS-B-Flugzeugs und dessen ICAO-Adresse (hex).
    var callsign: String?
    var aircraftICAO: String?

    var mhz: Double { AirbandGrid.mhz(index) }
}

/// Was der Suchlauf „aktive Kanäle finden“ je Rasterkanal gesehen hat.
struct AirbandActivity: Sendable, Equatable {
    var observedSeconds = 0.0
    var openSeconds = 0.0
    /// Sprüche (mit „Nur Sprache“: nur erkannte Sprache).
    var transmissions = 0
    /// Alle Öffnungen der Rauschsperre, auch Knackser und Trägertasten.
    var bursts = 0
    var peakDB: Float = 0

    /// Fast immer offen: Dauerträger (ATIS/VOLMET) oder Störlinie.
    var looksContinuous: Bool { observedSeconds > 5 && openSeconds / observedSeconds > 0.8 }

    /// Zählt die Beobachtung eines Blocks hinzu.
    mutating func merge(_ other: AirbandActivity) {
        observedSeconds += other.observedSeconds
        openSeconds += other.openSeconds
        transmissions += other.transmissions
        bursts += other.bursts
        peakDB = max(peakDB, other.peakDB)
    }
}

/// Ein Fund des Suchlaufs.
struct AirbandFinding: Identifiable, Sendable, Equatable {
    var index: Int
    var activity: AirbandActivity
    var id: Int { index }
}

/// Der Empfangsteil der Flugfunkseite: Filterbank über den ganzen Ausschnitt,
/// Rauschsperre je Kanal, Auswahl des hörbaren Kanals, AM-Demodulation,
/// Verlauf und Mitschnitt. Läuft auf der Empfangswarteschlange.
///
/// Zwei Locks (Review 28.10.2026, Y13 – vorher lief die ganze Rechnung unter
/// `lock`, und der Main Actor wartete bei jedem Poll auf den Block):
/// - `lock` schützt Einstellungen und veröffentlichte Ergebnisse; alle
///   Zugriffe von außen laufen darüber. Die Auswertung kopiert am Blockanfang
///   die Einstellungen und veröffentlicht am Ende die Ergebnisse – beides kurz.
/// - `work` schützt den Rechenzustand (Filterbank, Rauschsperren, Audio).
///   Die Auswertung hält ihn während der Rechnung, nie zusammen mit `lock`.
///   `setWindow`, `resetState` und `resetActivity` werden von außen unter
///   `lock` gerufen und nehmen `work` dazu – Reihenfolge immer `lock` → `work`,
///   daher keine Verklemmung.
final class AirbandReceiver: @unchecked Sendable {
    static let finishedLimit = 200
    static let maxRecordingSeconds = 120.0
    static let minTransmissionSeconds = 0.5

    let lock = NSLock()
    private let work = NSLock()
    let channelizer: AirbandChannelizer
    let output: AudioRingBuffer?

    // Einstellungen (unter `lock` setzen)
    private(set) var window: AirbandWindow
    var channels: [AirbandChannel] = []
    var thresholdDB: Float = 8
    var volume: Float = 0.5
    /// Ton für den Fernzugriff (48 kHz mono, volle Lautstärke); `nil` = aus.
    var remoteTap: (@Sendable ([Float]) -> Void)?
    /// Mac stumm, solange jemand aus der Ferne zuhört.
    var localMuted = false
    var hold: Int?
    /// Ton der Sprüche mitliefern: zum Aufzeichnen (`recordAudio`) und/oder für die
    /// Spracherkennung (`transcribeAudio`, nur im Speicher). Was davon gilt,
    /// entscheidet `AirbandModel` beim Abholen.
    var recordAudio = false
    var transcribeAudio = false
    var finderActive = false
    /// Nur Sprache zählt als Spruch (Verlauf und Suchlauf), siehe `AirbandVoiceDetector`.
    var speechOnly = true

    // Zustand (unter `lock` lesen)
    private(set) var audible: Int?
    /// Abstand zum Rauschboden je Listenkanal (dB) und ob die Sperre offen ist.
    private(set) var channelExcess: [Int: Float] = [:]
    private(set) var channelOpen: Set<Int> = []
    private(set) var finished: [(AirbandTransmission, [Int16]?)] = []
    private(set) var activity: [Int: AirbandActivity] = [:]
    private(set) var processedSeconds = 0.0
    /// Zählen Rücksetzungen (unter `lock` und `work` geschrieben). Ein Block,
    /// der vor einer Rücksetzung begonnen hat, veröffentlicht nichts Veraltetes.
    private var stateGeneration = 0
    private var activityGeneration = 0

    // Rechenzustand (unter `work`)
    private var squelch: [ChannelSquelch]
    private var audio: [Int: ChannelAudio] = [:]
    private var workAudible: Int?
    private var lastAudible: Int?
    private var outputGain: Float = 0
    private var upsampleHistory: [Float] = []
    private let upsampleFilter = RadioDemodulator.lowpass(taps: 63, cutoff: 3_800, rate: 48_000)

    private struct ChannelAudio {
        var carrier: Float = 0
        var wasOpen = false
        var active = false
        var start = Date()
        var lastAbove = Date()
        var peak: Float = 0
        var samples: [Int16] = []
        /// Letzter Block (16 kHz) für die Wiedergabe.
        var block: [Float] = []
        var voice = AirbandVoiceDetector()
    }

    /// Ein offener Kanal im Suchlauf: Ton wird mitdemoduliert, um Sprache zu erkennen.
    private struct FinderOpen {
        var audio = ChannelAudio()
        var aboveSeconds = 0.0
    }
    private var finderOpen: [Int: FinderOpen] = [:]

    /// Kopie der Einstellungen für einen Block.
    private struct Settings {
        var window: AirbandWindow
        var channels: [AirbandChannel]
        var thresholdDB: Float
        var volume: Float
        var remoteTap: (@Sendable ([Float]) -> Void)?
        var localMuted: Bool
        var hold: Int?
        var recordAudio: Bool
        var finderActive: Bool
        var speechOnly: Bool
        var stateGeneration: Int
        var activityGeneration: Int
    }

    /// Ergebnis eines Blocks, unter `lock` veröffentlicht.
    private struct BlockResult {
        var updated = false
        var seconds = 0.0
        var excess: [Int: Float] = [:]
        var open: Set<Int> = []
        var audible: Int?
        var finished: [(AirbandTransmission, [Int16]?)] = []
        var activity: [Int: AirbandActivity] = [:]
    }

    init(sampleRate: Double = 8_000_000, bins: Int = 960, output: AudioRingBuffer?) {
        channelizer = AirbandChannelizer(sampleRate: sampleRate, bins: bins, hop: Int(sampleRate / 16_000))
        window = AirbandWindow(center: 1140, bins: bins)
        squelch = [ChannelSquelch](repeating: ChannelSquelch(), count: bins)
        self.output = output
    }

    /// Neue Lage des Ausschnitts (unter `lock` aufrufen): Böden neu lernen.
    func setWindow(_ window: AirbandWindow) {
        guard window != self.window else { return }
        self.window = window
        resetState()
    }

    /// Unter `lock` aufrufen. Laufende Sprüche landen sofort in `finished`.
    func resetState() {
        work.withLock {
            channelizer.reset()
            for k in squelch.indices { squelch[k].reset() }
            // Laufende Sprüche abschließen, sonst gehen sie verloren.
            let now = Date()
            for (index, state) in audio where state.active {
                if let item = Self.finish(index: index, state: state, end: now, channels: channels,
                                          speechOnly: speechOnly, recordAudio: recordAudio || transcribeAudio) {
                    append(finished: [item])
                }
            }
            audio = [:]
            finderOpen = [:]
            workAudible = nil
            lastAudible = nil
            stateGeneration += 1
        }
        channelExcess = [:]
        channelOpen = []
        audible = nil
    }

    /// Unter `lock` aufrufen.
    func takeFinished() -> [(AirbandTransmission, [Int16]?)] {
        defer { finished = [] }
        return finished
    }

    /// Unter `lock` aufrufen.
    func resetActivity() {
        activity = [:]
        work.withLock {
            finderOpen = [:]
            activityGeneration += 1
        }
    }

    /// Unter `lock`: neue Sprüche anhängen, begrenzt auf `finishedLimit`.
    private func append(finished items: [(AirbandTransmission, [Int16]?)]) {
        guard !items.isEmpty else { return }
        finished += items
        if finished.count > Self.finishedLimit { finished.removeFirst(finished.count - Self.finishedLimit) }
    }

    /// Verarbeitet einen IQ-Block (int8, `channelizer.sampleRate`).
    func process(_ block: Data, now: Date = Date()) {
        let (re, im) = AirbandChannelizer.convert(block)
        let settings = lock.withLock {
            Settings(window: window, channels: channels, thresholdDB: thresholdDB, volume: volume, remoteTap: remoteTap, localMuted: localMuted, hold: hold,
                     recordAudio: recordAudio || transcribeAudio, finderActive: finderActive, speechOnly: speechOnly,
                     stateGeneration: stateGeneration, activityGeneration: activityGeneration)
        }
        let result = work.withLock { () -> BlockResult? in
            // Inzwischen zurückgesetzt (neuer Ausschnitt): Block verwerfen.
            guard stateGeneration == settings.stateGeneration else { return nil }
            return process(re: re, im: im, now: now, settings: settings)
        }
        guard let result else { return }
        lock.withLock {
            append(finished: result.finished)
            processedSeconds += result.seconds
            if result.updated, stateGeneration == settings.stateGeneration {
                channelExcess = result.excess
                channelOpen = result.open
                audible = result.audible
            }
            if activityGeneration == settings.activityGeneration {
                for (index, delta) in result.activity { activity[index, default: AirbandActivity()].merge(delta) }
            }
        }
    }

    private func process(re: [Float], im: [Float], now: Date, settings: Settings) -> BlockResult {
        var result = BlockResult()
        let window = settings.window
        let finderActive = settings.finderActive
        let thresholdDB = settings.thresholdDB
        let bins = channelizer.bins
        let listed = settings.channels.compactMap { channel -> (AirbandChannel, Int)? in
            guard let offset = window.offset(of: channel.index) else { return nil }
            return (channel, channelizer.binIndex(offset: offset))
        }
        // Im Suchlauf auch die gerade offenen Kanäle demodulieren (Spracherkennung).
        let finderBins = finderActive ? finderOpen.keys.sorted() : []
        let out = channelizer.process(re: re, im: im, select: listed.map(\.1) + finderBins)
        var finderSelected: [Int: Int] = [:]
        for (k, b) in finderBins.enumerated() { finderSelected[b] = listed.count + k }
        // Noch kein ganzer Ausgabewert: nichts zu veröffentlichen.
        guard out.frames > 0 else { return result }
        result.updated = true
        let seconds = Double(out.frames) / channelizer.outputRate
        result.seconds = seconds
        let scale = 1 / Float(out.frames)

        // Rauschsperre je Kanal (nutzbare Ablagen, ohne Mitte).
        let half = window.halfWidth
        var above = [Bool](repeating: false, count: bins)
        for offset in -half...half where offset != 0 {
            let b = channelizer.binIndex(offset: offset)
            let db = 10 * log10(max(out.powerSum[b] * scale, 1e-20))
            above[b] = squelch[b].update(powerDB: db, seconds: seconds, thresholdDB: thresholdDB)
        }
        for offset in -half...half where offset != 0 {
            let b = channelizer.binIndex(offset: offset)
            var hit = above[b]
            if hit {
                let left = channelizer.binIndex(offset: offset - 1), right = channelizer.binIndex(offset: offset + 1)
                let neighbor = max(squelch[left].excessDB, squelch[right].excessDB)
                if ChannelSquelch.isLeakage(excess: squelch[b].excessDB, neighborExcess: neighbor) { hit = false }
            }
            let wasOpen = squelch[b].open
            squelch[b].gate(hit, seconds: seconds)
            if finderActive {
                let index = window.center + offset
                guard AirbandGrid.range.contains(index) else { continue }
                var stat = AirbandActivity()
                stat.observedSeconds += seconds
                if squelch[b].open {
                    stat.openSeconds += seconds
                    stat.peakDB = max(stat.peakDB, squelch[b].excessDB)
                    var entry = finderOpen[b] ?? FinderOpen()
                    if hit { entry.aboveSeconds += seconds }
                    if let k = finderSelected[b] {
                        let block = Self.demodulate(re: out.selectedRe[k], im: out.selectedIm[k], state: &entry.audio,
                                                    opening: entry.audio.voice.samples == 0)
                        if hit { entry.audio.voice.feed(block) }
                    }
                    finderOpen[b] = entry
                } else if wasOpen, let entry = finderOpen.removeValue(forKey: b) {
                    stat.bursts += 1
                    if Self.counts(seconds: entry.aboveSeconds, voice: entry.audio.voice, speechOnly: settings.speechOnly) {
                        stat.transmissions += 1
                    }
                }
                result.activity[index] = stat
            }
        }

        // Listenkanäle: Pegel, Hörbarkeit, Audio, Verlauf.
        var candidates: [AirbandSelector.Candidate] = []
        for (k, (channel, b)) in listed.enumerated() {
            let s = squelch[b]
            result.excess[channel.index] = s.excessDB
            var state = audio[channel.index] ?? ChannelAudio()
            state.block = Self.demodulate(re: out.selectedRe[k], im: out.selectedIm[k], state: &state, opening: s.open && !state.wasOpen)
            state.wasOpen = s.open
            if s.open {
                result.open.insert(channel.index)
                candidates.append(.init(index: channel.index, excessDB: s.excessDB, priority: channel.priority, locked: channel.locked))
                if !state.active {
                    state.active = true
                    state.start = now.addingTimeInterval(-seconds)
                    state.peak = 0
                    state.samples = []
                    state.voice = AirbandVoiceDetector()
                }
                if s.excessDB > thresholdDB {
                    state.lastAbove = now
                    state.voice.feed(state.block)
                }
                state.peak = max(state.peak, s.excessDB)
                if settings.recordAudio, Double(state.samples.count) < Self.maxRecordingSeconds * 16_000 {
                    state.samples.append(contentsOf: state.block.map { Int16(max(-1, min(1, $0)) * 32_000) })
                }
            } else if state.active {
                if let item = Self.finish(index: channel.index, state: state, end: state.lastAbove, channels: settings.channels,
                                          speechOnly: settings.speechOnly, recordAudio: settings.recordAudio) {
                    result.finished.append(item)
                }
                state.active = false
                state.samples = []
            }
            audio[channel.index] = state
        }
        // Kanäle, die aus der Liste oder dem Ausschnitt gefallen sind.
        let present = Set(listed.map(\.0.index))
        for (index, state) in audio where !present.contains(index) {
            if state.active, let item = Self.finish(index: index, state: state, end: now, channels: settings.channels,
                                                     speechOnly: settings.speechOnly, recordAudio: settings.recordAudio) {
                result.finished.append(item)
            }
            audio[index] = nil
        }
        let holdIndex = settings.hold.flatMap { present.contains($0) ? $0 : nil }
        workAudible = AirbandSelector.choose(open: candidates, current: workAudible, hold: holdIndex)
        result.audible = workAudible

        writeAudio(frames: out.frames, volume: settings.volume, remoteTap: settings.remoteTap, localMuted: settings.localMuted)
        return result
    }

    /// AM: Hüllkurve, geteilt durch den Träger (gleitender Mittelwert ≈ 0,5 s;
    /// beim Öffnen auf den Blockmittelwert gesetzt, sonst wäre der Spruchanfang
    /// übersteuert). Ergebnis ist der Modulationsgrad, also schon pegelrichtig.
    private static func demodulate(re: [Float], im: [Float], state: inout ChannelAudio, opening: Bool) -> [Float] {
        guard !re.isEmpty else { return [] }
        var env = [Float](repeating: 0, count: re.count)
        for n in env.indices { env[n] = (re[n] * re[n] + im[n] * im[n]).squareRoot() }
        let mean = vDSP.mean(env)
        if opening || state.carrier <= 0 { state.carrier = mean }
        let alpha: Float = 1 / (0.5 * 16_000)
        var carrier = state.carrier
        for n in env.indices {
            carrier += alpha * (env[n] - carrier)
            env[n] = carrier > 0 ? max(-1, min(1, (env[n] / carrier - 1) * 0.9)) : 0
        }
        state.carrier = carrier
        return env
    }

    /// Abgeschlossener Spruch, falls er zählt (`nil` sonst).
    private static func finish(index: Int, state: ChannelAudio, end: Date, channels: [AirbandChannel],
                               speechOnly: Bool, recordAudio: Bool) -> (AirbandTransmission, [Int16]?)? {
        let duration = max(0, end.timeIntervalSince(state.start))
        guard counts(seconds: duration, voice: state.voice, speechOnly: speechOnly) else { return nil }
        let name = channels.first { $0.index == index }?.name ?? ""
        let transmission = AirbandTransmission(start: state.start, duration: duration, index: index, name: name, peakDB: state.peak)
        // Mitschnitt ohne den Nachlauf der Rauschsperre (nur Rauschen).
        let samples = Array(state.samples.prefix(Int(duration * 16_000)))
        return (transmission, recordAudio && !samples.isEmpty ? samples : nil)
    }

    /// Zählt ein Spruch? Mindestdauer immer, Spracherkennung nur mit `speechOnly`.
    static func counts(seconds: Double, voice: AirbandVoiceDetector, speechOnly: Bool) -> Bool {
        guard speechOnly else { return seconds >= minTransmissionSeconds }
        return seconds >= AirbandVoiceDetector.minSeconds && voice.isSpeech
    }

    /// Hörbaren Kanal auf 48 kHz bringen (×3, Tiefpass 3,8 kHz) und ausgeben;
    /// beim Wechsel ein- bzw. ausblenden. Ohne Kanal Stille, damit der
    /// Puffer gleichmäßig läuft.
    private func writeAudio(frames: Int, volume: Float, remoteTap: (@Sendable ([Float]) -> Void)?, localMuted: Bool) {
        guard let output else { return }
        var source: [Float]
        var target: Float = 1
        let audible = workAudible
        if let audible, let block = audio[audible]?.block, !block.isEmpty {
            source = block
            if audible != lastAudible { outputGain = 0 }
        } else if let last = lastAudible, let block = audio[last]?.block, !block.isEmpty {
            source = block
            target = 0
        } else {
            source = [Float](repeating: 0, count: frames)
            target = 0
        }
        lastAudible = audible
        if source.count != frames { source = Array(source.prefix(frames)) + [Float](repeating: 0, count: max(0, frames - source.count)) }
        let start = outputGain, step = (target - start) / Float(max(1, source.count))
        for n in source.indices { source[n] *= start + step * Float(n + 1) }
        outputGain = target
        var stuffed = [Float](repeating: 0, count: source.count * 3)
        for n in source.indices { stuffed[3 * n] = 3 * source[n] }
        var up = RadioDemodulator.decimateReal(stuffed, history: &upsampleHistory, filter: upsampleFilter, factor: 1)
        vDSP.clip(up, to: -1...1, result: &up)
        // Fernzugriff bekommt den Ton ohne den Lautstärkeregler des Mac.
        remoteTap?(up)
        if localMuted {
            output.write([Float](repeating: 0, count: up.count))
        } else {
            output.write(vDSP.multiply(volume, up))
        }
    }
}
