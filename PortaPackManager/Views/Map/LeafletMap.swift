import AppKit
import CoreLocation
import OSLog
import SwiftUI
import WebKit

/// Sichtbarer Ausschnitt der Karte, wie ihn die Seite meldet. Längen können über
/// ±180° hinausgehen (Leaflet rechnet über die Datumsgrenze weiter).
struct MapViewport: Equatable, Sendable {
    var south: Double
    var west: Double
    var north: Double
    var east: Double
    var zoom: Double
    var width: Double
    var height: Double

    var size: CGSize { CGSize(width: width, height: height) }

    /// Koordinate → Punkt in der Kartenansicht (Web-Mercator wie Leaflet, Norden
    /// oben). Die Länge wird auf die Welt-Kopie gelegt, die dem Ausschnitt am
    /// nächsten liegt.
    func point(_ c: CLLocationCoordinate2D) -> CGPoint {
        guard east > west, width > 0, height > 0 else { return .zero }
        let mid = (west + east) / 2
        var lon = c.longitude
        while lon - mid > 180 { lon -= 360 }
        while lon - mid < -180 { lon += 360 }
        let x = (lon - west) / (east - west) * width
        let top = Self.mercatorY(north), bottom = Self.mercatorY(south)
        let y = (top - Self.mercatorY(c.latitude)) / (top - bottom) * height
        return CGPoint(x: x, y: y)
    }

    static func mercatorY(_ lat: Double) -> Double {
        let clamped = min(max(lat, -85.05112878), 85.05112878) * .pi / 180
        return log(tan(.pi / 4 + clamped / 2))
    }

    /// Ausschnitt für die Flugplatzauswahl.
    var bounds: AirportFilter.Bounds? { AirportFilter.Bounds(south: south, west: west, north: north, east: east) }
}

/// Steuert eine `LeafletMap`: Ausschnitt setzen, allen Zielen folgen, und meldet
/// den sichtbaren Ausschnitt zurück. Als `@State` in der Ansicht halten.
@MainActor @Observable
final class MapController {
    /// Laufend beim Ziehen/Zoomen (für Infokarten, die neben einem Ziel stehen).
    private(set) var viewport: MapViewport?
    /// Erst nach dem Loslassen (für teurere Ableitungen wie die Flugplätze).
    private(set) var settledViewport: MapViewport?
    /// Der Ausschnitt folgt allen Zielen, bis der Nutzer die Karte bewegt oder
    /// eine Auswahl angesprungen wird – dann zeigen die Seiten „Alle zeigen“.
    private(set) var following = true

    @ObservationIgnored fileprivate var send: ((MapCommand) -> Void)?
    @ObservationIgnored fileprivate var queued: [MapCommand] = []

    /// Allen Zielen folgen und einpassen.
    func showAll(animated: Bool = true) {
        setFollowing(true)
        issue(.follow(animated: animated))
    }

    /// Auf eine Koordinate setzen (Zoom bleibt, wenn `zoom` fehlt).
    func center(on c: CLLocationCoordinate2D, zoom: Double? = nil, animated: Bool = true) {
        setFollowing(false)
        issue(.center(c, zoom: zoom, animated: animated))
    }

    /// Kreis um eine Koordinate zeigen (z. B. 300 m um die GPS-Position).
    func show(around c: CLLocationCoordinate2D, radiusMeters: Double, animated: Bool = true) {
        let dLat = radiusMeters / 111_320
        let dLon = radiusMeters / (111_320 * max(cos(c.latitude * .pi / 180), 0.01))
        setFollowing(false)
        issue(.fit(south: c.latitude - dLat, west: c.longitude - dLon, north: c.latitude + dLat,
                   east: c.longitude + dLon, animated: animated))
    }

    private func issue(_ command: MapCommand) {
        if let send { send(command) } else { queued.append(command) }
    }

    private func setFollowing(_ value: Bool) {
        if following != value { following = value }
    }

    fileprivate func attach(_ send: @escaping (MapCommand) -> Void) {
        self.send = send
        let pending = queued
        queued = []
        pending.forEach(send)
    }

    fileprivate func detach() { send = nil }

    fileprivate func receivedView(_ view: MapViewport, moving: Bool) {
        if viewport != view { viewport = view }
        if !moving, settledViewport != view { settledViewport = view }
    }

    fileprivate func userMoved() { setFollowing(false) }
}

/// Karte mit OpenStreetMap-Kacheln über Leaflet in einer `WKWebView` – überall in
/// der App dieselbe Karte wie auf der Fernzugriffs-Webseite. Inhalt sind
/// `MapFeature`s; an die Seite geht nur, was sich geändert hat (`MapDiff`).
/// Aufbau und Funde: `Docs/Erfahrungen/Karten.md`.
struct LeafletMap: NSViewRepresentable {
    let features: [MapFeature]
    let controller: MapController
    var options = MapOptions()
    /// Angeklicktes Ziel (`MapFeature.select`) bzw. `nil` beim Klick ins Leere.
    var onSelect: ((String?) -> Void)?
    /// Klick ins Leere mit Koordinate.
    var onTap: ((CLLocationCoordinate2D) -> Void)?

    static let log = Logger(subsystem: "de.christiangolz.portapackmanager", category: "Karte")

    func makeCoordinator() -> LeafletCoordinator { LeafletCoordinator() }

    func makeNSView(context: Context) -> LeafletWebView {
        let coordinator = context.coordinator
        let webView = Self.makeWebView(coordinator)
        coordinator.parent = self
        controller.attach { [weak coordinator] in coordinator?.command($0) }
        coordinator.controller = controller
        return webView
    }

    /// Web-Ansicht mit Leaflet, Brücke und Kachelrichtlinie; lädt die Seite.
    static func makeWebView(_ coordinator: LeafletCoordinator) -> LeafletWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()   // Kacheln bleiben im HTTP-Cache
        let content = WKUserContentController()
        content.add(LeafletMessageProxy(coordinator), name: "map")
        for source in Self.scripts {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        configuration.userContentController = content
        let webView = LeafletWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setAccessibilityLabel(String(localized: "Karte"))
        coordinator.webView = webView
        webView.loadHTMLString(Self.html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: LeafletWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.controller !== controller {
            coordinator.controller?.detach()
            coordinator.controller = controller
            controller.attach { [weak coordinator] in coordinator?.command($0) }
        }
        coordinator.update(features)
    }

    static func dismantleNSView(_ webView: LeafletWebView, coordinator: LeafletCoordinator) {
        coordinator.controller?.detach()
        coordinator.controller = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "map")
        webView.stopLoading()
    }

    // MARK: Seite

    /// OSM-Kachelrichtlinie: die App nennt sich mit Version und Kontakt.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "PortaPackManager/\(version) (+https://github.com/cpeg78/PortaPack-Manager)"
    }()

    static func resource(_ name: String, _ ext: String) -> String {
        for bundle in [Bundle.main, Bundle(for: LeafletCoordinator.self)] {
            if let url = bundle.url(forResource: name, withExtension: ext),
               let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        log.error("Kartenbaustein \(name, privacy: .public).\(ext, privacy: .public) fehlt im Bundle")
        return ""
    }

    /// Gerüst der Seite: nur Stile und der Kartenbereich. Leaflet und `ppm-map.js`
    /// kommen als Benutzerskripte dazu – nichts wird in HTML verkettet.
    static let html: String = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https://tile.openstreetmap.org data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <style>\(resource("leaflet", "css"))</style>
        <style>\(resource("ppm-map", "css"))</style>
        </head><body><div id="map"></div></body></html>
        """

    static let scripts: [String] = [resource("leaflet", "js"), resource("ppm-map", "js")]
}

/// Leitet Meldungen der Seite weiter, ohne den Koordinator festzuhalten
/// (`WKUserContentController` hält seine Empfänger stark).
final class LeafletMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: LeafletCoordinator?
    init(_ target: LeafletCoordinator) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message.body) }
    }
}

/// Brücke Swift ↔ Seite für eine `LeafletMap`.
@MainActor
final class LeafletCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var webView: WKWebView?
    var parent: LeafletMap?
    weak var controller: MapController?
    private var ready = false
    private var sent: [String: MapFeature] = [:]
    private var latest: [MapFeature] = []
    private var pendingCommands: [MapCommand] = []

    func update(_ features: [MapFeature]) {
        latest = features
        guard ready else { return }
        flush()
    }

    func command(_ command: MapCommand) {
        pendingCommands.append(command)
        guard ready else { return }
        flush()
    }

    private func flush(options: MapOptions? = nil) {
        let (diff, state) = MapDiff.make(old: sent, new: latest)
        sent = state
        let message = MapMessage(options: options, diff: diff, commands: pendingCommands)
        pendingCommands = []
        guard !message.isEmpty else { return }
        send(message)
    }

    private func send(_ message: MapMessage) {
        guard let webView else { return }
        // Der JSON-Text geht als Argument hinüber – nie als Teil des Quelltexts.
        webView.callAsyncJavaScript("return PPM.receive(m)", arguments: ["m": message.json()], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                LeafletMap.log.error("Karte: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func receive(_ body: Any) {
        guard let object = body as? [String: Any], let type = object["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            sent = [:]
            flush(options: parent?.options ?? MapOptions())
        case "view":
            func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
            guard let s = number("south"), let w = number("west"), let n = number("north"), let e = number("east"),
                  let z = number("zoom"), let width = number("width"), let height = number("height") else { return }
            let view = MapViewport(south: s, west: w, north: n, east: e, zoom: z, width: width, height: height)
            controller?.receivedView(view, moving: (object["moving"] as? Bool) ?? false)
        case "follow":
            controller?.userMoved()
        case "select":
            parent?.onSelect?(object["key"] as? String)
        case "tap":
            parent?.onSelect?(nil)
            if let lat = (object["lat"] as? NSNumber)?.doubleValue, let lon = (object["lon"] as? NSNumber)?.doubleValue {
                parent?.onTap?(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        case "error":
            LeafletMap.log.error("Kartenseite: \(String(describing: object["message"] ?? ""), privacy: .public)")
        default:
            break
        }
    }

    // MARK: Navigation – Links (Attribution) im Browser öffnen, die Seite nie verlassen

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
            return
        }
        let url = action.request.url
        decisionHandler(url == nil || url?.scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.scheme == "https" { NSWorkspace.shared.open(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Inhaltsprozess abgestürzt: neu laden, danach schickt "ready" den ganzen Stand.
        ready = false
        sent = [:]
        webView.loadHTMLString(LeafletMap.html, baseURL: nil)
    }
}

/// `WKWebView` ohne Kontextmenü („Neu laden“ u. Ä. ergeben auf der Karte keinen Sinn).
final class LeafletWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
