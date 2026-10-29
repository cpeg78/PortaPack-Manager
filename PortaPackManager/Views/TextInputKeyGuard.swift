import AppKit
import SwiftUI

/// Schutz für Tastenkürzel ohne Modifier (Leertaste = Start/Stopp, Pfeile =
/// Abstimmen im Radio): `.keyboardShortcut(…, modifiers: [])` läuft über
/// `performKeyEquivalent` und damit *vor* dem Textfeld – wer im MHz-Feld den
/// Cursor mit ← bewegte oder ein Leerzeichen tippte, verstellte die Frequenz
/// bzw. stoppte den Empfang (Bedienungs-Review 29.10.2026).
///
/// Ein lokaler Monitor reicht diese Tasten deshalb direkt an ein editierbares
/// Textfeld weiter, sobald es den Fokus hat – wie `ScreenView` es für die
/// Gerätetasten schon tat. Ohne Textfeld-Fokus greifen die Kürzel unverändert.
@MainActor
enum TextInputKeyGuard {
    private static var monitor: Any?

    /// Einmal beim Programmstart.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard shouldRoute(keyCode: event.keyCode, modifiers: event.modifierFlags),
                  let textView = event.window?.firstResponder as? NSTextView, textView.isEditable
            else { return event }
            textView.keyDown(with: event)
            return nil
        }
    }

    /// Leertaste und Pfeiltasten ohne ⌘/⌃/⌥ – genau die Tasten, die Seiten als
    /// Kürzel ohne Modifier benutzen. ⇧ bleibt erlaubt (Text markieren).
    nonisolated static func shouldRoute(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        return guardedKeyCodes.contains(keyCode)
    }

    /// Leertaste (49), ← (123), → (124), ↓ (125), ↑ (126).
    nonisolated static let guardedKeyCodes: Set<UInt16> = [49, 123, 124, 125, 126]
}

extension View {
    /// Leertaste startet/stoppt den Empfang der Seite – auf allen Empfängerseiten
    /// am Start-/Stopp-Knopf im Bedienfeld. Textfelder behalten die Leertaste
    /// (`TextInputKeyGuard`).
    func startStopShortcut() -> some View {
        keyboardShortcut(.space, modifiers: [])
    }
}
