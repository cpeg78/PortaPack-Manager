import Accelerate
import Foundation

/// 802.11-Empfang über den HackRF bei 20 MS/s, Mitte auf dem Kanal (Träger 0
/// ist bei OFDM unbelegt; der Gleichanteil wird je Block abgezogen). Hält
/// einen Puffer über Blockgrenzen und lässt DSSS- und OFDM-Erkennung darüber
/// laufen; angefangene Rahmen warten auf den nächsten Block.
final class WLANReceiver {
    static let sampleRate = 20_000_000.0
    /// WLAN-Kanalmitten in MHz (2,4 GHz: 1–14, 5 GHz: 32–177).
    static func frequencyMHz(channel: Int) -> Double {
        switch channel {
        case 1...13: 2407 + 5 * Double(channel)
        case 14: 2484
        default: 5000 + 5 * Double(channel)
        }
    }

    let dsss = WLANDSSSDemodulator()
    let ofdm = WLANOFDMDemodulator()

    private var re: [Float] = []
    private var im: [Float] = []
    /// Lesepositionen der beiden Erkennungen im Puffer – getrennt, damit ein
    /// angefangener DSSS-Burst den OFDM-Teil nicht denselben Rahmen zweimal
    /// finden lässt (und umgekehrt).
    private var dsssPosition = 0
    private var ofdmPosition = 0
    private var noise: Float = 0
    private(set) var frames = 0

    var noiseDB: Double { 10 * log10(Double(max(noise, 1e-12))) }

    func reset() {
        re = []
        im = []
        dsssPosition = 0
        ofdmPosition = 0
        noise = 0
    }

    func process(_ block: Data) -> [WLANPacket] {
        let count = block.count / 2
        guard count > 0 else { return [] }
        var blockRe = [Float](repeating: 0, count: count), blockIm = [Float](repeating: 0, count: count)
        block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int8.self)
            vDSP_vflt8(p.baseAddress!, 2, &blockRe, 1, vDSP_Length(count))
            vDSP_vflt8(p.baseAddress! + 1, 2, &blockIm, 1, vDSP_Length(count))
        }
        var scale = Float(1) / 128, meanRe: Float = 0, meanIm: Float = 0
        vDSP_meanv(blockRe, 1, &meanRe, vDSP_Length(count))
        vDSP_meanv(blockIm, 1, &meanIm, vDSP_Length(count))
        var offsetRe = -meanRe, offsetIm = -meanIm
        vDSP_vsadd(blockRe, 1, &offsetRe, &blockRe, 1, vDSP_Length(count))
        vDSP_vsadd(blockIm, 1, &offsetIm, &blockIm, 1, vDSP_Length(count))
        vDSP_vsmul(blockRe, 1, &scale, &blockRe, 1, vDSP_Length(count))
        vDSP_vsmul(blockIm, 1, &scale, &blockIm, 1, vDSP_Length(count))
        updateNoise(blockRe, blockIm)
        re += blockRe
        im += blockIm

        var packets: [WLANPacket] = []
        re.withUnsafeBufferPointer { r in
            im.withUnsafeBufferPointer { i in
                let a = dsss.detect(re: r.baseAddress!, im: i.baseAddress!, count: r.count, from: dsssPosition, noise: noise)
                let b = ofdm.detect(re: r.baseAddress!, im: i.baseAddress!, count: r.count, from: ofdmPosition, noise: noise)
                packets = a.packets + b.packets
                dsssPosition = a.consumed
                ofdmPosition = b.consumed
            }
        }
        frames += packets.count
        // Puffer kürzen: nichts Angefangenes verwerfen, aber begrenzt halten.
        let keep = max(re.count - min(dsssPosition, ofdmPosition), 4096)
        let bounded = min(keep, WLANDSSSDemodulator.maximumSamples + 4096)
        if re.count > bounded {
            let drop = re.count - bounded
            re.removeFirst(drop)
            im.removeFirst(drop)
            dsssPosition = max(0, dsssPosition - drop)
            ofdmPosition = max(0, ofdmPosition - drop)
        }
        return packets
    }

    /// Rauschboden je Abtastwert: unteres Drittel der Leistung (Rahmen sind kurz).
    private func updateNoise(_ re: [Float], _ im: [Float]) {
        let step = max(1, re.count / 4096)
        var sample: [Float] = []
        sample.reserveCapacity(re.count / step + 1)
        var n = 0
        while n < re.count {
            sample.append(re[n] * re[n] + im[n] * im[n])
            n += step
        }
        guard !sample.isEmpty else { return }
        sample.sort()
        let floor = max(sample[sample.count / 3], 1e-9)
        noise = noise == 0 ? floor : 0.8 * noise + 0.2 * floor
    }
}
