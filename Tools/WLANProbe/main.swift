import Foundation

// Live-Probe des 802.11-Empfängers ohne App: HackRF auf einen WLAN-Kanal
// stellen, einige Sekunden hören, Zähler und gesehene Netze ausgeben.
// Aufruf: Tools/wlan-probe.sh [Kanal] [Sekunden] [LNA] [VGA]
let arguments = CommandLine.arguments.dropFirst().map { $0 }
let channel = arguments.count > 0 ? Int(arguments[0]) ?? 6 : 6
let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 10 : 10
let lna = arguments.count > 2 ? Int(arguments[2]) ?? 24 : 24
let vga = arguments.count > 3 ? Int(arguments[3]) ?? 20 : 20

final class Box: @unchecked Sendable {
    let lock = NSLock()
    let receiver = WLANReceiver()
    var blocks = 0
    var packets: [WLANPacket] = []
    var clipped = 0.0
    var rms = 0.0
}
let box = Box()

do {
    let device = try HackRFDevice.openFirst()
    try device.setSampleRate(UInt32(WLANReceiver.sampleRate))
    try device.setBasebandFilter(20_000_000)
    try device.setFrequency(UInt64(WLANReceiver.frequencyMHz(channel: channel) * 1_000_000))
    try device.setLNAGain(lna)
    try device.setVGAGain(vga)
    try device.setAmplifier(false)
    print("Kanal \(channel) (\(WLANReceiver.frequencyMHz(channel: channel)) MHz), \(seconds) s, LNA \(lna), VGA \(vga)")
    try device.startReceiving(owner: box) { block in
        let stats = HackRFDevice.blockStatistics(block)
        let found = box.receiver.process(block)
        box.lock.withLock {
            box.blocks += 1
            box.packets += found
            box.clipped = 0.9 * box.clipped + 0.1 * stats.clipped
            box.rms = 0.9 * box.rms + 0.1 * stats.rmsDBFS
        }
    }
    Thread.sleep(forTimeInterval: seconds)
    device.stopReceiving()
    device.close()
} catch {
    print("Fehler: \(error)")
    exit(1)
}

let (blocks, packets, clipped, rms) = box.lock.withLock { (box.blocks, box.packets, box.clipped, box.rms) }
let r = box.receiver
print(String(format: "Blöcke %d · Pegel %.1f dBFS · Anschlag %.2f %% · Rauschboden %.1f dB", blocks, rms, clipped * 100, r.noiseDB))
print("DSSS: Bursts \(r.dsss.bursts), Kopf-CRC-Fehler \(r.dsss.headerErrors), FCS-Fehler \(r.dsss.fcsErrors), CCK (nicht dekodiert) \(r.dsss.unsupported)")
print("OFDM: Präambeln \(r.ofdm.preambles), SIGNAL-Fehler \(r.ofdm.signalErrors), FCS-Fehler \(r.ofdm.fcsErrors)")
print("Rahmen mit gültiger FCS: \(packets.count)")
var kinds: [String: Int] = [:]
var networks: [String: (ssid: String, rate: Double, rssi: Double, count: Int)] = [:]
var probes: [String: Set<String>] = [:]
for packet in packets {
    guard let frame = WLANFrame.parse(packet.mpdu) else { kinds["unlesbar", default: 0] += 1; continue }
    let key = "\(packet.modulation.rawValue) \(Int(packet.rateMbps)) Mbit/s · Typ \(frame.type)/\(frame.subtype)"
    kinds[key, default: 0] += 1
    if frame.kind == .beacon || frame.kind == .probeResponse {
        let bssid = WLANFrame.mac(frame.address3)
        var entry = networks[bssid] ?? (frame.ssid ?? "", packet.rateMbps, packet.rssiDB, 0)
        entry.count += 1
        entry.rssi = 0.8 * entry.rssi + 0.2 * packet.rssiDB
        if entry.ssid.isEmpty, let ssid = frame.ssid { entry.ssid = ssid }
        networks[bssid] = entry
    }
    if frame.type == 0, frame.subtype == 4 {         // Probe Request: Element 0 = gesuchte SSID
        var i = 0
        let ies = frame.body
        while i + 2 <= ies.count {
            let id = ies[i], length = Int(ies[i + 1])
            guard i + 2 + length <= ies.count else { break }
            if id == 0 { probes[WLANFrame.mac(frame.address2), default: []].insert(length == 0 ? "(alle)" : String(decoding: ies[(i + 2)..<(i + 2 + length)], as: UTF8.self)) }
            i += 2 + length
        }
    }
    if frame.nanAttributes != nil { kinds["NAN", default: 0] += 1 }
}
for (kind, count) in kinds.sorted(by: { $0.value > $1.value }) { print("  \(count)× \(kind)") }
if !networks.isEmpty {
    print("Netze:")
    for (bssid, n) in networks.sorted(by: { $0.value.count > $1.value.count }) {
        print(String(format: "  %@  %-32@ %3d Beacons  %.0f dBFS  %.0f Mbit/s", bssid, n.ssid.isEmpty ? "(verborgen)" : n.ssid, n.count, n.rssi, n.rate))
    }
}
if !probes.isEmpty {
    print("Probe-Requests:")
    for (mac, ssids) in probes { print("  \(mac): \(ssids.sorted().joined(separator: ", "))") }
}
