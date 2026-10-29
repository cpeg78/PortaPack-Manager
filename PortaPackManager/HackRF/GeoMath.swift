import Foundation

/// Abstand und Peilung zwischen zwei geografischen Punkten (Großkreis).
enum GeoMath {
    /// Entfernung in Kilometern (Haversine).
    static func distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371.0088
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Anfangspeilung in Grad (0 = Nord, im Uhrzeigersinn).
    static func bearingDegrees(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
        let dλ = (lon2 - lon1) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Kompasskürzel (N, NO, O …) zu einer Peilung.
    static func compass(_ degrees: Double) -> String {
        let names = [String(localized: "N", comment: "Himmelsrichtung Nord"), String(localized: "NO", comment: "Himmelsrichtung Nordost"),
                     String(localized: "O", comment: "Himmelsrichtung Ost"), String(localized: "SO", comment: "Himmelsrichtung Südost"),
                     String(localized: "S", comment: "Himmelsrichtung Süd"), String(localized: "SW", comment: "Himmelsrichtung Südwest"),
                     String(localized: "W", comment: "Himmelsrichtung West"), String(localized: "NW", comment: "Himmelsrichtung Nordwest")]
        // Kurse kommen teils aus Funkdaten – NaN/∞ ließe Int() abstürzen.
        guard degrees.isFinite else { return "–" }
        let i = Int((degrees.truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return names[(i + 8) % 8]
    }
}
