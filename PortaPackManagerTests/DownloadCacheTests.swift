import Foundation
import Testing
@testable import PortaPackManager

@Suite("Download-Cache")
struct DownloadCacheTests {
    private func makeCache() throws -> DownloadCache {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = DownloadCache(downloadDirectory: root.appendingPathComponent("Firmware", isDirectory: true),
                                  extractionDirectory: root.appendingPathComponent("SDCard", isDirectory: true))
        try FileManager.default.createDirectory(at: cache.downloadDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.extractionDirectory, withIntermediateDirectories: true)
        return cache
    }

    private func write(_ bytes: Int, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    @Test("Paketendungen werden abgeschnitten")
    func stem() {
        #expect(DownloadCache.stem(of: "OCI_hackrf_mayhem_nightly_n_261015.ppfw.tar") == "OCI_hackrf_mayhem_nightly_n_261015")
        #expect(DownloadCache.stem(of: "COPY_TO_SDCARD_hackrf_n_261015.zip") == "COPY_TO_SDCARD_hackrf_n_261015")
        #expect(DownloadCache.stem(of: "readme") == "readme")
    }

    @Test("Download und entpacktes Paket bilden einen Eintrag")
    func grouping() throws {
        let cache = try makeCache()
        try write(1000, cache.downloadDirectory.appendingPathComponent("COPY_TO_SDCARD_x.zip"))
        try write(500, cache.extractionDirectory.appendingPathComponent("COPY_TO_SDCARD_x/APPS/a.ppma"))
        try write(10, cache.extractionDirectory.appendingPathComponent("COPY_TO_SDCARD_x/.fertig"))
        try write(200, cache.downloadDirectory.appendingPathComponent("OCI_y.ppfw.tar.part"))

        let entries = cache.entries()
        #expect(entries.count == 2)
        let sd = try #require(entries.first { $0.name == "COPY_TO_SDCARD_x" })
        #expect(sd.isExtracted && !sd.isPartial)
        #expect(sd.urls.count == 2)
        #expect(sd.size >= 1510)
        let oci = try #require(entries.first { $0.name == "OCI_y" })
        #expect(oci.isPartial && !oci.isExtracted)
    }

    @Test("Einzeln und vollständig löschen")
    func removal() throws {
        let cache = try makeCache()
        try write(10, cache.downloadDirectory.appendingPathComponent("COPY_TO_SDCARD_x.zip"))
        try write(10, cache.extractionDirectory.appendingPathComponent("COPY_TO_SDCARD_x/BIN/a.bin"))
        try write(10, cache.downloadDirectory.appendingPathComponent("OCI_y.ppfw.tar"))

        let sd = try #require(cache.entries().first { $0.name == "COPY_TO_SDCARD_x" })
        try cache.remove(sd)
        #expect(cache.entries().map(\.name) == ["OCI_y"])

        try cache.removeAll()
        #expect(cache.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.downloadDirectory.path))
    }
}
