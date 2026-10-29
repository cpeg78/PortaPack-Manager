import Darwin
import Foundation
import Testing
@testable import PortaPackManager

// Prüfungen rund um das Flashen: alles, was vor dem Löschen des Chips
// greifen muss (Code-Review K15, W1–W4, W9, Y16–Y18).

/// Kleiner tar-Bauer für Grenzfälle (Größe, Typ, Magic, Prüfsumme frei wählbar).
private enum TarBuilder {
    static func header(name: String, size: String, type: Character = "0", gnu: Bool = false, checksum: Bool = true) -> Data {
        var header = Data(count: 512)
        header.replaceSubrange(0..<name.utf8.count, with: Data(name.utf8))
        let sizeField = Data(size.utf8.prefix(11)) + Data([0])
        header.replaceSubrange(124..<124 + sizeField.count, with: sizeField)
        header[156] = type.asciiValue!
        if gnu {
            header.replaceSubrange(257..<265, with: Data("ustar  \0".utf8))
        } else {
            header.replaceSubrange(257..<263, with: Data("ustar\0".utf8))
            header.replaceSubrange(263..<265, with: Data("00".utf8))
        }
        if checksum { TarArchiveTests.setChecksum(&header) }
        return header
    }

    static func entry(_ name: String, _ content: Data, type: Character = "0", gnu: Bool = false) -> Data {
        var out = header(name: name, size: String(format: "%011o", content.count), type: type, gnu: gnu)
        out.append(content)
        out.append(Data(count: (512 - content.count % 512) % 512))
        return out
    }

    static let end = Data(count: 1024)
}

/// Ein Abbild, wie es der LPC43xx erwartet (Werte aus Mayhem n_261027).
private func plausibleImage(size: Int = 1 << 20) -> Data {
    var image = Data(repeating: 0, count: size)
    let words: [UInt32] = [0x2000_0400, 0x0000_807D, 0x0000_814D, 0x0007_C9E5]
    for (index, word) in words.enumerated() {
        withUnsafeBytes(of: word.littleEndian) { image.replaceSubrange(index * 4..<index * 4 + 4, with: $0) }
    }
    return image
}

@Suite("tar-Leser: Grenzfälle")
struct TarEdgeCaseTests {
    @Test("Negative Größe wird abgelehnt, statt zu trappen oder ewig zu laufen")
    func negativeSize() {
        let tar = TarBuilder.header(name: "FIRMWARE/x.bin", size: "-0000001024") + TarBuilder.end
        #expect(throws: TarArchive.TarError.self) { try TarArchive(data: tar) }
        let small = TarBuilder.header(name: "FIRMWARE/x.bin", size: "-1") + TarBuilder.end
        #expect(throws: TarArchive.TarError.self) { try TarArchive(data: small) }
    }

    @Test("Größe über das Archivende hinaus heißt abgeschnitten")
    func oversized() {
        let tar = TarBuilder.header(name: "FIRMWARE/x.bin", size: String(format: "%011o", 1 << 20)) + Data(count: 2048) + TarBuilder.end
        #expect(throws: TarArchive.TarError.truncated) { try TarArchive(data: tar) }
    }

    @Test("Mitten im Inhalt abgeschnittenes Archiv wird erkannt")
    func truncatedContent() {
        let full = TarBuilder.entry("FIRMWARE/x.bin", Data(repeating: 7, count: 4096)) + TarBuilder.end
        #expect(throws: TarArchive.TarError.truncated) { try TarArchive(data: full.prefix(512 + 2000)) }
    }

    @Test("Ohne Endblock (an einer Blockgrenze abgeschnitten) gilt das Archiv als unvollständig")
    func missingEndBlock() throws {
        let entry = TarBuilder.entry("FIRMWARE/x.bin", Data(repeating: 7, count: 1024))
        #expect(throws: TarArchive.TarError.truncated) { try TarArchive(data: entry) }
        #expect(try TarArchive(data: entry + TarBuilder.end).files.count == 1)
    }

    @Test("Falsche Kopf-Prüfsumme und fehlende Magic werden abgelehnt")
    func checksumAndMagic() {
        var broken = TarBuilder.entry("APPS/a.ppma", Data([1, 2, 3]))
        broken[10] ^= 0x01
        #expect(throws: TarArchive.TarError.badChecksum(offset: 0)) { try TarArchive(data: broken + TarBuilder.end) }

        var noMagic = TarBuilder.entry("APPS/a.ppma", Data([1, 2, 3]))
        noMagic.replaceSubrange(257..<265, with: Data(count: 8))
        TarArchiveTests.setChecksum(&noMagic)
        #expect(throws: TarArchive.TarError.invalid) { try TarArchive(data: noMagic + TarBuilder.end) }
    }

    @Test("pax-Kopf liefert den Namen, wird aber selbst nicht zur Datei")
    func paxHeader() throws {
        let path = "FIRMWARE/" + String(repeating: "lang", count: 30) + ".bin"
        let record = " path=\(path)\n"
        // Die Längenangabe zählt ihre eigenen Ziffern mit.
        var length = record.utf8.count + 1
        while String(length).count + record.utf8.count != length { length = String(length).count + record.utf8.count }
        let pax = Data("\(length)\(record)".utf8)
        let tar = TarBuilder.entry("PaxHeaders/x", pax, type: "x")
            + TarBuilder.entry("FIRMWARE/kurz.bin", Data(repeating: 9, count: 600))
            + TarBuilder.end
        let archive = try TarArchive(data: tar)
        #expect(archive.files.map(\.name) == [path])
        #expect(archive.firmwareImages.count == 1)
        #expect(try archive.contents(of: archive.firmwareImages[0]) == Data(repeating: 9, count: 600))
    }

    @Test("GNU-Langname (Typ L) wird auf den folgenden Eintrag angewandt")
    func gnuLongName() throws {
        let path = "APPS/" + String(repeating: "x", count: 120) + ".ppma"
        let tar = TarBuilder.entry("././@LongLink", Data((path + "\0").utf8), type: "L", gnu: true)
            + TarBuilder.entry(String(path.prefix(99)), Data([1, 2, 3]), gnu: true)
            + TarBuilder.end
        let archive = try TarArchive(data: tar)
        #expect(archive.apps.map(\.name) == [path])
    }

    @Test("Links und Geräte gelten nicht als Dateien")
    func nonFileTypes() throws {
        let tar = TarBuilder.entry("FIRMWARE/link.bin", Data(), type: "2")
            + TarBuilder.entry("FIRMWARE/echt.bin", Data(repeating: 1, count: 10))
            + TarBuilder.end
        let archive = try TarArchive(data: tar)
        #expect(archive.firmwareImages.map(\.name) == ["FIRMWARE/echt.bin"])
    }

    @Test("App-Namen mit „..“ als letztem Teil fallen weg")
    func dotDotApp() throws {
        let tar = TarBuilder.entry("APPS/..", Data([1])) + TarBuilder.entry("APPS/ok.ppma", Data([2])) + TarBuilder.end
        #expect(try TarArchive(data: tar).apps.map(\.name) == ["APPS/ok.ppma"])
    }

    @Test("Ein Data-Ausschnitt mit verschobenen Indizes wird richtig gelesen")
    func sliceInput() throws {
        let tar = TarBuilder.entry("FIRMWARE/x.bin", Data(repeating: 5, count: 700)) + TarBuilder.end
        let padded = Data(repeating: 0xAA, count: 37) + tar
        let archive = try TarArchive(data: padded[37...])
        #expect(try archive.contents(of: archive.firmwareImages[0]) == Data(repeating: 5, count: 700))
    }

    @Test("Echte Werkzeuge: bsdtar im GNU- und pax-Format mit langen Namen")
    func realTar() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tar-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let long = String(repeating: "abcdefghij", count: 12) + ".ppma"
        try fm.createDirectory(at: root.appendingPathComponent("APPS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("FIRMWARE"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("APPS/\(long)"))
        try plausibleImage(size: 300_000).write(to: root.appendingPathComponent("FIRMWARE/fw.bin"))
        for format in ["gnutar", "pax", "ustar"] {
            let out = root.appendingPathComponent("\(format).tar")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.currentDirectoryURL = root
            process.environment = ["COPYFILE_DISABLE": "1"]
            // ustar kann den 125-Zeichen-Namen nicht – dort nur die Firmware.
            process.arguments = ["--format", format, "-cf", out.path] + (format == "ustar" ? ["FIRMWARE"] : ["APPS", "FIRMWARE"])
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let archive = try TarArchive(data: Data(contentsOf: out))
            if format != "ustar" { #expect(archive.apps.map(\.name) == ["APPS/\(long)"], "\(format)") }
            let image = try #require(archive.firmwareImages.first)
            #expect(try archive.contents(of: image) == plausibleImage(size: 300_000), "\(format)")
        }
    }

    @Test("Oktalfelder nehmen kein Vorzeichen an")
    func octal() {
        #expect(TarArchive.octal(Data("-17".utf8) + Data(count: 9), at: 0, length: 12) == nil)
        #expect(TarArchive.octal(Data("0000017 ".utf8) + Data(count: 4), at: 0, length: 12) == 15)
        #expect(TarArchive.octal(Data(count: 12), at: 0, length: 12) == 0)
    }
}

@Suite("Firmware-Abbild: Plausibilität vor dem Löschen")
struct FirmwareImageTests {
    @Test("Abbild wie Mayhem n_261027 ist plausibel")
    func plausible() throws {
        try FirmwareImage.validate(plausibleImage(), capacity: 0x10_0000)
        try FirmwareImage.validate(plausibleImage(size: 0x40_0000), capacity: 0x40_0000)
    }

    @Test("Zu klein (abgeschnitten) und zu groß für den Flash")
    func size() {
        #expect(throws: FirmwareImage.ImageError.tooSmall(0)) { try FirmwareImage.validate(Data()) }
        #expect(throws: FirmwareImage.ImageError.tooSmall(100_000)) { try FirmwareImage.validate(plausibleImage(size: 100_000)) }
        #expect(throws: FirmwareImage.ImageError.tooLarge(size: 0x40_0000, capacity: 0x10_0000)) {
            try FirmwareImage.validate(plausibleImage(size: 0x40_0000), capacity: 0x10_0000)
        }
    }

    @Test("Gelöschter Flash, Text und falsche Vektoren werden abgelehnt")
    func vectors() {
        #expect(throws: FirmwareImage.ImageError.self) { try FirmwareImage.validate(Data(repeating: 0xFF, count: 1 << 20)) }
        #expect(throws: FirmwareImage.ImageError.self) { try FirmwareImage.validate(Data(repeating: 0, count: 1 << 20)) }
        #expect(throws: FirmwareImage.ImageError.self) {
            try FirmwareImage.validate(Data(String(repeating: "path=FIRMWARE/x.bin\n", count: 20_000).utf8))
        }
        var evenReset = plausibleImage()
        evenReset[4] = 0x7C
        #expect(throws: FirmwareImage.ImageError.self) { try FirmwareImage.validate(evenReset) }
        var stackInFlash = plausibleImage()
        stackInFlash.replaceSubrange(0..<4, with: [0x00, 0x10, 0x00, 0x14])
        #expect(throws: FirmwareImage.ImageError.self) { try FirmwareImage.validate(stackInFlash) }
    }

    @Test("Paketprüfung: Abbild aus dem tar, abgeschnittenes Paket scheitert vor jeder Gerätaktion")
    func package() throws {
        let tar = TarBuilder.entry("APPS/a.ppma", Data([1, 2]))
            + TarBuilder.entry("FIRMWARE/fw.bin", plausibleImage())
            + TarBuilder.end
        let image = try FirmwareInstaller.validatePackage(tar, fileName: "OCI_hackrf_x.ppfw.tar", capacity: 0x10_0000)
        #expect(image == plausibleImage())
        #expect(throws: TarArchive.TarError.truncated) {
            try FirmwareInstaller.validatePackage(tar.prefix(600_000), fileName: "OCI_hackrf_x.ppfw.tar", capacity: nil)
        }
        let tinyImage = TarBuilder.entry("FIRMWARE/fw.bin", Data()) + TarBuilder.end
        #expect(throws: FirmwareImage.ImageError.tooSmall(0)) {
            try FirmwareInstaller.validatePackage(tinyImage, fileName: "x.ppfw.tar", capacity: nil)
        }
        #expect(throws: FirmwareImage.ImageError.self) {
            try FirmwareInstaller.validatePackage(plausibleImage(size: 0x40_0000), fileName: "pro.bin", capacity: DeviceType.hackrf.flashCapacity)
        }
    }

    @Test("Flash-Größe je Board: HackRF One 1 MiB, Pro 4 MiB, Unbekanntes vorsichtig 1 MiB")
    func capacity() {
        #expect(HackRFDevice.flashCapacity(boardID: 2) == 0x10_0000)
        #expect(HackRFDevice.flashCapacity(boardID: 4) == 0x10_0000)
        #expect(HackRFDevice.flashCapacity(boardID: 5) == 0x40_0000)
        #expect(HackRFDevice.flashCapacity(boardID: 99) == 0x10_0000)
        #expect(DeviceType.hackrf.flashCapacity == 0x10_0000)
    }
}

@Suite("Release-Auswahl und Downloads")
struct FirmwareCatalogSafetyTests {
    private static func asset(_ name: String) -> FirmwareAsset {
        FirmwareAsset(name: name, size: 1, downloadURL: URL(string: "https://example.invalid/\(name)")!)
    }

    private static func release(_ names: [String]) -> FirmwareRelease {
        FirmwareRelease(tag: "v2.0.0", title: "", publishedAt: Date(), isPrerelease: false, notes: "",
                        htmlURL: URL(string: "https://example.invalid")!, assets: names.map(asset))
    }

    @Test("Typloses Paket nur für HackRF One, nie für Pro oder PortaRF")
    func untypedFallback() {
        let old = Self.release(["portapack-h1_h2-mayhem.ppfw.tar", "COPY_TO_SDCARD-no-world-map.zip"])
        #expect(old.package(for: .hackrf)?.name == "portapack-h1_h2-mayhem.ppfw.tar")
        #expect(old.package(for: .hpro) == nil)
        #expect(old.package(for: .portarf) == nil)
        #expect(old.sdCardPackage(for: .hackrf, withWorldMap: false) != nil)
        #expect(old.sdCardPackage(for: .hpro, withWorldMap: false) == nil)

        let new = Self.release(["OCI_hackrf_mayhem_n_1.ppfw.tar", "OCI_hpro_mayhem_n_1.ppfw.tar"])
        #expect(new.package(for: .hpro)?.name == "OCI_hpro_mayhem_n_1.ppfw.tar")
        #expect(new.package(for: .hackrf)?.name == "OCI_hackrf_mayhem_n_1.ppfw.tar")
        #expect(new.package(for: .portarf) == nil)
    }

    @Test("Asset-Namen aus dem Netz werden nur als einfacher Dateiname übernommen")
    func safeNames() {
        #expect(FirmwareAsset.safeFileName("OCI_hackrf.ppfw.tar") == "OCI_hackrf.ppfw.tar")
        #expect(FirmwareAsset.safeFileName("../../evil.tar") == "evil.tar")
        #expect(FirmwareAsset.safeFileName("..") == nil)
        #expect(FirmwareAsset.safeFileName(".hidden") == nil)
        #expect(FirmwareAsset.safeFileName("") == nil)
    }

    @Test("GitHub-API: digest wird übernommen, unsichere Namen fallen weg")
    func parse() throws {
        let json = """
        [{"tag_name":"v2.1.0","name":"x","published_at":"2026-10-01T00:00:00Z","prerelease":false,"body":"",
          "html_url":"https://github.com/x","assets":[
            {"name":"OCI_hackrf_a.ppfw.tar","size":10,"browser_download_url":"https://x/a",
             "digest":"sha256:3ecdfa68b24d8b9feb6690f8f2fcf3f90a491cedcd1f6061fb7395d5eb540863"},
            {"name":"..","size":1,"browser_download_url":"https://x/b"},
            {"name":"alt.zip","size":5,"browser_download_url":"https://x/c"}]}]
        """
        let releases = try FirmwareCatalog.parse(Data(json.utf8))
        let assets = try #require(releases.first?.assets)
        #expect(assets.map(\.name) == ["OCI_hackrf_a.ppfw.tar", "alt.zip"])
        #expect(assets[0].sha256 == "3ecdfa68b24d8b9feb6690f8f2fcf3f90a491cedcd1f6061fb7395d5eb540863")
        #expect(assets[1].sha256 == nil)
    }

    @Test("SHA-256 einer Datei (stückweise gelesen)")
    func sha256() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try FirmwareDownloader.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite("Erneuern nachholen")
struct PendingRenewalTests {
    private func info(version: String, device: String = "") -> MayhemInfo {
        var info = MayhemInfo()
        info.mayhemVersion = version
        info.deviceName = device
        return info
    }

    @Test("Alte gespeicherte Einträge ohne Prüfsumme lassen sich weiter lesen")
    func backwardCompatible() throws {
        let old = Data(#"{"imagePath":"/FIRMWARE/x.bin","version":"n_261015"}"#.utf8)
        let pending = try JSONDecoder().decode(PendingRenewal.self, from: old)
        #expect(pending.imageCRC == nil && pending.imageSize == nil && pending.tag == nil)
        #expect(pending.expectedVersion == .nightly(yymmdd: 261015))
    }

    @Test("Neue Felder überstehen das Speichern")
    func roundTrip() throws {
        let pending = PendingRenewal(imagePath: "/FIRMWARE/x.bin", version: "n_261027", imageSize: 1 << 20,
                                     imageCRC: 0xDEAD_BEEF, tag: "nightly-tag-2026-10-27", deviceType: "hackrf", createdAt: nil)
        let decoded = try JSONDecoder().decode(PendingRenewal.self, from: JSONEncoder().encode(pending))
        #expect(decoded == pending)
        #expect(decoded.expectedVersion == .nightly(yymmdd: 261027))
    }

    @Test("Kein Nachholen auf falschem Gerätetyp, bei gleicher oder neuerer Version")
    func conflicts() {
        let pending = PendingRenewal(imagePath: "/FIRMWARE/x.bin", version: "n_261020", tag: "nightly-tag-2026-10-20", deviceType: "hackrf")
        #expect(pending.conflict(with: info(version: "n_261015")) == nil)
        #expect(pending.conflict(with: info(version: "n_261015", device: "HackRF One")) == nil)
        #expect(pending.conflict(with: info(version: "n_261015", device: "HackRF Pro")) != nil)
        #expect(pending.conflict(with: info(version: "n_261020")) != nil)
        #expect(pending.conflict(with: info(version: "n_261027")) != nil)
        #expect(pending.conflict(with: nil) == nil)
    }

    @Test("Gerätetyp gilt nur, wenn das Gerät ihn meldet")
    func reportedType() {
        #expect(info(version: "n_1").reportedDeviceType == nil)
        #expect(info(version: "n_1", device: "HackRF One").reportedDeviceType == .hackrf)
        #expect(info(version: "n_1", device: "HackRF Pro").reportedDeviceType == .hpro)
    }
}

@Suite("SD-Paket: Platz und Inhaltsverzeichnis")
struct SDCardSafetyTests {
    @Test("Zusatzbedarf: neue Dateien ganz, überschriebene nur der Zuwachs, gelöschte Apps abgezogen")
    func additionalBytes() {
        let plan: [(relative: String, size: Int64)] = [("APPS/a.ppma", 100), ("FIRMWARE/x.bin", 1000), ("ADSB/world.bin", 5000)]
        let existing: [String: Int64] = ["FIRMWARE/x.bin": 900, "ADSB/world.bin": 6000]
        let needed = SDCardPackage.additionalBytes(plan: plan, existingSize: { existing[$0] }, freedByRemoval: 50)
        #expect(needed == 100 + 100 + 0 - 50)
    }

    @Test("ZIP-Inhaltsverzeichnis: Größen und unsichere Pfade")
    func zipListing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let content = root.appendingPathComponent("inhalt")
        try fm.createDirectory(at: content.appendingPathComponent("APPS"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 12_345).write(to: content.appendingPathComponent("APPS/a.ppma"))
        try Data(repeating: 2, count: 100).write(to: content.appendingPathComponent("b.txt"))
        let zip = root.appendingPathComponent("paket.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", content.path, zip.path]
        try process.run()
        process.waitUntilExit()
        let listing = try ZipDirectory.read(zip)
        #expect(listing.uncompressedSize == 12_345 + 100)
        #expect(listing.entries.allSatisfy { $0.isSafe })

        #expect(!ZipDirectory.Entry(name: "../x", uncompressedSize: 0, isSymlink: false).isSafe)
        #expect(!ZipDirectory.Entry(name: "a/../../x", uncompressedSize: 0, isSymlink: false).isSafe)
        #expect(!ZipDirectory.Entry(name: "/etc/x", uncompressedSize: 0, isSymlink: false).isSafe)
        #expect(!ZipDirectory.Entry(name: "link", uncompressedSize: 0, isSymlink: true).isSafe)
        #expect(ZipDirectory.Entry(name: "APPS/..x.ppma", uncompressedSize: 0, isSymlink: false).isSafe)
    }

    @Test("Kein ZIP wird abgelehnt")
    func notZip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nozip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x41, count: 1000).write(to: url)
        #expect(throws: ZipDirectory.ZipError.self) { try ZipDirectory.read(url) }
    }
}

@Suite("Serielle Konsole")
struct SerialSafetyTests {
    @Test("Nur Mayhem-Konsolen (1d50:6018) bekommen Befehle")
    func mayhemFilter() {
        let devices = [
            SerialDevice(path: "/dev/cu.a", vendorID: 0x1D50, productID: 0x6018, productName: "PortaPack", serialNumber: ""),
            SerialDevice(path: "/dev/cu.b", vendorID: 0x1D50, productID: 0x60E6, productName: "GreatFET", serialNumber: ""),
            SerialDevice(path: "/dev/cu.c", vendorID: 0x0403, productID: 0x6018, productName: "Fremd", serialNumber: ""),
        ]
        #expect(SerialDeviceFinder.isMayhemConsole(devices).map(\.path) == ["/dev/cu.a"])
    }

    /// Pty-Paar: SerialPort auf der Nebenseite, der Test spielt das Gerät.
    private func makePty() throws -> (master: Int32, port: SerialPort) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        try #require(grantpt(master) == 0 && unlockpt(master) == 0)
        let name = String(cString: ptsname(master))
        let port = SerialPort(path: name)
        try port.open()
        return (master, port)
    }

    @Test("Pixeldaten direkt hinter dem Echo gehen nicht verloren (dauerhafter Empfangspuffer)")
    func fixedLengthKeepsOverhang() throws {
        let (master, port) = try makePty()
        defer { Darwin.close(master) }
        let shell = MayhemShell(port: port)
        defer { shell.close() }
        // Echo, Nutzdaten und Abschluss kommen in einem Stück – früher warf
        // readUntil alles hinter dem Echo weg.
        let payload = Data((0..<300).map { UInt8(32 + $0 % 64) })
        let response = Data("screenframeshort\r\n".utf8) + payload + Data("ok\r\nch> ".utf8)
        _ = response.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        let received = try shell.runFixedLength("screenframeshort", byteCount: payload.count, trailer: "ok\r\nch> ", timeout: 2)
        #expect(received == payload)
    }

    @Test("Was hinter der Eingabeaufforderung kommt, gehört zur nächsten Antwort")
    func overhangToNextCommand() throws {
        let (master, port) = try makePty()
        defer { Darwin.close(master) }
        let shell = MayhemShell(port: port)
        defer { shell.close() }
        let both = Data("info\r\nA: 1\r\nch> rtcget\r\nCurrent time: 1\r\nch> ".utf8)
        _ = both.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        #expect(try shell.run("info", timeout: 2) == "A: 1")
        #expect(try shell.run("rtcget", timeout: 2) == "Current time: 1")
    }

    @Test("abort() bricht ein laufendes Warten ab")
    func abort() throws {
        let (master, port) = try makePty()
        defer { Darwin.close(master) }
        let shell = MayhemShell(port: port)
        defer { shell.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { shell.abort() }
        let start = Date()
        #expect(throws: SerialPortError.self) { try shell.run("info", timeout: 10) }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("Blockierender Aufruf mit Zeitlimit")
    func blockingCall() async throws {
        let value = try await BlockingCall.run("schnell", timeout: 2) { 42 }
        #expect(value == 42)
        await #expect(throws: BlockingCall.TimedOut.self) {
            _ = try await BlockingCall.run("langsam", timeout: 0.2) { Thread.sleep(forTimeInterval: 1.5); return 1 }
        }
    }
}
