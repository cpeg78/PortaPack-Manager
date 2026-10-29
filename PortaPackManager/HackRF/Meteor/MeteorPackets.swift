import Foundation

/// Kopf einer VCDU (CCSDS AOS). Aufbau der 892 Bytes bei METEOR:
/// 6 Byte Kopf, 2 Byte Insert Zone, 2 Byte M-PDU-Kopf, 882 Byte Pakete
/// (SatDump `ccsds_aos::Demuxer(882, true)`).
struct MeteorVCDU: Sendable, Equatable {
    static let packetZoneOffset = 10
    static let packetZoneLength = 882
    static let noHeader = 2047

    var spacecraftID: Int
    var virtualChannel: Int
    var counter: Int
    var firstHeaderPointer: Int

    init?(_ data: [UInt8]) {
        guard data.count >= 892 else { return nil }
        spacecraftID = Int(data[0] & 0x3F) << 2 | Int(data[1] >> 6)
        virtualChannel = Int(data[1] & 0x3F)
        counter = Int(data[2]) << 16 | Int(data[3]) << 8 | Int(data[4])
        firstHeaderPointer = Int(data[8] & 0x07) << 8 | Int(data[9])
    }
}

/// Ein CCSDS-Quellpaket (Kopf zerlegt, Nutzdaten ohne die 6 Kopfbytes).
struct MeteorPacket: Sendable, Equatable {
    var apid: Int
    var sequence: Int
    var payload: [UInt8]
}

/// Setzt Pakete aus den Paketzonen aufeinanderfolgender VCDUs zusammen.
/// Fehlt eine VCDU (Zählerlücke), wird das angefangene Paket verworfen und
/// am nächsten Paketanfang (First Header Pointer) neu aufgesetzt.
final class MeteorPacketDemux {
    static let imageChannel = 5

    private var buffer: [UInt8] = []
    private var synced = false
    private var lastCounter: Int?
    private(set) var packetCount = 0
    private(set) var lostFrames = 0

    func reset() {
        buffer.removeAll()
        synced = false
        lastCounter = nil
        packetCount = 0
        lostFrames = 0
    }

    func process(_ vcdu: [UInt8]) -> [MeteorPacket] {
        guard let header = MeteorVCDU(vcdu), header.virtualChannel == Self.imageChannel else { return [] }
        if let last = lastCounter, (last + 1) & 0xFF_FFFF != header.counter {
            lostFrames += 1
            synced = false
        }
        lastCounter = header.counter
        let zone = vcdu[MeteorVCDU.packetZoneOffset..<(MeteorVCDU.packetZoneOffset + MeteorVCDU.packetZoneLength)]
        let pointer = header.firstHeaderPointer
        var packets: [MeteorPacket] = []

        if pointer == MeteorVCDU.noHeader {
            if synced {
                buffer.append(contentsOf: zone)
                packets += extract()
            }
            return packets
        }
        guard pointer < MeteorVCDU.packetZoneLength else {
            synced = false
            return []
        }
        if synced {
            // Fortsetzung bis zum ersten Paketanfang; danach muss der Puffer leer sein.
            buffer.append(contentsOf: zone.prefix(pointer))
            packets += extract()
            if !buffer.isEmpty { buffer.removeAll() }
        } else {
            buffer.removeAll()
        }
        synced = true
        buffer.append(contentsOf: zone.dropFirst(pointer))
        packets += extract()
        return packets
    }

    /// Schneidet vollständige Pakete vom Pufferanfang ab.
    private func extract() -> [MeteorPacket] {
        var packets: [MeteorPacket] = []
        var start = 0
        while buffer.count - start >= 6 {
            let length = Int(buffer[start + 4]) << 8 | Int(buffer[start + 5])
            let total = 6 + length + 1
            guard buffer.count - start >= total else { break }
            let apid = Int(buffer[start] & 0x07) << 8 | Int(buffer[start + 1])
            let sequence = Int(buffer[start + 2] & 0x3F) << 8 | Int(buffer[start + 3])
            if apid != 2047 {
                packets.append(MeteorPacket(apid: apid, sequence: sequence,
                                            payload: Array(buffer[(start + 6)..<(start + total)])))
                packetCount += 1
            }
            start += total
        }
        if start > 0 { buffer.removeFirst(start) }
        return packets
    }

    /// Gegenstück für Tests: verteilt Pakete auf VCDUs (VCID 5).
    static func pack(_ packets: [[UInt8]], spacecraft: Int = 0, startCounter: Int = 0) -> [[UInt8]] {
        var stream: [UInt8] = []
        var starts: [Int] = []
        for p in packets {
            starts.append(stream.count)
            stream += p
        }
        var frames: [[UInt8]] = []
        var offset = 0
        var counter = startCounter
        while offset < stream.count {
            var frame = [UInt8](repeating: 0, count: 892)
            frame[0] = 0x40 | UInt8((spacecraft >> 2) & 0x3F)
            frame[1] = UInt8((spacecraft & 3) << 6 | imageChannel)
            frame[2] = UInt8((counter >> 16) & 0xFF)
            frame[3] = UInt8((counter >> 8) & 0xFF)
            frame[4] = UInt8(counter & 0xFF)
            let end = offset + MeteorVCDU.packetZoneLength
            let first = starts.first { $0 >= offset && $0 < end }.map { $0 - offset } ?? MeteorVCDU.noHeader
            frame[8] = UInt8(first >> 8)
            frame[9] = UInt8(first & 0xFF)
            let chunk = stream[offset..<min(end, stream.count)]
            // Rest der Zone mit einem Füllpaket (APID 2047) auffüllen.
            var zone = Array(chunk)
            if zone.count < MeteorVCDU.packetZoneLength {
                let fill = MeteorVCDU.packetZoneLength - zone.count
                if fill >= 7 {
                    let length = fill - 7
                    zone += [0x07, 0xFF, 0xC0, 0x00, UInt8(length >> 8), UInt8(length & 0xFF)]
                    zone += [UInt8](repeating: 0, count: fill - 6)
                } else {
                    zone += [UInt8](repeating: 0, count: fill)
                }
            }
            frame.replaceSubrange(10..<892, with: zone)
            frames.append(frame)
            offset = end
            counter += 1
        }
        return frames
    }

    /// Baut ein Paket mit CCSDS-Kopf.
    static func packet(apid: Int, sequence: Int, payload: [UInt8]) -> [UInt8] {
        let length = payload.count - 1
        return [UInt8(0x08 | (apid >> 8) & 0x07), UInt8(apid & 0xFF),
                UInt8(0xC0 | (sequence >> 8) & 0x3F), UInt8(sequence & 0xFF),
                UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }
}
