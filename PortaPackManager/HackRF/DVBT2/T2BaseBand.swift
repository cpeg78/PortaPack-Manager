import Foundation

/// BBHEADER (5.1.7).
struct T2BBHeader: Sendable, Equatable {
    var transportStream: Bool
    var singleStream: Bool
    var issy: Bool
    var nullPacketDeletion: Bool
    var streamID: Int
    var upl: Int          // nur NM
    var dfl: Int
    var syncd: Int
    var highEfficiency: Bool

    /// `bytes`: die ersten 10 Bytes des entwürfelten BBFRAME.
    init?(bytes: ArraySlice<UInt8>) {
        guard bytes.count >= 10 else { return nil }
        let b = Array(bytes.prefix(10))
        let mode = T2CRC.crc8(b[0..<9][...]) ^ b[9]
        guard mode <= 1 else { return nil }
        highEfficiency = mode == 1
        transportStream = b[0] >> 6 == 3
        singleStream = (b[0] >> 5) & 1 == 1
        issy = (b[0] >> 3) & 1 == 1
        nullPacketDeletion = (b[0] >> 2) & 1 == 1
        streamID = Int(b[1])
        upl = Int(b[2]) << 8 | Int(b[3])
        dfl = Int(b[4]) << 8 | Int(b[5])
        syncd = Int(b[7]) << 8 | Int(b[8])
    }
}

/// BBFRAMEs → Transportstrom-Pakete (5.1.8): Sync-Byte wieder einsetzen,
/// Pakete über BBFRAME-Grenzen zusammensetzen. Gelöschte Nullpakete werden
/// nicht wieder eingefügt – für die Wiedergabe genügt der Nutzstrom.
final class T2TransportStreamExtractor {
    var packetHandler: (([UInt8]) -> Void)?
    private(set) var framesGood = 0
    private(set) var framesBad = 0
    private(set) var packets = 0
    private(set) var lastHeader: T2BBHeader?

    private var pending: [UInt8] = []
    private var pendingValid = false
    private var scrambler: [UInt8] = []

    func reset() {
        pending = []
        pendingValid = false
    }

    /// `bits`: die K_bch Bits eines BBFRAME (noch verwürfelt). `ok`: LDPC/BCH gültig.
    func process(bits: [UInt8], ok: Bool) {
        guard ok else {
            framesBad += 1
            pendingValid = false
            return
        }
        // Ein BBFRAME hat mindestens den 10-Byte-Kopf.
        guard bits.count >= 80 else { framesBad += 1; pendingValid = false; return }
        if scrambler.count != bits.count { scrambler = T2Reference.scramblingSequence(bits.count) }
        let byteCount = bits.count / 8
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
            var value: UInt8 = 0
            for j in 0..<8 { value = value << 1 | (bits[i * 8 + j] ^ scrambler[i * 8 + j]) }
            bytes[i] = value
        }
        guard let header = T2BBHeader(bytes: bytes[0..<10]), header.transportStream,
              header.dfl % 8 == 0, 10 + header.dfl / 8 <= byteCount else {
            framesBad += 1
            pendingValid = false
            return
        }
        framesGood += 1
        lastHeader = header
        let field = bytes[10..<(10 + header.dfl / 8)]
        let unit: Int
        let syncOffset: Int      // Position des Paketinhalts (nach dem entfernten Sync-Byte) im UP
        if header.highEfficiency {
            unit = 187 + (header.nullPacketDeletion ? 1 : 0)
            syncOffset = 0
        } else {
            unit = header.upl / 8
            syncOffset = 1       // NM: UP beginnt mit der CRC-8 des vorigen Pakets
            guard unit >= 188 else { framesBad += 1; return }
        }

        if header.syncd == 0xFFFF {
            if pendingValid { pending += field } else { return }
            emitComplete(unit: unit, syncOffset: syncOffset)
            return
        }
        let syncByte = header.syncd / 8
        guard syncByte <= field.count else { return }
        if pendingValid {
            pending += field[field.startIndex..<(field.startIndex + syncByte)]
            if pending.count == unit { emit(pending, syncOffset: syncOffset) }
        }
        pending = Array(field[(field.startIndex + syncByte)...])
        pendingValid = true
        emitComplete(unit: unit, syncOffset: syncOffset)
    }

    private func emitComplete(unit: Int, syncOffset: Int) {
        var start = 0
        while pending.count - start >= unit {
            emit(Array(pending[start..<(start + unit)]), syncOffset: syncOffset)
            start += unit
        }
        if start > 0 { pending.removeFirst(start) }
    }

    private func emit(_ up: [UInt8], syncOffset: Int) {
        guard up.count >= syncOffset + 187 else { return }
        var packet = [UInt8](repeating: 0x47, count: 188)
        packet.replaceSubrange(1..<188, with: up[syncOffset..<(syncOffset + 187)])
        packets += 1
        packetHandler?(packet)
    }
}
