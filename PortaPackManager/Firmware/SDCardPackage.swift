import Foundation

extension FirmwareRelease {
    /// Das `COPY_TO_SDCARD_…zip` für einen Gerätetyp, mit oder ohne Weltkarte.
    func sdCardPackage(for type: DeviceType, withWorldMap: Bool) -> FirmwareAsset? {
        let packages = assets.filter { $0.name.hasPrefix("COPY_TO_SDCARD") && $0.name.hasSuffix(".zip") }
        let matching = packages.filter { $0.name.contains("-no-world-map") != withWorldMap }
        if let exact = matching.first(where: { $0.deviceType == type }) { return exact }
        // Typlose Pakete stammen aus der Zeit vor Pro/PortaRF – nur HackRF One.
        return type == .hackrf ? matching.first { $0.deviceType == nil } : nil
    }
}

/// Ein entpacktes SD-Karten-Paket und das Kopieren auf die Karte.
struct SDCardPackage: Sendable {
    let root: URL

    struct Options: Sendable {
        /// Vorhandene Frequenzlisten nicht überschreiben (eigene Einträge bleiben).
        var keepFrequencyLists = true
        /// Alte externe Apps vorher löschen (verhindert Versionskonflikte).
        var removeOldApps = true
    }

    struct CopyProgress: Sendable {
        var copiedBytes: Int64
        var totalBytes: Int64
        var currentFile: String
    }

    static let extractionDirectory: URL = FirmwareDownloader.cacheDirectory.deletingLastPathComponent()
        .appendingPathComponent("SDCard", isDirectory: true)

    /// Reserve über dem entpackten Umfang, damit der Mac nicht vollläuft.
    static let freeSpaceReserve: Int64 = 500 * 1024 * 1024

    /// Entpackt das ZIP mit `ditto` in den Cache (außerhalb von iCloud).
    ///
    /// Vorher wird das Inhaltsverzeichnis gelesen: Pfade mit `..`, absolute
    /// Pfade und symbolische Links werden abgelehnt, und der entpackte Umfang
    /// (mit Weltkarte 2,2 GB) muss auf die Platte passen. `ditto` selbst
    /// entschärft `../` und absolute Pfade (geprüft 27.10.2026: es legt sie
    /// innerhalb des Ziels an) und bricht bei Links ab – die eigene Prüfung
    /// hängt aber nicht an diesem Verhalten.
    static func extract(_ zip: URL) async throws -> SDCardPackage {
        let target = extractionDirectory.appendingPathComponent(zip.deletingPathExtension().lastPathComponent, isDirectory: true)
        let marker = target.appendingPathComponent(".fertig")
        if FileManager.default.fileExists(atPath: marker.path) {
            return SDCardPackage(root: target)
        }
        try? FileManager.default.removeItem(at: target)
        let listing = try await Task.detached { try ZipDirectory.read(zip) }.value
        if let bad = listing.entries.first(where: { !$0.isSafe }) {
            throw SDCardError.extractionFailed(String(localized: "unzulässiger Pfad im Paket: \(bad.name)"))
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let needed = listing.uncompressedSize + freeSpaceReserve
        if let free = availableCapacity(at: target), free < needed {
            try? FileManager.default.removeItem(at: target)
            throw SDCardError.notEnoughSpace(needed: needed, available: free, where: String(localized: "auf dem Mac"))
        }
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", "--noextattr", "--noqtn", zip.path, target.path]
            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SDCardError.extractionFailed(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
        }.value
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        return SDCardPackage(root: target)
    }

    /// Freier Platz eines lokalen Laufwerks (für das Cache-Volume die Angabe
    /// „für wichtige Daten“, die löschbare Caches mitzählt).
    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Bytes, die das Kopieren auf der Karte zusätzlich belegt: neue Dateien
    /// ganz, überschriebene nur mit dem Zuwachs, gelöschte Apps abgezogen.
    static func additionalBytes(plan: [(relative: String, size: Int64)], existingSize: (String) -> Int64?, freedByRemoval: Int64) -> Int64 {
        let growth = plan.reduce(Int64(0)) { sum, item in
            sum + max(0, item.size - (existingSize(item.relative) ?? 0))
        }
        return growth - freedByRemoval
    }

    /// Alle zu kopierenden Dateien (relativ), ohne macOS-Beiwerk.
    func files() throws -> [(relative: String, size: Int64)] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var result: [(String, Int64)] = []
        let base = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" || name == ".fertig" || name == "__MACOSX" {
                if name == "__MACOSX" { enumerator.skipDescendants() }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            result.append((relative, Int64(values.fileSize ?? 0)))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Das Firmware-Abbild im Paket (`FIRMWARE/portapack-mayhem_….bin`).
    func firmwareImage() throws -> String? {
        try files().map(\.relative).first { $0.uppercased().hasPrefix("FIRMWARE/") && $0.lowercased().hasSuffix(".bin") }
    }

    /// Kopiert das Paket auf die Karte. Kopiert wird roh (ohne erweiterte
    /// Attribute), damit auf der FAT-Karte keine `._`-Dateien entstehen.
    func copy(to volume: URL, options: Options, progress: @Sendable (CopyProgress) -> Void) throws {
        let fm = FileManager.default
        var plan = try files()
        if options.keepFrequencyLists {
            plan.removeAll { item in
                item.relative.uppercased().hasPrefix("FREQMAN/")
                    && fm.fileExists(atPath: volume.appendingPathComponent(item.relative).path)
            }
        }

        let apps = volume.appendingPathComponent("APPS", isDirectory: true)
        let oldApps = options.removeOldApps
            ? ((try? fm.contentsOfDirectory(atPath: apps.path)) ?? []).filter {
                $0.hasSuffix(".ppma") || $0.hasSuffix(".ppmp") || $0.hasPrefix("._")
            }
            : []
        // Platz vor dem Löschen prüfen: reicht er nicht, bleiben die alten
        // Apps stehen und das Gerät bleibt benutzbar.
        func fileSize(_ url: URL) -> Int64? {
            (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
        let freed = oldApps.reduce(Int64(0)) { $0 + (fileSize(apps.appendingPathComponent($1)) ?? 0) }
        let needed = Self.additionalBytes(
            plan: plan,
            existingSize: { relative in
                let isOldApp = oldApps.contains { relative.uppercased() == "APPS/" + $0.uppercased() }
                return isOldApp ? nil : fileSize(volume.appendingPathComponent(relative))
            },
            freedByRemoval: freed)
        // Reserve für FAT-Verwaltung und angebrochene Cluster vieler kleiner Dateien.
        let reserve: Int64 = 16 * 1024 * 1024 + max(0, needed) / 50
        if let free = (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init),
           free < needed + reserve {
            throw SDCardError.notEnoughSpace(needed: needed + reserve, available: free, where: String(localized: "auf der SD-Karte"))
        }

        // Spotlight soll die Karte nicht durchsuchen: jeder Lesezugriff läuft
        // über die langsame Verbindung und hält das Aushängen auf.
        fm.createFile(atPath: volume.appendingPathComponent(".metadata_never_index").path, contents: Data())
        for name in oldApps {
            try? fm.removeItem(at: apps.appendingPathComponent(name))
        }
        let total = plan.reduce(Int64(0)) { $0 + $1.size }
        var copied: Int64 = 0
        let bufferSize = 1 << 20
        var lastReport = Date.distantPast

        for item in plan {
            try Task.checkCancellation()
            let source = root.appendingPathComponent(item.relative)
            let destination = volume.appendingPathComponent(item.relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            guard fm.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }
            while let chunk = try input.read(upToCount: bufferSize), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                if Date().timeIntervalSince(lastReport) > 0.2 {
                    progress(CopyProgress(copiedBytes: copied, totalBytes: total, currentFile: item.relative))
                    lastReport = Date()
                }
            }
            try output.synchronize()
        }
        progress(CopyProgress(copiedBytes: copied, totalBytes: total, currentFile: ""))
    }
}
