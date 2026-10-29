import AudioToolbox
import Foundation

/// Dekodiert DAB+-Access-Units (AAC) und DAB-Rahmen (MPEG-1/2 Layer II)
/// mit AudioToolbox zu 48 kHz Stereo.
///
/// DAB+ nutzt AAC mit 960er-Rahmen, die AudioToolbox ablehnt. Die Syntax
/// ist aber bis auf das oberste Skalenband gleich; ein 1024er-Dekoder
/// liefert dann je Rahmen 1024 statt 960 Werte mit um 15/16 gestauchten
/// Frequenzen – also dasselbe Signal, nur mit 16/15 der Rate abgetastet.
/// Die anschließende Ratenwandlung von R · 16/15 auf 48 kHz stellt es wieder her.
final class DABAudioDecoder: @unchecked Sendable {
    enum Codec: Equatable, Sendable {
        case aac(DABPlusFormat)
        case mp2(sampleRate: Int, channels: Int)
    }

    enum DecoderError: Error, LocalizedError {
        case setup(OSStatus)
        var errorDescription: String? {
            switch self {
            case let .setup(status): String(localized: "Der Audiodekoder ließ sich nicht einrichten (\(status)).")
            }
        }
    }

    static let outputRate = 48_000.0

    let codec: Codec
    private var decoder: AudioConverterRef?
    private var resampler: AudioConverterRef?
    private let decodedChannels: Int
    private(set) var errors = 0

    init(codec: Codec) throws {
        self.codec = codec
        var input = AudioStreamBasicDescription()
        let decodedRate: Double
        var cookie: [UInt8] = []
        switch codec {
        case let .aac(format):
            decodedChannels = format.stereo || format.parametricStereo ? 2 : 1
            decodedRate = Double(format.outputRate)
            input.mSampleRate = decodedRate
            input.mFormatID = format.sbr ? (format.parametricStereo ? kAudioFormatMPEG4AAC_HE_V2 : kAudioFormatMPEG4AAC_HE) : kAudioFormatMPEG4AAC
            input.mFramesPerPacket = format.sbr ? 2048 : 1024
            input.mChannelsPerFrame = UInt32(decodedChannels)
            cookie = Self.esds(Self.audioSpecificConfig(format))
        case let .mp2(sampleRate, channels):
            decodedChannels = channels
            decodedRate = Double(sampleRate)
            input.mSampleRate = decodedRate
            input.mFormatID = kAudioFormatMPEGLayer2
            input.mFramesPerPacket = 1152
            input.mChannelsPerFrame = UInt32(channels)
        }
        var pcm = Self.floatFormat(rate: decodedRate, channels: decodedChannels)
        var converter: AudioConverterRef?
        var status = AudioConverterNew(&input, &pcm, &converter)
        guard status == noErr, let converter else { throw DecoderError.setup(status) }
        decoder = converter
        if !cookie.isEmpty {
            status = cookie.withUnsafeBytes {
                AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
            }
            guard status == noErr else { throw DecoderError.setup(status) }
        }

        // Ratenwandler auf 48 kHz Stereo (bei AAC mit dem 16/15-Ausgleich).
        let sourceRate = if case .aac = codec { decodedRate * 16 / 15 } else { decodedRate }
        var from = Self.floatFormat(rate: sourceRate, channels: 2)
        var to = Self.floatFormat(rate: Self.outputRate, channels: 2)
        var sampleRateConverter: AudioConverterRef?
        status = AudioConverterNew(&from, &to, &sampleRateConverter)
        guard status == noErr, let sampleRateConverter else { throw DecoderError.setup(status) }
        var quality = kAudioConverterQuality_High
        AudioConverterSetProperty(sampleRateConverter, kAudioConverterSampleRateConverterQuality,
                                  UInt32(MemoryLayout<UInt32>.size), &quality)
        resampler = sampleRateConverter
    }

    deinit {
        if let decoder { AudioConverterDispose(decoder) }
        if let resampler { AudioConverterDispose(resampler) }
    }

    // MARK: - Konfiguration

    private static func floatFormat(rate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    private static func samplingFrequencyIndex(_ rate: Int) -> Int {
        [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8000].firstIndex(of: rate) ?? 3
    }

    /// AudioSpecificConfig mit 1024er-Rahmen (siehe Typbeschreibung);
    /// SBR und PS explizit-hierarchisch signalisiert.
    static func audioSpecificConfig(_ format: DABPlusFormat) -> [UInt8] {
        var writer = BitWriter()
        let core = samplingFrequencyIndex(format.coreRate)
        if format.sbr {
            writer.put(format.parametricStereo ? 29 : 5, 5)
            writer.put(core, 4)
            writer.put(format.stereo ? 2 : 1, 4)
            writer.put(samplingFrequencyIndex(format.outputRate), 4)
            writer.put(2, 5)                     // AAC LC als Kern
        } else {
            writer.put(2, 5)
            writer.put(core, 4)
            writer.put(format.stereo ? 2 : 1, 4)
        }
        writer.put(0, 3)                         // 1024er-Rahmen, kein Kern-Coder, keine Erweiterung
        return writer.bytes
    }

    /// Verpackt die AudioSpecificConfig als ES-Deskriptor (Magic Cookie).
    private static func esds(_ asc: [UInt8]) -> [UInt8] {
        let specific: [UInt8] = [0x05, UInt8(asc.count)] + asc
        let decoderConfig: [UInt8] = [0x04, UInt8(13 + specific.count), 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + specific
        return [0x03, UInt8(3 + decoderConfig.count + 3), 0, 0, 0] + decoderConfig + [0x06, 0x01, 0x02]
    }

    struct BitWriter {
        var bytes: [UInt8] = []
        private var bitCount = 0
        mutating func put(_ value: Int, _ count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) {
                if bitCount % 8 == 0 { bytes.append(0) }
                if value >> i & 1 == 1 { bytes[bytes.count - 1] |= UInt8(0x80 >> (bitCount % 8)) }
                bitCount += 1
            }
        }
    }

    // MARK: - Dekodieren

    /// Dekodiert ein Paket (AU bzw. MP2-Rahmen) zu 48 kHz Stereo.
    func decode(_ packet: [UInt8]) -> (left: [Float], right: [Float]) {
        guard let decoder, let resampler else { return ([], []) }
        let pcm = Self.convertPacket(decoder, packet: packet, channels: decodedChannels, maxFrames: 4096)
        if pcm == nil { errors += 1 }
        guard let pcm, !pcm.isEmpty else { return ([], []) }
        // Auf Stereo bringen (Mono doppeln), verschränkt.
        var stereo: [Float]
        if decodedChannels == 1 {
            stereo = [Float](repeating: 0, count: pcm.count * 2)
            for n in pcm.indices { stereo[2 * n] = pcm[n]; stereo[2 * n + 1] = pcm[n] }
        } else {
            stereo = pcm
        }
        let resampled = Self.convertPCM(resampler, stereo, maxFrames: stereo.count)
        var left = [Float](repeating: 0, count: resampled.count / 2)
        var right = left
        for n in left.indices { left[n] = resampled[2 * n]; right[n] = resampled[2 * n + 1] }
        return (left, right)
    }

    private final class PacketSource {
        var data: [UInt8]
        var description = AudioStreamPacketDescription()
        var consumed = false
        init(_ data: [UInt8]) { self.data = data }
    }

    /// Ein komprimiertes Paket durch den Dekoder; `nil` bei einem Fehler.
    private static func convertPacket(_ converter: AudioConverterRef, packet: [UInt8], channels: Int, maxFrames: Int) -> [Float]? {
        let source = PacketSource(packet)
        var output = [Float](repeating: 0, count: maxFrames * channels)
        var frames = UInt32(maxFrames)
        let status = output.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, { _, packets, data, descriptions, user in
                let source = Unmanaged<PacketSource>.fromOpaque(user!).takeUnretainedValue()
                if source.consumed {
                    packets.pointee = 0
                    return DABAudioDecoder.noMoreData
                }
                source.consumed = true
                source.data.withUnsafeMutableBytes { bytes in
                    data.pointee.mBuffers.mData = bytes.baseAddress
                    data.pointee.mBuffers.mDataByteSize = UInt32(bytes.count)
                    data.pointee.mBuffers.mNumberChannels = 0
                }
                source.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                  mDataByteSize: UInt32(source.data.count))
                if let descriptions {
                    withUnsafeMutablePointer(to: &source.description) { descriptions.pointee = $0 }
                }
                packets.pointee = 1
                return noErr
            }, Unmanaged.passUnretained(source).toOpaque(), &frames, &list, nil)
        }
        guard status == noErr || status == noMoreData else { return nil }
        return Array(output.prefix(Int(frames) * channels))
    }

    private final class PCMSource {
        var samples: [Float]
        var consumed = false
        init(_ samples: [Float]) { self.samples = samples }
    }

    /// Stereo-PCM durch den Ratenwandler.
    private static func convertPCM(_ converter: AudioConverterRef, _ samples: [Float], maxFrames: Int) -> [Float] {
        let source = PCMSource(samples)
        var result: [Float] = []
        while true {
            var output = [Float](repeating: 0, count: maxFrames * 2)
            var frames = UInt32(maxFrames)
            let status = output.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, { _, packets, data, _, user in
                    let source = Unmanaged<PCMSource>.fromOpaque(user!).takeUnretainedValue()
                    if source.consumed || source.samples.isEmpty {
                        packets.pointee = 0
                        return DABAudioDecoder.noMoreData
                    }
                    source.consumed = true
                    source.samples.withUnsafeMutableBytes { bytes in
                        data.pointee.mBuffers.mData = bytes.baseAddress
                        data.pointee.mBuffers.mDataByteSize = UInt32(bytes.count)
                        data.pointee.mBuffers.mNumberChannels = 2
                    }
                    packets.pointee = UInt32(source.samples.count / 2)
                    return noErr
                }, Unmanaged.passUnretained(source).toOpaque(), &frames, &list, nil)
            }
            result += output.prefix(Int(frames) * 2)
            if status != noErr || frames == 0 { break }
        }
        return result
    }

    /// Eigener Status „vorerst keine Daten“ – der Wandler behält seinen Zustand.
    static let noMoreData: OSStatus = 0x6E6F6D6F   // 'nomo'
}
