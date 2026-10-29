import Foundation
import Testing
@testable import PortaPackManager

@Suite("CRC-32 wie in der Firmware")
struct CRC32Tests {
    @Test("Prüfwert von 123456789 ist der von CRC-32/BZIP2")
    func checkValue() {
        #expect(MayhemCRC32.checksum(Data("123456789".utf8)) == 0xFC89_1918)
    }

    @Test("Leere Daten")
    func empty() {
        #expect(MayhemCRC32.checksum(Data()) == 0)
    }
}

@Suite("Mayhem-Konsole")
struct ShellParsingTests {
    @Test("Echo und Eingabeaufforderung werden entfernt")
    func envelope() {
        let raw = Data("getres\r\n240x320\r\nok\r\nch> ".utf8)
        #expect(MayhemShell.stripEnvelope(raw, command: "getres") == "240x320\r\nok")
    }

    @Test("Reste einer früheren Antwort vor dem Echo werden verworfen")
    func leftovers() {
        let raw = Data("alt\r\nrtcget\r\nCurrent time: 2026-10-20 21:33:56\r\nch> ".utf8)
        #expect(MayhemShell.stripEnvelope(raw, command: "rtcget") == "Current time: 2026-10-20 21:33:56")
    }

    @Test("info wird in Felder zerlegt")
    func info() {
        let text = """
        Kernel:           2.6.8
        Board:            PortaPack Application
        Mayhem Version:   n_251101
        HackRF Board Rev: R9
        Reference Source: External
        Reference Freq:   10.0000 MHz
        Build time:       Nov  1 2025 - 00:14:18
        """
        let info = MayhemInfo.parse(text)
        #expect(info.mayhemVersion == "n_251101")
        #expect(info.hackRFBoardRevision == "R9")
        #expect(info.buildTime == "Nov  1 2025 - 00:14:18")
        #expect(info.deviceType == .hackrf)
        #expect(info.version == .nightly(yymmdd: 251101))
    }

    @Test("Gerätename bestimmt den Pakettyp")
    func deviceType() {
        #expect(DeviceType(deviceName: "HackRF Pro") == .hpro)
        #expect(DeviceType(deviceName: "PortaRF") == .portarf)
        #expect(DeviceType(deviceName: "HackRF One") == .hackrf)
        #expect(DeviceType(deviceName: "") == .hackrf)
    }

    @Test("Hex-Antworten von fread werden dekodiert")
    func hex() {
        #expect(Data(hexString: "00FFa5") == Data([0x00, 0xFF, 0xA5]))
        #expect(Data(hexString: "0") == nil)
        #expect(Data(hexString: "zz") == nil)
    }
}

@Suite("Bildschirmdaten")
struct ScreenFrameTests {
    @Test("Ein Zeichen je Pixel: Wert minus 32 ergibt rrggbb mit zwei Bit je Kanal")
    func decodeShort() throws {
        // 2×2 Pixel: Rot, Grün / Blau, Weiß; je Zeile \r\n.
        let red = UInt8(32 + (3 << 4)), green = UInt8(32 + (3 << 2)), blue = UInt8(32 + 3), white = UInt8(32 + 63)
        let payload = Data([red, green, 13, 10, blue, white, 13, 10])
        let frame = try #require(ScreenFrame.decodeShort(payload, width: 2, height: 2))
        let px = [UInt8](frame.rgba)
        #expect(Array(px[0..<3]) == [255, 0, 0])
        #expect(Array(px[4..<7]) == [0, 255, 0])
        #expect(Array(px[8..<11]) == [0, 0, 255])
        #expect(Array(px[12..<15]) == [255, 255, 255])
    }

    @Test("Zu kurze Daten werden abgelehnt")
    func tooShort() {
        #expect(ScreenFrame.decodeShort(Data([32, 32]), width: 2, height: 2) == nil)
    }
}

@Suite("tar-Leser")
struct TarArchiveTests {
    /// Baut ein minimales ustar-Archiv.
    static func makeTar(_ files: [(String, Data?)]) -> Data {
        var out = Data()
        for (name, content) in files {
            var header = Data(count: 512)
            header.replaceSubrange(0..<name.utf8.count, with: Data(name.utf8))
            let size = String(format: "%011o", content?.count ?? 0) + "\0"
            header.replaceSubrange(124..<136, with: Data(size.utf8))
            header[156] = content == nil ? UInt8(ascii: "5") : UInt8(ascii: "0")
            header.replaceSubrange(257..<263, with: Data("ustar\0".utf8))
            header.replaceSubrange(263..<265, with: Data("00".utf8))
            setChecksum(&header)
            out.append(header)
            if let content {
                out.append(content)
                let pad = (512 - content.count % 512) % 512
                out.append(Data(count: pad))
            }
        }
        out.append(Data(count: 1024))
        return out
    }

    /// Kopf-Prüfsumme wie tar: Summe aller Bytes, Feld selbst als Leerzeichen.
    static func setChecksum(_ header: inout Data) {
        header.replaceSubrange(148..<156, with: Data(repeating: UInt8(ascii: " "), count: 8))
        let sum = header.reduce(0) { $0 + Int($1) }
        header.replaceSubrange(148..<156, with: Data((String(format: "%06o", sum) + "\0 ").utf8))
    }

    @Test("Apps und Firmware-Abbild werden gefunden")
    func entries() throws {
        let tar = Self.makeTar([
            ("APPS/", nil),
            ("APPS/tetris.ppma", Data(repeating: 1, count: 700)),
            ("APPS/doom.ppma", Data(repeating: 2, count: 10)),
            ("FIRMWARE/", nil),
            ("FIRMWARE/portapack-mayhem_n_261015.bin", Data(repeating: 3, count: 1024)),
        ])
        let archive = try TarArchive(data: tar)
        #expect(archive.apps.map(\.name) == ["APPS/tetris.ppma", "APPS/doom.ppma"])
        let image = try #require(archive.firmwareImages.first)
        #expect(image.name == "FIRMWARE/portapack-mayhem_n_261015.bin")
        #expect(try archive.contents(of: image) == Data(repeating: 3, count: 1024))
        #expect(try archive.contents(of: archive.apps[0]) == Data(repeating: 1, count: 700))
    }

    @Test("Kein tar wird abgelehnt")
    func invalid() {
        #expect(throws: TarArchive.TarError.self) { try TarArchive(data: Data(count: 1024)) }
    }
}

@Suite("HackRF")
struct HackRFTests {
    @Test("Basisbandfilter wie libhackrf: größter Wert ≤ Wunsch")
    func filter() {
        #expect(HackRFDevice.basebandFilter(for: 7_500_000) == 7_000_000)
        #expect(HackRFDevice.basebandFilter(for: 15_000_000) == 15_000_000)
        #expect(HackRFDevice.basebandFilter(for: 1_000_000) == 1_750_000)
    }
}

@Suite("Grenzen der Mayhem-Shell")
struct ShellLimitTests {
    @Test("Pfade mit einzelnen Leerzeichen gehen bis sechs Wörter")
    func spaces() {
        #expect(MayhemDevice.shellProblem(command: "filesize", path: "/GPS/position.csv") == nil)
        #expect(MayhemDevice.shellProblem(command: "filesize", path: "/GPS/Mein Track 1.C8") == nil)
        #expect(MayhemDevice.shellProblem(command: "ls", path: "/a b c d e f") == nil)
        #expect(MayhemDevice.shellProblem(command: "ls", path: "/a b c d e f g") != nil)
    }

    @Test("Der Name aus dem Fehlerbild scheitert an der Wortzahl")
    func screenshotCase() {
        let reason = MayhemDevice.shellProblem(command: "filesize", path: "/GPS/How to generate files for the GPS Sim.url")
        #expect(reason?.contains("Leerzeichen") == true)
    }

    @Test("Zeilen über 63 Zeichen und doppelte Leerzeichen werden abgelehnt")
    func lengthAndWhitespace() {
        let path = "/" + String(repeating: "x", count: 63 - "fopen /".count)
        #expect(MayhemDevice.shellProblem(command: "fopen", path: path) == nil)
        #expect(MayhemDevice.shellProblem(command: "fopen", path: path + "x") != nil)
        #expect(MayhemDevice.shellProblem(command: "ls", path: "/a  b") != nil)
        #expect(MayhemDevice.shellProblem(command: "ls", path: "/a\tb") != nil)
        #expect(MayhemDevice.shellProblem(command: "ls", path: "/a /b") != nil)
    }
}
