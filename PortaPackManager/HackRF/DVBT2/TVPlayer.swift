import AVFoundation
import CoreMedia
import Foundation

/// Gibt einen Dienst wieder: Video (HEVC/H.264) dekodiert der
/// `AVSampleBufferDisplayLayer` in Hardware, Ton wird zu PCM dekodiert und
/// über einen `AVSampleBufferAudioRenderer` ausgegeben; ein gemeinsamer
/// Synchronizer hält beides auf der Zeitachse der PTS.
///
/// Die Daten kommen von der Empfangswarteschlange; nur die Erzeugung findet
/// auf dem Main Actor statt.
final class TVPlayer: @unchecked Sendable {
    struct Statistics: Sendable, Equatable {
        var videoFrames = 0
        var audioFrames = 0
        var videoErrors = 0
        var audioErrors = 0
        var width = 0
        var height = 0
        var codec = ""
        var audioCodec = ""
        var playing = false
    }

    let displayLayer: AVSampleBufferDisplayLayer
    /// Renderer des Layers; einmal auf dem Main Actor geholt, danach von der Empfangswarteschlange benutzt.
    private let videoRenderer: AVSampleBufferVideoRenderer
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let lock = NSLock()
    private var stats = Statistics()

    private var videoKind: TSStream.Kind?
    private var audioDecoder: TVAudioDecoder?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [UInt8: [UInt8]] = [:]       // NAL-Typ → Einheit
    private var waitingForKeyFrame = true
    private var audioFormat: CMAudioFormatDescription?
    private var audioFormatRate: Double = 0
    private var started = false
    private var firstVideoPTS: CMTime?
    private var firstAudioPTS: CMTime?
    private var lastPTS: [Int: Int64] = [:]
    private var bufferedAudio: Double = 0

    @MainActor
    init() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        videoRenderer = displayLayer.sampleBufferRenderer
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
    }

    var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = newValue }
    }

    var statistics: Statistics { lock.withLock { stats } }

    /// Neuen Dienst wählen (Ströme aus der PMT).
    func select(video: TSStream?, audio: TSStream?) {
        lock.withLock {
            videoKind = video?.kind
            audioDecoder = audio.map { TVAudioDecoder(kind: $0.kind) }
            formatDescription = nil
            parameterSets = [:]
            waitingForKeyFrame = true
            audioFormat = nil
            started = false
            firstVideoPTS = nil
            firstAudioPTS = nil
            lastPTS = [:]
            bufferedAudio = 0
            stats = Statistics()
            stats.codec = video?.kind.rawValue ?? ""
            stats.audioCodec = audio?.kind.rawValue ?? ""
        }
        synchronizer.setRate(0, time: .zero)
        videoRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audioRenderer.flush()
    }

    func stop() {
        select(video: nil, audio: nil)
    }

    // MARK: - Eingang

    func handleVideo(_ pes: PESPacket) {
        guard let kind = lock.withLock({ videoKind }), let pts = pes.pts else { return }
        let presentation = time(pts, stream: 0)
        let decode = pes.dts.map { time($0, stream: 0, update: false) } ?? presentation
        let units = Self.nalUnits(pes.payload)
        var sample: [UInt8] = []
        var keyFrame = false
        var parametersChanged = false
        lock.lock()
        for unit in units where !unit.isEmpty {
            let type: UInt8
            switch kind {
            case .hevc:
                type = (unit[0] >> 1) & 0x3F
                if (32...34).contains(type) {
                    if parameterSets[type] != unit { parameterSets[type] = unit; parametersChanged = true }
                    continue
                }
                if type == 35 { continue }                  // Zugriffseinheiten-Trenner
                if (16...23).contains(type) { keyFrame = true }
            case .h264:
                type = unit[0] & 0x1F
                if type == 7 || type == 8 {
                    if parameterSets[type] != unit { parameterSets[type] = unit; parametersChanged = true }
                    continue
                }
                if type == 9 { continue }
                if type == 5 { keyFrame = true }
            default:
                lock.unlock()
                return
            }
            let length = UInt32(unit.count)
            sample += [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
            sample += unit
        }
        if parametersChanged || formatDescription == nil { formatDescription = makeVideoFormat(kind) }
        let format = formatDescription
        let waiting = waitingForKeyFrame && !keyFrame
        if keyFrame { waitingForKeyFrame = false }
        lock.unlock()
        guard let format, !sample.isEmpty, !waiting else { return }

        var block: CMBlockBuffer?
        let count = sample.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        sample.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentation, decodeTimeStamp: decode)
        var size = count
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr, let buffer else { return }
        if !keyFrame, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = videoRenderer
        if renderer.status == .failed {
            renderer.flush()
            lock.withLock { stats.videoErrors += 1; waitingForKeyFrame = true }
            return
        }
        renderer.enqueue(buffer)
        lock.withLock {
            stats.videoFrames += 1
            if firstVideoPTS == nil { firstVideoPTS = presentation }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            stats.width = Int(dimensions.width); stats.height = Int(dimensions.height)
        }
        startIfReady()
    }

    func handleAudio(_ pes: PESPacket) {
        guard let decoder = lock.withLock({ audioDecoder }) else { return }
        var presentation = pes.pts.map { time($0, stream: 1) }
        let blocks = decoder.decode(pes.payload)
        let rate = decoder.sampleRate
        for pcm in blocks where !pcm.isEmpty {
            let frames = pcm.count / 2
            guard let buffer = makeAudioBuffer(pcm, frames: frames, rate: rate, time: presentation ?? .invalid) else { continue }
            if audioRenderer.status == .failed { audioRenderer.flush() }
            audioRenderer.enqueue(buffer)
            lock.withLock {
                stats.audioFrames += 1
                stats.audioErrors = decoder.errors
                if firstAudioPTS == nil, let presentation { firstAudioPTS = presentation }
                bufferedAudio += Double(frames) / rate
            }
            if let p = presentation { presentation = p + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)) }
        }
        startIfReady()
    }

    /// Wiedergabe beginnen, sobald etwas Vorrat da ist (Ton führt).
    private func startIfReady() {
        let decision: CMTime? = lock.withLock {
            guard !started else { return nil }
            let hasAudio = audioDecoder != nil, hasVideo = videoKind != nil
            if hasAudio {
                guard bufferedAudio > 0.8, let audio = firstAudioPTS else { return nil }
                if hasVideo, firstVideoPTS == nil, bufferedAudio < 3 { return nil }
                started = true
                stats.playing = true
                if let video = firstVideoPTS { return CMTimeMaximum(audio, video) }
                return audio
            }
            if hasVideo, stats.videoFrames > 25, let video = firstVideoPTS {
                started = true
                stats.playing = true
                return video
            }
            return nil
        }
        if let start = decision { synchronizer.setRate(1, time: start) }
    }

    // MARK: - Hilfen

    /// 90-kHz-PTS → CMTime, mit Behandlung des 33-Bit-Überlaufs.
    private func time(_ value: Int64, stream: Int, update: Bool = true) -> CMTime {
        lock.lock()
        var v = value
        if let last = lastPTS[stream] {
            let wrap: Int64 = 1 << 33
            while v - last > wrap / 2 { v -= wrap }
            while last - v > wrap / 2 { v += wrap }
        }
        if update { lastPTS[stream] = v }
        lock.unlock()
        return CMTime(value: v, timescale: 90_000)
    }

    private func makeVideoFormat(_ kind: TSStream.Kind) -> CMVideoFormatDescription? {
        let sets: [[UInt8]]
        switch kind {
        case .hevc:
            guard let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34] else { return nil }
            sets = [vps, sps, pps]
        case .h264:
            guard let sps = parameterSets[7], let pps = parameterSets[8] else { return nil }
            sets = [sps, pps]
        default:
            return nil
        }
        var description: CMVideoFormatDescription?
        let datas = sets.map { Data($0) }
        let status: OSStatus = withPointers(datas) { pointers, sizes in
            if kind == .hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, extensions: nil,
                                                                           formatDescriptionOut: &description)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                       parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                       nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    private func withPointers<R>(_ datas: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        var copies: [UnsafeMutablePointer<UInt8>] = []
        for d in datas {
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: copy, count: d.count)
            copies.append(copy)
            pointers.append(UnsafePointer(copy))
        }
        defer { copies.forEach { $0.deallocate() } }
        let sizes = datas.map(\.count)
        return pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) } }
    }

    private func makeAudioBuffer(_ pcm: [Float], frames: Int, rate: Double, time: CMTime) -> CMSampleBuffer? {
        if audioFormat == nil || audioFormatRate != rate {
            var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                   mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            audioFormat = format
            audioFormatRate = rate
        }
        guard let format = audioFormat else { return nil }
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                    sampleCount: frames, presentationTimeStamp: time,
                                                                    packetDescriptions: nil, sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }

    /// Annex-B-Strom → NAL-Einheiten (ohne Startcodes).
    static func nalUnits(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var units: [[UInt8]] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    var end = i
                    while end > s, bytes[end - 1] == 0 { end -= 1 }
                    units.append(Array(bytes[s..<end]))
                }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if let s = start, s < bytes.count { units.append(Array(bytes[s...])) }
        return units
    }
}
