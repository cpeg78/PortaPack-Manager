import AppKit
import CoreLocation
import SwiftUI

/// Punkt auf der Karte, als `[breite, länge]` kodiert (auf 6 Stellen gerundet,
/// das sind ≈ 10 cm – kürzere Nachrichten an die Kartenseite).
struct MapPoint: Equatable, Sendable, Encodable {
    var lat: Double
    var lon: Double

    init(_ lat: Double, _ lon: Double) { self.lat = lat; self.lon = lon }
    init(_ c: CLLocationCoordinate2D) { self.init(c.latitude, c.longitude) }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode((lat * 1e6).rounded() / 1e6)
        try c.encode((lon * 1e6).rounded() / 1e6)
    }
}

/// Zeichen eines Markers. Die Formen stehen in `ppm-map.js` (SVG, 24×24,
/// gerichtete zeigen nach Norden) – nur diese festen Namen gehen an die Seite.
enum MapSymbol: String, Sendable, Encodable, CaseIterable {
    case plane, arrow, arrowHead, dot, house, antenna, signal, beacon, balloon, descent, ascent, scope
    case person, planeCircle, hexagon, sos, ship, car, truck, bus, weather, walker, bike, sailboat
    case medical, flame, pin
    /// Schiff von oben (Bug nach Norden), dunkel umrandet – hebt sich von Wasser und Land ab.
    case hull
    /// Flugplätze: gefüllter Kreis (groß/mittel), Ring (klein/Wasser), „H“ (Hubschrauber).
    case apFilled, apRing, apHeli

    /// Nächstes Kartenzeichen zu einem SF-Symbol (APRS u. a. liefern SF-Namen).
    init(sfSymbol name: String) {
        switch name {
        case "airplane": self = .plane
        case "airplane.circle.fill": self = .planeCircle
        case "location.north.fill": self = .arrow
        case "arrowtriangle.up.fill": self = .arrowHead
        case "circle.fill": self = .dot
        case "house.fill", "house": self = .house
        case "antenna.radiowaves.left.and.right", "dot.radiowaves.left.and.right": self = .antenna
        case "dot.radiowaves.up.forward": self = .signal
        case "light.beacon.max.fill": self = .beacon
        case "balloon.fill", "balloon": self = .balloon
        case "arrow.down.circle.fill": self = .descent
        case "arrow.up.circle", "arrow.up.circle.fill": self = .ascent
        case "scope": self = .scope
        case "person.fill": self = .person
        case "hexagon.fill": self = .hexagon
        case "sos.circle.fill", "sos": self = .sos
        case "ferry.fill", "ferry": self = .ship
        case "car.fill": self = .car
        case "box.truck.fill": self = .truck
        case "bus.fill": self = .bus
        case "cloud.sun.fill": self = .weather
        case "figure.walk": self = .walker
        case "bicycle": self = .bike
        case "sailboat.fill": self = .sailboat
        case "cross.case.fill": self = .medical
        case "flame.fill": self = .flame
        default: self = .pin
        }
    }
}

/// Ebene einer Karteneinheit (von unten nach oben).
enum MapLayer: String, Sendable, Encodable {
    /// Flächen und Kreise.
    case area
    /// Spuren und Linien.
    case track
    /// Unter den Zielen, z. B. Flugplätze.
    case ground
    /// Ziele (Flugzeuge, Schiffe, Sonden …).
    case marker
    /// Ganz oben.
    case top
}

/// Eine Einheit auf der Karte: Marker, Linie, Fläche oder Kreis. Wird als JSON an
/// die Kartenseite geschickt; jede Kennung steht für genau eine Leaflet-Ebene, die
/// nur neu gesetzt wird, wenn sich an ihr etwas ändert (`MapDiff`).
struct MapFeature: Equatable, Sendable, Encodable, Identifiable {
    enum Kind: String, Sendable, Encodable { case marker, line, polygon, circle }

    var id: String
    var kind: Kind
    var layer: MapLayer
    /// Marker/Kreis: ein Punkt; Linie/Fläche: alle Eckpunkte.
    var points: [MapPoint]
    /// CSS-Farbe (`#rrggbb`).
    var color: String
    var opacity: Double?

    // Marker
    var symbol: MapSymbol?
    /// Drehung des Symbols in Grad (im Uhrzeigersinn, 0 = Norden).
    var rotation: Double?
    var size: Double?
    /// Farbiger Kreis mit weißem Zeichen (wie ein MapKit-`Marker`).
    var badge: Bool?
    /// Beschriftung unter (bzw. rechts neben) dem Symbol – Funktext, wird nur als Text gesetzt.
    var label: String?
    var labelPosition: String?
    var labelStyle: String?
    var dimLabel: Bool?
    /// Hervorgehoben (Auswahl): fette Beschriftung, die nie ausgeblendet wird.
    var emphasis: Bool?
    var labelPriority: Int?
    /// Hinweis beim Darüberfahren.
    var tooltip: String?
    /// Stapelreihenfolge (größer = oben).
    var z: Int?

    // Linie, Fläche, Kreis
    var width: Double?
    var dash: [Double]?
    var fill: String?
    var fillOpacity: Double?
    /// Kreisradius in Metern.
    var radius: Double?
    /// Linie: Richtungspfeile in Linienfarbe. Die Seite setzt sie bei jedem Zoom neu,
    /// mit festem Abstand in Bildschirmpunkten (`arrowMarks` in `ppm-map.js`) –
    /// herausgezoomt weniger, hineingezoomt mehr.
    var arrows: Bool?

    /// Wert, der beim Anklicken zurückgemeldet wird; `nil` = nicht anklickbar.
    var select: String?
    /// Zählt beim Einpassen mit (Standard: Marker, Flächen, Kreise ja; Linien nein).
    var fit: Bool?

    init(id: String, kind: Kind, layer: MapLayer, points: [MapPoint], color: String) {
        self.id = id; self.kind = kind; self.layer = layer; self.points = points; self.color = color
    }

    // MARK: Bausteine

    static func marker(_ id: String, at c: CLLocationCoordinate2D, symbol: MapSymbol, color: String,
                       size: Double = 18, rotation: Double? = nil, label: String? = nil,
                       selected: Bool = false, select: String? = nil, layer: MapLayer = .marker) -> MapFeature {
        var f = MapFeature(id: id, kind: .marker, layer: layer, points: [MapPoint(c)], color: color)
        f.symbol = symbol
        f.size = size
        f.rotation = rotation
        f.label = label?.isEmpty == true ? nil : label
        f.select = select
        if selected { f.emphasis = true; f.z = 1000; f.size = size + 4 }
        return f
    }

    /// Wie ein MapKit-`Marker`: farbiger Kreis mit weißem Zeichen und Beschriftung.
    static func badge(_ id: String, at c: CLLocationCoordinate2D, symbol: MapSymbol, color: String,
                      label: String? = nil, tooltip: String? = nil, select: String? = nil) -> MapFeature {
        var f = marker(id, at: c, symbol: symbol, color: color, size: 26, label: label, select: select)
        f.badge = true
        f.tooltip = tooltip
        f.z = 500
        return f
    }

    /// Der eigene Standort (Haus, braun; Beschriftung nur beim Darüberfahren).
    static func home(_ c: CLLocationCoordinate2D, color: String = MapColor.home) -> MapFeature {
        var f = badge("home", at: c, symbol: .house, color: color, tooltip: String(localized: "Standort"))
        f.size = 24
        f.z = -100
        return f
    }

    static func line(_ id: String, _ coordinates: [CLLocationCoordinate2D], color: String, width: Double = 2,
                     opacity: Double? = nil, dash: [Double]? = nil, arrows: Bool = false,
                     selected: Bool = false) -> MapFeature {
        var f = MapFeature(id: id, kind: .line, layer: .track, points: coordinates.map(MapPoint.init), color: color)
        f.width = width
        if arrows { f.arrows = true }
        f.opacity = opacity
        f.dash = dash
        if selected { f.z = 1 }
        return f
    }

    static func polygon(_ id: String, _ coordinates: [CLLocationCoordinate2D], color: String, width: Double = 1,
                        fillOpacity: Double, select: String? = nil, selected: Bool = false) -> MapFeature {
        var f = MapFeature(id: id, kind: .polygon, layer: .area, points: coordinates.map(MapPoint.init), color: color)
        f.width = width
        f.fillOpacity = fillOpacity
        f.select = select
        if selected { f.z = 1 }
        return f
    }

    static func circle(_ id: String, center: CLLocationCoordinate2D, radius: Double, color: String,
                       width: Double = 1, opacity: Double? = nil, fillOpacity: Double? = nil) -> MapFeature {
        var f = MapFeature(id: id, kind: .circle, layer: .area, points: [MapPoint(center)], color: color)
        f.radius = radius
        f.width = width
        f.opacity = opacity
        f.fillOpacity = fillOpacity
        return f
    }

    /// Unsichtbarer Kreis, der nur beim Einpassen zählt (typische Reichweite um den
    /// Standort) – ohne Ziele zoomte die Karte sonst bis auf die eigene Straße.
    static func extent(_ id: String, center: CLLocationCoordinate2D, radius: Double) -> MapFeature {
        var f = circle(id, center: center, radius: radius, color: "#000000", width: 0)
        f.fit = true
        return f
    }
}

/// Farben der Karte (CSS). Systemfarben werden beim Erzeugen aufgelöst.
enum MapColor {
    static let selected = "#ff9500"
    static let stale = "#8e8e93"
    static let home = "#a2845e"
    static let red = "#ff3b30"
    static let purple = "#af52de"
    static let blue = "#007aff"
    static let indigo = "#5856d6"
    static let green = "#34c759"
    static let teal = "#30b0c7"

    /// Akzentfarbe des Systems.
    @MainActor static var accent: String { hex(NSColor.controlAccentColor) }

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return blue }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    static func hex(_ color: Color) -> String { hex(NSColor(color)) }
}

/// Unterschied zwischen dem, was die Seite zeigt, und dem neuen Stand – nur das
/// geht an die Seite. Wächst eine Linie nur am Ende (Spuren), gehen nur die neuen
/// Punkte hinüber.
struct MapDiff: Equatable {
    struct Append: Equatable, Encodable {
        var id: String
        var points: [MapPoint]
    }

    var upsert: [MapFeature] = []
    var append: [Append] = []
    var remove: [String] = []

    var isEmpty: Bool { upsert.isEmpty && append.isEmpty && remove.isEmpty }

    /// Vergleicht `old` (gesendet) mit `new`; doppelte Kennungen: die letzte gilt.
    /// Liefert den Unterschied und den neuen gesendeten Stand.
    static func make(old: [String: MapFeature], new: [MapFeature]) -> (diff: MapDiff, state: [String: MapFeature]) {
        var state: [String: MapFeature] = [:]
        state.reserveCapacity(new.count)
        var order: [String] = []
        for feature in new {
            if state.updateValue(feature, forKey: feature.id) == nil { order.append(feature.id) }
        }
        var diff = MapDiff()
        for id in order {
            let feature = state[id]!
            guard let previous = old[id] else { diff.upsert.append(feature); continue }
            if previous == feature { continue }
            if let tail = appendedTail(previous, feature) {
                diff.append.append(Append(id: id, points: tail))
            } else {
                diff.upsert.append(feature)
            }
        }
        for id in old.keys where state[id] == nil { diff.remove.append(id) }
        diff.remove.sort()
        return (diff, state)
    }

    /// Neue Punkte, wenn `new` dieselbe Linie wie `old` ist und nur hinten wächst.
    static func appendedTail(_ old: MapFeature, _ new: MapFeature) -> [MapPoint]? {
        guard old.kind == .line, new.kind == .line, new.points.count > old.points.count else { return nil }
        var a = old, b = new
        a.points = []; b.points = []
        guard a == b, new.points.starts(with: old.points) else { return nil }
        return Array(new.points[old.points.count...])
    }
}

/// Befehl an die Kartenseite (Ausschnitt).
struct MapCommand: Equatable, Encodable {
    var cmd: String
    var lat: Double?
    var lon: Double?
    var zoom: Double?
    var south: Double?
    var west: Double?
    var north: Double?
    var east: Double?
    var maxZoom: Double?
    var animate: Bool?

    /// Allen Zielen folgen (wie `.automatic` bei MapKit).
    static func follow(animated: Bool = true) -> MapCommand { MapCommand(cmd: "follow", animate: animated) }

    static func center(_ c: CLLocationCoordinate2D, zoom: Double? = nil, animated: Bool = true) -> MapCommand {
        MapCommand(cmd: "center", lat: c.latitude, lon: c.longitude, zoom: zoom, animate: animated)
    }

    static func fit(south: Double, west: Double, north: Double, east: Double, maxZoom: Double? = nil,
                    animated: Bool = true) -> MapCommand {
        MapCommand(cmd: "fit", south: south, west: west, north: north, east: east, maxZoom: maxZoom, animate: animated)
    }
}

/// Feste Einstellungen einer Karte (beim Laden der Seite).
struct MapOptions: Equatable, Encodable {
    /// Höchste Zoomstufe beim Einpassen (Leaflet-Stufen: 10 ≈ 50 km, 13 ≈ 6 km, 16 ≈ 800 m Breite).
    var fitMaxZoom: Double = 13
    var center: MapPoint = MapPoint(51, 10)
    var zoom: Double = 5
    var zoomInTitle = String(localized: "Vergrößern")
    var zoomOutTitle = String(localized: "Verkleinern")
}

/// Eine Nachricht an die Kartenseite.
struct MapMessage: Encodable {
    var options: MapOptions?
    var upsert: [MapFeature]?
    var append: [MapDiff.Append]?
    var remove: [String]?
    var commands: [MapCommand]?

    init(options: MapOptions? = nil, diff: MapDiff = MapDiff(), commands: [MapCommand] = []) {
        self.options = options
        upsert = diff.upsert.isEmpty ? nil : diff.upsert
        append = diff.append.isEmpty ? nil : diff.append
        remove = diff.remove.isEmpty ? nil : diff.remove
        self.commands = commands.isEmpty ? nil : commands
    }

    var isEmpty: Bool { options == nil && upsert == nil && append == nil && remove == nil && commands == nil }

    /// JSON-Text – geht als Argument (Daten) an `PPM.receive`, nie als JS-Quelltext.
    func json() -> String {
        // Schrägstriche bleiben maskiert („<\/script>“) – doppelte Vorsicht, falls der
        // Text je in HTML landet.
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
