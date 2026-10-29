import AppKit
import SwiftUI

/// Große Frequenzanzeige, in der jede Ziffer einzeln verstellbar ist:
/// Mausrad bzw. Trackpad über der Ziffer, Klick oben (+) oder unten (−).
struct FrequencyDial: View {
    let mhz: Double
    /// Nachkommastellen (MHz). 3 → kleinste Stelle 1 kHz, 4 → 100 Hz.
    let decimals: Int
    /// Schritt für VoiceOver und die Tastatur-Bedienungshilfe (Hoch/Runter);
    /// ohne Angabe die zweitkleinste Stelle.
    var stepMHz: Double?
    let onChange: (Double) -> Void

    @State private var hovered: Int?

    private struct Digit: Identifiable {
        let id: Int
        let character: Character
        let placeHz: Double?    // nil = Trennzeichen
        let leading: Bool       // führende Null (abgedunkelt)
    }

    private var digits: [Digit] {
        let text = String(format: "%0\(5 + decimals).\(decimals)f", mhz)   // z. B. 0125.1700
        var result: [Digit] = []
        let integerCount = text.firstIndex(of: ".").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
        var seenNonZero = false
        for (index, character) in text.enumerated() {
            if character == "." {
                result.append(Digit(id: index, character: ".", placeHz: nil, leading: false))
                continue
            }
            let exponent = index < integerCount ? integerCount - 1 - index : -(index - integerCount)
            if character != "0" || index >= integerCount - 1 { seenNonZero = true }
            result.append(Digit(id: index, character: character, placeHz: pow(10, Double(exponent)) * 1_000_000,
                                leading: !seenNonZero))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(digits) { digit in
                if let place = digit.placeHz {
                    Text(String(digit.character))
                        .foregroundStyle(digit.leading ? Color.secondary.opacity(0.35) : (hovered == digit.id ? Color.accentColor : Color.primary))
                        .overlay {
                            DigitControl { delta in
                                onChange(max(1, min(6000, mhz + delta * place / 1_000_000)))
                            }
                        }
                        .overlay(alignment: .top) {
                            if hovered == digit.id {
                                Image(systemName: "chevron.up").font(.caption2).foregroundStyle(.secondary).offset(y: -4)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if hovered == digit.id {
                                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary).offset(y: 4)
                            }
                        }
                        .onHover { inside in hovered = inside ? digit.id : (hovered == digit.id ? nil : hovered) }
                        .help("Mausrad oder Klick oben/unten: ±\(Self.label(place))")
                } else {
                    Text(".")
                }
            }
        }
        .font(.system(size: 54, weight: .light, design: .rounded).monospacedDigit())
        // Die Ziffern sind einzelne AppKit-Ansichten – für VoiceOver ein einziges,
        // verstellbares Element (Bedienungs-Review 29.10.2026).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frequenz")
        .accessibilityValue(Text(verbatim: FrequencyInput.format(mhz, decimals: decimals) + " MHz"))
        .accessibilityAdjustableAction { direction in
            let step = stepMHz ?? pow(10, Double(1 - decimals))
            switch direction {
            case .increment: onChange(min(6000, mhz + step))
            case .decrement: onChange(max(1, mhz - step))
            @unknown default: break
            }
        }
    }

    static func label(_ hz: Double) -> String {
        switch hz {
        case 1_000_000...: return "\(Int(hz / 1_000_000)) MHz"
        case 1_000...: return "\(Int(hz / 1_000)) kHz"
        default: return "\(Int(hz)) Hz"
        }
    }
}

/// Fängt Mausrad und Klicks über einer Ziffer ab.
private struct DigitControl: NSViewRepresentable {
    let onStep: (Double) -> Void

    func makeNSView(context: Context) -> ControlView {
        let view = ControlView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ view: ControlView, context: Context) {
        view.onStep = onStep
    }

    final class ControlView: NSView {
        var onStep: ((Double) -> Void)?
        private var accumulated: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            if event.hasPreciseScrollingDeltas {
                // Trackpad: viele kleine Schritte – erst ab einer Schwelle zählen.
                accumulated += event.scrollingDeltaY
                while abs(accumulated) >= 12 {
                    onStep?(accumulated > 0 ? 1 : -1)
                    accumulated -= accumulated > 0 ? 12 : -12
                }
            } else if event.scrollingDeltaY != 0 {
                onStep?(event.scrollingDeltaY > 0 ? 1 : -1)
            }
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            // NSView zählt y von unten: obere Hälfte = größerer y-Wert.
            onStep?(point.y > bounds.midY ? 1 : -1)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
