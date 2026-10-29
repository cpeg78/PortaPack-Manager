import Foundation

/// Eine Vorlage fürs Spektrum: Mittenfrequenz und passende Bandbreite.
struct SpectrumPreset: Identifiable, Hashable, Sendable {
    let name: String
    let mhz: Double
    let bandwidthMHz: Double
    var note: String = ""
    /// Kanalraster, das nach Wahl der Vorlage zusätzlich angeboten wird.
    var channels: SpectrumPresets.ChannelPlan?
    var id: String { "\(name)@\(mhz)" }
}

struct SpectrumPresetGroup: Identifiable, Sendable {
    let title: String
    let symbol: String
    let presets: [SpectrumPreset]
    var id: String { title }
}

/// Alle Vorlagen. Frequenzen für Deutschland bzw. Europa; der HackRF reicht
/// von 1 MHz bis 6 GHz. Das Spektrum zeigt nur Signalenergie – Inhalte
/// nichtöffentlicher Funkdienste werden nicht dekodiert.
enum SpectrumPresets {
    static let groups: [SpectrumPresetGroup] = [
        SpectrumPresetGroup(title: String(localized: "Rundfunk"), symbol: "radio", presets: [
            .init(name: String(localized: "UKW-Rundfunk (Bandmitte)"), mhz: 98.0, bandwidthMHz: 20, note: String(localized: "87,5–108 MHz")),
            .init(name: String(localized: "UKW unteres Band"), mhz: 92.0, bandwidthMHz: 10),
            .init(name: String(localized: "UKW oberes Band"), mhz: 104.0, bandwidthMHz: 10),
            .init(name: String(localized: "DAB+ Block 5C (bundesweit)"), mhz: 178.352, bandwidthMHz: 4),
            .init(name: "DAB+ Block 11D", mhz: 222.064, bandwidthMHz: 4),
            .init(name: String(localized: "DAB+ Band III komplett"), mhz: 208.0, bandwidthMHz: 20, note: String(localized: "Ausschnitt")),
            .init(name: String(localized: "DVB-T2 Kanal 21–23"), mhz: 482.0, bandwidthMHz: 20),
            .init(name: String(localized: "Kurzwelle 49-m-Band"), mhz: 6.05, bandwidthMHz: 2),
            .init(name: String(localized: "Kurzwelle 31-m-Band"), mhz: 9.6, bandwidthMHz: 2),
        ]),
        SpectrumPresetGroup(title: String(localized: "Luftfahrt"), symbol: "airplane", presets: [
            .init(name: String(localized: "Flugfunk VHF (Bandmitte)"), mhz: 127.0, bandwidthMHz: 20, note: String(localized: "118–137 MHz, AM")),
            .init(name: String(localized: "ATIS/Tower-Bereich"), mhz: 119.0, bandwidthMHz: 4),
            .init(name: String(localized: "ACARS Europa"), mhz: 131.725, bandwidthMHz: 2),
            .init(name: String(localized: "VOR/ILS-Navigation"), mhz: 112.5, bandwidthMHz: 10),
            .init(name: String(localized: "ADS-B / Mode S (Antwort)"), mhz: 1090.0, bandwidthMHz: 4),
            .init(name: String(localized: "Mode S Abfrage (Boden)"), mhz: 1030.0, bandwidthMHz: 4),
            .init(name: String(localized: "Notfrequenz 121,5"), mhz: 121.5, bandwidthMHz: 2),
        ]),
        SpectrumPresetGroup(title: String(localized: "Satelliten & Wetter"), symbol: "globe.europe.africa", presets: [
            .init(name: "Meteor-M (LRPT)", mhz: 137.9, bandwidthMHz: 2),
            .init(name: String(localized: "Radiosonden"), mhz: 403.0, bandwidthMHz: 8, note: String(localized: "Wetterballons 400–406 MHz")),
            .init(name: String(localized: "ISS / Amateurfunk-Satelliten"), mhz: 145.85, bandwidthMHz: 2),
            .init(name: "GPS / Galileo L1/E1", mhz: 1575.42, bandwidthMHz: 4, note: String(localized: "unter dem Rauschen – Spitze nur mit aktiver Antenne")),
            .init(name: "GLONASS L1", mhz: 1602.0, bandwidthMHz: 10),
            .init(name: "Iridium", mhz: 1622.0, bandwidthMHz: 16),
            .init(name: "Inmarsat", mhz: 1541.5, bandwidthMHz: 8),
            .init(name: String(localized: "Notfunkbaken (EPIRB)"), mhz: 406.05, bandwidthMHz: 2),
        ]),
        SpectrumPresetGroup(title: String(localized: "Amateurfunk & Jedermannfunk"), symbol: "antenna.radiowaves.left.and.right", presets: [
            .init(name: String(localized: "2-m-Band"), mhz: 145.0, bandwidthMHz: 4),
            .init(name: String(localized: "APRS Europa"), mhz: 144.8, bandwidthMHz: 2),
            .init(name: String(localized: "70-cm-Band"), mhz: 435.0, bandwidthMHz: 10),
            .init(name: String(localized: "DAPNET-Funkruf"), mhz: 439.9875, bandwidthMHz: 2, note: String(localized: "POCSAG der Funkamateure")),
            .init(name: String(localized: "10-m-Band"), mhz: 28.5, bandwidthMHz: 2),
            .init(name: String(localized: "CB-Funk"), mhz: 27.185, bandwidthMHz: 2, note: String(localized: "26,965–27,405 MHz")),
            .init(name: "PMR446", mhz: 446.1, bandwidthMHz: 2),
            .init(name: "Freenet", mhz: 149.05, bandwidthMHz: 2),
            .init(name: "QO-100 Uplink", mhz: 2400.25, bandwidthMHz: 2),
        ]),
        SpectrumPresetGroup(title: String(localized: "WLAN"), symbol: "wifi", presets: [
            .init(name: String(localized: "WLAN 2,4 GHz"), mhz: 2437.0, bandwidthMHz: 20, note: String(localized: "Kanal 6, weitere danach wählbar"), channels: .wifi24),
            .init(name: String(localized: "WLAN 5 GHz"), mhz: 5180.0, bandwidthMHz: 20, note: String(localized: "Kanal 36, weitere danach wählbar"), channels: .wifi5),
            .init(name: String(localized: "WLAN 6 GHz"), mhz: 5955.0, bandwidthMHz: 20, note: String(localized: "Kanal 1, nur bis 6 GHz"), channels: .wifi6),
        ]),
        SpectrumPresetGroup(title: String(localized: "ISM & Smart Home"), symbol: "house", presets: [
            .init(name: String(localized: "433-MHz-ISM (Funksteckdosen, Wetterstationen)"), mhz: 433.92, bandwidthMHz: 2),
            .init(name: String(localized: "Reifendrucksensoren (TPMS)"), mhz: 433.92, bandwidthMHz: 2),
            .init(name: String(localized: "868 MHz SRD (LoRa, Rauchmelder)"), mhz: 868.3, bandwidthMHz: 4),
            .init(name: String(localized: "LoRaWAN EU-Kanäle"), mhz: 868.3, bandwidthMHz: 2),
            .init(name: "Z-Wave", mhz: 868.42, bandwidthMHz: 2),
            .init(name: String(localized: "Funkmikrofone 863–865"), mhz: 864.0, bandwidthMHz: 4),
            .init(name: String(localized: "Zigbee 2,4 GHz"), mhz: 2425.0, bandwidthMHz: 4, note: String(localized: "Kanal 15, weitere danach wählbar"), channels: .zigbee),
            .init(name: String(localized: "Bluetooth Werbekanal 37"), mhz: 2402.0, bandwidthMHz: 4),
            .init(name: String(localized: "Bluetooth Werbekanal 38"), mhz: 2426.0, bandwidthMHz: 4),
            .init(name: String(localized: "Bluetooth Werbekanal 39"), mhz: 2480.0, bandwidthMHz: 4),
            .init(name: String(localized: "Mikrowellenherd"), mhz: 2450.0, bandwidthMHz: 20),
            .init(name: String(localized: "DECT-Telefone"), mhz: 1890.0, bandwidthMHz: 20, note: String(localized: "1880–1900 MHz")),
            .init(name: String(localized: "FPV-Drohnen 5,8 GHz"), mhz: 5800.0, bandwidthMHz: 20),
        ]),
        SpectrumPresetGroup(title: String(localized: "Mobilfunk (Downlink)"), symbol: "cellularbars", presets: [
            .init(name: "LTE 800 (Band 20)", mhz: 806.0, bandwidthMHz: 20),
            .init(name: "GSM/LTE 900 (Band 8)", mhz: 947.5, bandwidthMHz: 20),
            .init(name: "LTE 1800 (Band 3)", mhz: 1842.5, bandwidthMHz: 20),
            .init(name: "UMTS/LTE 2100 (Band 1)", mhz: 2140.0, bandwidthMHz: 20),
            .init(name: "LTE 2600 (Band 7)", mhz: 2655.0, bandwidthMHz: 20),
            .init(name: String(localized: "5G 3,6 GHz (n78)"), mhz: 3600.0, bandwidthMHz: 20),
        ]),
        SpectrumPresetGroup(title: String(localized: "Pager & Datenfunk"), symbol: "message", presets: [
            .init(name: "e*Message / POCSAG", mhz: 466.075, bandwidthMHz: 2),
            .init(name: String(localized: "Pager-Bereich 465–467"), mhz: 466.0, bandwidthMHz: 4),
            .init(name: String(localized: "AIS (Schiffe)"), mhz: 162.0, bandwidthMHz: 2, note: String(localized: "161,975 / 162,025 MHz")),
            .init(name: String(localized: "Seefunk UKW"), mhz: 157.0, bandwidthMHz: 4),
        ]),
    ]

    // MARK: - Kanalraster zu Vorlagen

    enum ChannelPlan: String, Hashable, Sendable {
        case wifi24, wifi5, wifi6, zigbee

        var title: String {
            switch self {
            case .wifi24: String(localized: "WLAN-Kanal 2,4 GHz")
            case .wifi5: String(localized: "WLAN-Kanal 5 GHz")
            case .wifi6: String(localized: "WLAN-Kanal 6 GHz")
            case .zigbee: String(localized: "Zigbee-Kanal")
            }
        }

        /// Kurzname für die Anzeige des gewählten Kanals.
        var name: String {
            switch self {
            case .wifi24: String(localized: "WLAN 2,4 GHz")
            case .wifi5: String(localized: "WLAN 5 GHz")
            case .wifi6: String(localized: "WLAN 6 GHz")
            case .zigbee: "Zigbee"
            }
        }

        var symbol: String {
            switch self {
            case .wifi24, .wifi5, .wifi6: "wifi"
            case .zigbee: "point.3.connected.trianglepath.dotted"
            }
        }

        var channels: [Channel] {
            switch self {
            case .wifi24: SpectrumPresets.wifi24
            case .wifi5: SpectrumPresets.wifi5
            case .wifi6: SpectrumPresets.wifi6
            case .zigbee: SpectrumPresets.zigbee
            }
        }
    }

    struct Channel: Identifiable, Hashable, Sendable {
        let number: Int
        let mhz: Double
        var hint: String = ""
        var id: Int { number }
        var title: String {
            let mhz = String(format: "%g", mhz)
            return hint.isEmpty ? String(localized: "Kanal \(number) – \(mhz) MHz")
                : String(localized: "Kanal \(number) – \(mhz) MHz (\(hint))")
        }
    }

    /// Zigbee/IEEE 802.15.4 im 2,4-GHz-Band: Kanäle 11–26, 5 MHz Raster,
    /// je 2 MHz breit. 15, 20, 25 und 26 liegen zwischen den WLAN-Kanälen 1/6/11.
    static let zigbee: [Channel] = (11...26).map { number in
        Channel(number: number, mhz: Double(2405 + 5 * (number - 11)),
                hint: [15, 20, 25, 26].contains(number) ? String(localized: "neben WLAN 1/6/11") : "")
    }

    /// WLAN 2,4 GHz: Kanäle 1–13 (Europa) und 14 (Japan).
    static let wifi24: [Channel] = (1...13).map { Channel(number: $0, mhz: Double(2407 + 5 * $0)) }
        + [Channel(number: 14, mhz: 2484, hint: String(localized: "nur Japan"))]

    /// WLAN 5 GHz: in Europa zugelassene 20-MHz-Kanäle (UNII-1 bis UNII-3).
    static let wifi5: [Channel] = ([36, 40, 44, 48, 52, 56, 60, 64] + Array(stride(from: 100, through: 144, by: 4)) + [149, 153, 157, 161, 165])
        .map { Channel(number: $0, mhz: Double(5000 + 5 * $0)) }

    /// WLAN 6 GHz (Wi-Fi 6E): nur die Kanäle unter 6 GHz – das Limit des HackRF.
    static let wifi6: [Channel] = [1, 5, 9].map { Channel(number: $0, mhz: Double(5950 + 5 * $0)) }
}
