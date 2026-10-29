import Foundation

/// Plausibilitätsprüfung eines Firmware-Abbilds für den SPI-Flash des
/// LPC43xx, bevor irgendetwas gelöscht wird.
///
/// Der LPC4320 bootet direkt aus dem SPI-Flash; das Abbild beginnt ohne
/// eigenen Kopf mit der Cortex-M-Vektortabelle. Gemessen an
/// `portapack-mayhem_n_261027.bin` (HackRF One: 1 MiB, HackRF Pro: 4 MiB):
/// Stapelzeiger `0x20000400` (AHB-SRAM), Reset-Vektor `0x0000807D` – die
/// Boot-ROM spiegelt den Flash an Adresse 0, Thumb-Bit gesetzt. Andere
/// Bauweisen (libopencm3 `rom_to_ram`) legen Stapel bzw. Code ins lokale SRAM
/// `0x1000_0000` oder springen in den SPIFI-Bereich `0x1400_0000`.
enum FirmwareImage {
    /// Kleiner ist kein echtes Abbild – eher ein abgeschnittener Download
    /// oder ein leerer tar-Eintrag. Die HackRF-Firmware allein hat ≈ 40 KiB,
    /// Mayhem-Abbilder sind 1 MiB (HackRF One) bzw. 4 MiB (Pro).
    static let minimumSize = 256 * 1024

    enum ImageError: Error, LocalizedError, Equatable {
        case tooSmall(Int)
        case tooLarge(size: Int, capacity: Int)
        case implausibleVectorTable(String)

        var errorDescription: String? {
            switch self {
            case let .tooSmall(size):
                String(localized: "Die Firmware-Datei ist mit \(size) Bytes zu klein (mindestens \(FirmwareImage.minimumSize / 1024) KiB) – vermutlich abgeschnitten. Es wurde nichts geschrieben.")
            case let .tooLarge(size, capacity):
                String(localized: "Die Firmware-Datei ist mit \(size) Bytes größer als der Speicher dieses Geräts (\(capacity) Bytes) – falscher Gerätetyp? Es wurde nichts geschrieben.")
            case let .implausibleVectorTable(reason):
                String(localized: "Die Datei sieht nicht wie eine Firmware für dieses Gerät aus (\(reason)). Es wurde nichts geschrieben.")
            }
        }
    }

    /// RAM-Bereiche des LPC43xx, in die der Stapelzeiger zeigen darf (obere
    /// Grenze einschließlich – der Stapel wächst nach unten).
    private static let stackRanges: [ClosedRange<UInt32>] = [
        0x1000_0000...0x1002_0000,   // lokales SRAM 128 KiB
        0x1008_0000...0x1009_2000,   // lokales SRAM 72 KiB
        0x2000_0000...0x2001_0000,   // AHB-SRAM 64 KiB
    ]

    /// Prüft Größe und Vektortabelle. `capacity` = Größe des SPI-Flashs.
    static func validate(_ image: Data, capacity: Int? = nil) throws {
        guard image.count >= minimumSize else { throw ImageError.tooSmall(image.count) }
        if let capacity, image.count > capacity {
            throw ImageError.tooLarge(size: image.count, capacity: capacity)
        }
        let words = (0..<4).map { index -> UInt32 in
            let start = image.startIndex + index * 4
            return image[start..<start + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        }
        let stack = words[0]
        guard stack & 0x3 == 0, stackRanges.contains(where: { $0.contains(stack) }) else {
            throw ImageError.implausibleVectorTable(String(format: "Stapelzeiger 0x%08X liegt nicht im RAM", stack))
        }
        // Reset, NMI, HardFault: Thumb-Code (ungerade) mit Ziel im Abbild,
        // im SPIFI-Fenster oder im RAM.
        let names = ["Reset", "NMI", "HardFault"]
        for (name, vector) in zip(names, words[1...]) {
            guard vector & 1 == 1, isPlausibleCodeAddress(vector & ~1, imageSize: image.count) else {
                throw ImageError.implausibleVectorTable(String(format: "%@-Vektor 0x%08X", name, vector))
            }
        }
    }

    private static func isPlausibleCodeAddress(_ address: UInt32, imageSize: Int) -> Bool {
        let size = UInt32(clamping: imageSize)
        // Gespiegelter Flash ab 0 (hinter der Vektortabelle) bzw. SPIFI-Fenster.
        if address >= 0x40, address < size { return true }
        if address >= 0x1400_0040, address < 0x1400_0000 &+ size { return true }
        if address >= 0x8000_0040, address < 0x8000_0000 &+ size { return true }
        return stackRanges.contains { $0.contains(address) }
    }
}
