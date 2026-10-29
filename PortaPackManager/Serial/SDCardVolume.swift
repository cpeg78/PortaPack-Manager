import DiskArbitration
import Foundation

/// Die SD-Karte des PortaPack als Laufwerk am Mac („SD over USB“).
///
/// Im SD-Modus meldet sich das Gerät als Kartenleser `0781:a7a8` mit dem
/// SCSI-Modell „Portapack MSD“ an. Ein USB-Reset (Neu-Enumeration) lässt es
/// zurück in Mayhem starten – so steht es in
/// `firmware/baseband/sd_over_usb/proc_sd_over_usb.cpp`.
enum SDCardVolume {
    static let modelName = "Portapack MSD"

    /// Liefert das eingehängte Laufwerk der PortaPack-Karte, falls vorhanden.
    ///
    /// Über `getfsstat(MNT_NOWAIT)`: das liefert die zwischengespeicherte
    /// Einhängeliste, ohne ein einziges Dateisystem anzufragen. Netzlaufwerke
    /// fallen über `MNT_LOCAL` und die Quelle `/dev/disk…` heraus, bevor
    /// irgendetwas sie berührt – `mountedVolumeURLs` mit Ressourcenwerten fragte
    /// alle Volumes ab, und ein schlafendes NAS konnte dabei hängen.
    static func mounted() -> URL? {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        for mount in localDiskMounts() where mount.mountPoint.hasPrefix("/Volumes/") {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, mount.bsdName),
                  let description = DADiskCopyDescription(disk) as? [CFString: Any] else { continue }
            let model = (description[kDADiskDescriptionDeviceModelKey] as? String) ?? ""
            if model.contains(modelName) { return URL(fileURLWithPath: mount.mountPoint, isDirectory: true) }
        }
        return nil
    }

    /// Lokale, von einem Blockgerät eingehängte Dateisysteme.
    static func localDiskMounts() -> [(bsdName: String, mountPoint: String)] {
        let capacity = getfsstat(nil, 0, MNT_NOWAIT)
        guard capacity > 0 else { return [] }
        // `statfs()` ist in Swift zugleich Funktion und Struktur – deshalb
        // ohne Vorbelegung über unbelegten Speicher.
        let pointer = UnsafeMutablePointer<statfs>.allocate(capacity: Int(capacity))
        defer { pointer.deallocate() }
        let count = getfsstat(pointer, Int32(Int(capacity) * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard count > 0 else { return [] }
        return UnsafeBufferPointer(start: pointer, count: min(Int(count), Int(capacity))).compactMap { fs in
            guard fs.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }
            let from = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let on = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard from.hasPrefix("/dev/disk") else { return nil }
            return (String(from.dropFirst("/dev/".count)), on)
        }
    }

    /// Ist das Gerät gerade im SD-Modus am USB (eingehängt oder nicht)?
    static var devicePresent: Bool {
        SerialDeviceFinder.usbDevicePresent(vendorID: USBIdentity.sanDisk, productID: USBIdentity.sdOverUSB)
    }

    /// Hängt das Laufwerk aus (schreibt dabei alle Puffer zurück).
    ///
    /// Mit Zeitlimit: Antwortet der Kartenmodus des Geräts nicht mehr, hängt
    /// `diskutil` sonst unbegrenzt – selbst mit `force` (Fund: 20.10.2026).
    static func unmount(_ volume: URL, timeout: TimeInterval = 90) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", volume.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if process.isRunning {
            process.terminate()
            throw SDCardError.unmountTimedOut
        }
        guard process.terminationStatus == 0 else {
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw SDCardError.unmountFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Beendet den SD-Modus: USB-Reset, das Gerät startet Mayhem neu.
    @discardableResult
    static func leaveSDMode() -> Bool {
        HackRFDevice.reenumerate(vendorID: USBIdentity.sanDisk, productID: USBIdentity.sdOverUSB)
    }
}

enum SDCardError: Error, LocalizedError {
    case unmountFailed(String)
    case volumeDidNotAppear
    case unmountTimedOut
    case missingPackage(String)
    case extractionFailed(String)
    case notEnoughSpace(needed: Int64, available: Int64, where: String)

    var errorDescription: String? {
        switch self {
        case let .unmountFailed(text): String(localized: "Die SD-Karte ließ sich nicht auswerfen: \(text)")
        case .unmountTimedOut: String(localized: "Die SD-Karte antwortet nicht mehr und ließ sich nicht auswerfen. Schalte das PortaPack aus und wieder ein – danach „Erneuern abschließen“.")
        case .volumeDidNotAppear: String(localized: "Die SD-Karte ist nicht als Laufwerk erschienen. Zeigt das PortaPack den Bildschirm „SD over USB“?")
        case let .missingPackage(name): String(localized: "In dieser Firmware-Version fehlt das Paket für die SD-Karte (\(name)).")
        case let .extractionFailed(text): String(localized: "Das Paket für die SD-Karte ließ sich nicht entpacken: \(text)")
        case let .notEnoughSpace(needed, available, place):
            String(localized: "Zu wenig Platz \(place): nötig \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), frei \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)). Es wurde nichts gelöscht.")
        }
    }
}
