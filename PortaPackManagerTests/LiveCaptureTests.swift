import Foundation
import Testing
@testable import PortaPackManager

private let liveCaptureFolder = ProcessInfo.processInfo.environment["LIVE_IQ"].map { URL(fileURLWithPath: $0) }

/// Live-Proben: echte IQ-Aufnahmen (`Tools/iq-capture.sh`) durch dieselben
/// Dekoder wie die App. Dateiname `<empfänger>_<rate>_<mitte>.iq`, Abstimmung
/// genau wie das jeweilige Modell. Läuft nur mit
/// `TEST_RUNNER_LIVE_IQ=<ordner> xcodebuild test -only-testing:PortaPackManagerTests/LiveCaptureTests …`
/// und prüft nichts – es gibt aus, was gefunden wurde.
@Suite("Live-Aufnahmen", .enabled(if: liveCaptureFolder != nil))
struct LiveCaptureTests {

    /// Aufnahmen eines Empfängers (Dateiname beginnt mit `prefix`), sortiert.
    private func files(_ prefix: String) throws -> [URL] {
        guard let folder = liveCaptureFolder else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".iq") }.sorted()
            .map { folder.appending(path: $0) }
    }

    /// Mitte in Hz aus dem Dateinamen `<name>_<rate>_<mitte>.iq`.
    private func center(_ url: URL) -> UInt64 {
        UInt64(url.deletingPathExtension().lastPathComponent.split(separator: "_").last ?? "") ?? 0
    }

    /// Liest die Aufnahme in Blöcken zu 256 KiB wie der Empfang.
    private func blocks(_ name: String, _ body: (Data) -> Void) throws {
        guard let url = try files(name + "_").first else { return }
        try blocks(url, body)
    }

    private func blocks(_ url: URL, _ body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let block = try handle.read(upToCount: 262_144), !block.isEmpty { body(block) }
    }

    private func report(_ name: String, _ lines: [String]) {
        print("LIVE \(name): " + lines.joined(separator: "\nLIVE \(name):   "))
    }

    /// DVB-T2: Dateien `tv<kanal>_<rate>_<mitte>.iq` (Vorlage „DVB-T2-Kanal“).
    @Test func fernsehen() throws {
        for url in try files("tv") {
            let decoder = TVOfflineDecoder()
            try blocks(url) { decoder.process($0) }
            let result = decoder.result(channel: IQPreset.tvChannel(center: center(url)))
            let st = result.status
            report("Fernsehen", [url.lastPathComponent + ": " + st.stage + " · " + result.modeDescription,
                                 String(format: "  SNR %.1f dB (nötig %@), Ablage %.0f Hz / %.2f ppm, Rahmen %d, Blöcke %d gut / %d schlecht, Pakete %d",
                                        st.snr, result.requiredSNR.map { String(format: "%.1f dB", $0) } ?? "?",
                                        st.frequencyOffsetHz, st.sampleRateOffsetPPM, st.frames, st.blocksGood, st.blocksBad, st.packets),
                                 "  " + (result.plpDescription ?? "kein PLP") + (st.message.map { " · " + $0 } ?? ""),
                                 "  Netz „\(result.networkName)“, Dienste: " + result.services.map { $0.name }.joined(separator: ", ")])
        }
    }

    /// GPS: Datei `gps_<rate>_<mitte>.iq`, Bezugsdatum = Änderungsdatum der Datei.
    @Test func gps() throws {
        guard let url = try files("gps_").first else { return }
        var options = GPSReceiver.Options()
        options.sampleRate = Double(url.deletingPathExtension().lastPathComponent.split(separator: "_")[1]) ?? 4_096_000
        options.asynchronousAcquisition = false
        options.referenceDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let receiver = GPSReceiver(options: options)
        try blocks(url) { receiver.process($0) }
        let st = receiver.status
        var lines = [String(format: "%.0f s, Ephemeriden %d, Lösungen %d", st.elapsed, st.ephemerisCount, st.fixCount)]
        lines += st.channels.map { "\($0)" }.prefix(12)
        lines += st.acquisition.map { "Akquisition \($0)" }.prefix(12)
        if let solution = st.solution { lines.append("Lösung \(solution)") }
        report("GPS", lines)
    }

    /// METEOR-LRPT: Datei `meteor_2880000_137500000.iq` (wie `MeteorModel`),
    /// beide Frequenzen; ein Bild landet im Bilderordner der METEOR-Seite.
    @Test func meteor() throws {
        for url in try files("meteor") {
            for frequency in MeteorReceiver.frequencies {
                let receiver = MeteorReceiver(offset: frequency - Double(MeteorReceiver.centerFrequency), signal: .oqpsk72)
                var best = MeteorReceiver.Snapshot()
                try blocks(url) { block in
                    receiver.process(block)
                    let s = receiver.snapshot
                    if s.frame.framesOK >= best.frame.framesOK { best = s }
                }
                let s = receiver.snapshot
                var lines = [String(format: "%@ %.1f MHz: Pegel %.1f dB, Lock %@ (%.2f), Ablage %.0f Hz, BER %.3f (%@), Rahmen %d gut / %d schlecht, Pakete %d, Zeilen %d, Kanäle %@",
                                    url.lastPathComponent, frequency / 1e6, s.levelDB, s.locked ? "ja" : "nein", s.lockQuality,
                                    s.frequencyOffset, best.frame.bitErrorRate, best.frame.hypothesis,
                                    s.frame.framesOK, s.frame.framesFailed, s.packets, s.lines, "\(s.segments)")]
                if s.lines >= 16 {
                    let prefix = "live-" + url.deletingPathExtension().lastPathComponent
                    lines += try MeteorPNG.saveAll(receiver.currentImage, prefix: prefix).map { "Bild " + $0.path }
                }
                report("METEOR", lines)
            }
        }
    }

    @Test func radiosonden() throws {
        let receiver = SondeReceiver()
        // Kommagetrennte Frequenzen in Hz festhalten (Prüfung einzelner Träger).
        for value in (ProcessInfo.processInfo.environment["LIVE_SONDE_PIN"] ?? "").split(separator: ",") {
            if let hz = Double(value) { receiver.pin(hz) }
        }
        let analyzer = SpectrumAnalyzer(fftSize: 8192)
        var reports: [SondeReport] = []
        var channels: [Double: (count: Int, level: Float)] = [:]
        var carriers: [Double: Int] = [:]
        var index = 0
        var totalLinear: [Float]?
        try blocks("sonde") { block in
            receiver.process(block)
            reports += receiver.takeReports()
            for channel in receiver.activeChannels {
                let old = channels[channel.frequency] ?? (0, -200)
                channels[channel.frequency] = (old.count + 1, max(old.level, channel.levelDB))
            }
            analyzer.process(block, maxFFTs: 2)
            index += 1
            if index % 40 == 0, let spectrum = analyzer.takeSpectrum() {
                let linear = spectrum.map { powf(10, $0 / 10) }
                totalLinear = totalLinear.map { zip($0, linear).map(+) } ?? linear
                for offset in SondeReceiver.carriers(in: spectrum, sampleRate: 1e7, threshold: 8) {
                    carriers[(offset / 5000).rounded() * 5000, default: 0] += 1
                }
            }
        }
        // Gemitteltes Spektrum um festgehaltene Frequenzen (dB über dem Median).
        var profile: [String] = []
        if let sum = totalLinear?.map({ 10 * log10f($0) }) {
            let floor = sum.sorted()[sum.count / 2]
            for value in (ProcessInfo.processInfo.environment["LIVE_SONDE_PIN"] ?? "").split(separator: ",") {
                guard let hz = Double(value) else { continue }
                let center = Int(((hz - 403e6) / (1e7 / 8192)).rounded()) + 4096
                let row = (center - 16...center + 16).map { String(format: "%.0f", sum[$0] - floor) }
                profile.append(String(format: "%.3f MHz ±20 kHz: ", hz / 1e6) + row.joined(separator: " "))
            }
        }
        let channelLines = channels.sorted { $0.key < $1.key }
            .map { String(format: "Kanal %.3f MHz: %d Blöcke, Pegel bis %.1f dB", $0.key / 1e6, $0.value.count, $0.value.level) }
        let carrierLines = carriers.sorted { $0.value > $1.value }.prefix(15)
            .map { String(format: "Träger %.3f MHz: %d×", (403e6 + $0.key) / 1e6, $0.value) }
        report("Sonden", ["\(reports.count) Meldungen"] + profile + channelLines + carrierLines + reports.prefix(10).map { "\($0)" })
    }

    /// Symbolrate eines Trägers: mischen, Mittelwert über 400 Werte (25 kS/s),
    /// FM-Diskriminator, dann Leistung der Flankenfolge bei typischen Raten.
    @Test func sondenSymbolrate() throws {
        let frequencies = (ProcessInfo.processInfo.environment["LIVE_SONDE_PIN"] ?? "").split(separator: ",").compactMap { Double($0) }
        for hz in frequencies {
            let offset = hz - 403e6
            var phase = 0.0
            let step = -2 * Double.pi * offset / 1e7
            var accRe = 0.0, accIm = 0.0, n = 0
            var base: [(Double, Double)] = []
            try blocks("sonde") { block in
                block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let p = raw.bindMemory(to: Int8.self)
                    for k in 0..<(block.count / 2) {
                        let c = cos(phase), s = sin(phase)
                        let i = Double(p[2 * k]), q = Double(p[2 * k + 1])
                        accRe += i * c - q * s
                        accIm += i * s + q * c
                        phase += step
                        n += 1
                        if n == 400 { base.append((accRe, accIm)); accRe = 0; accIm = 0; n = 0 }
                    }
                    phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
                }
            }
            // Diskriminator und Flanken (Betrag der Änderung).
            var disc: [Double] = []
            for k in 1..<base.count {
                let (a, b) = base[k - 1], (c, d) = base[k]
                disc.append(atan2(b * c - a * d, a * c + b * d))
            }
            let edges = (1..<disc.count).map { abs(disc[$0] - disc[$0 - 1]) }
            let mean = edges.reduce(0, +) / Double(edges.count)
            func line(_ rate: Double) -> Double {
                var re = 0.0, im = 0.0
                for (k, e) in edges.enumerated() {
                    let w = 2 * Double.pi * rate * Double(k) / 25_000
                    re += (e - mean) * cos(w); im += (e - mean) * sin(w)
                }
                return 10 * log10((re * re + im * im) / Double(edges.count) + 1e-12)
            }
            let rates = [1200.0, 2400, 2500, 4800, 9600, 3000, 3700, 6000]
            report("Symbolrate", [String(format: "%.3f MHz: ", hz / 1e6) + rates.map { String(format: "%.0f Bd %.1f dB", $0, line($0)) }.joined(separator: ", ")])
        }
    }

    @Test func aprs() throws {
        let front = FMChannelizer(channelOffsets: [0], stage1Cutoff: 50_000, channelCutoff: 8_000)
        let demod = AFSKDemodulator()
        var packets: [String] = []
        var frames = 0
        var power: [Float] = []
        try blocks("aprs") { block in
            let found = demod.process(front.process(block)[0])
            frames += found.count
            power.append(front.channelPowerDB.first ?? -100)
            packets += found.compactMap(AX25Frame.parse).map { "\(APRSPacket.parse($0))" }
        }
        report("APRS", ["\(frames) Rahmen, \(packets.count) Pakete, Kanalpegel max \(power.max() ?? -100) dB"] + packets.prefix(15))
    }

    @Test func funkruf() throws {
        let front = FMChannelizer(channelOffsets: [0], stage1Cutoff: 50_000, channelCutoff: 9_000)
        let demod = POCSAGDemodulator()
        var messages: [PagerMessage] = []
        var locked = Set<Int>()
        var power: [Float] = []
        try blocks("pager") { block in
            messages += demod.process(front.process(block)[0])
            locked.formUnion(demod.lockedRates)
            power.append(front.channelPowerDB.first ?? -100)
        }
        report("Funkruf", ["\(messages.count) Rufe, eingerastet \(locked.sorted()), Kanalpegel max \(power.max() ?? -100) dB"]
               + messages.prefix(15).map { "\($0)" })
    }

    /// VDL2: `vdl2_2100000_136850000.iq` (2,1 MS/s, vier Kanäle 136,725–136,975 MHz).
    @Test func vdl2() throws {
        let receiver = VDL2Receiver()
        var frames: [VDL2Frame] = []
        try blocks("vdl2") { frames += receiver.process($0) }

        let aircraft = Set(frames.compactMap(\.aircraftAddress))
        report("VDL2", ["\(frames.count) Rahmen (\(frames.filter { $0.acars != nil }.count) ACARS), \(aircraft.count) Flugzeuge, "
                        + "\(receiver.syncs) Präambeln, \(receiver.bursts) Bursts, \(receiver.badBursts) FEC-Fehler, \(receiver.rescued) gerettet, "
                        + "\(receiver.badFrames) FCS-Fehler, Pegel \(receiver.channelizer.channelPowerDB)"]
               + frames.prefix(400).map { f in
                   String(format: "%.3f %06X(%d)→%06X(%d) %@ %.0f dB ", f.frequencyMHz, f.source, f.sourceType.rawValue,
                          f.destination, f.destinationType.rawValue, f.kindText, f.levelDB)
                   + (f.acars.map { "\($0.registration) \($0.label) \($0.flight ?? "") \($0.messageNumber ?? "") → \($0.interpretation.summary) \($0.interpretation.rows.map { "\($0.name)=\($0.value)" })" } ?? "")
                   + (f.location.map { String(format: " Position %.1f/%.1f %d ft Ziel %@", $0.latitude, $0.longitude, $0.altitudeFt, f.destinationAirport ?? "–") } ?? "")
                   + (f.atn.map { " ATN[\($0.layers)] \($0.summary) \($0.rows.map { "\($0.name)=\($0.value)" })" } ?? (f.x25.map { " " + $0 } ?? ""))
                   + (f.atn == nil ? (f.x25User.map { " HEX " + $0.map { String(format: "%02x", $0) }.joined() } ?? "") : "")
               })
    }

    @Test func acars() throws {
        guard let plan = ACARSPlan.plan(ACARSPlan.defaultMHz) else { return }
        let receiver = ACARSReceiver(plan: plan)
        var messages: [ACARSMessage] = []
        try blocks("acars") { messages += receiver.process($0) }
        report("ACARS", ["\(messages.count) Meldungen, \(receiver.crcErrors) CRC-Fehler, Pegel \(receiver.channelizer.channelPowerDB)"]
               + messages.prefix(15).map { "\($0)" })
    }

    @Test func funksensoren() throws {
        let demod = SensorDemodulator()
        var trains = 0
        var readings: [String] = []
        try blocks("sensors") { block in
            let found = demod.process(block)
            trains += found.count
            readings += found.flatMap { SensorDecoders.decode($0) }.map { "\($0)" }
        }
        report("Funksensoren", ["\(trains) Pulsfolgen, \(readings.count) dekodiert, Rauschen \(demod.noiseDB) dB"] + readings.prefix(20))
    }

    @Test func meshtastic() throws {
        let preset = MeshtasticPreset.longFast
        let demod = LoRaDemodulator(parameters: preset.parameters, centerFrequency: 869_525_000)
        let channels = [MeshtasticChannel(name: preset.displayName, psk: [1])]
        var frames: [LoRaFrame] = []
        var packets: [String] = []
        try blocks("meshtastic") { block in
            let found = demod.process(block)
            frames += found
            for frame in found where frame.crcValid != false {
                packets.append(Meshtastic.decode(frame.payload, channels: channels).map { "\($0)" } ?? "nicht lesbar: \(frame.payload.count) Byte")
            }
        }
        report("Meshtastic", ["\(frames.count) Rahmen, CRC-Fehler \(demod.crcErrors), Kopffehler \(demod.headerErrors), Rauschen \(demod.noiseDB) dB"]
               + packets.prefix(15))
    }

    /// Bluetooth LE Kanal 37: `ble_8000000_2400000000.iq` (HackRF 2 MHz unter 2402 MHz).
    /// Gibt Pakete, eine Prüfsumme über alle PDUs und die Rechenzeit aus –
    /// für Vorher/Nachher-Vergleiche bei Optimierungen.
    @Test func bluetooth() throws {
        let demod = BLEDemodulator()
        var packets: [BLEPacket] = []
        var seconds = 0.0, bytes = 0
        let clock = ContinuousClock()
        try blocks("ble") { block in
            bytes += block.count
            let d = clock.measure { packets += demod.process(block, channel: 37) }
            seconds += Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let digest = packets.reduce(UInt64(1469598103934665603)) { h, p in p.pdu.reduce(h) { ($0 ^ UInt64($1)) &* 1099511628211 } }
        let audio = Double(bytes / 2) / BLEDemodulator.inputRate
        report("BLE", [String(format: "%d Pakete, Prüfsumme %016llx, %.2f s Rechenzeit für %.1f s Signal (%.0f %% eines Kerns)",
                              packets.count, digest, seconds, audio, 100 * seconds / max(audio, 1e-9))])
    }

    /// WLAN Kanal 6: `wlan_20000000_2437000000.iq` (20 MS/s, Mitte = Kanal).
    @Test func wlan() throws {
        let receiver = WLANReceiver()
        var packets: [WLANPacket] = []
        var seconds = 0.0, bytes = 0
        let clock = ContinuousClock()
        // LIVE_REPEAT=n: Aufnahme n-mal durchlaufen (für `sample` beim Messen).
        let repeats = Int(ProcessInfo.processInfo.environment["LIVE_REPEAT"] ?? "") ?? 1
        for _ in 0..<repeats { try blocks("wlan") { block in
            bytes += block.count
            let d = clock.measure { packets += receiver.process(block) }
            seconds += Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        } }
        let digest = packets.reduce(UInt64(1469598103934665603)) { h, p in p.mpdu.reduce(h) { ($0 ^ UInt64($1)) &* 1099511628211 } }
        let audio = Double(bytes / 2) / WLANReceiver.sampleRate
        let dsss = packets.filter { $0.modulation == .dsss }.count
        report("WLAN", [String(format: "%d Rahmen (%d DSSS, %d OFDM), Prüfsumme %016llx, %.2f s Rechenzeit für %.1f s Signal (%.0f %% eines Kerns)",
                               packets.count, dsss, packets.count - dsss, digest, seconds, audio, 100 * seconds / max(audio, 1e-9)),
                       "DSSS-Stöße \(receiver.dsss.bursts), OFDM-Präambeln \(receiver.ofdm.preambles), SIGNAL-Fehler \(receiver.ofdm.signalErrors), FCS-Fehler OFDM \(receiver.ofdm.fcsErrors) / DSSS \(receiver.dsss.fcsErrors)"])
    }

    /// Rechenlast der Sonden-Vorstufe mit vier festgehaltenen Kanälen (je eigener
    /// Mischer + Dezimierer bei 10 MS/s): `sonde_10000000_403000000.iq`.
    @Test func sondenLast() throws {
        let receiver = SondeReceiver()
        for hz in [401_100_000.0, 402_500_000, 403_700_000, 404_500_000] { receiver.pin(hz) }
        var seconds = 0.0, bytes = 0, reports = 0, levels: [Float] = []
        let clock = ContinuousClock()
        try blocks("sonde") { block in
            bytes += block.count
            let d = clock.measure { receiver.process(block) }
            seconds += Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            reports += receiver.takeReports().count
            levels = receiver.activeChannels.map(\.levelDB)
        }
        let signal = Double(bytes / 2) / Double(SondeReceiver.sampleRate)
        report("Sondenlast", [String(format: "%d Kanäle, %d Meldungen, %.2f s Rechenzeit für %.1f s Signal (%.0f %% eines Kerns), Pegel %@",
                                     levels.count, reports, seconds, signal, 100 * seconds / max(signal, 1e-9),
                                     levels.map { String(format: "%.2f", $0) }.joined(separator: " "))])
    }
}
