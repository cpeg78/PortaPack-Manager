import Foundation

/// Reiter „Smart Home 868“ des Fernzugriffs (`/api/smart868[?dev=<Gerät>]`):
/// Geräte je Funkart mit letztem Wert, Messwerten, Pegel und Zähler; mit
/// `dev` dazu die letzten Rahmen dieses Geräts. Nur lesen.
///
/// **Nie Schlüssel ausliefern:** Der Zustand wird nur aus Geräten und
/// Empfängen gebaut – die wM-Bus-Zählerschlüssel (`wmbusKeys`) und die
/// Rohbytes der Rahmen kommen hier gar nicht erst an. Felder, deren Name nach
/// Schlüssel klingt, fallen zusätzlich heraus (`RemoteSmartHomeTests`).
@MainActor
enum RemoteSmartHomeAPI {
    static let deviceLimit = 500
    static let frameLimit = 25

    struct State: Encodable {
        struct Value: Encodable, Equatable {
            let n: String
            let v: String
        }
        struct Radio: Encodable {
            let name: String
            let on: Bool
            let mhz: String
            let devices: Int
        }
        struct Device: Encodable {
            let id: String
            let radio: String
            let addr: String
            let type: String
            let last: String
            let values: [Value]
            let enc: Bool
            let rssi: Double
            let snr: Double
            let t: Double
            let first: Double
            let count: Int
        }
        struct Frame: Encodable {
            let t: Double
            let mode: String
            let kind: String
            let summary: String
            let dest: String?
            let ok: Bool
            let enc: Bool
            let mhz: Double
            let rssi: Double
            let snr: Double
            let fields: [Value]
            let values: [Value]
        }
        let running: Bool
        let remote: Bool
        let frames: Int
        let bursts: Int
        let noise: [Value]
        let radios: [Radio]
        let total: Int
        let devices: [Device]
        /// Gewähltes Gerät und seine letzten Rahmen (neueste zuerst).
        let dev: String?
        let history: [Frame]?
        let error: String?
    }

    static func handle(_ query: [String: String], hub: RemoteHub) -> Data {
        let model = hub.smartHome
        let s = state(devices: model.devices, receptions: model.receptions, radios: model.radios,
                      running: model.running, remote: hub.remoteMode == .smartHome868, frames: model.frameCount,
                      bursts: model.burstCount, noise: model.noiseDB, error: model.error,
                      selected: query["dev"].flatMap { $0.isEmpty ? nil : String($0.prefix(200)) })
        return (try? JSONEncoder().encode(s)) ?? Data("{}".utf8)
    }

    static func state(devices: [SmartHomeDevice], receptions: [SmartHomeReception], radios: Set<SmartHomeRadio>,
                      running: Bool, remote: Bool, frames: Int, bursts: Int, noise: [SmartHomeChannel: Double],
                      error: String?, selected: String?) -> State {
        let sorted = devices.sorted { $0.lastSeen > $1.lastSeen }
        let history: [State.Frame]? = selected.map { id in
            receptions.filter { $0.frame.deviceKey == id }
                .sorted { $0.date > $1.date }
                .prefix(frameLimit)
                .map { r in
                    let f = r.frame
                    return .init(t: ms(r.date), mode: f.mode, kind: f.kind, summary: f.summary, dest: f.destination,
                                 ok: f.checksumOK, enc: f.encrypted, mhz: round(r.frequencyMHz, 3),
                                 rssi: round(r.rssiDB, 1), snr: round(r.snrDB, 1),
                                 fields: f.fields.filter { !looksSecret($0.name) }.map { .init(n: $0.name, v: $0.value) },
                                 values: f.values.map { .init(n: $0.label, v: $0.formatted) })
                }
        }
        return State(
            running: running, remote: remote, frames: frames, bursts: bursts,
            noise: SmartHomeChannel.allCases.compactMap { channel in
                noise[channel].flatMap { $0.isFinite ? .init(n: mhzText(channel.frequencyMHz), v: "\(Int($0.rounded())) dB") : nil }
            },
            radios: SmartHomeRadio.allCases.map { radio in
                .init(name: radio.rawValue, on: radios.contains(radio), mhz: radio.frequencies,
                      devices: devices.filter { $0.radio == radio }.count)
            },
            total: devices.count,
            devices: sorted.prefix(deviceLimit).map { d in
                .init(id: d.id, radio: d.radio.rawValue, addr: d.address, type: d.deviceType, last: d.lastValueText,
                      values: d.values.map { .init(n: $0.label, v: $0.formatted) }, enc: d.encrypted,
                      rssi: round(d.rssiDB, 1), snr: round(d.snrDB, 1), t: ms(d.lastSeen), first: ms(d.firstSeen),
                      count: d.count)
            },
            dev: selected, history: history, error: error)
    }

    /// Feldnamen, die nach Schlüsselmaterial klingen („Schlüssel“, „Key“) –
    /// „Entschlüsselt: ja“ ist harmlos und bleibt.
    static func looksSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("entschlüssel") || lower.hasPrefix("verschlüssel") { return false }
        return lower.contains("schlüssel") || lower.contains("key")
    }

    private static func mhzText(_ mhz: Double) -> String {
        mhz.formatted(.number.precision(.fractionLength(2)).locale(RemotePage.locale)) + " MHz"
    }
    private static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
    private static func round(_ value: Double, _ digits: Int) -> Double {
        guard value.isFinite else { return 0 }
        let f = pow(10, Double(digits))
        return (value * f).rounded() / f
    }
}
