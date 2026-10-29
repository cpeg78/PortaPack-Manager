import Foundation
import Testing
@testable import PortaPackManager

@Suite("SD-Karten-Paket")
struct SDCardPackageTests {
    private func release(_ names: [String]) -> FirmwareRelease {
        FirmwareRelease(tag: "nightly-tag-2026-10-15", title: "", publishedAt: Date(), isPrerelease: true, notes: "",
                        htmlURL: URL(string: "https://example.com")!,
                        assets: names.map { FirmwareAsset(name: $0, size: 1, downloadURL: URL(string: "https://example.com/\($0)")!) })
    }

    @Test("Gerätetyp und Weltkarte bestimmen das Paket")
    func selection() {
        let r = release([
            "COPY_TO_SDCARD_hackrf_mayhem_nightly_n_261015-no-world-map.zip",
            "COPY_TO_SDCARD_hackrf_mayhem_nightly_n_261015.zip",
            "COPY_TO_SDCARD_hpro_mayhem_nightly_n_261015-no-world-map.zip",
            "OCI_hackrf_mayhem_nightly_n_261015.ppfw.tar",
        ])
        #expect(r.sdCardPackage(for: .hackrf, withWorldMap: false)?.name == "COPY_TO_SDCARD_hackrf_mayhem_nightly_n_261015-no-world-map.zip")
        #expect(r.sdCardPackage(for: .hackrf, withWorldMap: true)?.name == "COPY_TO_SDCARD_hackrf_mayhem_nightly_n_261015.zip")
        #expect(r.sdCardPackage(for: .hpro, withWorldMap: true) == nil)
        #expect(r.sdCardPackage(for: .portarf, withWorldMap: false) == nil)
    }

    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ root: URL, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ root: URL, _ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("Kopieren: Frequenzlisten bleiben, alte Apps verschwinden, kein macOS-Beiwerk")
    func copy() throws {
        let package = try makeDir(), card = try makeDir()
        defer { try? FileManager.default.removeItem(at: package); try? FileManager.default.removeItem(at: card) }
        try write("neu", package, "APPS/tetris.ppma")
        try write("fw", package, "FIRMWARE/portapack-mayhem_n_261015.bin")
        try write("standard", package, "FREQMAN/AIRBAND.TXT")
        try write("standard", package, "FREQMAN/NEU.TXT")
        try write("x", package, "._APPS")
        try write("x", package, ".fertig")

        try write("alt", card, "APPS/veraltet.ppma")
        try write("eigene", card, "FREQMAN/AIRBAND.TXT")
        try write("aufnahme", card, "CAPTURES/rec.C16")

        let pkg = SDCardPackage(root: package)
        #expect(try pkg.firmwareImage() == "FIRMWARE/portapack-mayhem_n_261015.bin")
        let progress = ProgressBox()
        try pkg.copy(to: card, options: .init(keepFrequencyLists: true, removeOldApps: true)) { progress.last = $0 }

        #expect(read(card, "APPS/tetris.ppma") == "neu")
        #expect(read(card, "APPS/veraltet.ppma") == nil)
        #expect(read(card, "FREQMAN/AIRBAND.TXT") == "eigene")
        #expect(read(card, "FREQMAN/NEU.TXT") == "standard")
        #expect(read(card, "CAPTURES/rec.C16") == "aufnahme")
        #expect(read(card, "._APPS") == nil)
        #expect(read(card, ".fertig") == nil)
        #expect(progress.last?.copiedBytes == progress.last?.totalBytes)
    }

    @Test("Ohne „behalten“ werden auch Frequenzlisten überschrieben")
    func overwriteFreqman() throws {
        let package = try makeDir(), card = try makeDir()
        defer { try? FileManager.default.removeItem(at: package); try? FileManager.default.removeItem(at: card) }
        try write("standard", package, "FREQMAN/AIRBAND.TXT")
        try write("eigene", card, "FREQMAN/AIRBAND.TXT")
        try SDCardPackage(root: package).copy(to: card, options: .init(keepFrequencyLists: false, removeOldApps: false)) { _ in }
        #expect(read(card, "FREQMAN/AIRBAND.TXT") == "standard")
    }
}

private final class ProgressBox: @unchecked Sendable {
    var last: SDCardPackage.CopyProgress?
}

@Suite("Protokoll-Details")
struct ProtocolDetailTests {
    @Test("Prüfsumme von ABCD entspricht der vom Gerät gemeldeten")
    func deviceCRC() {
        // Am 20.10.2026 vom PortaPack (n_251101) per `crc32` gemeldet.
        #expect(MayhemCRC32.checksum(Data("ABCD".utf8)) == 0x5430_659C)
    }
}
