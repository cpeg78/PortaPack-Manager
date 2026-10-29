import SwiftUI

/// „Signal optimieren“: probiert Verstärkungen am laufenden Empfang durch
/// (siehe `GainSearch`) und übernimmt die beste.
struct GainOptimizerRow: View {
    let model: any GainTunable
    let device: HackRFDevice?
    private var optimizer: GainOptimizer { .shared(for: model) }
    @Bindable private var autoGain = AutoGain.shared

    // Kein Abbruch in onDisappear: im Formular verschwindet die Zeile schon
    // beim Wegscrollen. Wechselt der Empfang, bricht der Optimierer selbst ab.
    var body: some View {
        if model.receivesInBursts {
            // Stoß-Empfänger (LTE): weder Optimierer noch Automatik – die
            // Aufnahmen nehmen je Band selbst zurück bzw. wieder hoch.
            Text("Die Verstärkung regelt der Suchlauf je Band selbst: übersteuert eine Aufnahme, nimmt er eine LNA-Stufe zurück, ist sie zu leise, geht er wieder hoch – höchstens bis zu deinem Wert.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            optimizerControls
        }
    }

    private var optimizerControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Signal optimieren", systemImage: "wand.and.stars") { optimizer.run(model, device: device) }
                    .disabled(optimizer.active || !model.running || device == nil)
                    .help(model.quality == nil
                          ? "Stellt LNA, VGA und den eingebauten Verstärker so ein, dass der Wandler gut ausgesteuert ist und nicht übersteuert (wenige Sekunden)."
                          : "Erst den Pegel einstellen, dann benachbarte Stufen je \(Int(GainOptimizer.qualitySeconds)) s am Dekoder vergleichen und die beste übernehmen (etwa eine halbe Minute).")
                if optimizer.active {
                    ProgressView().controlSize(.small)
                    Spacer()
                    Button("Abbrechen") { optimizer.cancel() }
                }
            }
            if optimizer.active {
                Text(optimizer.status).font(.caption).foregroundStyle(.secondary)
            } else if let result = optimizer.result {
                // Nur das Ergebnis – den Zustand des Empfangs meldet die Statuszeile darüber.
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
            if !model.wantsAutoGain {
                Text("Die Automatik regelt hier nicht nach – die Pegel einer Aufzeichnung bleiben so vergleichbar.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Toggle("Verstärkung automatisch nachregeln", isOn: $autoGain.enabled)
                    .font(.caption)
                    .help("Gilt für alle Empfänger (auch in den Einstellungen unter Antenne & Gerät): Übersteuert der Empfang, nimmt die App die Verstärkung eine Stufe zurück; ist das Signal viel zu leise, dreht sie eine Stufe hoch. Sonst bleiben deine Werte unverändert.")
                if autoGain.enabled, let note = autoGain.note(for: model) {
                    Text("Automatik: \(note)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Gemeinsame Hilfetexte der Verstärkungsregler – überall gleich, in Alltagssprache.
enum GainHelp {
    static var lna: String { String(localized: "Eingangsverstärkung (LNA, 0–40 dB in 8er-Schritten): verstärkt das Antennensignal zuerst und entscheidet am meisten, ob schwache Sender ankommen. Zu viel → „Übersteuert“. Einfacher: „Signal optimieren“.") }
    static var vga: String { String(localized: "Nachverstärkung (VGA, 0–62 dB): bringt das Signal auf die richtige Höhe für den Wandler. Erst die Eingangsverstärkung einstellen, dann diese.") }
    static var amplifier: String { String(localized: "Eingebauter Verstärker (+14 dB) direkt an der Antenne. Hilft nur bei sehr schwachen Signalen; neben starken Sendern übersteuert er schnell. Mit externem LNA aus lassen.") }
    static var biasTee: String { String(localized: "Legt 3,3 V an die Antennenbuchse – nur für aktive Antennen oder Vorverstärker, die darüber versorgt werden! Eine normale Antenne oder ein Messgerät kann daran Schaden nehmen.") }
}
