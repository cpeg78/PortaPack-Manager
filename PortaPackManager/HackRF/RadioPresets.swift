import Foundation

/// Abstimmvorlage fürs Radio (ohne Suchlauf): Frequenz und Betriebsart.
struct RadioPreset: Identifiable, Hashable, Sendable {
    /// Bandname („2 m“) – nicht übersetzt.
    let band: String
    let mhz: Double
    let mode: RadioMode
    /// Anruffrequenz laut Bandplan (dort trifft man sich, dann wird ausgewichen).
    var calling = false
    var id: String { "\(band)-\(mode.rawValue)-\(mhz)" }
}

/// Amateurfunk-Vorlagen nach dem IARU-Region-1-Bandplan: SSB unter 10 MHz im
/// unteren, darüber im oberen Seitenband; CW in den QRP-/Anrufbereichen.
/// Kurzwelle (unter 30 MHz) hört der HackRF nur schwach – die Radio-Seite weist
/// dort auf Upconverter und Antenne hin.
enum RadioPresets {
    static let amateur: [RadioPreset] = [
        RadioPreset(band: "80 m", mhz: 3.700, mode: .lsb),
        RadioPreset(band: "40 m", mhz: 7.030, mode: .cw),
        RadioPreset(band: "40 m", mhz: 7.100, mode: .lsb),
        RadioPreset(band: "20 m", mhz: 14.060, mode: .cw),
        RadioPreset(band: "20 m", mhz: 14.200, mode: .usb),
        RadioPreset(band: "10 m", mhz: 28.060, mode: .cw),
        RadioPreset(band: "10 m", mhz: 28.500, mode: .usb),
        RadioPreset(band: "10 m", mhz: 29.600, mode: .nfm, calling: true),
        RadioPreset(band: "6 m", mhz: 50.150, mode: .usb),
        RadioPreset(band: "2 m", mhz: 144.050, mode: .cw, calling: true),
        RadioPreset(band: "2 m", mhz: 144.300, mode: .usb, calling: true),
        RadioPreset(band: "70 cm", mhz: 432.050, mode: .cw, calling: true),
        RadioPreset(band: "70 cm", mhz: 432.200, mode: .usb, calling: true),
        RadioPreset(band: "23 cm", mhz: 1296.200, mode: .usb, calling: true),
    ]

    /// Unter dieser Frequenz (MHz) zeigt die Radio-Seite den Kurzwellen-Hinweis.
    static let shortwaveLimitMHz = 30.0
}
