import Charts
import SwiftUI

/// Verlauf eines Sondenflugs: Höhe, Steigen, Temperatur/Feuchte über die Zeit
/// und das Profil über der Höhe (die klassische Darstellung eines Aufstiegs).
struct SondeHistoryView: View {
    let flight: SondeFlight
    @AppStorage("sondeHistoryChart") private var chart: Kind = .altitude
    /// Messpunkt unter dem Mauszeiger (Infobox im Diagramm).
    @State private var hovered: SondeSample?

    enum Kind: String, CaseIterable, Identifiable {
        case altitude, climb, weather, profile
        var id: String { rawValue }
        var title: String {
            switch self {
            case .altitude: String(localized: "Höhe")
            case .climb: String(localized: "Steigen")
            case .weather: String(localized: "Temperatur & Feuchte")
            case .profile: String(localized: "Profil")
            }
        }
    }

    /// Ausgedünnte Punkte, Aufstieg und Kopfzeile – nur bei neuen Daten neu
    /// berechnet, nicht bei jedem Hover (Review L7, 29.10.2026: bei 7 k Meldungen
    /// 0,1–0,3 ms je Mausbewegung). Ein Klassenobjekt, damit das Nachführen im
    /// `body` keinen Zustandswechsel auslöst.
    @State private var cache = DerivedCache()

    @MainActor private final class DerivedCache {
        struct Key: Equatable {
            var serial: String
            var count: Int
            var first: Date
            var last: Date
        }
        var key: Key?
        var points: [SondeSample] = []
        var ascent: [SondeSample] = []
        var summary = ""

        func update(_ flight: SondeFlight) {
            let key = Key(serial: flight.serial, count: flight.samples.count, first: flight.first, last: flight.last)
            guard key != self.key else { return }
            self.key = key
            points = SondeArchive.thinned(flight.samples)
            if let peakDate = flight.peak?.date {
                ascent = points.filter { $0.date <= peakDate }
            } else {
                ascent = points
            }
            summary = SondeHistoryView.summary(flight)
        }
    }

    private var derived: DerivedCache {
        cache.update(flight)
        return cache
    }

    private var points: [SondeSample] { derived.points }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(flight.serial) · \(flight.type)").font(.headline)
                Text(derived.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Picker("Darstellung", selection: $chart) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Group {
                switch chart {
                case .altitude: altitudeChart
                case .climb: climbChart
                case .weather: weatherCharts
                case .profile: profileCharts
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
    }

    private static func summary(_ flight: SondeFlight) -> String {
        var parts = [flight.first.formatted(.dateTime.day().month().hour().minute())
                     + "–" + flight.last.formatted(.dateTime.hour().minute())]
        if let top = flight.peak?.altitude { parts.append(String(localized: "Gipfel \((top / 1000).formatted(.number.precision(.fractionLength(1)))) km")) }
        if flight.burst { parts.append(String(localized: "geplatzt")) }
        if let t = flight.minTemperature { parts.append(String(localized: "tiefste Temperatur \(t.formatted(.number.precision(.fractionLength(0)))) °C")) }
        parts.append(String(localized: "\(flight.samples.count) Meldungen"))
        return parts.joined(separator: " · ")
    }

    private func empty(_ text: LocalizedStringKey) -> some View {
        ContentUnavailableView(text, systemImage: "chart.xyaxis.line")
    }

    // MARK: Über die Zeit

    @ViewBuilder private var altitudeChart: some View {
        let data = points.filter { $0.altitude != nil }
        if data.isEmpty { empty("Noch keine Höhe empfangen") } else {
            Chart {
                ForEach(data, id: \.date) { s in
                    LineMark(x: .value("Zeit", s.date), y: .value("Höhe (km)", s.altitude! / 1000))
                        .foregroundStyle(.blue)
                }
                timeRule
            }
            .chartYAxisLabel("km")
            .chartOverlay { timeHover($0, data) }
        }
    }

    @ViewBuilder private var climbChart: some View {
        let data = points.filter { $0.verticalSpeed != nil }
        if data.isEmpty { empty("Noch keine Steiggeschwindigkeit empfangen") } else {
            Chart {
                RuleMark(y: .value("Null", 0)).foregroundStyle(.secondary.opacity(0.5))
                ForEach(data, id: \.date) { s in
                    LineMark(x: .value("Zeit", s.date), y: .value("Steigen", s.verticalSpeed!))
                        .foregroundStyle(.green)
                }
                timeRule
            }
            .chartYAxisLabel("m/s")
            .chartOverlay { timeHover($0, data) }
        }
    }

    @ViewBuilder private var weatherCharts: some View {
        let temperature = points.filter { $0.temperature != nil }
        let humidity = points.filter { $0.humidity != nil }
        if temperature.isEmpty && humidity.isEmpty {
            empty("Noch keine Temperatur – sie erscheint nach etwa einer Minute Empfang")
        } else {
            VStack(spacing: 6) {
                Chart {
                    ForEach(temperature, id: \.date) { s in
                        LineMark(x: .value("Zeit", s.date), y: .value("Temperatur", s.temperature!))
                            .foregroundStyle(.red)
                    }
                    timeRule
                }
                .chartYAxisLabel("°C")
                .chartOverlay { timeHover($0, temperature) }
                Chart {
                    ForEach(humidity, id: \.date) { s in
                        LineMark(x: .value("Zeit", s.date), y: .value("Feuchte", s.humidity!))
                            .foregroundStyle(.teal)
                    }
                    timeRule
                }
                .chartYAxisLabel("% rel. Feuchte")
                .chartYScale(domain: 0...100)
                .chartOverlay { timeHover($0, humidity) }
            }
        }
    }

    // MARK: Über der Höhe

    /// Nur der Aufstieg bis zum Gipfel – im Sinkflug misst die Sonde verfälscht
    /// (sie fällt durch ihre eigene Wärmefahne) und das Profil liefe doppelt.
    private var ascent: [SondeSample] { derived.ascent }

    @ViewBuilder private var profileCharts: some View {
        let temperature = ascent.filter { $0.temperature != nil && $0.altitude != nil }
        let humidity = ascent.filter { $0.humidity != nil && $0.altitude != nil }
        if temperature.isEmpty {
            empty("Für das Profil braucht es Temperatur und Höhe")
        } else {
            // Punkte statt Linie: Charts verbindet Linien nach x geordnet, und bei
            // Inversionen (Temperatur steigt mit der Höhe) entstünde ein Zickzack.
            HStack(spacing: 10) {
                Chart {
                    ForEach(temperature, id: \.date) { s in
                        PointMark(x: .value("Temperatur", s.temperature!), y: .value("Höhe", s.altitude! / 1000))
                            .symbolSize(6)
                            .foregroundStyle(.red)
                    }
                    altitudeRule
                }
                .chartXAxisLabel("Temperatur (°C)")
                .chartYAxisLabel("km")
                .chartOverlay { altitudeHover($0, temperature) }
                Chart {
                    ForEach(humidity, id: \.date) { s in
                        PointMark(x: .value("Feuchte", s.humidity!), y: .value("Höhe", s.altitude! / 1000))
                            .symbolSize(6)
                            .foregroundStyle(.teal)
                    }
                    altitudeRule
                }
                .chartXAxisLabel("Feuchte (%)")
                .chartXScale(domain: 0...100)
                .chartYAxisLabel("km")
                .chartOverlay { altitudeHover($0, humidity) }
            }
        }
    }

    // MARK: Infobox am Mauszeiger

    /// Senkrechte Linie samt Infobox am Messpunkt unter dem Mauszeiger.
    @ChartContentBuilder private var timeRule: some ChartContent {
        if let s = hovered {
            RuleMark(x: .value("Zeit", s.date))
                .foregroundStyle(.secondary.opacity(0.6))
                .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    SampleInfo(sample: s)
                }
        }
    }

    /// Waagerechte Linie samt Infobox in der Höhe unter dem Mauszeiger (Profil).
    @ChartContentBuilder private var altitudeRule: some ChartContent {
        if let s = hovered, let altitude = s.altitude {
            RuleMark(y: .value("Höhe", altitude / 1000))
                .foregroundStyle(.secondary.opacity(0.6))
                .annotation(position: .top, alignment: .leading, spacing: 2,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    SampleInfo(sample: s)
                }
        }
    }

    /// Nächster Messpunkt zur Zeit unter dem Mauszeiger.
    private func timeHover(_ proxy: ChartProxy, _ data: [SondeSample]) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active(let point) = phase, let frame = proxy.plotFrame,
                          let date: Date = proxy.value(atX: point.x - geo[frame].origin.x) else { hovered = nil; return }
                    hovered = data.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                }
        }
    }

    /// Nächster Messpunkt zur Höhe unter dem Mauszeiger.
    private func altitudeHover(_ proxy: ChartProxy, _ data: [SondeSample]) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active(let point) = phase, let frame = proxy.plotFrame,
                          let km: Double = proxy.value(atY: point.y - geo[frame].origin.y) else { hovered = nil; return }
                    hovered = data.min { abs(($0.altitude ?? 0) / 1000 - km) < abs(($1.altitude ?? 0) / 1000 - km) }
                }
        }
    }
}

/// Kleine Infobox mit den Werten eines Messpunkts.
private struct SampleInfo: View {
    let sample: SondeSample

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(sample.date.formatted(date: .omitted, time: .standard)).fontWeight(.semibold)
            if let a = sample.altitude {
                Text("Höhe \((a / 1000).formatted(.number.precision(.fractionLength(2)))) km")
            }
            if let v = sample.verticalSpeed {
                Text("Steigen \(v.formatted(.number.precision(.fractionLength(1)))) m/s")
            }
            if let t = sample.temperature {
                Text("Temperatur \(t.formatted(.number.precision(.fractionLength(1)))) °C")
            }
            if let h = sample.humidity {
                Text("Feuchte \(h.formatted(.number.precision(.fractionLength(0)))) %")
            }
        }
        .font(.caption.monospacedDigit())
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }
}
