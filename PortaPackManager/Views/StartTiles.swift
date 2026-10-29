import SwiftUI

/// Startseite „Was möchtest du sehen?“: ein Klick öffnet die Seite, wechselt
/// bei Bedarf in den HackRF-Modus und startet den Empfang. Jede Kachel sagt,
/// ob gerade etwas zu erwarten ist – aus Daten, die die App ohnehin hat.
struct StartTiles: View {
    @Environment(DeviceSession.self) private var session
    /// Kachel, die wegen einer laufenden Installation nicht starten darf.
    @State private var pending: SidebarItem?
    /// Titel und Symbol kommen aus der Seitenleiste (`SidebarItem`), damit man
    /// die Seite dort wiederfindet; der Untertitel erklärt in Alltagssprache.
    struct Tile: Identifiable {
        let page: SidebarItem
        let subtitle: String
        var start = true
        var id: SidebarItem { page }
        var title: String { page.title }
        var symbol: String { page.symbol }
    }

    static let tiles: [Tile] = [
        Tile(page: .adsb, subtitle: String(localized: "Flugzeuge live auf der Karte, mit Typ, Strecke und Foto")),
        Tile(page: .ais, subtitle: String(localized: "Frachter und Fähren in Funkreichweite")),
        Tile(page: .radio, subtitle: String(localized: "UKW hören, mit Sendernamen")),
        Tile(page: .dab, subtitle: String(localized: "Radio in bester Qualität")),
        Tile(page: .tv, subtitle: String(localized: "Fernsehen über Antenne")),
        Tile(page: .sonde, subtitle: String(localized: "Messsonden bis in 35 km Höhe")),
        Tile(page: .meteor, subtitle: String(localized: "Wetterbilder beim Überflug"), start: false),
        Tile(page: .acars, subtitle: String(localized: "Textnachrichten aus dem Cockpit")),
        Tile(page: .sensors, subtitle: String(localized: "Wetterstationen und Thermometer")),
        Tile(page: .gps, subtitle: String(localized: "Eigene Position aus den Satelliten")),
        Tile(page: .spectrum, subtitle: String(localized: "Was funkt hier? Spektrum und Wasserfall")),
        Tile(page: .antennaCheck, subtitle: String(localized: "Wofür taugt meine Antenne? (2 min)"), start: false),
    ]

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Self.tiles) { tile in
                Button { choose(tile) } label: { card(tile) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        // Während einer Installation nie das Gerät nehmen. Einen laufenden
        // Plan-Termin fragt `ReceiverStore.requestStart` beim Start der Seite ab –
        // vorher fragte die Kachel zusätzlich, also zweimal (Review 29.10.2026).
        .confirmationDialog(String(localized: "Am Mac läuft gerade eine Installation."),
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            if let page = pending {
                Button("Nur die Seite öffnen") { AppNavigation.shared.open(page, start: false); pending = nil }
            }
            Button("Abbrechen", role: .cancel) { pending = nil }
        }
    }

    private func choose(_ tile: Tile) {
        if tile.start, session.busy {
            pending = tile.page
        } else {
            AppNavigation.shared.open(tile.page, start: tile.start)
        }
    }

    private func card(_ tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: tile.symbol).font(.title2).foregroundStyle(.tint)
                Spacer()
                if let live = live(tile.page) {
                    Text(live).font(.caption.weight(.medium)).foregroundStyle(.green)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            Text(tile.title).font(.headline)
            Text(tile.subtitle).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Was gerade los ist – nur, wo die App es schon weiß.
    private func live(_ page: SidebarItem) -> String? {
        let hub = RemoteHub.shared, planner = ReceptionPlanner.shared
        switch page {
        case .adsb: return hub.adsb.running ? String(localized: "\(hub.adsb.aircraftCount) gerade") : nil
        case .ais: return hub.ais.running ? String(localized: "\(hub.ais.vesselCount) gerade") : nil
        case .dab: return hub.dab.running ? String(localized: "läuft") : nil
        case .sonde:
            let n = planner.sondesInRange.count
            return n > 0 ? String(localized: "\(n) in Reichweite") : nil
        case .meteor:
            guard let next = planner.passes.first(where: { $0.end > Date() }) else { return nil }
            return next.start <= Date() ? String(localized: "jetzt!") : String(localized: "ab \(next.start.formatted(date: .omitted, time: .shortened))")
        default: return nil
        }
    }
}
