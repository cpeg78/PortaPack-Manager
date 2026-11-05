import SwiftUI

/// Aufklappbereich, der auf die ganze Titelzeile reagiert – `DisclosureGroup`
/// klappt unter macOS nur auf, wenn man genau den Pfeil trifft.
struct FoldOut<Content: View>: View {
    let title: LocalizedStringKey
    private let externalExpanded: Binding<Bool>?
    @State private var localExpanded = false
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, isExpanded: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        externalExpanded = isExpanded
        self.content = content
    }

    private var expanded: Binding<Bool> { externalExpanded ?? $localExpanded }

    var body: some View {
        DisclosureGroup(isExpanded: expanded, content: content) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { expanded.wrappedValue.toggle() } }
        }
    }
}
