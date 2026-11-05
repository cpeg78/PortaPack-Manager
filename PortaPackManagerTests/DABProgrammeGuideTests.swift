import Foundation
import Testing
@testable import PortaPackManager

@Suite("DAB: Programmführer (SPI)")
struct DABProgrammeGuideTests {
    // MARK: - Kodierhilfen (wie TS 102 371 bzw. EN 300 401)

    private func element(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        precondition(content.count < 254)
        return [tag, UInt8(content.count)] + content
    }

    private func text(_ tag: UInt8, _ string: String) -> [UInt8] {
        element(tag, element(0x01, Array(string.utf8)))
    }

    /// Kurzform: MJD · Stunde · Minute (UTC).
    private func time(mjd: Int, hour: Int, minute: Int) -> [UInt8] {
        let w = UInt32(mjd) << 14 | UInt32(hour) << 6 | UInt32(minute)
        return [UInt8(w >> 24), UInt8(w >> 16 & 0xFF), UInt8(w >> 8 & 0xFF), UInt8(w & 0xFF)]
    }

    /// ContentId mit Ensemble (ECC E0, EId 10C3) und 16-Bit-SId.
    private func contentID(sid: UInt16) -> [UInt8] {
        [0x40, 0xE0, 0x10, 0xC3, UInt8(sid >> 8), UInt8(sid & 0xFF)]
    }

    private func programme(_ name: String, detail: String, hour: Int, minutes: Int, sid: UInt16) -> [UInt8] {
        element(0x1C, text(0x11, name)
                + element(0x13, text(0x1A, detail))
                + element(0x19, element(0x2C, element(0x80, time(mjd: 61348, hour: hour, minute: 0))
                                                + element(0x81, [UInt8((minutes * 60) >> 8), UInt8((minutes * 60) & 0xFF)]))
                                 + element(0x2D, element(0x80, contentID(sid: sid)))))
    }

    private var epgFile: [UInt8] {
        element(0x02, element(0x21, programme("Morgenmagazin", detail: "Nachrichten und Musik", hour: 19, minutes: 60, sid: 0xD312)
                                     + programme("Abendkonzert", detail: "Live aus dem Funkhaus", hour: 20, minutes: 120, sid: 0xD312)))
    }

    private func dataGroup(type: Int, segment: Int = 0, last: Bool = true, transportID: Int, data: [UInt8]) -> [UInt8] {
        var g: [UInt8] = [0x70 | UInt8(type), 0x00,
                          (last ? 0x80 : 0) | UInt8(segment >> 8), UInt8(segment & 0xFF),
                          0x12, UInt8(transportID >> 8), UInt8(transportID & 0xFF),
                          UInt8(data.count >> 8), UInt8(data.count & 0xFF)] + data
        let crc = DABCRC.ccitt(g)
        g += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        return g
    }

    /// MOT-Kopf mit Inhaltstyp 7 (SPI), Untertyp 1, ohne Parameter.
    private func motHeader(bodySize: Int) -> [UInt8] {
        let bits = UInt64(bodySize) << 28 | UInt64(7) << 15 | UInt64(7) << 9 | 1
        return (0..<7).map { UInt8(truncatingIfNeeded: bits >> (8 * (6 - $0))) }
    }

    private func directory(transportID: Int, bodySize: Int) -> [UInt8] {
        let entry = [UInt8(transportID >> 8), UInt8(transportID & 0xFF)] + motHeader(bodySize: bodySize)
        let size = 13 + entry.count
        return [0, 0, UInt8(size >> 8), UInt8(size & 0xFF), 0x00, 0x01, 0, 0, 0, 0x00, 0x00, 0x00, 0x00] + entry
    }

    /// Datengruppe in Pakete zu 24 Byte (19 Nutzbytes) an Adresse `address`.
    private func packets(_ group: [UInt8], address: Int) -> [UInt8] {
        let chunks = stride(from: 0, to: group.count, by: 19).map { Array(group[$0..<min($0 + 19, group.count)]) }
        var out: [UInt8] = []
        for (n, chunk) in chunks.enumerated() {
            var b0 = UInt8((n & 3) << 4) | UInt8(address >> 8 & 0x03)
            if n == 0 { b0 |= 0x08 }
            if n == chunks.count - 1 { b0 |= 0x04 }
            var packet = [b0, UInt8(address & 0xFF), UInt8(chunk.count)] + chunk
            packet += [UInt8](repeating: 0, count: 22 - packet.count)
            let crc = DABCRC.ccitt(packet)
            out += packet + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        }
        return out
    }

    // MARK: - Tests

    @Test("SPI-Binärformat: Sendungen mit Name, Beschreibung, Zeit, Dauer und Dienst")
    func spiProgrammes() throws {
        let root = try #require(SPIBinary.parse(epgFile))
        let items = SPIBinary.programmes(root)
        #expect(items.count == 2)
        let first = try #require(items.first)
        #expect(first.name == "Morgenmagazin")
        #expect(first.detail == "Nachrichten und Musik")
        #expect(first.serviceID == 0xD312)
        #expect(first.start == Date(timeIntervalSince1970: TimeInterval((61348 - 40587) * 86400 + 19 * 3600)))
        #expect(first.duration == 3600)
        #expect(items[1].duration == 7200)
        // Abgeschnitten oder mit falscher Länge: nichts, kein Absturz.
        #expect(SPIBinary.parse(Array(epgFile.dropLast())) == nil)
        #expect(SPIBinary.parse([0x02, 0xFF, 0xFF]) == nil)
    }

    @Test("SPI: Token-Tabelle ersetzt Steuerzeichen im Namen")
    func spiTokens() throws {
        var tokens: [UInt8] = [0x01, 4] + Array("Nach".utf8)
        tokens += [0x02, 6] + Array("richten".utf8).prefix(6)
        let name = element(0x11, element(0x01, [0x01, 0x02, 0x6E]))   // „Nach“ + „richte“ + „n“
        let prog = element(0x1C, name + element(0x19, element(0x2C, element(0x80, time(mjd: 61348, hour: 8, minute: 30))
                                                                         + element(0x81, [0x07, 0x08]))
                                                          + element(0x2D, element(0x80, contentID(sid: 0xD312)))))
        let file = element(0x02, element(0x04, tokens) + element(0x21, prog))
        let items = SPIBinary.programmes(try #require(SPIBinary.parse(file)))
        #expect(items.first?.name == "Nachrichten")
        #expect(items.first?.duration == 1800)
    }

    @Test("Paketmodus und MOT-Verzeichnis: Pakete → Datengruppen → Datei → Sendungen")
    func carouselToProgrammes() throws {
        var guide = DABProgrammeGuide()
        guide.reset(address: 0x123)
        let body = epgFile
        // Fremde Adresse und Füllpakete stören nicht; Rahmen zu 48 Byte (16 kbit/s).
        var stream = packets(dataGroup(type: 6, transportID: 0x0100, data: directory(transportID: 0x4711, bodySize: body.count)), address: 0x123)
        stream += packets(dataGroup(type: 4, transportID: 0x0999, data: [1, 2, 3]), address: 0x200)
        stream += packets(dataGroup(type: 4, transportID: 0x4711, data: body), address: 0x123)
        stream += [UInt8](repeating: 0, count: (48 - stream.count % 48) % 48)
        // Feste Zeit: der Führer verwirft Sendungen, die > 6 h vorbei sind (Zeitfalle 05.11.2026).
        let now = Date(timeIntervalSince1970: TimeInterval((61348 - 40587) * 86400 + 19 * 3600 + 1800))
        for start in stride(from: 0, to: stream.count, by: 48) {
            guide.process(Array(stream[start..<(start + 48)]), now: now)
        }
        let upcoming = guide.upcoming(for: 0xD312, now: now)
        #expect(upcoming.map(\.name) == ["Morgenmagazin", "Abendkonzert"])
    }

    @Test("MOT-Karussell: zweiter Umlauf liefert nichts erneut, Rumpf vor Verzeichnis kommt sofort, Grenzen greifen")
    func carouselRounds() throws {
        var carousel = DABMOTCarousel()
        let body: [UInt8] = epgFile
        let dir = try #require(DABDataGroup(dataGroup(type: 6, transportID: 0x0100, data: directory(transportID: 0x4711, bodySize: body.count))))
        let obj = try #require(DABDataGroup(dataGroup(type: 4, transportID: 0x4711, data: body)))
        // Rumpf zuerst: wird mit dem Verzeichnis sofort geliefert (Review 05.11.2026).
        #expect(carousel.add(obj).isEmpty)
        #expect(carousel.add(dir).count == 1)
        // Zweiter Umlauf mit demselben Verzeichnis und Rumpf: nichts erneut.
        #expect(carousel.add(dir).isEmpty)
        #expect(carousel.add(obj).isEmpty)
        // Unplausible Segmentnummer und zu große Rümpfe werden verworfen.
        let far = try #require(DABDataGroup(dataGroup(type: 4, segment: 2000, last: false, transportID: 0x4711, data: [1])))
        #expect(carousel.add(far).isEmpty)
        var big = DABMOTCarousel()
        _ = big.add(dir)
        for n in 0..<70 {
            let chunk = try #require(DABDataGroup(dataGroup(type: 4, segment: n, last: false, transportID: 0x4711, data: [UInt8](repeating: 0, count: 8000))))
            #expect(big.add(chunk).isEmpty)
        }
        let end = try #require(DABDataGroup(dataGroup(type: 4, segment: 70, last: true, transportID: 0x4711, data: [0])))
        #expect(big.add(end).isEmpty)
    }

    @Test("SPI: defaultContentId gilt für Sendungen ohne eigenen Dienst; Kommandopakete stören nicht")
    func defaultContentAndCommandPackets() throws {
        // Sendung ohne bearer, Dienst über 0x05 am Wurzelelement.
        let noBearer = element(0x1C, text(0x11, "Ohne Träger")
                               + element(0x19, element(0x2C, element(0x80, time(mjd: 61348, hour: 9, minute: 0)) + element(0x81, [0x0E, 0x10]))))
        let file = element(0x02, element(0x05, contentID(sid: 0xD313)) + element(0x21, noBearer))
        let items = SPIBinary.programmes(try #require(SPIBinary.parse(file)))
        #expect(items.first?.serviceID == 0xD313 && items.first?.name == "Ohne Träger")
        // Ein Kommandopaket (Command-Bit) zwischen den Datenpaketen derselben Adresse.
        var assembler = DABPacketAssembler(address: 5)
        var stream = packets(dataGroup(type: 4, transportID: 1, data: [UInt8](repeating: 9, count: 30)), address: 5)
        var command: [UInt8] = [0x08 | 0x00, 5, 0x80 | 3, 1, 2, 3]
        command += [UInt8](repeating: 0, count: 22 - command.count)
        let crc = DABCRC.ccitt(command)
        command += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        stream.insert(contentsOf: command, at: 24)
        stream += [UInt8](repeating: 0, count: (24 - stream.count % 24) % 24)
        #expect(assembler.process(stream).count == 1)
    }

    @Test("Paketmodus: falsche Prüfsumme verwirft die angefangene Datengruppe")
    func packetCRC() {
        var assembler = DABPacketAssembler(address: 5)
        var stream = packets(dataGroup(type: 4, transportID: 1, data: [UInt8](repeating: 7, count: 40)), address: 5)
        stream[30] ^= 0xFF
        stream += [UInt8](repeating: 0, count: (24 - stream.count % 24) % 24)
        #expect(assembler.process(stream).isEmpty)
        #expect(assembler.crcErrors == 1)
    }

    @Test("FIC: FIG 0/2 (Paketdaten), 0/3 und 0/13 (SPI) ergeben die Programmführer-Komponente")
    func ficComponent() throws {
        var ensemble = DABEnsemble()
        func fig0(_ ext: UInt8, _ payload: [UInt8]) -> ArraySlice<UInt8> {
            let body = [ext] + payload
            return ([UInt8(body.count)] + body + [0xFF])[...]
        }
        // Unterkanal 9, EEP 3-A, 12 CU an CU 300.
        ensemble.process(fib: fig0(1, [9 << 2 | 0x01, 0x2C, 0x80 | 0x08, 12]))
        // Dienst E1C0 mit Paketkomponente SCId 0x055 (TMId 3).
        ensemble.process(fib: fig0(2, [0xE1, 0xC0, 0x01, 0xC0 | 0x01, 0x55 << 2 & 0xFC | 0x02]))
        // FIG 0/3: SCId 055, DG 0, DSCTy 60, SubCh 9, Adresse 0x3E8.
        ensemble.process(fib: fig0(3, [0x05, 0x50, 60, 9 << 2 | 0x03, 0xE8]))
        // FIG 0/13: SId E1C0, eine Anwendung Typ 7 (SPI) ohne Daten.
        ensemble.process(fib: fig0(13, [0xE1, 0xC0, 0x01, 0x00, 7 << 5]))
        let component = try #require(ensemble.programmeGuideComponent)
        #expect(component.subchannelID == 9)
        #expect(component.address == 0x3E8)
        #expect(component.serviceType == 60)
        #expect(ensemble.spiServices == [0xE1C0])
    }
}
