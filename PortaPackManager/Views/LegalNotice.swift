import SwiftUI

/// Rechtshinweis (§ 5 TDDDG, Abhör- und Mitteilungsverbot) im Abschnitt
/// „Hinweis“ jeder Seite, die fremde Kommunikation empfängt: ACARS/VDL2/CPDLC,
/// Flugfunk, Funkruf, Radio, Meshtastic, LoRaWAN, Zigbee, Smart Home, DSC.
/// Vorher stand er nur bei Radio, Flugfunk (Handy) und Funkruf, jeweils anders
/// formuliert (Bedienungs-Review 29.10.2026). Kurz, nicht belehrend; das
/// Ausführliche steht in der Hilfe („Rechtliches und Datenschutz“).
struct LegalNotice: View {
    var text: LocalizedStringKey = "Was nicht für dich bestimmt ist, darfst du weder aufzeichnen noch weitergeben – auch nicht, dass du es empfangen hast (§ 5 TDDDG). Eigene Netze und Geräte sind ausgenommen."
    var help: LocalizedStringKey = "Abhör- und Mitteilungsverbot nach § 5 TDDDG. Mehr dazu in der Hilfe unter „Rechtliches und Datenschutz“."

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: "building.columns") }
            .font(.caption).foregroundStyle(.secondary)
            .help(help)
    }
}
