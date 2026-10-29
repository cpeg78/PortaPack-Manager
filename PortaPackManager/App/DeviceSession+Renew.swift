import Foundation

extension DeviceSession {
    /// Erneuert das Gerät komplett, ohne die SD-Karte auszubauen:
    /// SD-Paket laden und entpacken → SD over USB → Inhalt auf die Karte
    /// kopieren → auswerfen (Gerät startet Mayhem) → Firmware von der Karte
    /// flashen → Version prüfen. Über die langsame Konsole läuft nichts.
    func renewDevice(_ release: FirmwareRelease, type: DeviceType, withWorldMap: Bool, options: SDCardPackage.Options) async {
        screenMirroring = false
        await performExclusive(String(localized: "Gerät wird erneuert")) {
            let started = Date()
            let report = progressReporter()
            @MainActor func update(_ phase: InstallProgress.Phase, _ fraction: Double, _ detail: String) {
                installProgress = InstallProgress(phase: phase, fraction: fraction, detail: detail, startedAt: started)
            }
            do {
                // 1. Paket beschaffen
                guard let asset = release.sdCardPackage(for: type, withWorldMap: withWorldMap) else {
                    throw SDCardError.missingPackage(String(localized: "COPY_TO_SDCARD für \(type.displayName)"))
                }
                update(.downloading, 0, asset.name)
                let zip = try await installer.downloadToCache(asset, startedAt: started, report: report)
                update(.extracting, 0, String(localized: "\(asset.name) – das dauert einen Moment …"))
                let package = try await SDCardPackage.extract(zip)
                guard let image = try package.firmwareImage() else {
                    throw MayhemError.unexpectedResponse(String(localized: "Im Paket für die SD-Karte steckt keine Firmware-Datei."))
                }
                // Abbild vor jeder Änderung an der Karte prüfen und Größe/CRC
                // merken – damit wird später die Kopie auf der Karte verglichen.
                let imageURL = package.root.appendingPathComponent(image)
                let (imageSize, imageCRC) = try await Task.detached {
                    let bytes = try Data(contentsOf: imageURL)
                    try FirmwareImage.validate(bytes, capacity: type.flashCapacity)
                    return (bytes.count, MayhemCRC32.checksum(bytes))
                }.value

                // 2. SD-Karte bereitstellen
                let volume = try await mountSDCard(update: update)

                // 3. Kopieren
                let copyStart = Date()
                try await Task.detached {
                    try package.copy(to: volume, options: options) { p in
                        let elapsed = Date().timeIntervalSince(copyStart)
                        let rate = elapsed > 0.5 ? Double(p.copiedBytes) / elapsed : 0
                        let remaining = rate > 0 ? Double(p.totalBytes - p.copiedBytes) / rate : 0
                        report(InstallProgress(
                            phase: .copyingToCard,
                            fraction: p.totalBytes > 0 ? Double(p.copiedBytes) / Double(p.totalBytes) : 0,
                            detail: (rate > 0
                                ? String(localized: "\(FirmwareInstaller.ofTotal(p.copiedBytes, p.totalBytes)) · \(FirmwareInstaller.format(Int64(rate)))/s · noch \(FirmwareInstaller.duration(remaining))")
                                : FirmwareInstaller.ofTotal(p.copiedBytes, p.totalBytes))
                                + (p.currentFile.isEmpty ? "" : "\n\(p.currentFile)"),
                            startedAt: started))
                    }
                }.value

                // Ab hier liegt alles auf der Karte; bricht etwas ab, lässt
                // sich das Flashen später nachholen.
                let pending = PendingRenewal(imagePath: "/" + image, version: release.version.description,
                                             imageSize: imageSize, imageCRC: imageCRC, tag: release.tag,
                                             deviceType: type.rawValue, createdAt: Date())
                pendingRenewal = pending

                // 4. Auswerfen → Gerät startet Mayhem
                update(.ejecting, 0, String(localized: "Schreibe die letzten Daten und werfe die Karte aus …"))
                try await Task.detached { try SDCardVolume.unmount(volume) }.value
                sdVolume = nil
                SDCardVolume.leaveSDMode()
                mode = .disconnected
                guard let device = try await waitForMayhem(timeout: 60, phase: .waitingForReboot, detail: String(localized: "Gerät startet Mayhem …")) else {
                    throw MayhemError.unexpectedResponse(String(localized: "Das Gerät ist nach dem Auswerfen nicht in Mayhem zurückgekehrt. Steck es ab und wieder an."))
                }

                // 5. Flashen
                try await flashFromCard(device: device, pending: pending, started: started)
            } catch {
                finishProgress(InstallProgress(phase: .failed, detail: error.localizedDescription, startedAt: started))
            }
        }
    }

    /// Flasht das Abbild, das schon auf der Karte liegt, und prüft die Version.
    ///
    /// Vorher werden Größe und CRC der Datei auf der Karte mit den beim
    /// Kopieren gemerkten Werten verglichen: nach einem hängenden Aushängen
    /// (Fund 20.10.2026) kann sie unvollständig sein, und Mayhem flasht, was
    /// es findet.
    func flashFromCard(device: MayhemDevice, pending: PendingRenewal, started: Date) async throws {
        let imagePath = pending.imagePath
        let expected = pending.expectedVersion
        if pending.imageSize != nil || pending.imageCRC != nil {
            installProgress = InstallProgress(phase: .verifying, detail: String(localized: "Prüfe \(imagePath) auf der Karte …"), startedAt: started)
            if let size = pending.imageSize {
                let actual = try await device.fileSize(imagePath)
                guard actual == size else {
                    throw MayhemError.unexpectedResponse(
                        String(localized: "Die Firmware-Datei auf der Karte ist \(actual) statt \(size) Bytes groß – beim Kopieren unvollständig geworden. Wiederhole „Gerät komplett erneuern“. Es wurde nichts geschrieben."))
                }
            }
            if let crc = pending.imageCRC {
                let actual = try await device.crc32(imagePath)
                guard actual == crc else {
                    throw MayhemError.checksumMismatch(expected: crc, actual: actual)
                }
            }
        }
        installProgress = InstallProgress(phase: .flashing, detail: String(localized: "Schreibe \(imagePath) – nicht abstecken!"), startedAt: started)
        if try await device.flash(imagePath) == .connectionLost {
            installProgress = InstallProgress(phase: .flashing,
                                              detail: String(localized: "Die Verbindung ist beim Start abgerissen – das Gerät schreibt vermutlich gerade. NICHT abstecken, schau auf den Bildschirm des Geräts."),
                                              startedAt: started)
        }
        self.device = nil
        mode = .disconnected
        try await Task.sleep(for: .seconds(12))
        guard let flashed = try await waitForMayhem(timeout: 180, phase: .waitingForReboot, detail: String(localized: "Gerät schreibt die Firmware und startet neu …")) else {
            throw MayhemError.unexpectedResponse(String(localized: "Das Gerät hat sich nach dem Schreiben nicht wieder gemeldet. Schau auf den Bildschirm des Geräts."))
        }
        let info = try await flashed.info()
        if info.version != expected {
            throw MayhemError.unexpectedResponse(String(localized: "Das Gerät meldet \(info.mayhemVersion) statt \(expected.description). Die neue Firmware wurde vermutlich abgelehnt."))
        }
        pendingRenewal = nil
        finishProgress(InstallProgress(phase: .done, fraction: 1,
                                       detail: String(localized: "Gerät erneuert, Firmware \(info.mayhemVersion) installiert."),
                                       startedAt: started, finishedAt: Date()))
    }

    /// Schließt ein unterbrochenes Erneuern ab: die Dateien liegen schon auf
    /// der Karte, nur das Flashen fehlt noch.
    func finishPendingRenewal() async {
        guard let pending = pendingRenewal, let device else { return }
        screenMirroring = false
        await performExclusive(String(localized: "Erneuern wird abgeschlossen")) {
            let started = Date()
            do {
                if let conflict = pending.conflict(with: info) {
                    throw MayhemError.unexpectedResponse(String(localized: "\(conflict) Es wurde nichts geschrieben."))
                }
                try await flashFromCard(device: device, pending: pending, started: started)
            } catch {
                finishProgress(InstallProgress(phase: .failed, detail: error.localizedDescription, startedAt: started))
            }
        }
    }

    /// Schaltet in den SD-over-USB-Modus und wartet auf das Laufwerk.
    func mountSDCard(update: @MainActor (InstallProgress.Phase, Double, String) -> Void) async throws -> URL {
        if let volume = await Task.detached(operation: { SDCardVolume.mounted() }).value { return volume }
        if let device {
            update(.switchingToSD, 0, String(localized: "Starte „SD over USB“ auf dem PortaPack …"))
            try await device.startSDOverUSB()
            await device.close()
            self.device = nil
        }
        mode = .sdCard
        for second in 0..<60 {
            try await Task.sleep(for: .seconds(1))
            update(.switchingToSD, Double(second) / 60, String(localized: "Warte auf das Laufwerk … (\(second) s)"))
            if let volume = await Task.detached(operation: { SDCardVolume.mounted() }).value {
                sdVolume = volume
                return volume
            }
        }
        throw SDCardError.volumeDidNotAppear
    }

    /// Wartet, bis Mayhem wieder antwortet, und verbindet sich.
    func waitForMayhem(timeout: Int, phase: InstallProgress.Phase, detail: String) async throws -> MayhemDevice? {
        let started = installProgress.startedAt
        for second in 0..<timeout {
            try await Task.sleep(for: .seconds(1))
            installProgress = InstallProgress(phase: phase, fraction: min(0.95, Double(second) / Double(timeout)),
                                              detail: "\(detail) (\(second) s)", startedAt: started)
            if let found = try? await reconnectIfAvailable() { return found }
        }
        return nil
    }

    // MARK: - Manuell

    /// SD-Karte als Laufwerk bereitstellen (zum Kopieren im Finder).
    func shareSDCard() async {
        guard !busy else { return }
        await performExclusive(String(localized: "SD-Karte wird bereitgestellt")) {
            do {
                let volume = try await mountSDCard { [weak self] phase, fraction, detail in
                    self?.installProgress = InstallProgress(phase: phase, fraction: fraction, detail: detail)
                }
                installProgress = InstallProgress()
                note(String(localized: "SD-Karte als Laufwerk bereit: \(volume.path)"))
            } catch {
                connectionError = error.localizedDescription
                installProgress = InstallProgress()
            }
        }
    }

    /// SD-Karte aushängen und zurück in Mayhem.
    func ejectSDCard() async {
        guard !busy else { return }
        await performExclusive(String(localized: "SD-Karte wird ausgeworfen")) {
            do {
                if let volume = await Task.detached(operation: { SDCardVolume.mounted() }).value {
                    try await Task.detached { try SDCardVolume.unmount(volume) }.value
                }
                sdVolume = nil
                SDCardVolume.leaveSDMode()
                mode = .disconnected
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }
}
