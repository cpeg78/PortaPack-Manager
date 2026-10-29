import Accelerate
import Foundation

/// Rechnet IQ-Blöcke in ein gemitteltes Leistungsspektrum (dBFS) um.
final class SpectrumAnalyzer: @unchecked Sendable {
    let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let lock = NSLock()
    private var accumulator: [Float]
    private var accumulated = 0

    init(fftSize: Int = 1024) {
        precondition(fftSize.nonzeroBitCount == 1, "FFT-Größe muss eine Zweierpotenz sein")
        self.fftSize = fftSize
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = window
        accumulator = [Float](repeating: 0, count: fftSize)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Verarbeitet einen IQ-Block (int8, verschränkt). Rechnet höchstens
    /// `maxFFTs` Transformationen je Block, um die CPU zu schonen.
    func process(_ iq: Data, maxFFTs: Int = 16) {
        let samplesPerFFT = fftSize * 2
        let available = iq.count / samplesPerFFT
        guard available > 0 else { return }
        let count = min(available, maxFFTs)
        let step = available / count

        var real = [Float](repeating: 0, count: fftSize)
        var imag = [Float](repeating: 0, count: fftSize)
        var power = [Float](repeating: 0, count: fftSize)

        iq.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: Int8.self)
            // Gleichanteil über den ganzen Block abziehen: der HackRF mischt
            // direkt auf 0 Hz, Restgleichspannung und durchsickernder Oszillator
            // stünden sonst als feste Linie genau in der Mitte („DC-Spitze“).
            // Über ≈ 130 000 Werte gemittelt trifft das nur die Mittenfrequenz selbst.
            var sumI = 0, sumQ = 0
            let pairs = iq.count / 2
            for k in 0..<pairs { sumI += Int(bytes[2 * k]); sumQ += Int(bytes[2 * k + 1]) }
            let dcI = Float(sumI) / Float(max(1, pairs)), dcQ = Float(sumQ) / Float(max(1, pairs))
            for block in 0..<count {
                let base = block * step * samplesPerFFT
                for i in 0..<fftSize {
                    real[i] = (Float(bytes[base + 2 * i]) - dcI) / 128 * window[i]
                    imag[i] = (Float(bytes[base + 2 * i + 1]) - dcQ) / 128 * window[i]
                }
                real.withUnsafeMutableBufferPointer { re in
                    imag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize))
                    }
                }
                lock.withLock {
                    vDSP_vadd(accumulator, 1, power, 1, &accumulator, 1, vDSP_Length(fftSize))
                    accumulated += 1
                }
            }
        }
    }

    /// Liefert das Mittel seit dem letzten Aufruf in dB, mit der
    /// Mittenfrequenz in der Mitte (FFT-Shift). `nil`, wenn nichts anliegt.
    func takeSpectrum() -> [Float]? {
        let (sum, n): ([Float], Int) = lock.withLock {
            let result = (accumulator, accumulated)
            accumulator = [Float](repeating: 0, count: fftSize)
            accumulated = 0
            return result
        }
        guard n > 0 else { return nil }
        var scale = 1 / Float(n) / Float(fftSize * fftSize) * 4
        var averaged = [Float](repeating: 0, count: fftSize)
        vDSP_vsmul(sum, 1, &scale, &averaged, 1, vDSP_Length(fftSize))
        var floor: Float = 1e-12
        vDSP_vthr(averaged, 1, &floor, &averaged, 1, vDSP_Length(fftSize))
        var reference: Float = 1
        var db = [Float](repeating: 0, count: fftSize)
        vDSP_vdbcon(averaged, 1, &reference, &db, 1, vDSP_Length(fftSize), 0)
        let half = fftSize / 2
        return Array(db[half...] + db[..<half])
    }
}
