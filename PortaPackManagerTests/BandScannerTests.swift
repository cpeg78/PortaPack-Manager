import Accelerate
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

    @Test("Gemeinsame FFT-Stufe rechnet bitgleich wie die frühere Schleife (Fenster je Wert, FFT, Betragsquadrat)")
    func sharedPowerStageIsIdentical() {
        let n = 1024
        let fft = HannPowerFFT(size: n)
        var state: UInt64 = 3
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(Int8(truncatingIfNeeded: state >> 56)) - 0.37) / 128
        }
        let inRe = (0..<n).map { _ in next() }, inIm = (0..<n).map { _ in next() }
        // Früherer Weg (Spektrum/Suchlauf): Fenster in der Einleseschleife.
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var oldRe = (0..<n).map { inRe[$0] * window[$0] }, oldIm = (0..<n).map { inIm[$0] * window[$0] }
        var oldPower = [Float](repeating: 0, count: n)
        let log2n = vDSP_Length(10)
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        oldRe.withUnsafeMutableBufferPointer { r in
            oldIm.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &oldPower, 1, vDSP_Length(n))
            }
        }
        var re = inRe, im = inIm, power = [Float](repeating: 0, count: n)
        fft.power(&re, &im, into: &power)
        #expect(power == oldPower)
        #expect(fft.window == window)
    }
}
