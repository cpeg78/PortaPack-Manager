import Foundation

/// Fehler im HackRF-Modus.
enum HackRFError: Error, LocalizedError, Sendable {
    case notFound
    case openFailed(Int32)
    case transferFailed(request: String, code: Int32)
    case invalidParameter(String)
    case imageTooLarge(Int)
    /// Eine andere Seite, der Fernzugriff oder der Empfangsplan hat das Gerät übernommen.
    case takenOver

    var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "Kein HackRF am USB gefunden. Ist das PortaPack angeschlossen und im HackRF-Modus?")
        case let .openFailed(code):
            String(localized: "Der HackRF ließ sich nicht öffnen (Fehler \(Self.hex(code))). Zieh das USB-Kabel kurz ab und steck es wieder an.")
        case let .transferFailed(request, code):
            String(localized: "Die USB-Verbindung zum HackRF hat nicht geantwortet (\(request), \(Self.hex(code))).")
        case let .invalidParameter(text): text
        case let .imageTooLarge(size): String(localized: "Die Firmware-Datei ist mit \(size) Bytes zu groß für den Speicher des HackRF.")
        case .takenOver: String(localized: "Ein anderer Empfänger hat den HackRF übernommen – zum Weitermachen neu starten.")
        }
    }

    private static func hex(_ code: Int32) -> String { String(format: "0x%08X", UInt32(bitPattern: code)) }
}

/// Vendor-Requests der HackRF-Firmware (libhackrf, `hackrf.c`).
enum HackRFRequest: UInt8 {
    case setTransceiverMode = 1
    case sampleRateSet = 6
    case basebandFilterBandwidthSet = 7
    case spiflashErase = 10
    case spiflashWrite = 11
    case spiflashRead = 12
    case boardIDRead = 14
    case versionStringRead = 15
    case setFrequency = 16
    case ampEnable = 17
    case boardPartIDSerialRead = 18
    case setLNAGain = 19
    case setVGAGain = 20
    case antennaEnable = 23
    case reset = 30
    case uiEnable = 37
    case spiflashStatus = 33
    case clkinStatusRead = 44
    case boardRevisionRead = 45
}

/// Kennwerte, die `hackrf_info` ausgibt.
struct HackRFInfo: Sendable, Equatable {
    var boardID: UInt8 = 0
    var firmwareVersion: String = ""
    var partID: String = ""
    var serialNumber: String = ""
    var boardRevision: UInt8?

    var boardName: String {
        switch boardID {
        case 0: "Jellybean"
        case 1: "Jawbreaker"
        case 2: String(localized: "HackRF One (alt)")
        case 3: "rad1o"
        case 4: "HackRF One"
        case 5: "HackRF Pro"
        default: String(localized: "Unbekannt (\(boardID))")
        }
    }
}

/// Ein Gerät im HackRF-Modus. Alle Aufrufe sind synchron und laufen über
/// einen eigenen Lock. Empfangen wird mit ständig offenen asynchronen
/// USB-Transfers; verarbeitet wird getrennt davon auf einer seriellen
/// Warteschlange, damit langsame Auswertung keine Abtastwerte kostet.
final class HackRFDevice: @unchecked Sendable {
    static let productIDs: [UInt16] = [UInt16(USBIdentity.hackRFOne), UInt16(USBIdentity.jawbreaker), 0xCC15]
    static let flashPageSize = 256

    /// Größe des SPI-Flashs je Board-ID. HackRF One (2, 4), Jawbreaker und
    /// rad1o haben 1 MiB (W25Q80); nur das Pro-Abbild von Mayhem ist 4 MiB
    /// groß. Unbekannte Boards bekommen vorsichtshalber 1 MiB – ein zu großes
    /// Abbild liefe sonst über das Chipende um und überschriebe den Anfang.
    static func flashCapacity(boardID: UInt8) -> Int {
        boardID == 5 ? 0x40_0000 : 0x10_0000
    }

    private let handle: OpaquePointer
    private let lock = NSLock()
    /// Hält Start, Stopp und Schließen gegeneinander: `close()` läuft seit
    /// dem 27.10.2026 abseits des Main Actors (`pthread_join` kann dauern),
    /// eine Seite könnte sonst gleichzeitig einen Strom auf dem schon
    /// freigegebenen Handle starten. Rekursiv, weil `startReceiving` selbst
    /// `stopReceiving` aufruft. Rückrufe des Empfangs nehmen ihn nie.
    private let lifecycle = NSRecursiveLock()
    /// Schützt den Empfangszustand (`streaming`, `owner`, `stream`, `flashing`)
    /// für Leser auf anderen Threads. Geschrieben wird er nur unter `lifecycle`
    /// *und* diesem Lock; gelesen wird ein Schnappschuss nur unter diesem –
    /// kurz gehalten, damit der Main Actor nie auf `pthread_join` oder einen
    /// USB-Transfer wartet (Review 28.10.2026, W6: `close()` läuft abseits).
    private let stateLock = NSLock()
    private var _streaming = false
    /// Gewünschte Antennenspeisung; aktiv ist sie nur während des Empfangs.
    private var _antennaPowerWanted = false
    private var _stream: ReceiveStream?
    /// Wer den laufenden Empfang gestartet hat. Nur er darf ihn stoppen –
    /// sonst beendete das Schließen einer Seite den Empfang einer anderen
    /// (Fund 26.10.2026: Fernzugriff ohne Ton, DAB+ hielt sich für laufend).
    private var _owner: ObjectIdentifier?
    /// Der Besitzer selbst (schwach) – für die Pegelautomatik (`AutoGain`).
    private weak var _ownerObject: AnyObject?
    /// SPI-Flash wird beschrieben/gelesen: `startReceiving` wirft dann
    /// `.takenOver` (Review 28.10.2026, W7 – sonst liefen Bulk-Transfers
    /// parallel zum Seitenschreiben).
    private var _flashing = FlashLock()
    /// Stoß-Empfänger (LTE), der das Gerät zwischen seinen Aufnahmen ohne
    /// Strom für sich beansprucht. Jeder Start eines anderen Besitzers hebt
    /// die Reservierung auf (Review 28.10.2026, W2/W3).
    private weak var _burstOwner: AnyObject?
    /// Zuletzt eingestellte Mittenfrequenz (Hz, ohne Quarzkorrektur) – nur zur
    /// Anzeige in der Menüleiste.
    private var _tunedHz: UInt64?

    private var streaming: Bool { stateLock.withLock { _streaming } }
    private var antennaPowerWanted: Bool { stateLock.withLock { _antennaPowerWanted } }
    private var stream: ReceiveStream? { stateLock.withLock { _stream } }
    /// Ob gerade der SPI-Flash beschrieben oder gelesen wird.
    var isFlashing: Bool { stateLock.withLock { _flashing.blocksReceiving } }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        close()
    }

    static func openFirst() throws -> HackRFDevice {
        var error: Int32 = 0
        let ids = productIDs
        let raw = ids.withUnsafeBufferPointer { buffer in
            hrf_usb_open(UInt16(USBIdentity.greatScottGadgets), buffer.baseAddress, buffer.count, &error)
        }
        guard let raw else {
            throw error == 0 ? HackRFError.notFound : HackRFError.openFailed(error)
        }
        let device = HackRFDevice(handle: raw)
        // Wunsch „Display aus“ gleich beim Öffnen anwenden – die Firmware
        // startet immer mit Oberfläche. Ältere Firmware ohne Request 37: egal.
        if !displayEnabled { try? device.setDisplay(false) }
        return device
    }

    // MARK: - PortaPack-Display

    static let displayEnabledKey = "hackrfDisplayEnabled"
    /// Wunsch des Nutzers, ob das PortaPack-Display im HackRF-Modus leuchtet.
    /// Standard: aus.
    static var displayEnabled: Bool {
        get { UserDefaults.standard.object(forKey: displayEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: displayEnabledKey) }
    }

    /// Schaltet die Oberfläche der HackRF-Firmware auf dem PortaPack an oder
    /// aus (Vendor-Request 37, libhackrf `hackrf_set_ui_enable`). Aus heißt in
    /// `ui_portapack.c`: Bild löschen und Hintergrundbeleuchtung ab. Wieder an
    /// zeichnet die Firmware die Oberfläche neu (LCD-Init, ≈ 150 ms).
    func setDisplay(_ enabled: Bool) throws {
        try controlOut(.uiEnable, value: enabled ? 1 : 0)
    }

    private var closed = false
    func close() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        stopReceiving()
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        hrf_usb_close(handle)
    }

    // MARK: - Control-Transfers

    private func controlIn(_ request: HackRFRequest, value: UInt16 = 0, index: UInt16 = 0, length: Int, timeout: UInt32 = 1000) throws -> Data {
        var buffer = Data(count: length)
        // Nach `close()` ist der Handle freigegeben – ein noch laufender Task
        // (Optimierer, WLAN-Suchlauf) hielte sonst auf freiem Speicher.
        let result = buffer.withUnsafeMutableBytes { raw in
            lock.withLock { closed ? -1 : hrf_usb_control_in(handle, request.rawValue, value, index, raw.baseAddress, UInt16(length), timeout) }
        }
        guard result >= 0 else { throw HackRFError.transferFailed(request: "\(request)", code: result) }
        buffer.count = Int(result)
        return buffer
    }

    private func controlOut(_ request: HackRFRequest, value: UInt16 = 0, index: UInt16 = 0, data: Data = Data(), timeout: UInt32 = 1000) throws {
        let result = data.withUnsafeBytes { raw in
            lock.withLock { closed ? -1 : hrf_usb_control_out(handle, request.rawValue, value, index, raw.baseAddress, UInt16(data.count), timeout) }
        }
        guard result >= 0, Int(result) >= data.count else {
            throw HackRFError.transferFailed(request: "\(request)", code: result)
        }
    }

    // MARK: - Information

    func readInfo() throws -> HackRFInfo {
        var info = HackRFInfo()
        info.boardID = try controlIn(.boardIDRead, length: 1).first ?? 0
        info.firmwareVersion = String(decoding: try controlIn(.versionStringRead, length: 255).prefix { $0 != 0 }, as: UTF8.self)
        let ids = try controlIn(.boardPartIDSerialRead, length: 24)
        if ids.count == 24 {
            let words = stride(from: 0, to: 24, by: 4).map { offset in
                ids[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            }
            info.partID = String(format: "0x%08x 0x%08x", words[0], words[1])
            info.serialNumber = words[2...5].map { String(format: "%08x", $0) }.joined()
        }
        info.boardRevision = try? controlIn(.boardRevisionRead, length: 1).first
        return info
    }

    /// Liegt ein externer Takt an CLKIN an (z. B. 10 MHz von einem GPSDO oder
    /// der TCXO eines PortaPack)? Vendor-Request 44, libhackrf
    /// `hackrf_get_clkin_status` (USB-API ≥ 1.06) – nur lesend. Ältere
    /// Firmware kennt den Request nicht: dann ein Fehler, den Aufrufer mit
    /// `try?` als „unbekannt“ lesen.
    func clockInputDetected() throws -> Bool {
        guard let status = try controlIn(.clkinStatusRead, length: 1).first else {
            throw HackRFError.transferFailed(request: "\(HackRFRequest.clkinStatusRead)", code: 0)
        }
        return status == 1
    }

    // MARK: - Funkparameter

    /// Ablage des Referenzquarzes in ppm (positiv: Quarz läuft zu schnell).
    /// Gemessen im Radio an einem UKW-Sender; wirkt auf Frequenz und
    /// Abtastrate, weil der HackRF beides aus demselben Quarz ableitet.
    static var frequencyCorrectionPPM: Double {
        get { UserDefaults.standard.double(forKey: "frequencyCorrectionPPM") }
        set { UserDefaults.standard.set(newValue, forKey: "frequencyCorrectionPPM") }
    }

    /// Wert, der eingestellt werden muss, damit tatsächlich `hz` herauskommt.
    static func corrected(_ hz: Double) -> Double {
        hz / (1 + frequencyCorrectionPPM * 1e-6)
    }

    func setFrequency(_ hz: UInt64) throws {
        let requested = hz
        let hz = UInt64(Self.corrected(Double(hz)).rounded())
        let mhz = UInt32(hz / 1_000_000)
        let rest = UInt32(hz % 1_000_000)
        var payload = Data()
        payload.append(contentsOf: withUnsafeBytes(of: mhz.littleEndian, Array.init))
        payload.append(contentsOf: withUnsafeBytes(of: rest.littleEndian, Array.init))
        try controlOut(.setFrequency, data: payload)
        stateLock.withLock { _tunedHz = requested }
    }

    /// Mittenfrequenz des laufenden Empfangs (Hz) – Empfänger mit Versatz gegen
    /// die DC-Spitze liegen etwas neben ihrem Kanal. `nil` ohne Empfang.
    var tunedFrequencyHz: UInt64? { stateLock.withLock { _streaming ? _tunedHz : nil } }

    /// Abtastrate in Hz (2–20 MHz). Setzt danach das passende Basisbandfilter.
    func setSampleRate(_ hz: UInt32) throws {
        guard (2_000_000...20_000_000).contains(hz) else {
            throw HackRFError.invalidParameter(String(localized: "Die Abtastrate muss zwischen 2 und 20 MHz liegen."))
        }
        // Frequenz und Teiler: der Teiler erlaubt Bruchteile von Hz für die Quarzkorrektur.
        let divider: UInt32 = 16
        let scaled = UInt32((Self.corrected(Double(hz)) * Double(divider)).rounded())
        var payload = Data()
        payload.append(contentsOf: withUnsafeBytes(of: scaled.littleEndian, Array.init))
        payload.append(contentsOf: withUnsafeBytes(of: divider.littleEndian, Array.init))
        try controlOut(.sampleRateSet, data: payload)
        try setBasebandFilter(Self.basebandFilter(for: UInt32(Double(hz) * 0.75)))
    }

    func setBasebandFilter(_ hz: UInt32) throws {
        try controlOut(.basebandFilterBandwidthSet, value: UInt16(hz & 0xFFFF), index: UInt16(hz >> 16))
    }

    /// LNA (ZF) 0–40 dB in 8-dB-Schritten.
    func setLNAGain(_ db: Int) throws {
        let value = UInt16(max(0, min(40, db)) & ~0x07)
        let reply = try controlIn(.setLNAGain, index: value, length: 1)
        guard reply.first == 1 else { throw HackRFError.invalidParameter(String(localized: "Der HackRF hat die LNA-Verstärkung abgelehnt.")) }
    }

    /// VGA (Basisband) 0–62 dB in 2-dB-Schritten.
    func setVGAGain(_ db: Int) throws {
        let value = UInt16(max(0, min(62, db)) & ~0x01)
        let reply = try controlIn(.setVGAGain, index: value, length: 1)
        guard reply.first == 1 else { throw HackRFError.invalidParameter(String(localized: "Der HackRF hat die VGA-Verstärkung abgelehnt.")) }
    }

    func setAmplifier(_ enabled: Bool) throws {
        try controlOut(.ampEnable, value: enabled ? 1 : 0)
    }

    /// Antennenspeisung (Bias-Tee, 3,3 V am Antennenanschluss). Liegt nur
    /// während des Empfangs an – `stopReceiving` schaltet sie ab, damit keine
    /// Spannung stehen bleibt, wenn danach eine passive Antenne (oder ein
    /// Messgerät) angesteckt wird; `startReceiving` stellt sie wieder her.
    func setAntennaPower(_ enabled: Bool) throws {
        let active = stateLock.withLock { () -> Bool in
            _antennaPowerWanted = enabled
            return _streaming
        }
        guard active || !enabled else { return }
        try controlOut(.antennaEnable, value: enabled ? 1 : 0)
    }

    /// Startet das Gerät neu. Ein PortaPack kehrt dabei in die Mayhem-Firmware zurück.
    func reset() throws {
        try controlOut(.reset)
    }

    static let basebandFilters: [UInt32] = [
        1_750_000, 2_500_000, 3_500_000, 5_000_000, 5_500_000, 6_000_000, 7_000_000, 8_000_000,
        9_000_000, 10_000_000, 12_000_000, 14_000_000, 15_000_000, 20_000_000, 24_000_000, 28_000_000,
    ]

    /// Wie `hackrf_compute_baseband_filter_bw`: größter Wert ≤ Wunsch (mindestens der kleinste).
    static func basebandFilter(for hz: UInt32) -> UInt32 {
        basebandFilters.last { $0 <= hz } ?? basebandFilters[0]
    }

    // MARK: - Empfang

    /// Startet den Empfang. `handler` bekommt Blöcke vorzeichenbehafteter
    /// 8-Bit-IQ-Paare (I, Q, I, Q, …) der Reihe nach auf einer seriellen
    /// Hintergrund-Warteschlange.
    ///
    /// Läuft schon ein Empfang eines anderen Besitzers, wird er beendet – der
    /// letzte Start bekommt das Gerät. Derselbe Besitzer startet nicht doppelt.
    func startReceiving(owner: AnyObject, handler: @escaping @Sendable (Data) -> Void) throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !lock.withLock({ closed }) else { throw HackRFError.notFound }
        // Während des Flashens gehört das Gerät der Installation (W7).
        guard !isFlashing else { throw HackRFError.takenOver }
        let id = ObjectIdentifier(owner)
        let (running, current) = stateLock.withLock { (_streaming, _owner) }
        if running {
            if current == id { return }
            stopReceiving()
        }
        let stream = ReceiveStream(handler: handler)
        let context = Unmanaged.passRetained(stream).toOpaque()
        // 16 × 256 KiB: bei 20 MS/s gut 100 ms Reserve, bevor der HackRF überläuft.
        let result = hrf_usb_stream_start(handle, 16, 262_144, { context, data, length in
            guard let context, let data else { return }
            Unmanaged<ReceiveStream>.fromOpaque(context).takeUnretainedValue().receive(data, Int(length))
        }, context)
        guard result == 0 else {
            Unmanaged<ReceiveStream>.fromOpaque(context).release()
            throw HackRFError.transferFailed(request: String(localized: "Empfang starten"), code: result)
        }
        do {
            try controlOut(.setTransceiverMode, value: 1)
            if antennaPowerWanted { try controlOut(.antennaEnable, value: 1) }
        } catch {
            hrf_usb_stream_stop(handle)
            // Schon eingereihte Blöcke dürfen den Rückruf nicht mehr erreichen.
            stream.finish()
            Unmanaged<ReceiveStream>.fromOpaque(context).release()
            throw error
        }
        stateLock.withLock {
            _stream = stream
            _streaming = true
            _owner = id
            _ownerObject = owner
            if _burstOwner !== owner { _burstOwner = nil }
        }
    }

    /// Reserviert das Gerät für einen Empfänger, der in kurzen Stößen
    /// aufnimmt und den Strom zwischendurch freigibt (`receivesInBursts`).
    /// Zwischen den Stößen empfängt niemand – mit der Reservierung erkennen
    /// Fernzugriffs-Wächter und Stoß-Empfänger selbst, wem das Gerät gehört.
    /// Startet ein anderer Besitzer, verfällt sie.
    func reserveForBursts(owner: AnyObject) {
        stateLock.withLock { _burstOwner = owner }
    }

    /// Gibt die Reservierung frei, falls `owner` sie noch hält.
    func releaseBurstReservation(owner: AnyObject) {
        stateLock.withLock { if _burstOwner === owner { _burstOwner = nil } }
    }

    /// Wer das Gerät für Stoßaufnahmen reserviert hat (`nil`: niemand).
    var burstOwner: AnyObject? { stateLock.withLock { _burstOwner } }

    /// Beendet den Empfang, aber nur, wenn `owner` ihn gestartet hat.
    func stopReceiving(owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        // Erst ohne `lifecycle` prüfen – Nicht-Besitzer warten so nie auf ein
        // laufendes `close()` –, dann unter `lifecycle` erneut.
        guard stateLock.withLock({ _owner }) == id else { return }
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard stateLock.withLock({ _owner }) == id else { return }
        stopReceiving()
    }

    /// Beendet jeden Empfang, gleich wer ihn gestartet hat (Moduswechsel,
    /// Schließen, Fernzugriff übernimmt das Gerät).
    func stopReceiving() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        // Erst den Zustand umlegen (Leser sehen sofort „kein Empfang“), den
        // Strom aber bis nach `hrf_usb_stream_stop` behalten.
        let stream = stateLock.withLock { () -> ReceiveStream? in
            guard _streaming else { return nil }
            _streaming = false
            _owner = nil
            _ownerObject = nil
            let stream = _stream
            _stream = nil
            return stream
        }
        guard let stream else { return }
        try? controlOut(.setTransceiverMode, value: 0)
        hrf_usb_stream_stop(handle)
        if antennaPowerWanted { try? controlOut(.antennaEnable, value: 0) }
        stream.finish()
        Unmanaged.passUnretained(stream).release()
    }

    var isReceiving: Bool { streaming }

    /// Ob gerade `owner` empfängt (und nicht eine andere Seite).
    func isReceiving(for owner: AnyObject) -> Bool {
        stateLock.withLock { _streaming && _owner == ObjectIdentifier(owner) }
    }

    /// Wer gerade empfängt (`nil` ohne Empfang).
    var currentOwner: AnyObject? { stateLock.withLock { _streaming ? _ownerObject : nil } }

    /// Strom läuft für `owner`, liefert aber seit über `seconds` keine Blöcke
    /// mehr (USB-Aussetzer). Dann hilft nur Stopp und Neustart.
    func isStalled(for owner: AnyObject, seconds: Double = 3) -> Bool {
        let stream = stateLock.withLock { _streaming && _owner == ObjectIdentifier(owner) ? _stream : nil }
        guard let stream else { return false }
        return stream.silence > .seconds(seconds)
    }

    /// Blöcke, die verworfen wurden, weil die Auswertung nicht hinterherkam.
    var droppedBlocks: Int { stream?.dropped ?? 0 }

    /// Anteil der Abtastwerte am Anschlag des 8-Bit-Wandlers (|x| ≥ 127),
    /// über die letzten Blöcke geglättet. Ab etwa 0,1 % entstehen
    /// Mischprodukte – dann LNA/VGA oder den Vorverstärker zurücknehmen.
    var clippedFraction: Double { stream?.levels.clipped ?? 0 }

    /// Pegel am Wandler: Mittel (RMS) und Spitze in dBFS, Übersteuerungsanteil.
    var inputLevels: InputLevels? { stream?.levels }

    /// Neues Messfenster für den Pegel (z. B. nach einer Verstärkungsänderung).
    func beginLevelMeasurement() { stream?.beginWindow() }

    /// Pegel seit `beginLevelMeasurement()` – Mittel über alle Blöcke,
    /// dazu die Zahl der Blöcke. `nil`, solange kein Block angekommen ist.
    func measuredLevels() -> (levels: InputLevels, blocks: Int)? { stream?.window() }

    struct InputLevels: Sendable, Equatable {
        var rmsDBFS: Double = -100
        var peakDBFS: Double = -100
        var clipped: Double = 0
    }

    /// Kennwerte eines Blocks: Anteil der Werte bei ±127 bzw. −128, mittlere
    /// Leistung und Spitze, beide relativ zum Vollausschlag (128).
    ///
    /// Läuft für jeden USB-Block (bei 2 MS/s 4 MB/s). Rechnet in Abschnitten
    /// zu 65 536 Werten mit 32-Bit-Teilsummen (65 536 · 128² = 2³⁰ passt) und
    /// verzweigungsfrei – das vektorisiert der Compiler: 256 KiB in ≈ 28 statt
    /// ≈ 150 µs, Ergebnis bitgleich (Review L4, 29.10.2026). Nicht nur jeden
    /// n-ten Block: Pegelglättung und Messfenster (`GainOptimizer`) zählen Blöcke.
    static func blockStatistics(_ data: Data) -> (clipped: Double, rmsDBFS: Double, peakDBFS: Double) {
        guard !data.isEmpty else { return (0, -100, -100) }
        let (count, sum, peak) = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Int, Int, Int) in
            let p = raw.bindMemory(to: Int8.self)
            var n = 0, sum = 0, peak: Int32 = 0
            var start = 0
            while start < p.count {
                let end = min(p.count, start + 65536)
                var s: Int32 = 0, clipped: Int32 = 0, top: Int32 = 0
                for k in start..<end {
                    let v = Int32(p[k])
                    let a = v < 0 ? -v : v
                    s &+= a &* a
                    clipped &+= a >= 127 ? 1 : 0
                    top = a > top ? a : top
                }
                sum += Int(s)
                n += Int(clipped)
                peak = max(peak, top)
                start = end
            }
            return (n, sum, Int(peak))
        }
        let mean = Double(sum) / Double(data.count) / (128 * 128)
        return (Double(count) / Double(data.count),
                10 * log10(max(mean, 1e-10)),
                20 * log10(max(Double(peak) / 128, 1e-5)))
    }

    static func clippedFraction(_ data: Data) -> Double { blockStatistics(data).clipped }

    // MARK: - SPI-Flash (Firmware-Update über den HackRF-Modus)

    /// Flash-Größe dieses Geräts (über die Board-ID).
    func flashCapacity() throws -> Int {
        Self.flashCapacity(boardID: try controlIn(.boardIDRead, length: 1).first ?? 0)
    }

    /// Schreibt ein Firmware-Abbild in den SPI-Flash – wie `hackrf_spiflash -w`.
    /// Danach muss das Gerät neu starten (`reset()`).
    ///
    /// Vor dem Löschen wird das Abbild geprüft (Mindestgröße, Vektortabelle,
    /// Flash-Größe dieses Boards): ein leeres oder abgeschnittenes Abbild
    /// hinterließe einen gelöschten Chip, und der Rücklesevergleich über
    /// 0 Byte hätte das als Erfolg gemeldet. Jede Seite wird bei einem
    /// USB-Fehler bis zu `pageRetries`-mal wiederholt.
    func writeFirmware(_ image: Data, pageRetries: Int = 2, progress: (Int, Int) -> Void) throws {
        let image = Data(image)
        try FirmwareImage.validate(image, capacity: try flashCapacity())
        try beginFlashing()
        defer { endFlashing() }
        try controlOut(.spiflashErase, timeout: 30_000)
        var address = 0
        while address < image.count {
            let end = min(address + Self.flashPageSize, image.count)
            var attempt = 0
            while true {
                do {
                    try controlOut(.spiflashWrite,
                                   value: UInt16(address >> 16), index: UInt16(address & 0xFFFF),
                                   data: image[address..<end], timeout: 2000)
                    break
                } catch {
                    attempt += 1
                    guard attempt <= pageRetries else { throw error }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            address = end
            progress(address, image.count)
        }
    }

    /// Liest den Flash zurück (zum Vergleich nach dem Schreiben).
    func readFlash(length: Int, progress: (Int, Int) -> Void) throws -> Data {
        try beginFlashing()
        defer { endFlashing() }
        var result = Data()
        result.reserveCapacity(length)
        var address = 0
        while address < length {
            let chunk = min(Self.flashPageSize, length - address)
            let data = try controlIn(.spiflashRead, value: UInt16(address >> 16), index: UInt16(address & 0xFFFF), length: chunk, timeout: 2000)
            guard data.count == chunk else {
                throw HackRFError.transferFailed(request: "spiflashRead", code: Int32(data.count))
            }
            result.append(data)
            address += chunk
            progress(address, length)
        }
        return result
    }

    /// Sperrt den Empfang für die Dauer eines Flash-Zugriffs: Stoppen und
    /// Setzen des Flags unter `lifecycle`, damit kein `startReceiving`
    /// dazwischenkommt. Der Flash-Zugriff selbst läuft danach ohne
    /// `lifecycle` (sonst wartete der Main Actor minutenlang).
    private func beginFlashing() throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !lock.withLock({ closed }) else { throw HackRFError.notFound }
        stopReceiving()
        let began = stateLock.withLock { _flashing.beginAccess() }
        if !began { throw HackRFError.invalidParameter(String(localized: "Die Firmware wird gerade schon geschrieben.")) }
    }

    private func endFlashing() {
        stateLock.withLock { _flashing.endAccess() }
    }

    /// Hält die Flash-Sperre über einen ganzen Installationsvorgang – auch
    /// zwischen Schreiben und Rücklesen und in der Pause vor dem zweiten
    /// Versuch. Vorher war das Flag dort kurz aus, und `startReceiving` einer
    /// Seite kam bei teilweise gelöschtem Chip durch (Review 28.10.2026, W7-Rest).
    /// Stoppt einen laufenden Empfang. Mit `releaseFlash()` wieder freigeben.
    func holdFlash() throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !lock.withLock({ closed }) else { throw HackRFError.notFound }
        stopReceiving()
        stateLock.withLock { _flashing.held = true }
    }

    func releaseFlash() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        stateLock.withLock { _flashing.held = false }
    }

    /// Lässt ein USB-Gerät neu enumerieren (wie Ab- und Anstecken).
    @discardableResult
    static func reenumerate(vendorID: Int, productID: Int) -> Bool {
        hrf_usb_reenumerate(UInt16(vendorID), UInt16(productID)) == 0
    }
}

/// Zustand der Flash-Sperre (W7): ein einzelner Zugriff (`writeFirmware`,
/// `readFlash`) und das Halten über den ganzen Vorgang (`holdFlash`). Empfang
/// ist gesperrt, solange eines davon gilt; zwei Zugriffe gleichzeitig nie.
struct FlashLock: Sendable, Equatable {
    private(set) var accessing = false
    var held = false

    var blocksReceiving: Bool { accessing || held }

    /// `false`, wenn schon ein Zugriff läuft.
    mutating func beginAccess() -> Bool {
        guard !accessing else { return false }
        accessing = true
        return true
    }

    mutating func endAccess() { accessing = false }
}

/// Verbindet die USB-Rückrufe mit dem Auswerter: kopiert jeden Block und
/// reicht ihn an eine serielle Warteschlange weiter.
private final class ReceiveStream: @unchecked Sendable {
    /// Höchstens so viele Blöcke dürfen auf die Auswertung warten (bei
    /// 20 MS/s ≈ 0,4 s), danach wird verworfen statt Speicher zu fressen.
    static let maximumBacklog = 32

    private let handler: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "HackRF-Auswertung", qos: .userInitiated)
    private let lock = NSLock()
    private var backlog = 0
    private var active = true
    private var droppedCount = 0
    private var lastBlock = ContinuousClock.now
    var dropped: Int { lock.withLock { droppedCount } }
    /// Sekunden seit dem letzten USB-Block. Nach 100 Fehlern in Folge gibt der
    /// C-Teil die Transfers nicht mehr aus – ohne diesen Wert merkte das niemand.
    var silence: Duration { lock.withLock { ContinuousClock.now - lastBlock } }
    private var current = HackRFDevice.InputLevels()
    private var windowBlocks = 0
    private var windowClipped = 0.0
    private var windowPower = 0.0
    private var windowPeak = -100.0

    var levels: HackRFDevice.InputLevels { lock.withLock { current } }

    func beginWindow() {
        lock.withLock { windowBlocks = 0; windowClipped = 0; windowPower = 0; windowPeak = -100 }
    }

    func window() -> (levels: HackRFDevice.InputLevels, blocks: Int)? {
        lock.withLock {
            guard windowBlocks > 0 else { return nil }
            let n = Double(windowBlocks)
            return (HackRFDevice.InputLevels(rmsDBFS: 10 * log10(max(windowPower / n, 1e-10)),
                                             peakDBFS: windowPeak, clipped: windowClipped / n), windowBlocks)
        }
    }

    init(handler: @escaping @Sendable (Data) -> Void) {
        self.handler = handler
    }

    func receive(_ bytes: UnsafePointer<UInt8>, _ count: Int) {
        let accepted = lock.withLock {
            lastBlock = .now
            guard active, backlog < Self.maximumBacklog else {
                if active { droppedCount += 1 }
                return false
            }
            backlog += 1
            return true
        }
        guard accepted else { return }
        let data = Data(bytes: bytes, count: count)
        queue.async { [self] in
            let run = lock.withLock { active }
            guard run else { lock.withLock { backlog -= 1 }; return }
            let block = HackRFDevice.blockStatistics(data)
            lock.withLock {
                current.clipped += 0.1 * (block.clipped - current.clipped)
                current.rmsDBFS += 0.2 * (block.rmsDBFS - current.rmsDBFS)
                // Spitze: sofort hoch, je Block um 0,3 dB wieder herunter.
                current.peakDBFS = max(block.peakDBFS, current.peakDBFS - 0.3)
                windowBlocks += 1
                windowClipped += block.clipped
                windowPower += pow(10, block.rmsDBFS / 10)
                windowPeak = max(windowPeak, block.peakDBFS)
            }
            handler(data)
            lock.withLock { backlog -= 1 }
        }
    }

    /// Nach dem Stopp: nichts Neues mehr ausliefern und warten, bis ein
    /// gerade laufender Block fertig ist.
    func finish() {
        lock.withLock { active = false }
        queue.sync {}
    }
}
