import Foundation
import Testing
@testable import PortaPackManager

@Suite("Firmware-Versionen")
struct FirmwareVersionTests {
    @Test("Nightly-Kennung aus der Geräteanzeige wird erkannt")
    func nightlyFromDevice() {
        #expect(FirmwareVersion(string: "n_251101") == .nightly(yymmdd: 251101))
    }

    @Test("Nightly-Tag von GitHub entspricht der Geräteanzeige")
    func nightlyTagMatchesDevice() {
        #expect(FirmwareVersion(tag: "nightly-tag-2026-10-15") == FirmwareVersion(string: "n_261015"))
        #expect(FirmwareVersion(string: "n_261015").releaseTag == "nightly-tag-2026-10-15")
    }

    @Test("Stabile Versionen mit und ohne v")
    func stable() {
        #expect(FirmwareVersion(string: "v2.4.0") == .stable(major: 2, minor: 4, patch: 0))
        #expect(FirmwareVersion(string: "2.4.0") == .stable(major: 2, minor: 4, patch: 0))
        #expect(FirmwareVersion(string: "v2.4.0").description == "v2.4.0")
    }

    @Test("Commit-Hashes gelten als eigener Build")
    func custom() {
        #expect(FirmwareVersion(string: "a1b2c3d") == .custom("a1b2c3d"))
    }

    @Test("Nur gleichartige Versionen sind vergleichbar")
    func comparison() {
        let old = FirmwareVersion(string: "n_251101")
        #expect(old.isOlder(than: FirmwareVersion(string: "n_261015")) == true)
        #expect(FirmwareVersion(string: "n_261015").isOlder(than: old) == false)
        #expect(FirmwareVersion(string: "v2.3.2").isOlder(than: FirmwareVersion(string: "v2.4.0")) == true)
        #expect(old.isOlder(than: FirmwareVersion(string: "v2.4.0")) == nil)
    }

    @Test("Nightly-Datum wird korrekt gelesen")
    func nightlyDate() throws {
        let date = try #require(FirmwareVersion(string: "n_261015").nightlyDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 15)
    }
}

@Suite("Release-Katalog")
struct FirmwareCatalogTests {
    private let json = """
    [
      {"tag_name":"nightly-tag-2026-10-15","name":"Nightly","published_at":"2026-10-15T00:35:33Z","prerelease":true,
       "body":"x","html_url":"https://github.com/x/y/releases/tag/nightly-tag-2026-10-15",
       "assets":[
         {"name":"FIRMWARE_mayhem_nightly_n_261015.zip","size":10,"browser_download_url":"https://example.com/a.zip"},
         {"name":"OCI_hackrf_mayhem_nightly_n_261015.ppfw.tar","size":20,"browser_download_url":"https://example.com/h.tar"},
         {"name":"OCI_hpro_mayhem_nightly_n_261015.ppfw.tar","size":30,"browser_download_url":"https://example.com/p.tar"}
       ]},
      {"tag_name":"v2.4.0","name":"Mayhem firmware v2.4.0","published_at":"2026-03-24T09:54:49Z","prerelease":false,
       "body":null,"html_url":"https://github.com/x/y/releases/tag/v2.4.0",
       "assets":[{"name":"mayhem_v2.4.0_OCI.ppfw.tar","size":40,"browser_download_url":"https://example.com/old.tar"}]}
    ]
    """

    @Test("Releases werden gelesen und nach Datum sortiert")
    func parse() throws {
        let releases = try FirmwareCatalog.parse(Data(json.utf8))
        #expect(releases.count == 2)
        #expect(releases[0].version == .nightly(yymmdd: 261015))
        #expect(releases[1].version == .stable(major: 2, minor: 4, patch: 0))
    }

    @Test("Das Paket passt zum Gerätetyp")
    func packageForDevice() throws {
        let nightly = try FirmwareCatalog.parse(Data(json.utf8))[0]
        #expect(nightly.package(for: .hackrf)?.name == "OCI_hackrf_mayhem_nightly_n_261015.ppfw.tar")
        #expect(nightly.package(for: .hpro)?.name == "OCI_hpro_mayhem_nightly_n_261015.ppfw.tar")
        #expect(nightly.package(for: .portarf) == nil)
    }

    @Test("Ältere Releases ohne Gerätetyp im Namen liefern ihr einziges Paket")
    func genericPackage() throws {
        let stable = try FirmwareCatalog.parse(Data(json.utf8))[1]
        #expect(stable.package(for: .hackrf)?.name == "mayhem_v2.4.0_OCI.ppfw.tar")
    }

    @Test("Lange Dateinamen werden gekürzt, die Endung bleibt")
    func shortening() {
        let long = String(repeating: "x", count: 80) + "_n_261015.ppfw.tar"
        let short = FirmwareInstaller.shortened(long)
        #expect(short.count == FirmwareInstaller.maximumFileNameLength)
        #expect(short.hasSuffix("_n_261015.ppfw.tar"))
    }

    @Test("Gerätename passt mit jedem Befehl in eine Shell-Zeile")
    func deviceFileName() {
        let name = FirmwareInstaller.deviceFileName("Meine Firmware " + String(repeating: "x", count: 60) + ".ppfw.tar")
        #expect(!name.contains(" "))
        #expect(name.hasPrefix("x") && name.hasSuffix(".ppfw.tar"))
        for command in ["filesize", "unlink", "fopen", "crc32", "flash"] {
            #expect(MayhemDevice.shellProblem(command: command, path: "/FIRMWARE/" + name) == nil)
        }
        #expect(FirmwareInstaller.deviceFileName("OCI_hackrf_mayhem_nightly_n_261015.ppfw.tar") == "OCI_hackrf_mayhem_nightly_n_261015.ppfw.tar")
    }
}
