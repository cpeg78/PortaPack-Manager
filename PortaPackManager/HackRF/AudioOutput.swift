import AVFoundation
import Foundation

/// Threadsicherer Ringpuffer für Stereo-Audio (Bildpaare links/rechts).
final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var left: [Float]
    private var right: [Float]
    private var readIndex = 0
    private var count = 0

    /// `capacity` in Bildern (ein Bild = ein Wert je Kanal).
    init(capacity: Int) {
        left = [Float](repeating: 0, count: capacity)
        right = [Float](repeating: 0, count: capacity)
    }

    /// Gefüllte Bilder.
    var fill: Int { lock.withLock { count } }

    /// Mono: derselbe Wert auf beiden Kanälen.
    func write(_ samples: [Float]) {
        write(left: samples, right: samples)
    }

    func write(left l: [Float], right r: [Float]) {
        lock.withLock {
            let capacity = left.count
            for n in 0..<min(l.count, r.count) {
                let writeIndex = (readIndex + count) % capacity
                left[writeIndex] = l[n]
                right[writeIndex] = r[n]
                if count < capacity { count += 1 } else { readIndex = (readIndex + 1) % capacity }
            }
        }
    }

    /// Liest bis zu `frames` Bilder; fehlende werden mit Stille aufgefüllt.
    /// `r` darf `nil` sein (Monoausgabe).
    func read(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>?, frames: Int) {
        lock.withLock {
            let capacity = left.count
            let available = min(frames, count)
            for n in 0..<available {
                let index = (readIndex + n) % capacity
                l[n] = left[index]
                r?[n] = right[index]
            }
            for n in available..<frames {
                l[n] = 0
                r?[n] = 0
            }
            readIndex = (readIndex + available) % capacity
            count -= available
        }
    }

    func clear() { lock.withLock { readIndex = 0; count = 0 } }
}

/// Spielt einen Ringpuffer (48 kHz, stereo) über die Standardausgabe ab.
final class AudioOutput: @unchecked Sendable {
    let buffer = AudioRingBuffer(capacity: 48_000)   // 1 s
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    func start() throws {
        guard source == nil else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: RadioDemodulator.audioRate, channels: 2)!
        let buffer = buffer
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            // Standardformat: ein Puffer je Kanal (nicht verschränkt).
            let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let second = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
            buffer.read(left: first, right: second, frames: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        source = node
    }

    func stop() {
        engine.stop()
        if let source {
            engine.detach(source)
        }
        source = nil
        buffer.clear()
    }
}
