import AudioToolbox
import Foundation

/// Fernsehton → Stereo-PCM (Float, verschränkt) mit AudioToolbox:
/// AAC (ADTS), HE-AAC (LATM/LOAS), MPEG-1 Layer II, AC-3 und E-AC-3.
final class TVAudioDecoder {
    struct Frame {
        var payload: [UInt8]
        var samples: Int
    }

    let kind: TSStream.Kind
    private(set) var sampleRate: Double = 48_000
    private(set) var errors = 0
    private var converter: AudioConverterRef?
    private var configuration: [UInt8] = []
    private var pending: [UInt8] = []

    init(kind: TSStream.Kind) {
        self.kind = kind
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    func reset() {
        pending = []
        if let converter { AudioConverterReset(converter) }
    }

    /// PES-Nutzdaten → PCM-Blöcke (Stereo, verschränkt) und Abtastrate.
    func decode(_ data: Data) -> [[Float]] {
        pending += data
        var out: [[Float]] = []
        while let frame = nextFrame() {
            guard let converter else { continue }
            if let pcm = Self.convert(converter, packet: frame.payload, maxFrames: max(frame.samples, 4096)) {
                out.append(pcm)
            } else {
                errors += 1
            }
        }
        if pending.count > 65_536 { pending.removeFirst(pending.count - 8192) }
        return out
    }

    // MARK: - Rahmen finden

    private func nextFrame() -> Frame? {
        switch kind {
        case .aacADTS: return nextADTS()
        case .aacLATM: return nextLATM()
        case .mpegAudio: return nextMPEG()
        case .ac3, .eac3: return nextAC3()
        default: pending = []; return nil
        }
    }

    private func sync(_ match: (Int) -> Bool, minimum: Int) -> Int? {
        var i = 0
        while i + minimum <= pending.count {
            if match(i) { if i > 0 { pending.removeFirst(i) }; return 0 }
            i += 1
        }
        if i > 0 { pending.removeFirst(max(0, i - 1)) }
        return nil
    }

    private static let aacRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8000, 7350]

    private func nextADTS() -> Frame? {
        // Schleife statt Rekursion: viele ungültige Rahmen hintereinander
        // (Funkdaten) liefen sonst den Stapel voll.
        while true {
            guard sync({ self.pending[$0] == 0xFF && self.pending[$0 + 1] & 0xF6 == 0xF0 }, minimum: 7) != nil else { return nil }
            let p = pending
            let protectionAbsent = p[1] & 1 == 1
            let profile = Int(p[2] >> 6) + 1
            let rateIndex = Int(p[2] >> 2) & 0x0F
            let channels = Int(p[2] & 1) << 2 | Int(p[3] >> 6)
            let length = Int(p[3] & 3) << 11 | Int(p[4]) << 3 | Int(p[5] >> 5)
            let header = protectionAbsent ? 7 : 9
            guard length > header, rateIndex < 13 else { pending.removeFirst(); continue }
            guard pending.count >= length else { return nil }
            var writer = BitWriter()
            writer.put(profile, 5); writer.put(rateIndex, 4); writer.put(max(1, channels), 4); writer.put(0, 3)
            configureAAC(asc: writer.bytes, rate: Double(Self.aacRates[rateIndex]), objectType: profile, channels: max(1, channels))
            let frame = Array(pending[header..<length])
            pending.removeFirst(length)
            return Frame(payload: frame, samples: 1024)
        }
    }

    /// LOAS/LATM (ISO 14496-3, 1.7): AudioSyncStream mit AudioMuxElement(1).
    private func nextLATM() -> Frame? {
        // Schleife statt Rekursion: viele ungültige Rahmen hintereinander
        // (Funkdaten) liefen sonst den Stapel voll.
        while true {
            guard sync({ self.pending[$0] == 0x56 && self.pending[$0 + 1] & 0xE0 == 0xE0 }, minimum: 3) != nil else { return nil }
            let length = Int(pending[1] & 0x1F) << 8 | Int(pending[2])
            guard pending.count >= 3 + length else { return nil }
            let element = Array(pending[3..<(3 + length)])
            pending.removeFirst(3 + length)
            var r = LATMBitReader(element)
            let useSameStreamMux = r.read(1) == 1
            if !useSameStreamMux {
                guard parseStreamMuxConfig(&r) else { continue }
            }
            guard converter != nil else { continue }
            // PayloadLengthInfo (frameLengthType 0): Summe von Bytes bis < 255.
            var payloadLength = 0
            while true {
                let b = r.read(8)
                payloadLength += b
                if b != 255 || r.overrun { break }
            }
            guard !r.overrun, payloadLength > 0, payloadLength <= element.count else { continue }
            var payload = [UInt8](repeating: 0, count: payloadLength)
            for i in 0..<payloadLength { payload[i] = UInt8(r.read(8)) }
            guard !r.overrun else { continue }
            return Frame(payload: payload, samples: 2048)
        }
    }

    private func parseStreamMuxConfig(_ r: inout LATMBitReader) -> Bool {
        let version = r.read(1)
        if version == 1 { guard r.read(1) == 0 else { return false }; _ = latmValue(&r) }
        _ = r.read(1)                     // allStreamsSameTimeFraming
        guard r.read(6) == 0, r.read(4) == 0, r.read(3) == 0 else { return false }   // 1 Unterrahmen, 1 Programm, 1 Schicht
        let ascStart = r.position
        var ascLength = 0
        if version == 1 { ascLength = latmValue(&r) }
        // ascLength (bis 32 Bit) kommt aus der Luft: eine echte AudioSpecificConfig
        // hat nur wenige Byte – große Werte liefen minutenlang durch die Kopierschleife.
        guard ascLength >= 0, ascLength <= Self.maxASCBits, !r.overrun else { return false }
        let start = r.position
        guard let parsed = Self.parseASC(&r) else { return false }
        let used = r.position - start
        if version == 1 { r.skip(ascLength - used) }
        let ascBits = (version == 1 ? ascLength : used)
        guard ascBits <= Self.maxASCBits, !r.overrun else { return false }
        var copy = LATMBitReader(r.data)
        copy.skip(version == 1 ? start : ascStart)
        var writer = BitWriter()
        var remaining = ascBits
        while remaining > 0 { let n = min(8, remaining); writer.put(copy.read(n), n); remaining -= n }
        guard r.read(3) == 0 else { return false }   // frameLengthType 0
        _ = r.read(8)                                 // latmBufferFullness
        if r.read(1) == 1 { if version == 1 { _ = latmValue(&r) } else { while r.read(1) == 1 { _ = r.read(8) }; _ = r.read(8) } }
        if r.read(1) == 1 { _ = r.read(8) }           // CRC
        configureAAC(asc: writer.bytes, rate: parsed.rate, objectType: parsed.objectType, channels: parsed.channels)
        return true
    }

    static let maxASCBits = 512

    private func latmValue(_ r: inout LATMBitReader) -> Int {
        let bytes = r.read(2) + 1
        var value = 0
        for _ in 0..<bytes { value = value << 8 | r.read(8) }
        return value
    }

    /// Liest eine AudioSpecificConfig: Objekttyp, Ausgaberate, Kanäle.
    private static func parseASC(_ r: inout LATMBitReader) -> (objectType: Int, rate: Double, channels: Int)? {
        func objectType() -> Int { let t = r.read(5); return t == 31 ? 32 + r.read(6) : t }
        func rate() -> Double { let i = r.read(4); return i == 15 ? Double(r.read(24)) : (i < 13 ? Double(aacRates[i]) : 0) }
        var type = objectType()
        var sampleRate = rate()
        let channels = r.read(4)
        if type == 5 || type == 29 {
            // Explizites SBR/PS: Ausgaberate, dann der Kern (AAC LC).
            sampleRate = rate()
            guard objectType() == 2 else { return nil }
        } else if type == 2 && sampleRate <= 24_000 {
            // Implizites SBR (abwärtskompatibel signalisiert): bei niedriger Kernrate ist es fast immer HE-AAC.
            type = 5
            sampleRate *= 2
        }
        guard type == 2 || type == 5 || type == 29 else { return nil }
        // GASpecificConfig: frameLength, dependsOnCoreCoder, extension
        _ = r.read(1)
        if r.read(1) == 1 { _ = r.read(14) }
        _ = r.read(1)
        return (type, sampleRate, max(1, channels))
    }

    private static let mpegRates = [[44_100, 48_000, 32_000], [22_050, 24_000, 16_000]]
    private static let mpegBitrates = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
    private static let mpeg2Bitrates = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    private func nextMPEG() -> Frame? {
        // Schleife statt Rekursion: viele ungültige Rahmen hintereinander
        // (Funkdaten) liefen sonst den Stapel voll.
        while true {
            guard sync({ self.pending[$0] == 0xFF && self.pending[$0 + 1] & 0xE6 == 0xE4 }, minimum: 4) != nil else { return nil }
            let mpeg1 = pending[1] & 0x08 != 0
            let bitrateIndex = Int(pending[2] >> 4), rateIndex = Int(pending[2] >> 2) & 3
            let padding = Int(pending[2] >> 1) & 1
            let channels = pending[3] >> 6 == 3 ? 1 : 2
            guard bitrateIndex > 0, bitrateIndex < 15, rateIndex < 3 else { pending.removeFirst(); continue }
            let rate = Self.mpegRates[mpeg1 ? 0 : 1][rateIndex]
            let bitrate = (mpeg1 ? Self.mpegBitrates : Self.mpeg2Bitrates)[bitrateIndex] * 1000
            let length = 144 * bitrate / rate + padding
            guard pending.count >= length else { return nil }
            if converter == nil || sampleRate != Double(rate) {
                var input = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatMPEGLayer2, mFormatFlags: 0,
                                                        mBytesPerPacket: 0, mFramesPerPacket: 1152, mBytesPerFrame: 0,
                                                        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
                makeConverter(&input, cookie: [])
            }
            let frame = Array(pending[0..<length])
            pending.removeFirst(length)
            return Frame(payload: frame, samples: 1152)
        }
    }

    private static let ac3Sizes: [[Int]] = [
        [64, 69, 96], [64, 70, 96], [80, 87, 120], [80, 88, 120], [96, 104, 144], [96, 105, 144], [112, 121, 168],
        [112, 122, 168], [128, 139, 192], [128, 140, 192], [160, 174, 240], [160, 175, 240], [192, 208, 288],
        [192, 209, 288], [224, 243, 336], [224, 244, 336], [256, 278, 384], [256, 279, 384], [320, 348, 480],
        [320, 349, 480], [384, 417, 576], [384, 418, 576], [448, 487, 672], [448, 488, 672], [512, 557, 768],
        [512, 558, 768], [640, 696, 960], [640, 697, 960], [768, 835, 1152], [768, 836, 1152], [896, 975, 1344],
        [896, 976, 1344], [1024, 1114, 1536], [1024, 1115, 1536], [1152, 1253, 1728], [1152, 1254, 1728],
        [1280, 1393, 1920], [1280, 1394, 1920],
    ]

    private func nextAC3() -> Frame? {
        // Schleife statt Rekursion: viele ungültige Rahmen hintereinander
        // (Funkdaten) liefen sonst den Stapel voll.
        while true {
            guard sync({ self.pending[$0] == 0x0B && self.pending[$0 + 1] == 0x77 }, minimum: 6) != nil else { return nil }
            let bsid = Int(pending[5] >> 3)
            var length: Int
            var rate: Int
            var samples = 1536
            if bsid > 10 {
                // E-AC-3: frmsiz in 16-Bit-Wörtern
                length = (Int(pending[2] & 0x07) << 8 | Int(pending[3]) + 1) * 2
                let fscod = Int(pending[4] >> 6)
                if fscod == 3 {
                    rate = [24_000, 22_050, 16_000, 0][Int(pending[4] >> 4) & 3]
                } else {
                    rate = [48_000, 44_100, 32_000][fscod]
                    samples = [1, 2, 3, 6][Int(pending[4] >> 4) & 3] * 256
                }
            } else {
                let fscod = Int(pending[4] >> 6), frmsizecod = Int(pending[4] & 0x3F)
                guard fscod < 3, frmsizecod < 38 else { pending.removeFirst(); continue }
                rate = [48_000, 44_100, 32_000][fscod]
                length = Self.ac3Sizes[frmsizecod][fscod] * 2
            }
            guard rate > 0, length > 6 else { pending.removeFirst(); continue }
            guard pending.count >= length else { return nil }
            if converter == nil || sampleRate != Double(rate) {
                var input = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: bsid > 10 ? kAudioFormatEnhancedAC3 : kAudioFormatAC3,
                                                        mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(samples),
                                                        mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
                makeConverter(&input, cookie: [])
            }
            let frame = Array(pending[0..<length])
            pending.removeFirst(length)
            return Frame(payload: frame, samples: samples)
        }
    }

    // MARK: - Dekoder

    private func configureAAC(asc: [UInt8], rate: Double, objectType: Int, channels: Int) {
        guard asc != configuration || converter == nil else { return }
        configuration = asc
        let format: AudioFormatID = objectType == 29 ? kAudioFormatMPEG4AAC_HE_V2 : (objectType == 5 ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC)
        var input = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: format, mFormatFlags: 0, mBytesPerPacket: 0,
                                                mFramesPerPacket: objectType == 2 ? 1024 : 2048, mBytesPerFrame: 0,
                                                mChannelsPerFrame: UInt32(objectType == 29 ? 2 : channels), mBitsPerChannel: 0, mReserved: 0)
        // Längen als ein Byte: geklemmt, damit eine übergroße ASC nicht abstürzt (dann scheitert nur der Wandler).
        let specific: [UInt8] = [0x05, UInt8(clamping: asc.count)] + asc
        let decoderConfig: [UInt8] = [0x04, UInt8(clamping: 13 + specific.count), 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + specific
        let esds: [UInt8] = [0x03, UInt8(clamping: 3 + decoderConfig.count + 3), 0, 0, 0] + decoderConfig + [0x06, 0x01, 0x02]
        makeConverter(&input, cookie: esds)
    }

    private func makeConverter(_ input: inout AudioStreamBasicDescription, cookie: [UInt8]) {
        if let converter { AudioConverterDispose(converter) }
        converter = nil
        sampleRate = input.mSampleRate
        var output = AudioStreamBasicDescription(
            mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var created: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &created) == noErr, let created else { errors += 1; return }
        if !cookie.isEmpty {
            _ = cookie.withUnsafeBytes { AudioConverterSetProperty(created, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!) }
        }
        // HE-AAC liefert die doppelte Rate; die tatsächliche Ausgabe abfragen.
        var actual = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioConverterGetProperty(created, kAudioConverterCurrentOutputStreamDescription, &size, &actual) == noErr, actual.mSampleRate > 0 {
            sampleRate = actual.mSampleRate
        }
        converter = created
    }

    /// Eigener Status „vorerst keine Daten“ – der Wandler behält seinen Zustand.
    private static let noMoreData: OSStatus = 0x6E6F6D6F   // 'nomo'

    private struct BitWriter {
        var bytes: [UInt8] = []
        private var count = 0
        mutating func put(_ value: Int, _ bits: Int) {
            for i in stride(from: bits - 1, through: 0, by: -1) {
                if count % 8 == 0 { bytes.append(0) }
                if value >> i & 1 == 1 { bytes[bytes.count - 1] |= UInt8(0x80 >> (count % 8)) }
                count += 1
            }
        }
    }

    private final class PacketSource {
        var data: [UInt8]
        var description = AudioStreamPacketDescription()
        var consumed = false
        init(_ data: [UInt8]) { self.data = data }
    }

    private static func convert(_ converter: AudioConverterRef, packet: [UInt8], maxFrames: Int) -> [Float]? {
        let source = PacketSource(packet)
        var output = [Float](repeating: 0, count: maxFrames * 2)
        var frames = UInt32(maxFrames)
        let status = output.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, { _, packets, data, descriptions, user in
                let source = Unmanaged<PacketSource>.fromOpaque(user!).takeUnretainedValue()
                if source.consumed { packets.pointee = 0; return TVAudioDecoder.noMoreData }
                source.consumed = true
                source.data.withUnsafeMutableBytes { bytes in
                    data.pointee.mBuffers.mData = bytes.baseAddress
                    data.pointee.mBuffers.mDataByteSize = UInt32(bytes.count)
                    data.pointee.mBuffers.mNumberChannels = 0
                }
                source.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(source.data.count))
                if let descriptions { withUnsafeMutablePointer(to: &source.description) { descriptions.pointee = $0 } }
                packets.pointee = 1
                return noErr
            }, Unmanaged.passUnretained(source).toOpaque(), &frames, &list, nil)
        }
        guard status == noErr || status == Self.noMoreData, frames > 0 else { return nil }
        return Array(output.prefix(Int(frames) * 2))
    }
}

/// Bitleser für LATM (MSB zuerst).
struct LATMBitReader {
    let data: [UInt8]
    private(set) var position = 0
    private(set) var overrun = false

    init(_ data: [UInt8]) { self.data = data }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byte = position / 8
            if byte >= data.count { overrun = true; value <<= 1; position += 1; continue }
            value = value << 1 | Int(data[byte] >> (7 - UInt8(position % 8)) & 1)
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) { position += max(0, count); if position > data.count * 8 { overrun = true } }
}
