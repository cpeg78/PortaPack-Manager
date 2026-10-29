import Foundation
import Testing
@testable import PortaPackManager

@Suite("DAB: MSC, DAB+ und PAD")
struct DABMSCTests {
    @Test("Reed-Solomon korrigiert bis zu fünf Bytefehler")
    func reedSolomon() {
        var random = DABTestTransmitter.Random(state: 77)
        for errors in 0...5 {
            let data = (0..<110).map { _ in UInt8(random.next() & 0xFF) }
            let codeword = DABReedSolomon.encode(data)
            var received = codeword
            var positions = Set<Int>()
            while positions.count < errors { positions.insert(Int(random.next() % 120)) }
            for p in positions { received[p] ^= UInt8(1 + random.next() % 255) }
            let corrected = DABReedSolomon.decode(&received)
            #expect(corrected == errors)
            #expect(received == codeword)
        }
        // Sechs Fehler sind zu viel – darf nicht als „korrigiert“ durchgehen.
        let data = (0..<110).map { _ in UInt8(random.next() & 0xFF) }
        var received = DABReedSolomon.encode(data)
        for p in [3, 17, 40, 66, 90, 115] { received[p] ^= 0x5A }
        let result = DABReedSolomon.decode(&received)
        #expect(result == nil || received != DABReedSolomon.encode(data))
    }

    @Test("Zeit-Entschachtelung, EEP und Viterbi liefern die Logikrahmen zurück")
    func subchannel() {
        let subchannel = DABSubchannel(id: 3, startCU: 100, sizeCU: 36, protection: .eep(profileB: false, level: 3))
        let puncturing = subchannel.puncturing!
        let frameBytes = 3 * subchannel.bitrate
        var random = DABTestTransmitter.Random(state: 13)
        let cifs = 24
        let logical = (0..<cifs).map { _ in (0..<frameBytes).map { _ in UInt8(random.next() & 0xFF) } }
        let prbs = DABTables.prbs(count: puncturing.dataBits)
        // Sender: verwischen, kodieren, punktieren
        let coded: [[UInt8]] = logical.map { bytes in
            var bits = DABBits.unpack(bytes)
            for i in bits.indices { bits[i] ^= prbs[i] }
            return puncturing.puncture(DABConvolutionalCode.encode(bits))
        }
        // Zeitverschachtelung: CIF r, Bit i stammt aus Rahmen r − I(i mod 16).
        let length = subchannel.sizeCU * 64
        var msc: [Int16] = []
        var frames: [[Int16]] = []
        for r in 0..<cifs {
            var cif = [Int16](repeating: 0, count: DABMode.cifBits)
            for i in 0..<length {
                let source = r - DABSubchannelDecoder.interleaveMap[i & 15]
                let bit: UInt8 = source >= 0 && i < coded[source].count ? coded[source][i] : 0
                var value: Int16 = bit == 0 ? 50 : -50
                if random.next() % 50 == 0 { value = -value }      // 2 % Fehler
                cif[subchannel.startCU * 64 + i] = value
            }
            msc += cif
            if msc.count == 4 * DABMode.cifBits {
                frames.append(msc)
                msc = []
            }
        }
        let decoder = DABSubchannelDecoder(subchannel: subchannel)!
        let output = frames.flatMap { decoder.process(msc: $0) }
        // Nach 15 CIFs Vorlauf: Ausgabe k gehört zu Logikrahmen k.
        #expect(output.count == cifs - 15)
        for (k, frame) in output.enumerated() { #expect(frame == logical[k], "Rahmen \(k)") }
    }

    @Test("Superframe: Synchronisation, RS-Korrektur und AU-Prüfung")
    func superframe() throws {
        let s = 6   // 48 kbit/s
        let units: [[UInt8]] = (0..<6).map { i in (0..<90).map { UInt8(($0 * 7 + i) & 0xFF) } }
        // 48 kHz, kein SBR, Mono → 6 AUs
        let sf = try #require(DABAudioTestSupport.superframe(units: units, formatByte: 0x40, s: s))
        #expect(sf.count == 120 * s)
        var corrupted = sf
        for p in [5, 200, 333, 501, 700] { corrupted[p] ^= 0xFF }
        let frameLength = sf.count / 5
        let decoder = DABPlusSuperframeDecoder()
        // Zwei fremde Rahmen davor: der Dekoder muss sich auf den Superframe einrasten.
        var out: [DABPlusSuperframeDecoder.AccessUnit] = []
        for junk in 0..<2 { out += decoder.process(logicalFrame: [UInt8](repeating: UInt8(junk + 1), count: frameLength)) }
        for f in 0..<5 { out += decoder.process(logicalFrame: Array(corrupted[(f * frameLength)..<((f + 1) * frameLength)])) }
        #expect(out.count == 6)
        #expect(out.first.map { Array($0.data.prefix(90)) } == units[0])
        #expect(decoder.format?.accessUnits == 6)
        #expect(decoder.rsCorrected == 5)
        #expect(decoder.accessUnitsBad == 0)
    }

    /// Baut das PAD (X-PAD verkehrt herum + F-PAD) mit einem Unterfeld.
    private func pad(subfield type: Int, data: [UInt8], lengthIndex: Int) -> [UInt8] {
        let lengths = [4, 6, 8, 12, 16, 24, 32, 48]
        var field = data
        field += [UInt8](repeating: 0, count: lengths[lengthIndex] - data.count)
        let xpad = [UInt8(lengthIndex << 5 | type), 0x00] + field   // CI, Endmarke, Daten
        let fpad: [UInt8] = [0x20, 0x02]                              // variables X-PAD, CI vorhanden
        return xpad.reversed() + fpad
    }

    @Test("Dynamic Label aus mehreren Segmenten")
    func dynamicLabel() {
        let text = Array("Jetzt läuft: Testsong – Interpret".utf8)
        let segments = stride(from: 0, to: text.count, by: 16).map { Array(text[$0..<min($0 + 16, text.count)]) }
        let decoder = DABPADDecoder()
        var changed = false
        for (n, chars) in segments.enumerated() {
            let last = n == segments.count - 1
            var prefix0: UInt8 = 0x80                         // Toggle
            if n == 0 { prefix0 |= 0x40 }
            if last { prefix0 |= 0x20 }
            prefix0 |= UInt8(chars.count - 1)
            let prefix1: UInt8 = n == 0 ? 0xF0 : UInt8(n << 4)  // UTF-8 bzw. Segmentnummer
            var group = [prefix0, prefix1] + chars
            let crc = DABCRC.ccitt(group)
            group += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            // Datengruppe in 16-Byte-Unterfeldern (Start = Typ 2, weiter = Typ 3)
            for (k, start) in stride(from: 0, to: group.count, by: 16).enumerated() {
                let part = Array(group[start..<min(start + 16, group.count)])
                changed = decoder.process(pad: pad(subfield: k == 0 ? 2 : 3, data: part, lengthIndex: 4), exactLength: false) || changed
            }
        }
        #expect(changed)
        #expect(decoder.dynamicLabel == "Jetzt läuft: Testsong – Interpret")
    }

    @Test("AAC (LC und HE): Ton kommt mit dem 960/1024-Ausgleich heraus", arguments: [false, true])
    func aacTone(he: Bool) throws {
        // AudioToolbox kodiert 1024er-Rahmen; der Dekoder nimmt 960er an und
        // rechnet um 16/15 um – ein 1-kHz-Ton erscheint also bei 1066,7 Hz.
        let units = DABAudioTestSupport.encodeTone(frequency: 1000, seconds: 1.5, sampleRate: 48_000,
                                                   channels: he ? 2 : 1, he: he, bitrate: he ? 48_000 : 64_000)
        try #require(units.count > 20)
        // 0x40 = 48 kHz LC Mono; 0x70 = 48 kHz, SBR, Stereo
        let decoder = try DABAudioDecoder(codec: .aac(DABPlusFormat(byte: he ? 0x70 : 0x40)))
        var left: [Float] = []
        var right: [Float] = []
        for unit in units {
            let (l, r) = decoder.decode(unit)
            left += l
            right += r
        }
        #expect(decoder.errors == 0)
        let seconds = Double(left.count) / 48_000
        #expect(seconds > 1.3 && seconds < 1.75)
        let frequency = DABAudioTestSupport.dominantFrequency(left, rate: 48_000)
        #expect(abs(frequency - 1000 * 16 / 15) < 15)
        #expect(left.count == right.count)
    }
}
