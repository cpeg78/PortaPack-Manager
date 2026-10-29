import Foundation

// Messwerkzeug für den DVB-T2-Empfänger: simulierte K23-Rahmen durch einen
// Kanal mit Rauschen, Echo, Frequenz- und Abtastratenablage; ausgegeben wird
// der Anteil korrekt dekodierter FEC-Blöcke je Störabstand.
// Übersetzen und starten: Tools/t2-sweep.sh [Optionen]
//
//   --snr VON:BIS:SCHRITT   Störabstände in dB (Standard 9:14:0.5; 999 = rauschfrei)
//   --echo DB               Echo relativ zum Hauptpfad (weglassen = AWGN)
//   --delay US              Echoverzögerung in µs (Standard 5)
//   --cfo HZ                Frequenzablage
//   --ppm PPM               Abtastratenablage
//   --frames N              gezählte Rahmen je Punkt (Standard 3)
//   --seed N                Zufallsstart des Rauschens
//   --adjacent DB           Nachbarkanal (zweites T2-Signal) relativ zum Nutzsignal
//   --adjacent-mhz MHZ      dessen Abstand (Standard +8, auch −8)
//   --tone DBC              Störträger im Kanal (dBc), --tone-hz HZ seine Ablage
//   --mode ldpc             nur Zellebene (ohne OFDM): Demapper/Dekoder vergleichen
//     --demapper app|maxlog|logmap  --decoder kernel|float|oms|nms|corr2|pwl  --iter N  --beta B  --alpha A
//     --blocks N  --fading 1 (0-dB-Echo als Zufallsphase je Zelle)

var parameters = T2TestChannel.Parameters()
var snrRange = (from: 9.0, to: 14.0, step: 0.5)
var frames = 3
var mode = "ofdm"
var demapper = LDPCExperiment.Demapper.app
var decoder = LDPCExperiment.Decoder.kernel
var iterations = 50
var blocks = 64
var fading = false
var debug = false
var averaging = 8
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let key = arguments.removeFirst()
    let value = arguments.isEmpty ? "" : arguments.removeFirst()
    switch key {
    case "--snr":
        let parts = value.split(separator: ":").compactMap { Double($0) }
        if parts.count == 3 { snrRange = (parts[0], parts[1], parts[2]) } else if parts.count == 1 { snrRange = (parts[0], parts[0], 1) }
    case "--echo": parameters.echoDB = Double(value)
    case "--delay": parameters.echoMicroseconds = Double(value) ?? 5
    case "--cfo": parameters.frequencyOffsetHz = Double(value) ?? 0
    case "--ppm": parameters.sampleRatePPM = Double(value) ?? 0
    case "--frames": frames = Int(value) ?? 3
    case "--seed": parameters.seed = UInt64(value) ?? 99
    case "--mode": mode = value
    case "--demapper": demapper = LDPCExperiment.Demapper(rawValue: value) ?? .app
    case "--decoder": decoder = LDPCExperiment.Decoder(rawValue: value) ?? .kernel
    case "--iter": iterations = Int(value) ?? 50
    case "--blocks": blocks = Int(value) ?? 64
    case "--fading": fading = value == "1"
    case "--debug": debug = value == "1"
    case "--averaging": averaging = Int(value) ?? 8
    case "--adjacent": parameters.adjacentDB = Double(value)
    case "--adjacent-mhz": parameters.adjacentMHz = Double(value) ?? 8
    case "--tone": parameters.toneDBc = Double(value)
    case "--tone-hz": parameters.toneOffsetHz = Double(value) ?? 1_234_567
    case "--beta": LDPCExperiment.beta = Float(value) ?? 0.3
    case "--alpha": LDPCExperiment.alpha = Float(value) ?? 0.8
    default:
        FileHandle.standardError.write("Unbekannte Option \(key)\n".data(using: .utf8)!)
        exit(2)
    }
}

if mode == "ldpc" {
    let snrs = Array(stride(from: snrRange.from, through: snrRange.to + 1e-9, by: snrRange.step))
    LDPCExperiment.run(snrs: snrs, blocks: blocks, demapper: demapper, decoder: decoder, iterations: iterations, rayleigh: fading)
    exit(0)
}

let echo = parameters.echoDB.map { String(format: "Echo %.1f dB / %.1f µs", $0, parameters.echoMicroseconds) } ?? "AWGN"
let adjacentText = (parameters.adjacentDB.map { String(format: ", Nachbarkanal %+.0f dB bei %+.0f MHz", $0, parameters.adjacentMHz) } ?? "")
    + (parameters.toneDBc.map { String(format: ", Störträger %.0f dBc bei %+.3f MHz", $0, parameters.toneOffsetHz / 1e6) } ?? "")
print("# K23-Simulation: \(echo)\(adjacentText), CFO \(parameters.frequencyOffsetHz) Hz, \(parameters.sampleRatePPM) ppm, \(frames) Rahmen je Punkt")
print("# C/N[dB]  Lock  Blöcke gut/alle  Quote   BBFRAMEs  TS gültig  SNR-Schätzung  Iter  s/Rahmen  Empfänger s/Rahmen")
var snr = snrRange.from
var perfect = 0
while snr <= snrRange.to + 1e-9 {
    parameters.snrDB = snr >= 999 ? nil : snr      // --snr 999: rauschfrei
    let r = T2Simulation.run(parameters, frames: frames) { $0.debug = debug; $0.averaging = averaging }
    let line = String(format: "%7.2f  %4@  %6d/%-6d  %6.3f  %8d  %9d  %13.2f  %4d  %8.2f  %8.3f",
                      snr, r.locked ? "ja" : "nein", r.blocksGood, r.blocksGood + r.blocksBad, r.blockRate,
                      r.bbFramesGood, r.validPackets, r.estimatedSNR, r.ldpcIterations, r.seconds / Double(max(1, frames + 1)),
                      r.receiverSeconds / Double(max(1, frames + 1)))
    print(line)
    fflush(stdout)
    perfect = r.blockRate >= 0.999 && r.blocksGood > 0 ? perfect + 1 : 0
    if perfect >= 2 { break }
    snr += snrRange.step
}
