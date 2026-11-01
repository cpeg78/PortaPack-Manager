import Foundation
import Testing
@testable import PortaPackManager

/// LoRa-APRS (433,775 MHz): Nutzlast-Format und ganzer Weg über den LoRa-Demodulator.
@Suite("LoRa-APRS")
struct LoRaAPRSTests {
    private static let line = "DL1ABC-9>APLRT1,WIDE1-1:!5333.00N/00957.00E>Fahrrad 73"

    @Test("Nutzlast mit Vorspann <\\xFF\\x01, ohne Vorspann und mit Zeilenende")
    func payload() throws {
        let body = Array(Self.line.utf8)
        for bytes in [[0x3C, 0xFF, 0x01] + body, body, [0x3C, 0xFF, 0x01] + body + [0x0D, 0x0A]] {
            let packet = try #require(APRSPacket.parse(loRa: bytes))
            #expect(packet.source == "DL1ABC-9")
            #expect(packet.destination == "APLRT1")
            #expect(packet.path == "WIDE1-1")
            #expect(packet.latitude.map { abs($0 - 53.55) < 0.001 } == true)
            #expect(packet.longitude.map { abs($0 - 9.95) < 0.001 } == true)
            #expect(packet.comment.hasSuffix("Fahrrad 73"))
        }
        #expect(APRSPacket.parse(loRa: [0x3C, 0xFF, 0x01] + Array("kein APRS".utf8)) == nil)
    }

    @Test("Parameter: SF12, 125 kHz, Sync 0x12, Low-Data-Rate an")
    func parameters() {
        let p = APRSModel.loraParameters
        #expect(p.spreadingFactor == 12 && p.bandwidth == 125_000 && p.syncWord == 0x12 && p.lowDataRate)
        #expect(APRSModel.Channel.lora.isLoRa && !APRSModel.Channel.europe.isLoRa)
    }

    @Test("LoRa-APRS-Paket moduliert, mit Rauschen und Frequenzablage empfangen und gelesen")
    func ganzerWeg() throws {
        let parameters = APRSModel.loraParameters
        let payload: [UInt8] = [0x3C, 0xFF, 0x01] + Array(Self.line.utf8)
        let symbols = LoRaCoding.encode(payload, sf: parameters.spreadingFactor, codingRate: 1, lowDataRate: parameters.lowDataRate)
        var tx = LoRaTestTransmitter(parameters: parameters)
        tx.preambleLength = 8            // LoRa-APRS-Sender (RadioLib-Standard)
        var (re, im) = tx.waveform(symbols: symbols, sampleRate: parameters.bandwidth * Double(LoRaDemodulator.oversampling),
                                   cfoHz: 4_200, carrierHz: 433_775_000, startDelay: 50_001.7, tail: 40_000)
        var noise = TestNoise(state: 7)
        for k in re.indices {
            re[k] += 0.5 * noise.gaussian()
            im[k] += 0.5 * noise.gaussian()
        }
        let demod = LoRaDemodulator(parameters: parameters, centerFrequency: 433_775_000)
        let frame = try #require(demod.process(re: re.map(Float.init), im: im.map(Float.init)).first)
        #expect(frame.crcValid == true)
        let packet = try #require(APRSPacket.parse(loRa: frame.payload))
        #expect(packet.source == "DL1ABC-9")
        #expect(packet.latitude != nil)
    }
}
