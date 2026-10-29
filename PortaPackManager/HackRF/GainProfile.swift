import Foundation

/// Startwerte für Verstärkung je Empfänger – ohne und mit externem
/// Breitband-Vorverstärker (≈ 20 dB) vor dem HackRF.
///
/// Gemessen 24.10.2026 (Skyscan draußen + 20-dB-LNA): Mit externem LNA
/// übersteuert der 8-Bit-Wandler bei UKW schon ab LNA 24 (40 % der Werte am
/// Anschlag), und der interne HF-Vorverstärker verschlechtert jedes Band –
/// er sitzt ungefiltert vor dem Mischer, starke UKW- und DVB-T-Sender
/// übersteuern ihn, egal worauf abgestimmt ist. Beste Werte: LNA 8 (UKW),
/// 24 (DAB, DVB-T), 40/VGA 40 (ADS-B).
enum GainProfile {
    struct Preset: Equatable, Sendable {
        var lna: Double
        var vga: Double
        var amplifier: Bool
    }

    enum Receiver: CaseIterable, Sendable {
        case spectrum, radio, dab, tv, adsb, acars, ais, aprs, pager, sonde, meteor
        case sensors, ble, drones, meshtastic, gps, recorder, zigbee, wifi, dcf77
        case cells, airband
    }

    static let externalAmplifierKey = "externalAmplifier"

    /// Hängt ein externer Vorverstärker vor dem HackRF? (Schalter „Externer LNA“ in den Einstellungen)
    static var externalAmplifier: Bool {
        get { UserDefaults.standard.bool(forKey: externalAmplifierKey) }
        set { UserDefaults.standard.set(newValue, forKey: externalAmplifierKey) }
    }

    static func preset(_ receiver: Receiver, externalAmplifier: Bool = Self.externalAmplifier) -> Preset {
        externalAmplifier ? withExternal(receiver) : standalone(receiver)
    }

    /// Ohne externen Verstärker: die bisherigen Werte der Seiten.
    private static func standalone(_ receiver: Receiver) -> Preset {
        switch receiver {
        case .spectrum: Preset(lna: 16, vga: 20, amplifier: false)
        case .radio: Preset(lna: 24, vga: 20, amplifier: false)
        case .dab: Preset(lna: 32, vga: 30, amplifier: false)
        case .tv: Preset(lna: 32, vga: 20, amplifier: true)
        case .adsb: Preset(lna: 32, vga: 32, amplifier: true)
        case .acars, .ais: Preset(lna: 32, vga: 30, amplifier: true)
        case .aprs, .pager: Preset(lna: 32, vga: 30, amplifier: false)
        case .sonde: Preset(lna: 32, vga: 24, amplifier: true)
        case .meteor: Preset(lna: 32, vga: 30, amplifier: true)
        case .sensors: Preset(lna: 24, vga: 20, amplifier: false)
        case .dcf77: Preset(lna: 32, vga: 30, amplifier: false)   // unter 1 MHz bringt der HF-Verstärker nichts
        case .ble, .drones, .meshtastic, .zigbee: Preset(lna: 32, vga: 24, amplifier: false)
        case .wifi: Preset(lna: 16, vga: 20, amplifier: false)
        case .gps: Preset(lna: 40, vga: 40, amplifier: true)
        case .recorder: Preset(lna: 32, vga: 32, amplifier: true)
        // LTE-Basisstationen sind meist kräftig; Breitband-Aufnahme (19,2 MS/s) übersteuert schnell.
        case .cells: Preset(lna: 32, vga: 20, amplifier: false)
        // Flugfunk-Scanner nimmt 8–16 MHz auf einmal auf – mit der ACARS-Vorgabe
        // (VGA 30) live bis 31 % am Anschlag (28.10.2026).
        case .airband: Preset(lna: 24, vga: 16, amplifier: false)
        }
    }

    /// Mit externem Verstärker: interner Vorverstärker immer aus.
    private static func withExternal(_ receiver: Receiver) -> Preset {
        switch receiver {
        case .spectrum: Preset(lna: 8, vga: 20, amplifier: false)
        case .radio: Preset(lna: 8, vga: 24, amplifier: false)
        case .dab, .tv: Preset(lna: 24, vga: 20, amplifier: false)
        case .adsb, .gps: Preset(lna: 40, vga: 40, amplifier: false)
        case .acars, .ais, .aprs, .pager, .meteor: Preset(lna: 24, vga: 30, amplifier: false)
        // Sonden 27.10.2026: −34 dBFS bei LNA 24, RS41 in 90–110 km im Rauschen –
        // eine Stufe mehr; übersteuert es, nimmt `SondeModel` selbst zurück.
        case .sonde: Preset(lna: 32, vga: 30, amplifier: false)
        case .sensors, .meshtastic: Preset(lna: 24, vga: 24, amplifier: false)
        case .dcf77: Preset(lna: 24, vga: 30, amplifier: false)
        case .ble, .drones: Preset(lna: 32, vga: 24, amplifier: false)
        // Zigbee live 24.10.2026: 24/20 → 621 Rahmen in 2 × 6 s, 32/24 übersteuert (−1 dB), 16/16 deutlich weniger.
        case .zigbee: Preset(lna: 24, vga: 20, amplifier: false)
        case .wifi: Preset(lna: 8, vga: 20, amplifier: false)
        case .recorder: Preset(lna: 16, vga: 20, amplifier: false)
        case .cells: Preset(lna: 16, vga: 20, amplifier: false)
        case .airband: Preset(lna: 8, vga: 16, amplifier: false)
        }
    }
}
