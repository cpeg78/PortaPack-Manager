import Foundation

extension DeviceSession {
    /// Normaler Weg: Paket auf die SD-Karte laden und `flash` auslösen. Die
    /// Firmware entpackt dabei die Apps nach `/APPS` und flasht das Abbild.
    func installFirmware(_ source: FirmwareSource, deviceType: DeviceType?) async {
        guard let device else {
            installProgress = InstallProgress(phase: .failed, detail: MayhemError.notConnected.localizedDescription)
            return
        }
        screenMirroring = false
        await performExclusive(String(localized: "Firmware wird installiert")) {
            do {
                try await installer.install(
                    source, on: device, deviceType: deviceType,
                    waitForDevice: { [weak self] in try await self?.reconnectIfAvailable() },
                    report: progressReporter())
                // Ein liegengebliebenes Erneuern ist jetzt überholt – „Erneuern
                // abschließen“ flashte sonst später womöglich eine ältere Version.
                pendingRenewal = nil
            } catch {
                note(String(localized: "Installation fehlgeschlagen: \(error.localizedDescription)"))
            }
        }
    }

    /// Nur die Apps aus einem Paket nach `/APPS` kopieren.
    func installAppsOnly(_ source: FirmwareSource) async {
        guard let device else {
            installProgress = InstallProgress(phase: .failed, detail: MayhemError.notConnected.localizedDescription)
            return
        }
        screenMirroring = false
        await performExclusive(String(localized: "Apps werden installiert")) {
            let report = progressReporter()
            do {
                installProgress = InstallProgress(phase: .downloading, startedAt: Date())
                let data = try await installer.fetch(source, report: report)
                try await installer.installApps(from: data, on: device, report: report)
                finishProgress(InstallProgress(phase: .done, fraction: 1, detail: String(localized: "Apps installiert"), finishedAt: Date()))
            } catch {
                finishProgress(InstallProgress(phase: .failed, detail: error.localizedDescription))
            }
        }
    }

    /// Rettungsweg über den HackRF-Modus: Firmware-Abbild direkt in den
    /// SPI-Flash schreiben (wie `hackrf_spiflash -w`), zurücklesen,
    /// neu starten und danach die Apps über die Konsole nachinstallieren.
    /// Funktioniert auch, wenn die Mayhem-Konsole nicht mehr nutzbar ist,
    /// solange das Gerät im HackRF-Modus startet.
    ///
    /// Bisher nie am Gerät erprobt (Stand 27.10.2026) – deshalb in der
    /// Oberfläche hinter einer eigenen Bestätigung, und alles, was sich vorher
    /// prüfen lässt (Paket, Abbild, Flash-Größe), wird vor dem Löschen geprüft.
    func flashViaHackRFMode(_ source: FirmwareSource, deviceType: DeviceType?, installApps: Bool) async {
        screenMirroring = false
        await performExclusive(String(localized: "Firmware wird über den HackRF-Modus geschrieben")) {
            let report = progressReporter()
            let started = Date()
            @MainActor func update(_ phase: InstallProgress.Phase, _ fraction: Double, _ detail: String) {
                installProgress = InstallProgress(phase: phase, fraction: fraction, detail: detail, startedAt: started)
            }
            // Ab dem Löschen ist ein Fehler ernst: dann steht kein startfähiges
            // Abbild mehr im Flash.
            var flashTouched = false
            do {
                update(.downloading, 0, source.fileName)
                let data = try await installer.fetch(source, report: report)

                // Abbild bestimmen und prüfen, bevor das Gerät angefasst wird.
                let image = try FirmwareInstaller.validatePackage(data, fileName: source.fileName,
                                                                  capacity: deviceType?.flashCapacity)
                let archive = source.fileName.lowercased().hasSuffix(".bin") ? nil : try TarArchive(data: data)

                // In den HackRF-Modus wechseln.
                if hackRF == nil {
                    update(.preparing, 0, String(localized: "Wechsle in den HackRF-Modus …"))
                    if let device {
                        await device.switchToHackRFMode()
                    }
                    self.device = nil
                    var opened: HackRFDevice?
                    for _ in 0..<30 {
                        try await Task.sleep(for: .seconds(1))
                        if let candidate = try? await Task.detached(operation: { try HackRFDevice.openFirst() }).value {
                            opened = candidate
                            break
                        }
                    }
                    guard let opened else {
                        throw HackRFError.notFound
                    }
                    hackRF = opened
                    mode = .hackRF
                }
                guard let hackRF else { throw HackRFError.notFound }

                // Kein Empfänger darf parallel Transfers laufen haben – auch nicht
                // zwischen Schreiben und Rücklesen oder in der Pause vor dem
                // zweiten Versuch (W7-Rest): Sperre über den ganzen Vorgang halten.
                try await Task.detached { try hackRF.holdFlash() }.value
                defer { hackRF.releaseFlash() }
                let capacity = try await Task.detached { try hackRF.flashCapacity() }.value
                try FirmwareImage.validate(image, capacity: capacity)

                // Schreiben und zurücklesen; scheitert es, einmal komplett
                // wiederholen (Löschen + Schreiben + Vergleich).
                let attempts = 2
                for attempt in 1...attempts {
                    do {
                        flashTouched = true
                        update(.flashing, 0, attempt == 1
                               ? String(localized: "Lösche den Firmware-Speicher … NICHT abstecken!")
                               : String(localized: "Zweiter Versuch: lösche und schreibe erneut … NICHT abstecken!"))
                        try await Task.detached {
                            try hackRF.writeFirmware(image) { done, total in
                                report(InstallProgress(phase: .flashing, fraction: Double(done) / Double(total),
                                                       detail: String(localized: "Schreibe \(FirmwareInstaller.ofTotal(Int64(done), Int64(total))) – NICHT abstecken!"),
                                                       startedAt: started))
                            }
                        }.value
                        update(.verifying, 0, String(localized: "Lese zur Kontrolle zurück …"))
                        let readBack = try await Task.detached {
                            try hackRF.readFlash(length: image.count) { done, total in
                                report(InstallProgress(phase: .verifying, fraction: Double(done) / Double(total),
                                                       detail: String(localized: "Vergleiche \(FirmwareInstaller.ofTotal(Int64(done), Int64(total)))"),
                                                       startedAt: started))
                            }
                        }.value
                        guard readBack == image else {
                            throw MayhemError.checksumMismatch(expected: MayhemCRC32.checksum(image), actual: MayhemCRC32.checksum(readBack))
                        }
                        break
                    } catch {
                        note(String(localized: "Firmware schreiben, Versuch \(attempt) von \(attempts): \(error.localizedDescription)"))
                        if attempt == attempts || error is FirmwareImage.ImageError { throw error }
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                flashTouched = false

                // Neustart in Mayhem.
                update(.waitingForReboot, 0, String(localized: "Starte neu …"))
                try? hackRF.reset()
                self.hackRF = nil
                await Task.detached { hackRF.close() }.value
                mode = .disconnected
                var reconnected: MayhemDevice?
                for second in 0..<90 {
                    try await Task.sleep(for: .seconds(1))
                    update(.waitingForReboot, Double(second) / 90, String(localized: "Warte auf Mayhem … (\(second) s)"))
                    if let found = try? await reconnectIfAvailable() {
                        reconnected = found
                        break
                    }
                }
                guard let reconnected else {
                    throw MayhemError.unexpectedResponse(String(localized: "Das Gerät hat sich nach dem Schreiben nicht im Mayhem-Modus gemeldet."))
                }

                if installApps, let archive {
                    try await reconnected.makeDirectory("/APPS")
                    let apps = archive.apps
                    for (index, entry) in apps.enumerated() {
                        let name = TarArchive.lastComponent(entry.name)
                        update(.installingApps, Double(index) / Double(max(apps.count, 1)), "\(name) (\(index + 1)/\(apps.count))")
                        try await reconnected.upload(try archive.contents(of: entry), to: "/APPS/\(name)") { _, _ in }
                    }
                }
                let info = try await reconnected.info()
                pendingRenewal = nil
                finishProgress(InstallProgress(phase: .done, fraction: 1, detail: String(localized: "Jetzt installiert: \(info.mayhemVersion)"),
                                               startedAt: started, finishedAt: Date()))
            } catch {
                finishProgress(InstallProgress(phase: .failed,
                                               detail: flashTouched ? Self.flashFailureText(error) : error.localizedDescription,
                                               startedAt: started))
            }
        }
    }

    /// Meldung, wenn nach dem Löschen des SPI-Flashs etwas schiefging. Das
    /// Gerät läuft weiter aus dem RAM – nur Ausschalten macht es zum DFU-Fall.
    nonisolated static func flashFailureText(_ error: any Error) -> String {
        String(localized: """
            Die Firmware ließ sich nicht schreiben: \(error.localizedDescription)

            Der Firmware-Speicher ist jetzt gelöscht oder unvollständig. Das PortaPack NICHT abstecken und NICHT ausschalten – solange es läuft, kannst du „Installieren“ wiederholen. Ausgeschaltet startet es nur noch über den DFU-Modus (hackrf_spiflash bzw. dfu-util).
            """)
    }

    /// Wechselt aus dem Mayhem- in den HackRF-Modus.
    ///
    /// Alle Gerätebefehle hier sind während eines exklusiven Vorgangs
    /// (`busy`: Installation, Rettungsweg, Erneuern) gesperrt – ein Neustart
    /// mitten im Seitenschreiben ließe das Gerät nur noch per DFU starten
    /// (Review 28.10.2026, W5).
    func enterHackRFMode() async {
        // Läuft auf dem PortaPack gerade eine App, beendet `hackrf` mitunter erst
        // diese – das Gerät meldet sich dann wieder als Mayhem (z. B. als
        // „Transceiver“), und erst der nächste Befehl wechselt (Fund 30.10.2026,
        // vom Handy dreimal tippen). Deshalb bis zu dreimal senden.
        for attempt in 1...3 {
            guard !busy, let device else { return }
            if attempt > 1 { Log.session.notice("HackRF-Modus nicht erreicht – Befehl erneut (Versuch \(attempt))") }
            await device.switchToHackRFMode()
            await disconnect()
            for _ in 0..<20 where hackRF == nil && self.device == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard hackRF == nil, self.device != nil else { return }
        }
    }

    /// Startet das Gerät neu (aus beiden Modi).
    func rebootDevice() async {
        guard !busy else { return }
        if let device {
            await device.reboot()
        } else if let hackRF {
            // Stoppen wartet auf den Empfangsthread – nicht auf dem Main Actor.
            await Task.detached {
                hackRF.stopReceiving()
                try? hackRF.reset()
            }.value
        }
        await disconnect()
    }

    func rebootToDFU() async {
        guard !busy, let device else { return }
        await device.rebootToDFU()
        await disconnect()
    }

    /// „Ab- und Anstecken“ per Software – löst einen hängenden seriellen Treiber.
    func reenumerateUSB() async {
        guard !busy else { return }
        await disconnect()
        for product in [USBIdentity.portaPackMayhem, USBIdentity.hackRFOne] {
            HackRFDevice.reenumerate(vendorID: USBIdentity.greatScottGadgets, productID: product)
        }
        note(String(localized: "USB-Gerät neu angemeldet."))
    }
}
