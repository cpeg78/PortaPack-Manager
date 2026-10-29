import Foundation
import Testing
@testable import PortaPackManager

@Suite("Verstärkungsvorgaben und Übersteuerung")
struct GainProfileTests {
    @Test("Mit externem Verstärker ist der interne Vorverstärker überall aus")
    func externalDisablesAmplifier() {
        for receiver in GainProfile.Receiver.allCases {
            #expect(!GainProfile.preset(receiver, externalAmplifier: true).amplifier, "\(receiver)")
        }
    }

    /// Der interne Vorverstärker bringt ≈ 14 dB; bei ADS-B ersetzt LNA 40 ihn.
    @Test("Mit externem Verstärker nie mehr Gesamtverstärkung als ohne")
    func externalNeverHigher() {
        for receiver in GainProfile.Receiver.allCases {
            let alone = GainProfile.preset(receiver, externalAmplifier: false)
            let with = GainProfile.preset(receiver, externalAmplifier: true)
            #expect(with.lna + (with.amplifier ? 14 : 0) <= alone.lna + (alone.amplifier ? 14 : 0), "\(receiver)")
        }
    }

    @Test("Gemessene Bestwerte vom 24.10.2026")
    func measuredValues() {
        #expect(GainProfile.preset(.spectrum, externalAmplifier: true).lna == 8)
        #expect(GainProfile.preset(.tv, externalAmplifier: true).lna == 24)
        #expect(GainProfile.preset(.adsb, externalAmplifier: true) == .init(lna: 40, vga: 40, amplifier: false))
        // 27.10.2026: Sonden eine LNA-Stufe höher als die übrigen Schmalbandempfänger.
        #expect(GainProfile.preset(.sonde, externalAmplifier: true) == .init(lna: 32, vga: 30, amplifier: false))
    }

    @Test("Werte liegen im Raster des HackRF (LNA 8 dB, VGA 2 dB)")
    func gainRaster() {
        for receiver in GainProfile.Receiver.allCases {
            for external in [false, true] {
                let p = GainProfile.preset(receiver, externalAmplifier: external)
                #expect((0...40).contains(p.lna) && p.lna.truncatingRemainder(dividingBy: 8) == 0)
                #expect((0...62).contains(p.vga) && p.vga.truncatingRemainder(dividingBy: 2) == 0)
            }
        }
    }

    @Test("Übersteuerung: Werte bei ±127 und −128 zählen")
    func clippedFraction() {
        let bytes: [Int8] = [0, 127, -127, -128, 126, -126, 10, -10]
        let data = bytes.withUnsafeBytes { Data($0) }
        #expect(HackRFDevice.clippedFraction(data) == 3.0 / 8.0)
        #expect(HackRFDevice.clippedFraction(Data()) == 0)
    }

    @Test("Bewertung der Übersteuerung")
    func levels() {
        #expect(ReceiveLevel(clippedFraction: 0) == .fine)
        #expect(ReceiveLevel(clippedFraction: 0.0005) == .fine)
        #expect(ReceiveLevel(clippedFraction: 0.005) == .warning)
        #expect(ReceiveLevel(clippedFraction: 0.4) == .overloaded)
        #expect(ReceiveLevel(.init(rmsDBFS: -25, peakDBFS: -12, clipped: 0)) == .fine)
        #expect(ReceiveLevel(.init(rmsDBFS: -45, peakDBFS: -30, clipped: 0)) == .low)
        #expect(ReceiveLevel(.init(rmsDBFS: -9, peakDBFS: -1, clipped: 0)) == .warning)
        #expect(ReceiveLevel(.init(rmsDBFS: -9, peakDBFS: 0, clipped: 0.05)) == .overloaded)
    }

    @Test("Blockpegel: Vollausschlag 0 dBFS, halbe Amplitude −6 dBFS")
    func blockStatistics() {
        let full = Data([Int8](repeating: -128, count: 64).withUnsafeBytes { Array($0) })
        let half = Data([Int8](repeating: 64, count: 64).withUnsafeBytes { Array($0) })
        #expect(abs(HackRFDevice.blockStatistics(full).rmsDBFS) < 0.01)
        #expect(abs(HackRFDevice.blockStatistics(half).rmsDBFS + 6.02) < 0.01)
        #expect(abs(HackRFDevice.blockStatistics(half).peakDBFS + 6.02) < 0.01)
        #expect(HackRFDevice.blockStatistics(full).clipped == 1)
    }
}
