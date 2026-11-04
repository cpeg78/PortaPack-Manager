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
///
/// Wechselt das Ausgabegerät (Bluetooth-Kopfhörer, Monitor mit Lautsprechern),
/// hält `AVAudioEngine` an und meldet `AVAudioEngineConfigurationChange` –
/// dann wird neu verbunden und gestartet, sonst blieb der Ton stumm
/// (Review 01.11.2026). `start`/`stop` laufen auf dem Main Actor, der
/// Neustart deshalb auch.
final class AudioOutput: @unchecked Sendable {
    let buffer = AudioRingBuffer(capacity: 48_000)   // 1 s
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let format = AVAudioFormat(standardFormatWithSampleRate: RadioDemodulator.audioRate, channels: 2)!
    private var configurationObserver: NSObjectProtocol?

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func start() throws {
        guard source == nil else { return }
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
        do {
            try engine.start()
        } catch {
            // Sonst hinge der nächste Start einen zweiten Knoten an.
            engine.detach(node)
            throw error
        }
        source = node
        if configurationObserver == nil {
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.restartAfterConfigurationChange()
            }
        }
    }

    /// Ausgabegerät gewechselt: Die Engine steht – neu verbinden und starten.
    private func restartAfterConfigurationChange() {
        guard let source, !engine.isRunning else { return }
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop()
        if let source {
            engine.detach(source)
        }
        source = nil
        buffer.clear()
    }
}
