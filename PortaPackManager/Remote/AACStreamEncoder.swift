import AVFoundation
import Foundation

/// Kodiert 48-kHz-Stereo (Float) laufend zu AAC-LC und liefert ADTS-Rahmen –
/// das Format, das Browser per `<audio src=…>` als Live-Stream abspielen
/// (wie Icecast mit `audio/aac`). Arbeitet auf einer eigenen Warteschlange,
/// damit der Empfangsthread nicht auf den Kodierer wartet.
final class AACStreamEncoder: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let framesPerPacket = 1024

    /// Bekommt je Aufruf einen oder mehrere vollständige ADTS-Rahmen.
    var onData: (@Sendable (Data) -> Void)?

    private let queue = DispatchQueue(label: "de.christiangolz.portapackmanager.aac", qos: .userInitiated)
    private let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var pendingLeft: [Float] = []
    private var pendingRight: [Float] = []

    init?(bitRate: Int = 128_000) {
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let output = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        converter.bitRate = bitRate
        outputFormat = output
        self.converter = converter
    }

    /// Nimmt Werte entgegen (beliebige Länge); kodiert asynchron.
    func push(left: [Float], right: [Float]) {
        queue.async { [self] in
            pendingLeft += left
            pendingRight += right
            var out = Data()
            while pendingLeft.count >= Self.framesPerPacket {
                out.append(encode(Array(pendingLeft.prefix(Self.framesPerPacket)),
                                  Array(pendingRight.prefix(Self.framesPerPacket))))
                pendingLeft.removeFirst(Self.framesPerPacket)
                pendingRight.removeFirst(Self.framesPerPacket)
            }
            if !out.isEmpty { onData?(out) }
        }
    }

    /// Wartet, bis alles Übergebene kodiert ist (für Tests).
    func flush() { queue.sync {} }

    private func encode(_ left: [Float], _ right: [Float]) -> Data {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(left.count)) else { return Data() }
        pcm.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { pcm.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) }

        var out = Data()
        var supplied = false
        let compressed = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 8,
                                                 maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
        while true {
            var error: NSError?
            let status = converter.convert(to: compressed, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return pcm
            }
            if compressed.packetCount > 0, let descriptions = compressed.packetDescriptions {
                let base = compressed.data.assumingMemoryBound(to: UInt8.self)
                for i in 0..<Int(compressed.packetCount) {
                    let d = descriptions[i]
                    out.append(contentsOf: Self.adtsHeader(payloadLength: Int(d.mDataByteSize)))
                    out.append(base + Int(d.mStartOffset), count: Int(d.mDataByteSize))
                }
            }
            compressed.packetCount = 0
            if status != .haveData { break }
        }
        return out
    }

    /// ADTS-Kopf (7 Byte, ohne CRC) für AAC-LC, 48 kHz, Stereo.
    static func adtsHeader(payloadLength: Int) -> [UInt8] {
        let length = payloadLength + 7
        let profile = 1          // AAC-LC (Objekttyp 2) − 1
        let rateIndex = 3        // 48 kHz
        let channels = 2
        return [
            0xFF, 0xF1,
            UInt8((profile << 6) | (rateIndex << 2) | (channels >> 2)),
            UInt8(((channels & 3) << 6) | (length >> 11)),
            UInt8((length >> 3) & 0xFF),
            UInt8(((length & 7) << 5) | 0x1F),
            0xFC,
        ]
    }
}
