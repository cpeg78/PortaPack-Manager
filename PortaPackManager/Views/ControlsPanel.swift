import SwiftUI

/// Seite mit Bedienfeld rechts – als macOS-Inspektor: ein- und ausklappbar
/// über den Knopf oben rechts in der Symbolleiste (wie die Seitenleiste
/// links), Breite per Ziehen änderbar. Ob das Bedienfeld offen ist, gilt für
/// alle Seiten und bleibt über Programmläufe erhalten.
///
/// Dialoge (`.alert`, `.fileImporter` …) weiterhin an eine Ansicht *im*
/// Bedienfeld hängen, nicht an diese Hülle (siehe CLAUDE.md, HSplitView-Falle).
struct ControlsSplit<Main: View, Controls: View>: View {
    static var shownKey: String { "controlsPanelShown" }

    let width: CGFloat
    /// Fehler der Seite – steht bei eingeklapptem Bedienfeld über dem Inhalt,
    /// sonst sähe man ihn gar nicht (Bedienungs-Review 29.10.2026).
    let issue: String?
    @ViewBuilder var main: Main
    @ViewBuilder var controls: Controls
    @AppStorage("controlsPanelShown") private var shown = true

    init(width: CGFloat = 290, issue: String? = nil, @ViewBuilder main: () -> Main, @ViewBuilder controls: () -> Controls) {
        self.width = width
        self.issue = issue
        self.main = main()
        self.controls = controls()
    }

    var body: some View {
        main
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if !shown, let issue, !issue.isEmpty {
                    PanelIssueBanner(text: issue) { withAnimation { shown = true } }
                }
            }
            .inspector(isPresented: $shown) {
                controls
                    .inspectorColumnWidth(min: 240, ideal: width, max: 520)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation { shown.toggle() }
                    } label: {
                        Label("Bedienfeld", systemImage: "sidebar.trailing")
                    }
                    .help(shown ? "Bedienfeld ausblenden" : "Bedienfeld einblenden")
                }
            }
    }
}

/// Schmales Band über dem Inhalt: Fehler der Seite bei eingeklapptem Bedienfeld.
struct PanelIssueBanner: View {
    let text: String
    let showPanel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(text).font(.callout).lineLimit(2)
            Spacer(minLength: 8)
            Button("Bedienfeld zeigen", action: showPanel)
                .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.red.opacity(0.4)))
        .padding(8)
        .accessibilityElement(children: .combine)
    }
}

/// Gruppenüberschrift als gewöhnliche Listenzeile. Echte Abschnittsköpfe heftet
/// macOS beim Scrollen oben an – unter der Symbolleiste blieb dann der erste
/// Kanal stehen, während die Liste darunter weiterlief.
struct ListGroupHeader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack { content }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .listRowSeparator(.hidden)
    }
}
