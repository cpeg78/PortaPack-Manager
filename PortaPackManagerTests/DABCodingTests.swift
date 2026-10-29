import Foundation
import Testing
@testable import PortaPackManager

@Suite("DAB: Kanalcodierung")
struct DABCodingTests {
    @Test("Kanaltabelle und Frequenz-Entschachtelung")
    func tables() {
        #expect(DABChannel.bandIII.count == 38)
        #expect(DABChannel.named("5C")?.frequency == 178_352_000)
        #expect(DABChannel.named("13F")?.frequency == 239_200_000)
        let map = DABTables.frequencyInterleaver
        #expect(map.count == 1536)
        #expect(Set(map).count == 1536)
        #expect(!map.contains(0))
        // Erste Werte nach EN 300 401 Tabelle 42: Π(1..) → k = −1024+…
        #expect(map.allSatisfy { $0 <= 768 || $0 >= 2048 - 768 })
    }

    @Test("Energieverwischung beginnt wie im Standard")
    func prbs() {
        // EN 300 401 §10: die ersten 16 Bits sind 0000 0111 1011 1110.
        let bits = DABTables.prbs(count: 16).map(String.init).joined()
        #expect(bits == "0000011110111110")
    }

    @Test("Punktierung: FIC und EEP haben die richtigen Längen")
    func puncturing() {
        #expect(DABPuncturing.fic.transmittedBits == 2304)
        #expect(DABPuncturing.fic.dataBits == 768)
        // EEP 3-A, 48 kbit/s: 36 CU = 2304 Bits, Logikrahmen 24 · 48 = 1152 Bits
        let eep3a = DABPuncturing.eep(profileB: false, level: 3, bitrate: 48)!
        #expect(eep3a.transmittedBits == 36 * 64)
        #expect(eep3a.dataBits == 1152)
        // EEP 1-B, 64 kbit/s: 54 CU
        let eep1b = DABPuncturing.eep(profileB: true, level: 1, bitrate: 64)!
        #expect(eep1b.transmittedBits == 54 * 64)
        // Alle UEP-Profile passen zur Größe in Tabelle 31.
        for entry in DABTables.uepSubchannels {
            let profile = DABPuncturing.uep(bitrate: entry.bitrate, level: entry.level)
            #expect(profile != nil)
            #expect(profile?.dataBits == 24 * entry.bitrate)
            // Bis zu 8 Füllbits am Ende des Unterkanals (EN 300 401 §11.3.1).
            let padding = entry.size * 64 - (profile?.transmittedBits ?? 0)
            #expect((0...8).contains(padding), "UEP \(entry.bitrate)/\(entry.level)")
        }
    }

    @Test("Viterbi korrigiert Bitfehler nach Punktierung")
    func viterbi() {
        var random = DABTestTransmitter.Random(state: 42)
        let data = (0..<768).map { _ in random.bit() }
        let sent = DABPuncturing.fic.puncture(DABConvolutionalCode.encode(data))
        #expect(sent.count == 2304)
        var soft = sent.map { Int16($0 == 0 ? 60 : -60) }
        // 3 % Fehler mit voller Zuversicht
        for _ in 0..<70 {
            let i = Int(random.next() % UInt64(soft.count))
            soft[i] = -soft[i]
        }
        let mother = soft.withUnsafeBufferPointer { DABPuncturing.fic.depuncture($0) }
        let decoded = DABViterbi().decode(mother, bits: 768)
        #expect(decoded == data)
    }

    @Test("CRC des FIB und Firecode")
    func crc() {
        let fib = DABTestTransmitter.fib([DABTestTransmitter.fig(type: 0, [0x00, 0x10, 0x01, 0x00, 0x00])])
        #expect(DABCRC.ccitt(fib.prefix(30)) == UInt16(fib[30]) << 8 | UInt16(fib[31]))
        // CRC-16/GENIBUS (CCITT, invertiert) von „123456789“ = 0xD64E
        #expect(DABCRC.ccitt(Array("123456789".utf8)) == 0xD64E)
        #expect(DABCRC.fire([UInt8](repeating: 0, count: 9)) == 0)
    }

    @Test("FIGs ergeben Ensemble, Dienst und Unterkanal")
    func figs() {
        var ensemble = DABEnsemble()
        for fib in DABTestTransmitter.exampleFIBs() { ensemble.process(fib: fib.prefix(30)) }
        #expect(ensemble.id == 0x1001)
        #expect(ensemble.label == "Test-Mux")
        let service = ensemble.audioServices.first
        #expect(service?.label == "Radio Eins")
        #expect(service?.kind == .dabPlus)
        let subchannel = service.flatMap { ensemble.subchannel(for: $0) }
        #expect(subchannel?.startCU == 0)
        #expect(subchannel?.sizeCU == 36)
        #expect(subchannel?.bitrate == 48)
        #expect(subchannel?.protection == .eep(profileB: false, level: 3))
    }

    @Test("EBU-Latin-Zeichensatz")
    func charset() {
        // 0x91 = ä, 0x97 = ö, 0x99 = ü, 0x8D = ß
        #expect(DABCharset.decode([0x53, 0x97, 0x99, 0x8D, 0x91, 0x20, 0x20], charset: 0) == "Söüßä")
        #expect(DABCharset.decode(Array("Grüße".utf8), charset: 15) == "Grüße")
    }
}
