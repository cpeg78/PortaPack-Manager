import Foundation

/// Minimaler PCAP-Schreiber (klassisches Format, little-endian) für die
/// Rahmenmitschnitte der Empfänger. Linktypen: 195 IEEE 802.15.4 mit FCS,
/// 105 IEEE 802.11 ohne Radiotap, 127 IEEE 802.11 mit Radiotap-Kopf.
enum PCAPWriter {
    struct Frame: Sendable {
        var bytes: [UInt8]
        var date: Date
        /// Optionaler Radiotap-Kopf (nur Linktyp 127) – wird den Bytes vorangestellt.
        var radiotap: [UInt8] = []
    }

    static func data(linktype: UInt32, frames: [Frame]) -> Data {
        var out = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        le32(0xA1B2_C3D4); le16(2); le16(4); le32(0); le32(0); le32(262_144); le32(linktype)
        for frame in frames {
            let record = frame.radiotap + frame.bytes
            let seconds = frame.date.timeIntervalSince1970
            le32(UInt32(seconds))
            le32(UInt32((seconds - floor(seconds)) * 1_000_000))
            le32(UInt32(record.count)); le32(UInt32(record.count))
            out.append(contentsOf: record)
        }
        return out
    }

    /// Radiotap-Kopf mit Kanalfrequenz und Signalpegel (dBm). Wireshark zeigt
    /// damit Kanal und RSSI je Rahmen an.
    static func radiotap(frequencyMHz: Int, rssiDBm: Int8, is5GHz: Bool) -> [UInt8] {
        // Länge 13: Version(1) Pad(1) Länge(2) Present(4) Flags(1) Channel(2+2) Signal(1).
        var header: [UInt8] = [0, 0, 13, 0]
        let present: UInt32 = 1 << 1 | 1 << 3 | 1 << 5    // Flags, Channel, dBm-Signal
        header += (0..<4).map { UInt8(present >> (8 * UInt32($0)) & 0xFF) }
        header += [0x10]                                   // Flags: FCS liegt am Rahmenende
        let f = UInt16(frequencyMHz)
        header += [UInt8(f & 0xFF), UInt8(f >> 8)]
        let flags: UInt16 = is5GHz ? 0x0140 : 0x00A0       // OFDM/5 GHz bzw. CCK/2 GHz
        header += [UInt8(flags & 0xFF), UInt8(flags >> 8)]
        header += [UInt8(bitPattern: rssiDBm)]
        return header
    }
}
