import Foundation
import Testing
@testable import PortaPackManager

@Suite("Bandsuchlauf")
struct BandScannerTests {
    @Test("Jeder Kanal liegt in einem Fenster außerhalb der DC-Lücke", arguments: ScanBands.all)
    func coverage(band: ScanBand) {
        let centers = BandScanner.windowCenters(for: band)
        for channel in band.channels {
            let covered = centers.contains { abs(channel - $0) <= BandScanner.usableHalfSpanMHz && abs(channel - $0) >= BandScanner.dcHoleMHz }
            #expect(covered, "\(band.name): \(channel) MHz nicht abgedeckt")
        }
    }

    @Test("UKW braucht nur vier Fenster, Flugfunk vier")
    func windowCount() {
        #expect(BandScanner.windowCenters(for: ScanBands.fm).count <= 4)
        #expect(BandScanner.windowCenters(for: ScanBands.all[1]).count <= 4)
    }

    @Test("Kanäle über dem Rauschboden werden gefunden, Nachbarn zusammengefasst")
    func pick() {
        var levels: [Double: Float] = [:]
        for channel in ScanBands.fm.channels { levels[channel] = -60 }
        levels[99.2] = -30; levels[99.3] = -40   // ein Sender, Nebenkanal schwächer
        levels[103.6] = -35
        let found = BandScanner.pickStations(levels, band: ScanBands.fm)
        #expect(found.map(\.mhz) == [99.2, 103.6])
        #expect(abs(found[0].levelDB - 30) < 0.01)
    }

    @Test("Flugfunk: drei Nachbarn im 8,33-kHz-Raster ergeben einen Treffer")
    func airbandMerge() {
        let band = ScanBands.all[1]
        var levels: [Double: Float] = [:]
        for channel in band.channels { levels[channel] = -70 }
        let ch = band.channels
        levels[ch[182]] = -50; levels[ch[183]] = -52; levels[ch[184]] = -55
        #expect(BandScanner.pickStations(levels, band: band).count == 1)
    }

    @Test("Ziffernwert: Flugfunk-Raster 8,33 kHz ergibt 2.280 Kanäle")
    func airbandChannels() {
        #expect(ScanBands.all[1].channels.count == 2280)
    }

    @Test("Favoriten: alte Frequenzliste bekommt Betriebsart und Funkart, JSON bleibt erhalten")
    func favorites() {
        let old = RadioFavorite.decode("98.1,123.45")
        #expect(old.count == 2)
        #expect(old[0].mode == .wfm && old[0].kind == "UKW-Rundfunk")
        #expect(old[1].mode == .am && old[1].kind == "Flugfunk")
        let saved = [RadioFavorite(mhz: 446.00625, mode: .nfm, stepKHz: 6.25, kind: "PMR446")]
        #expect(RadioFavorite.decode(RadioFavorite.encode(saved)) == saved)
    }
}
