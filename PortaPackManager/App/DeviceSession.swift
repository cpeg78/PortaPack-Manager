import Foundation
import Observation
import os
import SwiftUI

enum Log {
    static let session = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Sitzung")
}

/// In welchem Modus das Gerät gerade am USB hängt.
enum DeviceMode: Equatable, Sendable {
    case disconnected
    case mayhem(path: String)
    case hackRF
    case dfu
    case sdCard

    var title: String {
        switch self {
        case .disconnected: String(localized: "Nicht verbunden")
        case .mayhem: String(localized: "Mayhem-Modus")
        case .hackRF: String(localized: "HackRF-Modus")
        case .dfu: String(localized: "DFU-Modus")
        case .sdCard: String(localized: "SD-Karte am Mac")
        }
    }
}

/// Zentraler Zustand der App: erkennt das Gerät, hält die Verbindung und
/// bündelt alles, was die Oberfläche anzeigt.
@MainActor
@Observable
final class DeviceSession {
    var mode: DeviceMode = .disconnected {
        didSet { if mode != oldValue { Log.session.notice("Modus: \(self.mode.title, privacy: .public)") } }
    }
    var device: MayhemDevice?
    var hackRF: HackRFDevice?
    var installProgress = InstallProgress() {
        didSet {
            if installProgress.phase != oldValue.phase {
                Log.session.notice("Phase \(self.installProgress.phase.rawValue, privacy: .public): \(self.installProgress.detail, privacy: .public)")
            }
        }
    }
    /// Ein Erneuern, bei dem nur noch das Flashen fehlt (überlebt Neustarts).
    var pendingRenewal: PendingRenewal? = PendingRenewal.load() {
        didSet { PendingRenewal.store(pendingRenewal) }
    }

    /// Eingehängte SD-Karte im SD-over-USB-Modus.
    var sdVolume: URL?
    private(set) var info: MayhemInfo?
    private(set) var systemInfo: [(String, String)] = []
    private(set) var radioInfo: [(String, String)] = []
    private(set) var clock: String = ""
    var connectionError: String?
    private(set) var consoleLines: [ConsoleLine] = []
    var consoleEnabled = true

    /// Während einer Installation oder anderer langer Vorgänge bleibt die
    /// Geräteerkennung still, damit kein Neuverbinden dazwischenfunkt.
    var busy = false
    var busyReason: String = ""
    /// Zählt abgeschlossene Fortschrittsstände. Rückrufe aus dem Hintergrund
    /// kommen über `Task { @MainActor … }` an und können sich verspäten –
    /// ohne den Zähler überschrieb eine späte „Schreibe …“-Meldung das
    /// „Fertig“ (Review 28.10.2026).
    @ObservationIgnored private(set) var progressGeneration = 0

    /// Bildschirmspiegelung
    private(set) var screenImage: CGImage?
    var screenMirroring = false {
        didSet { if screenMirroring { startMirroring() } else { stopMirroring() } }
    }
    private(set) var screenFrameInterval: TimeInterval = 0
    private var mirrorTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastSerialPath: String?
    /// Schnittstelle, deren `open` nicht zurückkam (Treiber verklemmt). Bis
    /// der hängende Aufruf endet, nicht erneut öffnen – jeder weitere Versuch
    /// bliebe genauso im Kernel hängen.
    private var stuckSerialPath: String?

    let catalog = FirmwareCatalog()
    let installer = FirmwareInstaller()

    init() {}

    // MARK: - Geräteerkennung

    func startMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        guard !busy else { return }
        let serial = await Task.detached { SerialDeviceFinder.mayhemConsoles().first }.value
        let hackRFPresent = await Task.detached {
            SerialDeviceFinder.usbDevicePresent(vendorID: USBIdentity.greatScottGadgets, productID: USBIdentity.hackRFOne)
        }.value
        let dfuPresent = await Task.detached {
            SerialDeviceFinder.usbDevicePresent(vendorID: USBIdentity.nxp, productID: USBIdentity.lpcDFU)
        }.value
        let sdPresent = await Task.detached { SDCardVolume.devicePresent }.value
        // Während der Abfragen kann eine Installation begonnen haben; jetzt
        // zu verbinden oder zu trennen, schlösse ihr das Gerät unter der Hand.
        guard !busy else { return }

        if let serial {
            if case let .mayhem(path) = mode, path == serial.path, device != nil { return }
            if stuckSerialPath == serial.path { return }
            await connect(to: serial.path)
        } else if hackRFPresent {
            if case .hackRF = mode, hackRF != nil { return }
            await connectHackRF()
        } else if sdPresent {
            if mode != .sdCard { await disconnect(); mode = .sdCard }
            let volume = await Task.detached { SDCardVolume.mounted() }.value
            guard !busy else { return }
            sdVolume = volume
        } else if dfuPresent {
            if mode != .dfu { await disconnect(); mode = .dfu }
        } else if mode != .disconnected {
            await disconnect()
        }
    }

    private func connect(to path: String) async {
        await disconnect()
        do {
            let logSink: (@Sendable (ConsoleLine) -> Void) = { [weak self] line in
                Task { @MainActor in self?.appendConsole(line) }
            }
            let candidate: MayhemDevice
            do {
                candidate = try await MayhemDevice.open(path: path, log: logSink)
            } catch let error as BlockingCall.TimedOut {
                stuckSerialPath = path
                Task.detached { [weak self] in
                    // Wieder zulassen, sobald das Gerät abgesteckt wurde, spätestens
                    // nach einer Minute (dann höchstens ein weiterer hängender Thread je Minute).
                    for _ in 0..<12 where FileManager.default.fileExists(atPath: path) {
                        try? await Task.sleep(for: .seconds(5))
                        if await self?.stuckSerialPath != path { return }
                    }
                    await MainActor.run { if self?.stuckSerialPath == path { self?.stuckSerialPath = nil } }
                }
                throw error
            }
            try await candidate.connect()
            let info = try await candidate.info()
            device = candidate
            self.info = info
            mode = .mayhem(path: path)
            lastSerialPath = path
            connectionError = nil
            await refreshStatus()
            try? await candidate.setClock()
        } catch {
            connectionError = error.localizedDescription
            Log.session.error("Verbinden mit \(path, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            mode = .disconnected
        }
    }

    private func connectHackRF() async {
        await disconnect()
        do {
            // Abseits des Main Actors: IOKit-Öffnen und Display-Request können
            // bei einem hakenden Gerät spürbar dauern.
            let candidate = try await Task.detached { try HackRFDevice.openFirst() }.value
            // Hat inzwischen ein anderer Ablauf (Rettungsweg) selbst geöffnet, dessen Gerät behalten.
            guard hackRF == nil else { candidate.close(); return }
            hackRF = candidate
            mode = .hackRF
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
            mode = .disconnected
        }
    }

    func disconnect() async {
        stopMirroring()
        let mayhem = device
        let hackRFDevice = hackRF
        device = nil
        hackRF = nil
        if let mayhem {
            // Ein laufender Befehl (Spiegelbild, Upload) bricht ab, statt dass
            // das Schließen minutenlang hinter ihm wartet.
            mayhem.interrupt()
            await mayhem.close()
        }
        if let hackRFDevice {
            // `close` stoppt den Empfang (`pthread_join`) – nicht auf dem Main Actor.
            await Task.detached { hackRFDevice.close() }.value
        }
        if mode != .disconnected {
            info = nil
            systemInfo = []
            radioInfo = []
            mode = .disconnected
        }
    }

    /// Wartet, bis ein Gerät im Mayhem-Modus (wieder) erreichbar ist, und
    /// verbindet sich damit. Für den Installer.
    func reconnectIfAvailable() async throws -> MayhemDevice? {
        guard let serial = await Task.detached(operation: { SerialDeviceFinder.mayhemConsoles().first }).value else { return nil }
        // Nach dem Neustart braucht das Gerät einen Moment, bis die Shell antwortet.
        try await Task.sleep(for: .seconds(2))
        await connect(to: serial.path)
        return device
    }

    // MARK: - Statusdaten

    func refreshStatus() async {
        guard let device else { return }
        do {
            info = try await device.info()
            systemInfo = try await device.systemInfo()
            radioInfo = try await device.radioInfo()
            clock = try await device.clock()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    // MARK: - Bildschirmspiegelung

    private func startMirroring() {
        guard mirrorTask == nil, let device else { return }
        mirrorTask = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                guard let self, !self.busy else {
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                do {
                    let frame = try await device.screenFrame()
                    let image = frame.makeImage()
                    let now = Date()
                    self.screenFrameInterval = now.timeIntervalSince(last)
                    last = now
                    self.screenImage = image
                } catch {
                    // Beim Trennen bricht `interrupt()` das laufende Bild ab – kein Fehler.
                    if Task.isCancelled { break }
                    self.connectionError = error.localizedDescription
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func stopMirroring() {
        mirrorTask?.cancel()
        mirrorTask = nil
    }

    /// Holt ein einzelnes Bild (z. B. nach einer Eingabe ohne Dauerspiegelung).
    func captureScreen() async {
        guard let device else { return }
        if let frame = try? await device.screenFrame() {
            screenImage = frame.makeImage()
        }
    }

    // MARK: - Konsole

    private func appendConsole(_ line: ConsoleLine) {
        guard consoleEnabled else { return }
        consoleLines.append(line)
        if consoleLines.count > 2000 {
            consoleLines.removeFirst(consoleLines.count - 2000)
        }
    }

    func clearConsole() {
        consoleLines.removeAll()
    }

    func note(_ text: String) {
        Log.session.notice("\(text, privacy: .public)")
        appendConsole(ConsoleLine(direction: .note, text: text))
    }

    /// Rückruf für Fortschritt aus dem Hintergrund. Meldungen, die erst nach
    /// dem nächsten `finishProgress` ankommen, werden verworfen.
    func progressReporter() -> @Sendable (InstallProgress) -> Void {
        let generation = progressGeneration
        return { [weak self] progress in
            Task { @MainActor in
                guard let self, self.progressGeneration == generation else { return }
                self.installProgress = progress
            }
        }
    }

    /// Setzt einen abschließenden Stand (fertig, gescheitert) und macht alle
    /// bis dahin ausgegebenen `progressReporter` wirkungslos.
    func finishProgress(_ progress: InstallProgress) {
        progressGeneration &+= 1
        installProgress = progress
    }

    /// Führt einen Vorgang aus, während die Geräteerkennung pausiert.
    func performExclusive<T: Sendable>(_ reason: String, _ work: () async throws -> T) async rethrows -> T {
        busy = true
        busyReason = reason
        Log.session.notice("Beginne: \(reason, privacy: .public)")
        defer { busy = false; busyReason = "" }
        return try await work()
    }
}

/// Merkt sich ein unterbrochenes Erneuern (Pfad des Abbilds auf der Karte).
///
/// Mit Größe und CRC des Abbilds: vor dem nachgeholten `flash` wird die Datei
/// auf der Karte damit verglichen – gerade nach einem hängenden Aushängen
/// (dokumentiert) kann sie unvollständig sein. Tag und Gerätetyp verhindern,
/// dass ein altes Erneuern auf ein inzwischen anders bestücktes Gerät geht.
/// Ältere gespeicherte Einträge haben diese Felder nicht (`nil`).
struct PendingRenewal: Codable, Equatable, Sendable {
    var imagePath: String
    var version: String
    var imageSize: Int?
    var imageCRC: UInt32?
    var tag: String?
    var deviceType: String?
    var createdAt: Date?

    var expectedVersion: FirmwareVersion { tag.map(FirmwareVersion.init(tag:)) ?? FirmwareVersion(string: version) }

    /// Gründe, das Flashen gerade nicht nachzuholen; `nil` = in Ordnung.
    func conflict(with info: MayhemInfo?) -> String? {
        guard let info else { return nil }
        if let wanted = deviceType.flatMap(DeviceType.init(rawValue:)), let actual = info.reportedDeviceType, wanted != actual {
            return String(localized: "Die Dateien auf der Karte sind für \(wanted.displayName), das Gerät meldet \(actual.displayName).")
        }
        if info.version == expectedVersion {
            return String(localized: "Auf dem Gerät läuft bereits \(info.mayhemVersion) – es gibt nichts mehr nachzuholen.")
        }
        if info.version.isOlder(than: expectedVersion) == false {
            return String(localized: "Auf dem Gerät läuft \(info.mayhemVersion), neuer als \(expectedVersion.description) – Abschließen würde auf die ältere Version zurückgehen.")
        }
        return nil
    }

    private static let key = "pendingRenewal"

    static func load() -> PendingRenewal? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(PendingRenewal.self, from: $0) }
    }

    static func store(_ value: PendingRenewal?) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
