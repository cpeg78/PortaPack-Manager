import AudioToolbox
import Foundation
@testable import PortaPackManager

/// Erzeugt AAC-Access-Units mit dem Encoder von AudioToolbox und baut
/// daraus DAB+-Superframes und Logikrahmen.
enum DABAudioTestSupport {
    /// Kodiert einen Sinuston zu AAC-Paketen (ohne ADTS).
    static func encodeTone(frequency: Double, seconds: Double, sampleRate: Double, channels: Int,
                           he: Bool, bitrate: UInt32) -> [[UInt8]] {
        var pcmFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var aacFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: he ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: he ? 2048 : 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&pcmFormat, &aacFormat, &converter) == noErr, let converter else { return [] }
        defer { AudioConverterDispose(converter) }
        var rate = bitrate
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, 4, &rate)

        let frames = Int(seconds * sampleRate)
        var pcm = [Float](repeating: 0, count: frames * channels)
        for n in 0..<frames {
            let v = Float(0.3 * sin(2 * .pi * frequency * Double(n) / sampleRate))
            for c in 0..<channels { pcm[n * channels + c] = v }
        }
        final class Source { var pcm: [Float]; var offset = 0; let channels: Int
            init(_ p: [Float], _ c: Int) { pcm = p; channels = c } }
        let source = Source(pcm, channels)
        var packets: [[UInt8]] = []
        while true {
            var buffer = [UInt8](repeating: 0, count: 8192)
            var count: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, { _, n, data, _, user in
                    let s = Unmanaged<Source>.fromOpaque(user!).takeUnretainedValue()
                    let available = (s.pcm.count - s.offset) / s.channels
                    guard available > 0 else { n.pointee = 0; return noErr }
                    let take = min(available, 1024)
                    s.pcm.withUnsafeMutableBufferPointer { p in
                        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(p.baseAddress! + s.offset)
                    }
                    data.pointee.mBuffers.mDataByteSize = UInt32(take * s.channels * 4)
                    data.pointee.mBuffers.mNumberChannels = UInt32(s.channels)
                    s.offset += take * s.channels
                    n.pointee = UInt32(take)
                    return noErr
                }, Unmanaged.passUnretained(source).toOpaque(), &count, &list, &description)
            }
            guard status == noErr, count > 0 else { break }
            packets.append(Array(buffer.prefix(Int(description.mDataByteSize))))
        }
        return packets
    }

    /// Superframe (110 · s Datenbytes + RS) aus AUs; die letzte AU wird bis
    /// zum Ende aufgefüllt. Liefert `nil`, wenn die AUs nicht hineinpassen.
    static func superframe(units: [[UInt8]], formatByte: UInt8, s: Int) -> [UInt8]? {
        let format = DABPlusFormat(byte: formatByte)
        precondition(units.count == format.accessUnits)
        let dataLength = 110 * s
        var starts = [format.firstAccessUnitStart]
        for unit in units.dropLast() { starts.append(starts.last! + unit.count + 2) }
        guard starts.last! + units.last!.count + 2 <= dataLength else { return nil }
        var sf = [UInt8](repeating: 0, count: dataLength)
        sf[2] = formatByte
        // AU-Startadressen (12 Bit, ab der zweiten AU)
        var writer = DABAudioDecoder.BitWriter()
        for start in starts.dropFirst() { writer.put(start, 12) }
        for (i, byte) in writer.bytes.enumerated() { sf[3 + i] = byte }
        let fire = DABCRC.fire(sf[2..<11])
        sf[0] = UInt8(fire >> 8); sf[1] = UInt8(fire & 0xFF)
        for (i, unit) in units.enumerated() {
            let start = starts[i]
            let end = i + 1 < units.count ? starts[i + 1] : dataLength
            var body = unit + [UInt8](repeating: 0, count: end - start - 2 - unit.count)
            let crc = DABCRC.ccitt(body)
            body += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            sf.replaceSubrange(start..<end, with: body)
        }
        // RS-Prüfbytes, Codewörter verschränkt
        var full = sf + [UInt8](repeating: 0, count: 10 * s)
        for j in 0..<s {
            let data = (0..<110).map { sf[j + $0 * s] }
            let codeword = DABReedSolomon.encode(data)
            for k in 110..<120 { full[j + k * s] = codeword[k] }
        }
        return full
    }

    /// Dominante Frequenz über Nulldurchgänge.
    static func dominantFrequency(_ x: [Float], rate: Double) -> Double {
        let settled = Array(x.dropFirst(x.count / 4))
        guard settled.count > 100 else { return 0 }
        var crossings = 0
        for k in 1..<settled.count where settled[k - 1] < 0 && settled[k] >= 0 { crossings += 1 }
        return Double(crossings) / (Double(settled.count) / rate)
    }
}
