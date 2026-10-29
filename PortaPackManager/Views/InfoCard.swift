import SwiftUI

/// Foto für eine Infokarte samt Quellenangabe (Fotograf, Lizenz, Seite).
struct InfoCardPhoto: Equatable {
    let imageURL: URL
    let pageURL: URL
    /// z. B. „Foto: Kilian Feßler · planespotters.net“
    let credit: String
    /// Hilfetext beim Bild, z. B. „Foto auf planespotters.net öffnen“
    let help: String
}

/// Inhalt der Infokarten auf den Kartenseiten (ADS-B, AIS): Titel, Foto,
/// Wertetabelle, letzter Kontakt, Link.
struct InfoCardContent: View {
    struct Row: Equatable {
        let label: String
        let value: String
        init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    let title: String
    let subtitle: String?
    let photo: InfoCardPhoto?
    let rows: [Row]
    let lastSeen: Date
    let linkTitle: String
    let linkURL: URL?
    let width: CGFloat
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.semibold).monospaced()).lineLimit(1)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Auswahl aufheben")
                    .accessibilityLabel("Auswahl aufheben")
            }
            if let subtitle {
                Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let photo {
                VStack(alignment: .leading, spacing: 2) {
                    AsyncImage(url: photo.imageURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary).overlay(ProgressView().controlSize(.small))
                    }
                    .frame(width: width - 20, height: (width - 20) * 2 / 3)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { NSWorkspace.shared.open(photo.pageURL) }
                    .help(photo.help)
                    Link(destination: photo.pageURL) {
                        Text(photo.credit).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .font(.caption2)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(rows, id: \.label) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.value).monospacedDigit()
                    }
                }
                GridRow {
                    Text("Kontakt").foregroundStyle(.secondary)
                    Text(lastSeen, style: .relative)
                }
            }
            .font(.callout)
            if let linkURL {
                Button(linkTitle, systemImage: "safari") { NSWorkspace.shared.open(linkURL) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(10)
        .frame(width: width)
    }
}
