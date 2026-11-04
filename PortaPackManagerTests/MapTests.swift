import AppKit
import CoreLocation
import Foundation
import Testing
import WebKit
@testable import PortaPackManager

/// Leaflet-Karte der App: Aufbereitung der Kartenzustände, Unterschiede, Escaping
/// und die Brücke Swift ↔ Seite in einer echten `WKWebView`.
@Suite("Karte (Leaflet)")
struct MapTests {
    static func coordinate(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: Unterschiede

    @Test("Unterschied: neu, unverändert, geändert, entfernt")
    func diffGrundfaelle() {
        let a = MapFeature.marker("a", at: Self.coordinate(53, 10), symbol: .plane, color: "#000000")
        let b = MapFeature.marker("b", at: Self.coordinate(54, 10), symbol: .ship, color: "#000000")
        let first = MapDiff.make(old: [:], new: [a, b])
        #expect(first.diff.upsert.map(\.id) == ["a", "b"])
        #expect(first.diff.remove.isEmpty)

        let same = MapDiff.make(old: first.state, new: [a, b])
        #expect(same.diff.isEmpty)

        var moved = a
        moved.points = [MapPoint(53.1, 10)]
        let second = MapDiff.make(old: first.state, new: [moved])
        #expect(second.diff.upsert.map(\.id) == ["a"])
        #expect(second.diff.remove == ["b"])
        #expect(second.state.keys.sorted() == ["a"])
    }

    @Test("Wachsende Spur schickt nur die neuen Punkte")
    func diffSpurWaechst() {
        let points = (0..<5).map { Self.coordinate(53 + Double($0) * 0.01, 10) }
        let short = MapFeature.line("t", Array(points.prefix(3)), color: "#ff0000")
        let long = MapFeature.line("t", points, color: "#ff0000")
        let state = MapDiff.make(old: [:], new: [short]).state
        let grown = MapDiff.make(old: state, new: [long])
        #expect(grown.diff.upsert.isEmpty)
        #expect(grown.diff.append == [MapDiff.Append(id: "t", points: Array(long.points.suffix(2)))])

        // Anderer Stil: ganz neu setzen. Vorn gekürzt: nur `drop` (siehe gekappte Spur).
        var restyled = long
        restyled.width = 3
        #expect(MapDiff.make(old: state, new: [restyled]).diff.upsert.count == 1)
        let trimmed = MapFeature.line("t", Array(points.prefix(3).dropFirst()), color: "#ff0000")
        #expect(MapDiff.make(old: state, new: [trimmed]).diff.append == [MapDiff.Append(id: "t", points: [], drop: 1)])
    }

    /// Wendet einen Unterschied an wie `ppm-map.js` (`append`: vorne `drop` weg, hinten dazu).
    static func apply(_ diff: MapDiff, to page: inout [String: [MapPoint]]) {
        for id in diff.remove { page[id] = nil }
        for f in diff.upsert { page[f.id] = f.points }
        for a in diff.append {
            guard let points = page[a.id] else { continue }
            page[a.id] = Array(points.dropFirst(a.drop ?? 0)) + a.points
        }
    }

    @Test("Gekappte Spur: vorne weg, hinten neu – nur die neuen Punkte gehen hinüber")
    func diffGekappteSpur() throws {
        func track(_ range: Range<Int>) -> MapFeature {
            .line("t", range.map { Self.coordinate(50 + Double($0) * 0.001, 10 + Double($0) * 0.0005) }, color: "#ff0000")
        }
        let start = MapDiff.make(old: [:], new: [track(0..<1000)])
        // Ein Punkt dazu, einer vorne weg (Kappung bei 1000 Punkten).
        let one = MapDiff.make(old: start.state, new: [track(1..<1001)])
        #expect(one.diff.upsert.isEmpty)
        #expect(one.diff.append == [MapDiff.Append(id: "t", points: Array(track(1000..<1001).points), drop: 1)])
        // Mehrere auf einmal; nur vorne gekürzt; nur hinten gewachsen ohne `drop`.
        #expect(MapDiff.make(old: start.state, new: [track(3..<1003)]).diff.append.first?.drop == 3)
        let trimmed = MapDiff.make(old: start.state, new: [track(10..<1000)]).diff
        #expect(trimmed.append == [MapDiff.Append(id: "t", points: [], drop: 10)])
        #expect(MapDiff.make(old: start.state, new: [track(0..<1002)]).diff.append.first?.drop == nil)
        // Anderer Stil, ganz andere Punkte oder vorne geändert: ganz neu.
        var restyled = track(1..<1001)
        restyled.width = 3
        #expect(MapDiff.make(old: start.state, new: [restyled]).diff.upsert.count == 1)
        #expect(MapDiff.make(old: start.state, new: [track(2000..<2010)]).diff.upsert.count == 1)
        var changed = track(1..<1001)
        changed.points[5] = MapPoint(0, 0)
        #expect(MapDiff.make(old: start.state, new: [changed]).diff.upsert.count == 1)
        // `drop` steht im JSON nur, wenn vorne etwas wegfällt.
        let json = try #require(MapMessage(diff: one.diff).json())
        #expect(json.contains("\"drop\":1"))
        let grownJSON = try #require(MapMessage(diff: MapDiff.make(old: start.state, new: [track(0..<1001)]).diff).json())
        #expect(!grownJSON.contains("drop"))
    }

    @Test("Lange Spur im Dauerbetrieb: je Takt nur die neuen Punkte, die Seite bleibt gleich")
    func diffLangeSpurDauerbetrieb() {
        // Wie der ADS-B-Dekoder: anhängen, vorne auf 1000 kappen, je Takt 0–3 neue Punkte.
        var trail: [MapPoint] = []
        var sent: [String: MapFeature] = [:]
        var page: [String: [MapPoint]] = [:]
        var next = 0
        var largest = 0
        for tick in 0..<400 {
            let count = [0, 1, 3, 2][tick % 4] + (tick == 0 ? 1200 : 0)
            for _ in 0..<count {
                trail.append(MapPoint(50 + Double(next) * 1e-4, 10 + Double(next % 7) * 1e-4))
                next += 1
            }
            if trail.count > 1000 { trail.removeFirst(trail.count - 1000) }
            var line = MapFeature.line("pl:1/trail", [], color: "#007aff", width: 1.5, opacity: 0.5)
            line.points = trail
            let (diff, state) = MapDiff.make(old: sent, new: [line])
            sent = state
            Self.apply(diff, to: &page)
            #expect(page["pl:1/trail"] == trail)
            if tick > 0 {
                #expect(diff.upsert.isEmpty)
                largest = max(largest, diff.append.map(\.points.count).max() ?? 0)
            }
        }
        #expect(largest == 3)
    }

    @Test("Stehendes Ziel: gleiche Punkte mehrfach verwirren den Abgleich nicht")
    func diffGleichePunkte() {
        let same = Array(repeating: Self.coordinate(53, 10), count: 6)
        let old = MapFeature.line("t", same + [Self.coordinate(53.1, 10)], color: "#000000")
        let new = MapFeature.line("t", Array(same.dropFirst(2)) + [Self.coordinate(53.1, 10), Self.coordinate(53.2, 10)], color: "#000000")
        var page: [String: [MapPoint]] = [:]
        let first = MapDiff.make(old: [:], new: [old])
        Self.apply(first.diff, to: &page)
        let second = MapDiff.make(old: first.state, new: [new])
        Self.apply(second.diff, to: &page)
        #expect(page["t"] == new.points)
        #expect(second.diff.upsert.isEmpty)
    }

    @Test("Nicht endliche Werte: Ziel ohne gültigen Punkt fällt weg, die Nachricht bleibt kodierbar")
    func diffNichtEndlich() throws {
        let good = MapFeature.marker("ok", at: Self.coordinate(53, 10), symbol: .plane, color: "#000000")
        let lost = MapFeature.marker("nan", at: Self.coordinate(.nan, 10), symbol: .plane, color: "#000000")
        var turned = MapFeature.marker("rot", at: Self.coordinate(53, 11), symbol: .plane, color: "#000000", rotation: .infinity)
        turned.opacity = .nan
        let trail = MapFeature.line("line", [Self.coordinate(53, 10), Self.coordinate(.nan, 10), Self.coordinate(53.2, .infinity),
                                             Self.coordinate(53.3, 10)], color: "#000000")
        let circle = MapFeature.circle("c", center: Self.coordinate(53, 10), radius: .nan, color: "#000000")
        let result = MapDiff.make(old: [:], new: [good, lost, turned, trail, circle])
        #expect(result.diff.upsert.map(\.id) == ["ok", "rot", "line", "c"])
        #expect(result.state["nan"] == nil)
        #expect(result.state["rot"]?.rotation == nil && result.state["rot"]?.opacity == nil)
        #expect(result.state["line"]?.points == [MapPoint(53, 10), MapPoint(53.3, 10)])
        #expect(result.state["c"]?.radius == nil)
        #expect(MapMessage(diff: result.diff).json() != nil)
        // Derselbe Stand noch einmal: kein Unterschied (gesendeter Stand ist der bereinigte).
        #expect(MapDiff.make(old: result.state, new: [good, lost, turned, trail, circle]).diff.isEmpty)
        // Befehle mit NaN erkennt `isFinite` (die Brücke lässt sie weg).
        #expect(!MapCommand.center(Self.coordinate(.nan, 10)).isFinite)
        #expect(MapCommand.center(Self.coordinate(53, 10)).isFinite)
        // Ohne Bereinigung scheitert die Kodierung – deshalb darf `sent` dann nicht übernommen werden.
        #expect(MapMessage(diff: MapDiff(upsert: [lost])).json() == nil)
    }

    @Test("Controller: eine abgebaute alte Karte trennt die neue nicht")
    @MainActor
    func controllerBesitz() {
        let controller = MapController()
        let old = LeafletCoordinator(), new = LeafletCoordinator()
        var toOld = 0, toNew = 0
        controller.attach(old) { _ in toOld += 1 }
        controller.attach(new) { _ in toNew += 1 }
        controller.detach(from: old)   // die alte Karte wird nach dem Aufbau der neuen abgebaut
        controller.showAll()
        #expect(toOld == 0 && toNew == 1)
        controller.detach(from: new)
        controller.showAll()           // ohne Karte: vorgemerkt, beim nächsten Anhängen zugestellt
        #expect(toNew == 1)
        controller.attach(new) { _ in toNew += 1 }
        #expect(toNew == 2)
    }

    @Test("Doppelte Kennung: die letzte gilt")
    func diffDoppelt() {
        let a = MapFeature.marker("x", at: Self.coordinate(1, 1), symbol: .dot, color: "#111111")
        let b = MapFeature.marker("x", at: Self.coordinate(2, 2), symbol: .dot, color: "#222222")
        let result = MapDiff.make(old: [:], new: [a, b])
        #expect(result.diff.upsert == [b])
        #expect(result.state["x"] == b)
    }

    // MARK: JSON und Escaping

    @Test("Punkte als [Breite, Länge] auf 6 Stellen, leere Felder fehlen")
    func jsonForm() throws {
        let f = MapFeature.marker("p", at: Self.coordinate(53.123456789, 9.87654321), symbol: .plane, color: "#ff9500",
                                  rotation: 270)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(f)) as? [String: Any])
        let points = try #require(object["points"] as? [[Double]])
        #expect(points == [[53.123457, 9.876543]])
        #expect(object["symbol"] as? String == "plane")
        #expect(object["rotation"] as? Double == 270)
        #expect(object["label"] == nil && object["select"] == nil && object["dash"] == nil)
    }

    @Test("Freie Funktexte bleiben Daten: JSON maskiert, Rückweg verlustfrei")
    func escaping() throws {
        let evil = "</script><img src=x onerror=\"alert(1)\">'\\\u{2028}ÆØÅ"
        var f = MapFeature.marker("s", at: Self.coordinate(53.5, 9.9), symbol: .arrow, color: "#007aff", label: evil)
        f.tooltip = evil
        let json = try #require(MapMessage(diff: MapDiff.make(old: [:], new: [f]).diff).json())
        #expect(!json.contains("</"))
        #expect(json.contains("onerror=\\\"alert"))   // Anführungszeichen maskiert
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let upsert = try #require((object["upsert"] as? [[String: Any]])?.first)
        #expect(upsert["label"] as? String == evil)
        #expect(upsert["tooltip"] as? String == evil)
    }

    @Test("Kartenseite setzt Funktexte nur als Text, nie als HTML")
    func seiteOhneInnerHTMLFuerDaten() throws {
        let script = LeafletMap.resource("ppm-map", "js")
        #expect(!script.isEmpty)
        // Nur zwei innerHTML-Zuweisungen, beide mit festen Zeichen (SYMBOLS, Pfeil).
        let assignments = script.components(separatedBy: ".innerHTML =").count - 1
        #expect(assignments == 2)
        #expect(script.contains("el.innerHTML = ARROW_SVG;"))
        #expect(script.contains("sym.innerHTML = symbolMarkup(f);"))
        #expect(script.contains("label.textContent = text"))
        #expect(script.contains("el.textContent = text"))
        // Seite und Swift kennen dieselben Symbole.
        for symbol in MapSymbol.allCases {
            #expect(script.contains("\n    \(symbol.rawValue): "), "Symbol \(symbol.rawValue) fehlt in ppm-map.js")
        }
    }

    @Test("SF-Symbole der Empfänger haben ein Kartenzeichen")
    func symbole() {
        for name in ["airplane", "car.fill", "box.truck.fill", "bus.fill", "house.fill", "cloud.sun.fill",
                     "antenna.radiowaves.left.and.right", "figure.walk", "bicycle", "sailboat.fill", "ferry.fill",
                     "balloon.fill", "cross.case.fill", "flame.fill", "light.beacon.max.fill", "location.north.fill"] {
            #expect(MapSymbol(sfSymbol: name) != .pin, "\(name)")
        }
        #expect(MapSymbol(sfSymbol: "mappin.circle.fill") == .pin)
        #expect(MapSymbol(sfSymbol: "unbekannt") == .pin)
    }

    // MARK: Aufbereitung

    struct Target: MapTarget {
        let id: Int
        let label: String
        let coordinate: CLLocationCoordinate2D
        let heading: Double?
        let stale: Bool
        let trail: [CLLocationCoordinate2D]
        var symbol: MapSymbol { .arrow }
        var symbolSize: Double { 16 }
        static func == (a: Target, b: Target) -> Bool { a.id == b.id }
    }

    @Test("Ziele: Auswahl orange und hervorgehoben, alte grau, Spur nur mit zwei Punkten")
    @MainActor
    func ziele() throws {
        let trail = [Self.coordinate(53, 9), Self.coordinate(53.1, 9.1)]
        let targets = [
            Target(id: 1, label: "MS <Anna>", coordinate: Self.coordinate(53.1, 9.1), heading: 45, stale: false, trail: trail),
            Target(id: 2, label: "Alt", coordinate: Self.coordinate(54, 8), heading: nil, stale: true, trail: [trail[0]]),
        ]
        let features = MapFeature.targets(targets, showTrails: true, selection: 1, prefix: "sh:")
        #expect(features.map(\.id) == ["sh:1/trail", "sh:1", "sh:2"])
        let selected = try #require(features.first { $0.id == "sh:1" })
        #expect(selected.color == MapColor.selected && selected.emphasis == true && selected.rotation == 45)
        #expect(selected.select == "sh:1" && selected.label == "MS <Anna>" && selected.size == 20)
        let old = try #require(features.first { $0.id == "sh:2" })
        #expect(old.color == MapColor.stale && old.dimLabel == true && old.rotation == nil)
        #expect(MapFeature.targets(targets, showTrails: false, selection: nil, prefix: "sh:").count == 2)
    }

    @Test("Flugplätze: Wichtige beschriftet, nicht im Einpassen, Auswahl hervorgehoben")
    func flugplaetze() {
        let airports = [
            Airport(ident: "EDDH", icao: nil, iata: "HAM", name: "Hamburg", kind: .large, latitude: 53.63, longitude: 9.99,
                    elevationFt: 53, municipality: "Hamburg", scheduled: true),
            Airport(ident: "EDHS", icao: nil, iata: nil, name: "Stade", kind: .small, latitude: 53.56, longitude: 9.5,
                    elevationFt: 62, municipality: "Stade", scheduled: false),
        ]
        let far = MapFeature.airports(airports, selected: nil, labelAll: false)
        #expect(far.map(\.label) == ["EDDH", nil])
        #expect(far.allSatisfy { $0.fit == false && $0.layer == .ground })
        let picked = MapFeature.airports(airports, selected: "EDHS", labelAll: false)
        #expect(picked[1].label == "EDHS" && picked[1].emphasis == true && picked[1].color == MapColor.selected)
    }

    @Test("Linie mit Richtungspfeilen: Kennzeichen geht an die Seite, ohne Pfeile fehlt es")
    func pfeileKennzeichen() throws {
        let points = [Self.coordinate(50, 10), Self.coordinate(51, 10)]
        let with = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MapFeature.line("t", points, color: "#ff9500", arrows: true))) as? [String: Any])
        #expect(with["arrows"] as? Bool == true)
        let without = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MapFeature.line("t", points, color: "#ff9500"))) as? [String: Any])
        #expect(without["arrows"] == nil)
    }

    // MARK: Ausschnitt

    @Test("Projektion: Ecken, Mercator-Mitte, Welt-Kopie über die Datumsgrenze")
    func projektion() {
        let view = MapViewport(south: 50, west: 5, north: 55, east: 15, zoom: 7, width: 1000, height: 800)
        #expect(view.point(Self.coordinate(55, 5)) == .zero)
        let corner = view.point(Self.coordinate(50, 15))
        #expect(abs(corner.x - 1000) < 1e-9 && abs(corner.y - 800) < 1e-9)
        // Mercator dehnt nach Norden: die mittlere Breite liegt unter der Bildmitte.
        let mid = view.point(Self.coordinate(52.5, 10))
        #expect(abs(mid.x - 500) < 1e-9 && mid.y > 400)
        let pacific = MapViewport(south: -30, west: 170, north: -10, east: 190, zoom: 5, width: 400, height: 400)
        #expect(abs(pacific.point(Self.coordinate(-20, -175)).x - 300) < 1e-9)
    }

    @Test("Befehle und Einstellungen als JSON")
    func befehle() throws {
        let message = MapMessage(options: MapOptions(fitMaxZoom: 10),
                                 commands: [.follow(), .center(Self.coordinate(53, 10), zoom: 9)])
        let json = try #require(message.json())
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let options = try #require(object["options"] as? [String: Any])
        #expect(options["fitMaxZoom"] as? Double == 10)
        let commands = try #require(object["commands"] as? [[String: Any]])
        #expect(commands.map { $0["cmd"] as? String } == ["follow", "center"])
        #expect(commands[1]["zoom"] as? Double == 9)
        #expect(object["upsert"] == nil && object["remove"] == nil)
        #expect(MapMessage().isEmpty)
    }

    @Test("Kachelrichtlinie: App nennt sich mit Version und Kontakt")
    func userAgent() {
        #expect(LeafletMap.userAgent.hasPrefix("PortaPackManager/"))
        #expect(LeafletMap.userAgent.contains("(+https://github.com/cpeg78/PortaPack-Manager)"))
        #expect(LeafletMap.html.contains("tile.openstreetmap.org"))
        #expect(!LeafletMap.html.contains("unpkg.com") && !LeafletMap.html.contains("cdn"))
    }

    // MARK: Echte Seite

    /// Lädt die Kartenseite in einer `WKWebView` und schickt über die echte Brücke
    /// Ziele mit frei gewähltem Text hinüber. Mit `TEST_RUNNER_PPM_MAP_SNAPSHOT=<datei.png>`
    /// entsteht zusätzlich ein Bildschirmfoto zur Sichtprüfung.
    @Test("Seite lädt, Ziele kommen an, Funktext bleibt Text, Ausschnitt wird gemeldet")
    @MainActor
    func echteSeite() async throws {
        let coordinator = LeafletCoordinator()
        let controller = MapController()
        coordinator.controller = controller
        let webView = LeafletMap.makeWebView(coordinator)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }

        let evil = "<img src=x onerror=\"document.title='pwned'\">MS Anna"
        let trail = (0..<12).map { Self.coordinate(53.4 + Double($0) * 0.02, 9.6 + Double($0) * 0.03) }
        var features: [MapFeature] = [.home(Self.coordinate(53.6, 9.47)),
                                      .line("sh:1/trail", trail, color: MapColor.blue, width: 2, arrows: true)]
        features.append(.marker("sh:1", at: trail.last!, symbol: .arrow, color: MapColor.selected, size: 16, rotation: 40,
                                label: evil, selected: true, select: "sh:1"))
        features.append(.marker("pl:2", at: Self.coordinate(53.9, 10.3), symbol: .plane, color: MapColor.blue,
                                rotation: 120, label: "DLH4AB", select: "pl:2"))
        coordinator.update(features)

        func eval(_ script: String) async -> Any? {
            try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        }
        var count = 0
        for _ in 0..<100 {
            if let n = await eval("return (typeof PPM === 'object') ? PPM.count() : -1") as? Int, n == features.count {
                count = n
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(count == features.count)
        #expect(await eval("return PPM.labelText('sh:1')") as? String == evil)
        #expect(await eval("return document.querySelectorAll('img[src=x]').length") as? Int == 0)
        #expect(await eval("return document.title") as? String != "pwned")
        #expect(await eval("return document.querySelectorAll('.leaflet-control-attribution a').length") as? Int ?? 0 >= 1)
        #expect(await eval("return document.querySelector('.leaflet-control-attribution').textContent") as? String == "© OpenStreetMap")

        // Spur wächst: nur der Zusatz geht hinüber, die Linie hat danach alle Punkte.
        let longer = trail + [Self.coordinate(53.7, 10.0)]
        features[1] = .line("sh:1/trail", longer, color: MapColor.blue, width: 2, arrows: true)
        coordinator.update(features)
        var points = 0
        for _ in 0..<30 {
            points = await eval("return PPM.map() ? (function(){ var n = 0; PPM.map().eachLayer(function(l){ if (l.getLatLngs && !l.getRadius) n = Math.max(n, l.getLatLngs().length); }); return n; })() : 0") as? Int ?? 0
            if points == longer.count { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(points == longer.count)

        // Gekappte Spur: vorne zwei weg, hinten einer dazu – die Seite hat danach genau diese Punkte.
        let capped = Array(longer.dropFirst(2)) + [Self.coordinate(53.75, 10.1)]
        features[1] = .line("sh:1/trail", capped, color: MapColor.blue, width: 2, arrows: true)
        coordinator.update(features)
        let expected = try #require(String(data: JSONEncoder().encode(features[1].points), encoding: .utf8))
        var shown = ""
        for _ in 0..<30 {
            shown = await eval("return PPM.points('sh:1/trail')") as? String ?? ""
            if shown == expected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(shown == expected)


        // Richtungspfeile: reine Funktion in Pixeln, Abstand ≥ 60 Pt, Richtung im Bild.
        let north = await eval("return JSON.stringify(PPM.arrowMarks([[0,0],[0,-600]], 60))") as? String ?? ""
        let marks = try JSONSerialization.jsonObject(with: Data(north.utf8)) as? [[String: Double]] ?? []
        #expect(marks.count == 10)
        #expect(marks.first?["y"] == -30 && marks.allSatisfy { abs($0["angle"] ?? 99) < 1e-9 })
        #expect(await eval("return PPM.arrowMarks([[0,0],[100,0]], 60).map(function(m){return m.angle})[0]") as? Int == 90)
        #expect(await eval("return PPM.arrowMarks([[0,0]], 60).length") as? Int == 0)
        // Herauszoomen dünnt aus, Hineinzoomen setzt wieder mehr Pfeile.
        func arrows(atZoom zoom: Double) async throws -> Int {
            _ = await eval("PPM.map().setZoom(\(zoom), {animate: false}); return 0")
            try await Task.sleep(for: .milliseconds(300))
            return await eval("return PPM.arrowCount('sh:1/trail')") as? Int ?? -1
        }
        let near = try await arrows(atZoom: 12)
        let far = try await arrows(atZoom: 8)
        let again = try await arrows(atZoom: 12)
        #expect(near > far && far >= 0 && again == near)

        // Ausschnitt kommt zurück (Einpassen auf Standort und Ziele).
        for _ in 0..<30 where controller.settledViewport == nil { try await Task.sleep(for: .milliseconds(100)) }
        let view = try #require(controller.settledViewport)
        #expect(view.width == 640 && view.height == 420)
        #expect(view.south < view.north && view.zoom == 12)

        // Abgleich nach gescheiterter Zustellung: `reset` verwirft alles, `upsert` bringt den Stand zurück.
        func receive(_ message: MapMessage) async throws -> Int? {
            let json = try #require(message.json())
            return try? await webView.callAsyncJavaScript("return PPM.receive(m)", arguments: ["m": json], in: nil, contentWorld: .page) as? Int
        }
        #expect(try await receive(MapMessage(diff: MapDiff(upsert: [features[0]]), reset: true)) == 1)
        #expect(try await receive(MapMessage(diff: MapDiff.make(old: [:], new: features).diff)) == features.count)

        if let path = ProcessInfo.processInfo.environment["PPM_MAP_SNAPSHOT"] {
            try await Task.sleep(for: .seconds(3))   // Kacheln
            let tiles = await eval("return document.querySelectorAll('img.leaflet-tile').length + '/' + document.querySelectorAll('img.leaflet-tile-loaded').length") as? String
            print("Kacheln (alle/geladen):", tiles ?? "–")
            let image = try await webView.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
