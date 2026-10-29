import Foundation

/// Fortschritt einer Firmware-Installation.
struct InstallProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case idle = "Bereit"
        case downloading = "Lade herunter"
        case preparing = "Bereite vor"
        case uploading = "Übertrage auf SD-Karte"
        case verifying = "Prüfe Prüfsumme"
        case flashing = "Flashe"
        case waitingForReboot = "Warte auf Neustart"
        case installingApps = "Installiere Apps"
        case extracting = "Entpacke"
        case switchingToSD = "Stelle SD-Karte bereit"
        case copyingToCard = "Kopiere auf SD-Karte"
        case ejecting = "Werfe SD-Karte aus"
        case done = "Fertig"
        case failed = "Fehlgeschlagen"

        /// Angezeigter Name (der Rohwert bleibt fürs Protokoll deutsch).
        var title: String {
            switch self {
            case .idle: String(localized: "Bereit")
            case .downloading: String(localized: "Lade herunter")
            case .preparing: String(localized: "Bereite vor")
            case .uploading: String(localized: "Übertrage auf die SD-Karte")
            case .verifying: String(localized: "Prüfe die Übertragung")
            case .flashing: String(localized: "Schreibe die Firmware")
            case .waitingForReboot: String(localized: "Warte auf den Neustart")
            case .installingApps: String(localized: "Installiere Apps")
            case .extracting: String(localized: "Entpacke")
            case .switchingToSD: String(localized: "Stelle die SD-Karte bereit")
            case .copyingToCard: String(localized: "Kopiere auf die SD-Karte")
            case .ejecting: String(localized: "Werfe die SD-Karte aus")
            case .done: String(localized: "Fertig")
            case .failed: String(localized: "Fehlgeschlagen")
            }
        }
    }

    var phase: Phase = .idle
    var fraction: Double = 0
    var detail: String = ""
    var startedAt: Date?
    var finishedAt: Date?

    var isRunning: Bool {
        switch phase {
        case .idle, .done, .failed: false
        default: true
        }
    }
}

/// Die Quelle einer Installation: Release-Paket oder lokale Datei.
enum FirmwareSource: Sendable, Equatable {
    case release(FirmwareRelease, FirmwareAsset)
    case localFile(URL)

    var displayName: String {
        switch self {
        case let .release(release, asset): "\(release.version) – \(asset.name)"
        case let .localFile(url): url.lastPathComponent
        }
    }

    var fileName: String {
        switch self {
        case let .release(_, asset): asset.name
        case let .localFile(url): url.lastPathComponent
        }
    }
}

/// Führt die Installation durch: herunterladen → auf die SD-Karte laden →
/// Prüfsumme vergleichen → `flash` auslösen → auf das Wiedererscheinen des
/// Geräts warten. Die Mayhem-Firmware entpackt `.ppfw.tar` selbst, legt die
/// Apps nach `/APPS` und flasht das enthaltene `.bin`.
actor FirmwareInstaller {
    private let downloader = FirmwareDownloader()
    /// „Abbrechen“ während des Herunterladens – wirkt nur auf den Download,
    /// nie auf das Übertragen oder Schreiben danach.
    nonisolated let downloadCancel = DownloadCancel()

    /// Download in eigener Task, damit sich genau er abbrechen lässt.
    private func cancellableDownload(_ asset: FirmwareAsset,
                                     progress: @Sendable @escaping (Int64, Int64) -> Void) async throws -> URL {
        let downloader = downloader
        let task = Task { try await downloader.download(asset, progress: progress) }
        downloadCancel.attach { task.cancel() }
        defer { downloadCancel.attach(nil) }
        do {
            return try await task.value
        } catch {
            if downloadCancel.takeCancelled() { throw DownloadCancel.Cancelled() }
            throw error
        }
    }

    /// Längster Name unter `/FIRMWARE`, der mit dem längsten verwendeten
    /// Befehl (`filesize /FIRMWARE/…`) noch in eine Shell-Zeile passt.
    static let maximumFileNameLength = MayhemDevice.maximumLineLength - "filesize /FIRMWARE/".count

    func install(_ source: FirmwareSource,
                 on device: MayhemDevice,
                 deviceType: DeviceType? = nil,
                 appsOnly: Bool = false,
                 waitForDevice: @Sendable @escaping () async throws -> MayhemDevice?,
                 report: @Sendable @escaping (InstallProgress) -> Void) async throws {
        var progress = InstallProgress(startedAt: Date())
        func update(_ phase: InstallProgress.Phase, _ fraction: Double, _ detail: String) {
            progress.phase = phase
            progress.fraction = fraction
            progress.detail = detail
            report(progress)
        }

        do {
            // 1. Datei beschaffen
            let fileURL: URL
            switch source {
            case let .release(_, asset):
                update(.downloading, 0, asset.name)
                let downloadStart = progress.startedAt
                fileURL = try await cancellableDownload(asset) { received, total in
                    let fraction = total > 0 ? Double(received) / Double(total) : 0
                    report(InstallProgress(phase: .downloading, fraction: fraction,
                                           detail: Self.ofTotal(received, total), startedAt: downloadStart))
                }
            case let .localFile(url):
                fileURL = url
            }
            update(.preparing, 0, source.fileName)
            let data = try Data(contentsOf: fileURL)
            try Task.checkCancellation()

            if appsOnly {
                try await installApps(from: data, on: device, update: update)
                update(.done, 1, String(localized: "Apps installiert"))
                progress.finishedAt = Date()
                report(progress)
                return
            }

            // Abbild vorher prüfen: ein abgeschnittenes oder falsches Paket
            // soll gar nicht erst auf die Karte (Mayhem prüft selbst, aber
            // ein Fehler hier kostet keine 2 Minuten Upload).
            try Self.validatePackage(data, fileName: source.fileName, capacity: deviceType?.flashCapacity)

            let fileName = Self.deviceFileName(source.fileName)
            let remotePath = "/FIRMWARE/\(fileName)"
            try await device.makeDirectory("/FIRMWARE")
            try await device.makeDirectory("/APPS")

            // 2. Hochladen
            update(.uploading, 0, remotePath)
            let total = data.count
            let started = Date()
            let startedAt = progress.startedAt
            try await device.upload(data, to: remotePath) { done, _ in
                let elapsed = Date().timeIntervalSince(started)
                let rate = elapsed > 0 ? Double(done) / elapsed : 0
                let remaining = rate > 0 ? Double(total - done) / rate : 0
                report(InstallProgress(
                    phase: .uploading, fraction: Double(done) / Double(total),
                    detail: String(localized: "\(Self.ofTotal(Int64(done), Int64(total))) · \(Self.format(Int64(rate)))/s · noch \(Self.duration(remaining))"),
                    startedAt: startedAt))
            }

            // 3. Prüfen
            update(.verifying, 0, remotePath)
            let expected = MayhemCRC32.checksum(data)
            let actual = try await device.crc32(remotePath)
            guard expected == actual else { throw MayhemError.checksumMismatch(expected: expected, actual: actual) }
            let remoteSize = try await device.fileSize(remotePath)
            guard remoteSize == data.count else {
                throw MayhemError.unexpectedResponse(String(localized: "Auf dem Gerät liegen \(remoteSize) statt \(data.count) Bytes – die Übertragung ist unvollständig."))
            }

            // 4. Flashen
            update(.flashing, 0, String(localized: "Das Gerät schreibt die Firmware – nicht abstecken!"))
            if try await device.flash(remotePath) == .connectionLost {
                update(.flashing, 0, String(localized: "Die Verbindung ist beim Start abgerissen – das Gerät schreibt vermutlich gerade. NICHT abstecken, schau auf den Bildschirm des Geräts."))
            }

            // 5. Neustart abwarten. Während des Flashens bleibt das Gerät
            // eine Weile am USB, antwortet aber nicht – erst danach suchen.
            update(.waitingForReboot, 0, String(localized: "Das Gerät entpackt die Apps und schreibt die Firmware …"))
            try await Task.sleep(for: .seconds(12))
            let deadline = Date().addingTimeInterval(180)
            var reconnected: MayhemDevice?
            while Date() < deadline {
                try await Task.sleep(for: .seconds(2))
                let elapsed = 180 - deadline.timeIntervalSinceNow
                update(.waitingForReboot, min(elapsed / 90, 0.95), String(localized: "Das Gerät startet neu … (\(Int(elapsed)) s)"))
                if let found = try await waitForDevice() {
                    reconnected = found
                    break
                }
            }
            guard let reconnected else {
                throw MayhemError.unexpectedResponse(String(localized: "Das Gerät hat sich nach dem Schreiben nicht wieder gemeldet. Schau auf den Bildschirm des Geräts."))
            }
            let info = try await reconnected.info()
            if case let .release(release, _) = source, info.version != release.version {
                throw MayhemError.unexpectedResponse(
                    String(localized: "Nach dem Neustart meldet das Gerät \(info.mayhemVersion) statt \(release.version.description). Die neue Firmware wurde vermutlich abgelehnt – schau auf den Bildschirm des Geräts."))
            }
            update(.done, 1, String(localized: "Jetzt installiert: \(info.mayhemVersion)"))
            progress.finishedAt = Date()
            report(progress)
        } catch {
            update(.failed, progress.fraction, error.localizedDescription)
            throw error
        }
    }

    /// Nur die Apps aus einem `.ppfw.tar` nach `/APPS` kopieren (etwa nach
    /// einem Flash über den HackRF-Modus, der die Apps nicht mitbringt).
    private func installApps(from data: Data, on device: MayhemDevice,
                             update: (InstallProgress.Phase, Double, String) -> Void) async throws {
        let archive = try TarArchive(data: data)
        let apps = archive.apps
        guard !apps.isEmpty else { throw MayhemError.unexpectedResponse(String(localized: "Das Paket enthält keine Apps.")) }
        try await device.makeDirectory("/APPS")
        for (index, entry) in apps.enumerated() {
            try Task.checkCancellation()
            let name = TarArchive.lastComponent(entry.name)
            update(.installingApps, Double(index) / Double(apps.count), "\(name) (\(index + 1)/\(apps.count))")
            try await device.upload(try archive.contents(of: entry), to: "/APPS/\(name)") { _, _ in }
        }
    }

    /// Lädt die Quelle (falls nötig) herunter und liefert die Bytes.
    func fetch(_ source: FirmwareSource, report: @Sendable @escaping (InstallProgress) -> Void) async throws -> Data {
        switch source {
        case let .release(_, asset):
            let url = try await cancellableDownload(asset) { received, total in
                report(InstallProgress(phase: .downloading, fraction: total > 0 ? Double(received) / Double(total) : 0,
                                       detail: Self.ofTotal(received, total)))
            }
            return try Data(contentsOf: url)
        case let .localFile(url):
            return try Data(contentsOf: url)
        }
    }

    /// Lädt ein Asset in den Cache und liefert den Pfad (für große Dateien).
    func downloadToCache(_ asset: FirmwareAsset, startedAt: Date,
                         report: @Sendable @escaping (InstallProgress) -> Void) async throws -> URL {
        let started = Date()
        return try await cancellableDownload(asset) { received, total in
            let elapsed = Date().timeIntervalSince(started)
            let rate = elapsed > 0.5 ? Double(received) / elapsed : 0
            let remaining = rate > 0 ? Double(total - received) / rate : 0
            report(InstallProgress(phase: .downloading, fraction: total > 0 ? Double(received) / Double(total) : 0,
                                   detail: rate > 0
                                       ? String(localized: "\(asset.name)\n\(Self.ofTotal(received, total)) · \(Self.format(Int64(rate)))/s · noch \(Self.duration(remaining))")
                                       : "\(asset.name)\n\(Self.ofTotal(received, total))",
                                   startedAt: startedAt))
        }
    }

    nonisolated static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? String(localized: "\(s / 60) min \(s % 60) s") : String(localized: "\(s) s")
    }

    /// „3,2 MB von 12 MB“.
    nonisolated static func ofTotal(_ done: Int64, _ total: Int64) -> String {
        String(localized: "\(format(done)) von \(format(total))")
    }

    /// Kopiert alle Apps eines `.ppfw.tar` nach `/APPS`.
    func installApps(from data: Data, on device: MayhemDevice,
                     report: @Sendable @escaping (InstallProgress) -> Void) async throws {
        try await installApps(from: data, on: device) { phase, fraction, detail in
            report(InstallProgress(phase: phase, fraction: fraction, detail: detail))
        }
    }

    /// Prüft ein Paket (`.ppfw.tar`) bzw. Abbild (`.bin`) vor jeder
    /// Veränderung am Gerät und liefert das Firmware-Abbild.
    @discardableResult
    nonisolated static func validatePackage(_ data: Data, fileName: String, capacity: Int?) throws -> Data {
        let image: Data
        if fileName.lowercased().hasSuffix(".bin") {
            image = data
        } else {
            let archive = try TarArchive(data: data)
            guard let entry = archive.firmwareImages.first else {
                throw MayhemError.unexpectedResponse(String(localized: "Im Paket steckt keine Firmware-Datei (.bin)."))
            }
            guard archive.firmwareImages.count == 1 else {
                throw MayhemError.unexpectedResponse(String(localized: "Im Paket stecken mehrere Firmware-Dateien – unklar, welche gemeint ist."))
            }
            image = try archive.contents(of: entry)
        }
        try FirmwareImage.validate(image, capacity: capacity)
        return image
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Name auf dem Gerät: ohne Leerzeichen (die Shell trennt daran) und
    /// nicht länger als `maximumFileNameLength`.
    nonisolated static func deviceFileName(_ name: String) -> String {
        let plain = name.replacingOccurrences(of: "\\s", with: "_", options: .regularExpression)
        return plain.count > maximumFileNameLength ? shortened(plain) : plain
    }

    /// Kürzt lange Dateinamen, behält aber Endung und Versionsangabe.
    nonisolated static func shortened(_ name: String) -> String {
        let suffix = name.hasSuffix(".ppfw.tar") ? ".ppfw.tar" : (name as NSString).pathExtension.isEmpty ? "" : "." + (name as NSString).pathExtension
        let stem = String(name.dropLast(suffix.count))
        let allowed = maximumFileNameLength - suffix.count
        return String(stem.suffix(allowed)) + suffix
    }
}

/// Abbruch-Griff für den laufenden Firmware-Download. Außerhalb eines
/// Downloads tut `cancel()` nichts.
final class DownloadCancel: @unchecked Sendable {
    struct Cancelled: LocalizedError {
        var errorDescription: String? { String(localized: "Download abgebrochen.") }
    }

    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var cancelled = false

    /// Läuft gerade ein Download, der sich abbrechen lässt?
    var isActive: Bool { lock.withLock { handler != nil } }

    func attach(_ handler: (@Sendable () -> Void)?) {
        lock.withLock {
            self.handler = handler
            if handler != nil { cancelled = false }
        }
    }

    func cancel() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let handler = self.handler else { return nil }
            cancelled = true
            return handler
        }
        handler?()
    }

    /// Wurde abgebrochen? Setzt den Zustand zurück.
    func takeCancelled() -> Bool {
        lock.withLock {
            defer { cancelled = false }
            return cancelled
        }
    }
}
