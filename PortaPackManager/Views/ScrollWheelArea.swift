import AppKit
import SwiftUI

/// Gemeinsamer Helfer für lokale Mausrad-Monitore (Karten, Wärmebild, Zigbee-Netzkarte).
///
/// SwiftUI hat keinen Mausrad-Modifikator, deshalb hängen die Seiten einen lokalen
/// `NSEvent`-Monitor ein. Früher entschied der nur nach dem Hover-Zustand; blieb der
/// stehen (Archivfenster öffnete über der Karte, Seitenwechsel), schluckte die Karte
/// jedes Scroll-Ereignis der App, und Tabellen in anderen Fenstern scrollten nicht
/// mehr (Review 28.10.2026, W8). Jetzt hält der Monitor eine schwache Referenz auf
/// eine unsichtbare `NSView` hinter dem Inhalt und nimmt nur Ereignisse an, die im
/// selben Fenster *und* in deren Bereich liegen. Er lebt genau so lange wie die
/// Ansicht: `dismantleNSView` entfernt ihn und ruft `onRemove` (Hover-Zustand
/// zurücksetzen).
struct ScrollWheelArea: NSViewRepresentable {
    /// Ein Mausrad-Ereignis; `location` in Punkten ab oben links (wie SwiftUIs `.local`).
    struct Event {
        let dx: Double
        let dy: Double
        let precise: Bool
        let modifiers: NSEvent.ModifierFlags
        let location: CGPoint
    }

    var onRemove: (@MainActor () -> Void)?
    /// Liefert `true`, wenn das Ereignis verbraucht wurde.
    let handler: @MainActor (Event) -> Bool

    init(onRemove: (@MainActor () -> Void)? = nil, handler: @escaping @MainActor (Event) -> Bool) {
        self.onRemove = onRemove
        self.handler = handler
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassiveView()
        context.coordinator.handler = handler
        context.coordinator.onRemove = onRemove
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handler = handler
        context.coordinator.onRemove = onRemove
    }

    func makeCoordinator() -> ScrollWheelMonitor { ScrollWheelMonitor() }

    static func dismantleNSView(_ view: NSView, coordinator: ScrollWheelMonitor) { coordinator.remove() }

    /// Gekippt (Ursprung oben links) und für Klicks durchlässig.
    final class PassiveView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Der eigentliche Monitor zu einer `ScrollWheelArea`.
@MainActor
final class ScrollWheelMonitor {
    var handler: (@MainActor (ScrollWheelArea.Event) -> Bool)?
    var onRemove: (@MainActor () -> Void)?
    private var monitor: Any?
    private weak var view: NSView?

    var isInstalled: Bool { monitor != nil }

    func install(for view: NSView) {
        self.view = view
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let view = self.view else { return event }
            let local = view.convert(event.locationInWindow, from: nil)
            guard Self.accepts(eventWindow: event.window, viewWindow: view.window,
                               hidden: view.isHiddenOrHasHiddenAncestor, location: local, bounds: view.bounds),
                  let handler = self.handler
            else { return event }
            let wheel = ScrollWheelArea.Event(
                dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                precise: event.hasPreciseScrollingDeltas, modifiers: event.modifierFlags,
                location: view.isFlipped ? local : CGPoint(x: local.x, y: view.bounds.height - local.y))
            return handler(wheel) ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        view = nil
        onRemove?()
    }

    /// Nur Ereignisse aus dem eigenen Fenster und innerhalb des eigenen Bereichs.
    nonisolated static func accepts(eventWindow: AnyObject?, viewWindow: AnyObject?, hidden: Bool,
                                    location: CGPoint, bounds: CGRect) -> Bool {
        guard let viewWindow, let eventWindow, eventWindow === viewWindow, !hidden else { return false }
        return bounds.contains(location)
    }
}
