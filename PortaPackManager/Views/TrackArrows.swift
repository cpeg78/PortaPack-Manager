import MapKit
import SwiftUI

/// Kleine Richtungspfeile entlang einer Bahn (Flugzeuge, Schiffe, Sonden), damit
/// man die Flugrichtung erkennt. Abstand nach Bahnlänge, höchstens `limit` Pfeile.
struct TrackArrow: Identifiable, Equatable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    /// Kurs in Grad (0 = Nord, im Uhrzeigersinn).
    let bearing: Double

    static func == (a: TrackArrow, b: TrackArrow) -> Bool {
        a.id == b.id && a.bearing == b.bearing
            && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }

    /// Pfeile in gleichen Abständen (mindestens `minSpacingKm`), je in der Mitte
    /// des Abschnitts, in dem der Abstand erreicht wird.
    static func marks(_ points: [CLLocationCoordinate2D], minSpacingKm: Double = 3, limit: Int = 20) -> [TrackArrow] {
        guard points.count > 1, limit > 0 else { return [] }
        var lengths: [Double] = []
        for i in 1..<points.count {
            lengths.append(GeoMath.distanceKm(lat1: points[i - 1].latitude, lon1: points[i - 1].longitude,
                                              lat2: points[i].latitude, lon2: points[i].longitude))
        }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return [] }
        let spacing = max(minSpacingKm, total / Double(limit))
        var result: [TrackArrow] = []
        var travelled = spacing / 2
        for i in 1..<points.count where lengths[i - 1] > 0 {
            travelled += lengths[i - 1]
            guard travelled >= spacing else { continue }
            travelled = 0
            let a = points[i - 1], b = points[i]
            let middle = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
            result.append(TrackArrow(id: i, coordinate: middle,
                                     bearing: GeoMath.bearingDegrees(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)))
            if result.count >= limit { break }
        }
        return result
    }
}

/// Die Pfeile als Karteninhalt (in `Map { … }` neben der `MapPolyline`).
struct TrackArrowMarks: MapContent {
    let points: [CLLocationCoordinate2D]
    var color: Color = .orange
    var limit = 20

    var body: some MapContent {
        ForEach(TrackArrow.marks(points, limit: limit)) { arrow in
            Annotation("", coordinate: arrow.coordinate, anchor: .center) {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .rotationEffect(.degrees(arrow.bearing))
                    .allowsHitTesting(false)
            }
            .annotationTitles(.hidden)
        }
    }
}
