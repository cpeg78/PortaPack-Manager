import Foundation

/// Ein empfangenes Paket als Folge von Puls/Pause-Paaren in Mikrosekunden.
/// Bei OOK ist „Puls“ Träger an, bei FSK die höhere der beiden Frequenzen.
struct SensorPulseTrain: Sendable, Equatable {
    enum Modulation: String, Sendable {
        case ook = "OOK"
        case fsk = "FSK"
    }

    var modulation: Modulation
    var pulses: [Int]
    var gaps: [Int]
    /// Empfangspegel (dBFS) und Abstand zum Rauschen.
    var rssiDB: Double = 0
    var snrDB: Double = 0
    /// Ablage von der Mittenfrequenz in kHz (bei FSK die Mitte zwischen
    /// beiden Frequenzen) und bei FSK der Hub zwischen ihnen.
    var offsetKHz: Double = 0
    var deviationKHz: Double = 0
    var date = Date()

    var count: Int { pulses.count }

    /// Dauer ohne die abschließende Pause.
    var durationMicroseconds: Int {
        pulses.reduce(0, +) + gaps.dropLast().reduce(0, +)
    }
}

/// Wandelt Pulsfolgen in Bits – Nachbau der rtl_433-Slicer
/// (`pulse_slicer.c`). Alle Zeiten in µs.
enum SensorSlicer {
    /// Pulspositionsmodulation: die Pause entscheidet (kurz = 0, lang = 1).
    static func ppm(_ train: SensorPulseTrain, short: Int, long: Int, gapLimit: Int = 0, reset: Int,
                    sync: Int = 0, tolerance: Int = 0) -> [SensorBitBuffer] {
        let zeroL: Int, zeroU: Int, oneL: Int, oneU: Int
        var syncL = 0, syncU = 0
        if tolerance > 0 {
            zeroL = short - tolerance; zeroU = short + tolerance
            oneL = long - tolerance; oneU = long + tolerance
            if sync > 0 { syncL = sync - tolerance; syncU = sync + tolerance }
        } else {
            zeroL = 0
            zeroU = (short + long) / 2 + 1
            oneL = zeroU - 1
            oneU = gapLimit > 0 ? gapLimit : reset
        }
        var results: [SensorBitBuffer] = []
        var bits = SensorBitBuffer()
        for n in 0..<train.count {
            let gap = train.gaps[n]
            if gap > zeroL && gap < zeroU {
                bits.add(0)
            } else if gap > oneL && gap < oneU {
                bits.add(1)
            } else if gap > syncL && gap < syncU {
                bits.addSync()
            } else if gap < reset {
                bits.addRow()
            }
            if (n == train.count - 1 || gap >= reset) && !bits.isEmptyForEvent {
                results.append(bits)
                bits = SensorBitBuffer()
            } else if n == train.count - 1 || gap >= reset {
                bits = SensorBitBuffer()
            }
        }
        return results
    }

    /// Pulsbreitenmodulation: der Puls entscheidet (kurz = 1, lang = 0).
    static func pwm(_ train: SensorPulseTrain, short: Int, long: Int, sync: Int = 0, gapLimit: Int = 0,
                    reset: Int, tolerance: Int = 0) -> [SensorBitBuffer] {
        var oneL: Int, oneU: Int, zeroL: Int, zeroU: Int
        var syncL = 0, syncU = 0
        if tolerance > 0 {
            oneL = short - tolerance; oneU = short + tolerance
            zeroL = long - tolerance; zeroU = long + tolerance
            if sync > 0 { syncL = sync - tolerance; syncU = sync + tolerance }
        } else if sync <= 0 {
            oneL = 0; oneU = (short + long) / 2 + 1
            zeroL = oneU - 1; zeroU = Int.max
        } else if sync < short {
            syncL = 0; syncU = (sync + short) / 2 + 1
            oneL = syncU - 1; oneU = (short + long) / 2 + 1
            zeroL = oneU - 1; zeroU = Int.max
        } else if sync < long {
            oneL = 0; oneU = (short + sync) / 2 + 1
            syncL = oneU - 1; syncU = (sync + long) / 2 + 1
            zeroL = syncU - 1; zeroU = Int.max
        } else {
            oneL = 0; oneU = (short + long) / 2 + 1
            zeroL = oneU - 1; zeroU = (long + sync) / 2 + 1
            syncL = zeroU - 1; syncU = Int.max
        }
        var results: [SensorBitBuffer] = []
        var bits = SensorBitBuffer()
        for n in 0..<train.count {
            let pulse = train.pulses[n]
            if pulse > oneL && pulse < oneU {
                bits.add(1)
            } else if pulse > zeroL && pulse < zeroU {
                bits.add(0)
            } else if pulse > syncL && pulse < syncU {
                bits.addSync()
            } else if pulse <= oneL {
                // vereinzelte Störspitzen ignorieren
            } else {
                bits.addRow()
            }
            let gap = train.gaps[n]
            if (n == train.count - 1 || gap > reset) && !bits.rows.isEmpty {
                results.append(bits)
                bits = SensorBitBuffer()
            } else if gapLimit > 0 && gap > gapLimit, let last = bits.rows.last, last.count > 0 {
                bits.addRow()
            }
        }
        return results
    }

    /// NRZ-Pulscode (FSK): Puls- und Pausenlänge in ganzen Bitzeiten.
    ///
    /// Gemessene Läufe sind `n·T + c`: die Bitzeit `T` weicht je Sensor ein
    /// paar Prozent ab, und je nach Lage der beiden Frequenzen im Kanal sind
    /// Pulse um einen festen Betrag länger und Pausen kürzer (gemessen an
    /// einer Bresser-Aufnahme: +2 µs bzw. −18 µs). Deshalb werden `T` und die
    /// beiden Versätze per kleinster Quadrate über alle Läufe geschätzt,
    /// abwechselnd mit dem Runden auf ganze Bits.
    static func pcm(_ train: SensorPulseTrain, bitWidth: Int, reset: Int) -> [SensorBitBuffer] {
        guard train.count > 0, bitWidth > 0 else { return [] }
        let fit = fitNRZ(train, nominal: Double(bitWidth), reset: reset)
        let width = fit.width
        let maxZeros = max(1, Int(Double(reset) / width))
        var results: [SensorBitBuffer] = []
        var bits = SensorBitBuffer()
        for n in 0..<train.count {
            let highs = train.pulses[n] == 0 ? 0 : Int(((Double(train.pulses[n]) - fit.pulseOffset) / width).rounded())
            let lows = min(Int(((Double(train.gaps[n]) - fit.gapOffset) / width).rounded()), maxZeros)
            for _ in 0..<max(0, highs) { bits.add(1) }
            for _ in 0..<max(0, lows) { bits.add(0) }
            if (n == train.count - 1 || train.gaps[n] > reset) && !bits.isEmptyForEvent {
                results.append(bits)
                bits = SensorBitBuffer()
            }
        }
        return results
    }
}

extension SensorSlicer {
    /// Bitzeit und Versätze für `pcm` (siehe dort).
    static func fitNRZ(_ train: SensorPulseTrain, nominal: Double, reset: Int)
        -> (width: Double, pulseOffset: Double, gapOffset: Double) {
        var width = nominal, cp = 0.0, cg = 0.0
        // Messwerte: (Länge, ist Puls); letzte Pause und überlange Läufe weglassen
        var runs: [(x: Double, pulse: Bool)] = []
        for n in 0..<train.count {
            if train.pulses[n] > 0 { runs.append((Double(train.pulses[n]), true)) }
            if n < train.count - 1 && train.gaps[n] <= reset { runs.append((Double(train.gaps[n]), false)) }
        }
        for _ in 0..<4 {
            // Normalgleichungen für x = n·T + cp·[Puls] + cg·[Pause]
            var a = [[Double]](repeating: [0, 0, 0], count: 3)
            var y = [0.0, 0.0, 0.0]
            for run in runs {
                let n = max(1, ((run.x - (run.pulse ? cp : cg)) / width).rounded())
                guard n <= 16 else { continue }
                let row = [n, run.pulse ? 1 : 0, run.pulse ? 0 : 1]
                for i in 0..<3 {
                    y[i] += row[i] * run.x
                    for j in 0..<3 { a[i][j] += row[i] * row[j] }
                }
            }
            guard let solution = solve3(a, y), solution[0] > nominal * 0.8, solution[0] < nominal * 1.2,
                  abs(solution[1]) < nominal / 2, abs(solution[2]) < nominal / 2 else { break }
            (width, cp, cg) = (solution[0], solution[1], solution[2])
        }
        return (width, cp, cg)
    }

    /// 3×3-Gleichungssystem (Cramersche Regel), `nil` wenn singulär.
    private static func solve3(_ a: [[Double]], _ y: [Double]) -> [Double]? {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det(a)
        guard abs(d) > 1e-9 else { return nil }
        return (0..<3).map { column in
            var m = a
            for row in 0..<3 { m[row][column] = y[row] }
            return det(m) / d
        }
    }
}

extension SensorBitBuffer {
    /// Wie rtl_433: nur auswerten, wenn Bits angefallen sind
    /// (`bits_per_row[0] > 0 || num_rows > 1`).
    var isEmptyForEvent: Bool {
        rows.isEmpty || (rows.count == 1 && rows[0].count == 0)
    }
}
