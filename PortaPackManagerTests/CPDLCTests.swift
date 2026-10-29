import Foundation
import Testing
@testable import PortaPackManager

@Suite("CPDLC (PER-Dekoder)")
struct CPDLCTests {
    @Test("Schemas und Klartexte laden")
    func schemas() throws {
        let atn = try #require(ASN1Schema.atn)
        #expect(atn.types.count > 500)
        #expect(atn.resolve("ATCUplinkMessage")?.type.kind == "sequence")
        #expect(atn.resolve("CPDLCMessage")?.type.kind == "bits")
        let fans = try #require(ASN1Schema.fans)
        #expect(fans.types["FANSATCUplinkMsgElementId"]?.members?.count == 183)
        #expect(CPDLCFormatter.labels["ATCUplinkMsgElementId"]?["uM20Level"] == "CLIMB TO [level]")
        #expect(CPDLCFormatter.labels["FANSATCDownlinkMsgElementId"]?["dM0NULL"] == "WILCO")
    }

    @Test("Level: CHOICE → CHOICE → beschränkte Zahl (FL350)")
    func level() throws {
        let schema = try #require(ASN1Schema.atn)
        // singleLevel (1 Bit: 0), flightLevel (2 Bit: 10), 350 − 30 = 320 (10 Bit: 0101000000) → 0100 1010 0000 0000
        let value = try PERDecoder(schema: schema).decode("Level", bytes: [0x4A, 0x00], bitCount: 13)
        #expect(value == .choice("singleLevel", .choice("flightLevel", .int(350))))
        #expect(CPDLCFormatter.format(value, type: "Level", schema: schema) == "FL350")
    }

    @Test("Nachrichtenelement uM20 mit Parameter → „CLIMB TO FL350“")
    func element() throws {
        let schema = try #require(ASN1Schema.atn)
        // ext-Bit 0, Index 20 (8 Bit), dann Level wie oben: 0 00010100 0 10 0101000000 → 0000 1010 0010 0101 0000 00..
        let bytes: [UInt8] = [0x0A, 0x25, 0x00]
        let element = try PERDecoder(schema: schema).decode("ATCUplinkMsgElementId", bytes: bytes, bitCount: 22)
        #expect(CPDLCFormatter.elementText(element, labelTable: "ATCUplinkMsgElementId", schema: schema) == "CLIMB TO FL350")
    }

    @Test("Zeit, Frequenz und Freitext")
    func primitives() throws {
        let schema = try #require(ASN1Schema.atn)
        // Time: hours 22 (5 Bit 10110), minutes 50 (6 Bit 110010) → 1011 0110 010.
        let time = try PERDecoder(schema: schema).decode("Time", bytes: [0xB6, 0x40], bitCount: 11)
        #expect(CPDLCFormatter.format(time, type: "Time", schema: schema) == "22:50")
        // Frequencyvhf 23600..27398, 12 Bit: 121,5 MHz = 24300 → 700 → 001010111100
        let f = try PERDecoder(schema: schema).decode("Frequencyvhf", bytes: [0x2B, 0xC0], bitCount: 12)
        #expect(CPDLCFormatter.format(f, type: "Frequencyvhf", schema: schema) == "121.500 MHz")
        // FreeText SIZE(1..256) 8 Bit Länge (n − 1), 7 Bit je Zeichen: "HI" → 00000001 1001000 1001001
        let text = try PERDecoder(schema: schema).decode("FreeText", bytes: [0x01, 0x91, 0x24], bitCount: 22)
        #expect(text == .string("HI"))
    }
}
