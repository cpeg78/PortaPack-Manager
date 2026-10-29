import Foundation

// IQ-Rohaufnahme ohne App (8-Bit I/Q wie `HackRFDevice.startReceiving`) –
// für Live-Proben der Empfänger, ausgewertet mit `LiveCaptureTests`.
// Aufruf: Tools/iq-capture.sh <datei> <mitte Hz> <rate Hz> <sekunden> [LNA] [VGA] [verstärker 0/1] [filter Hz]
let arguments = CommandLine.arguments.dropFirst().map { $0 }
guard arguments.count >= 4, let center = UInt64(arguments[1]), let rate = UInt32(arguments[2]),
      let seconds = Double(arguments[3]) else {
    print("Aufruf: iq-capture.sh <datei> <mitte Hz> <rate Hz> <sekunden> [LNA] [VGA] [verstärker 0/1] [filter Hz]")
    exit(2)
}
let lna = arguments.count > 4 ? Int(arguments[4]) ?? 24 : 24
let vga = arguments.count > 5 ? Int(arguments[5]) ?? 20 : 20
let amp = arguments.count > 6 ? arguments[6] == "1" : false
/// Basisbandfilter; ohne Angabe wie `setSampleRate` (¾ der Rate).
let filter = arguments.count > 7 ? UInt32(arguments[7]) : nil

final class Box: @unchecked Sendable {
    let lock = NSLock()
    let file: FileHandle
    var bytes = 0
    var clipped = 0.0
    var rms = 0.0
    init(file: FileHandle) { self.file = file }
}

FileManager.default.createFile(atPath: arguments[0], contents: nil)
guard let handle = FileHandle(forWritingAtPath: arguments[0]) else { print("Datei nicht beschreibbar"); exit(1) }
let box = Box(file: handle)

do {
    let device = try HackRFDevice.openFirst()
    try device.setSampleRate(rate)
    if let filter { try device.setBasebandFilter(HackRFDevice.basebandFilter(for: filter)) }
    try device.setFrequency(center)
    try device.setLNAGain(lna)
    try device.setVGAGain(vga)
    try device.setAmplifier(amp)
    print("\(center) Hz, \(rate) S/s, \(seconds) s, LNA \(lna), VGA \(vga), Verstärker \(amp ? "an" : "aus")")
    try device.startReceiving(owner: box) { block in
        let stats = HackRFDevice.blockStatistics(block)
        box.lock.withLock {
            box.file.write(block)
            box.bytes += block.count
            box.clipped = 0.9 * box.clipped + 0.1 * stats.clipped
            box.rms = 0.9 * box.rms + 0.1 * stats.rmsDBFS
        }
    }
    Thread.sleep(forTimeInterval: seconds)
    device.stopReceiving()
    device.close()
    box.lock.withLock {
        try? box.file.close()
        let expected = Double(rate) * seconds * 2
        print(String(format: "%.1f MB (%.1f %% der Sollmenge), Pegel %.1f dBFS, Anschlag %.2f %%, verworfen %d",
                     Double(box.bytes) / 1e6, 100 * Double(box.bytes) / expected, box.rms, box.clipped * 100,
                     device.droppedBlocks))
    }
} catch {
    print("Fehler: \(error)")
    exit(1)
}
