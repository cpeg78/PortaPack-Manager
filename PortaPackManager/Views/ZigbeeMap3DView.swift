import AppKit
import SceneKit
import SwiftUI
import simd

/// Netzkarte im Raum (SceneKit): Geräte als Kugeln, Verbindungen als Stäbe,
/// Beschriftungen als Schilder, die immer zur Kamera zeigen. Drehen durch
/// Ziehen, Zoomen mit Mausrad oder Pinch, Klick wählt ein Gerät und hebt seine
/// Verbindungen hervor. Positionen werden weich nachgeführt (Animation), damit
/// nichts springt.
struct ZigbeeMap3DView: NSViewRepresentable {
    struct Device: Equatable {
        let address: UInt16
        let label: String
        let role: Role
        let connections: Int
    }
    enum Role { case coordinator, router, endDevice }

    let devices: [Device]
    let edges: [ZigbeeMapLayout.Edge]
    let positions: [UInt16: SIMD3<Double>]
    @Binding var selected: UInt16?
    /// Hell/dunkel: Die Schilder sind fertige Bilder und müssen bei einem Wechsel
    /// neu entstehen – vorher blieben sie im alten Erscheinungsbild stehen.
    @Environment(\.colorScheme) private var colorScheme

    static let worldScale: Float = 2.6

    func makeNSView(context: Context) -> SCNView {
        let view = ZoomingSCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .textBackgroundColor
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.isJitteringEnabled = true
        view.pointOfView = context.coordinator.cameraNode
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 30
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.click(_:)))
        view.addGestureRecognizer(click)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.dark = colorScheme == .dark
        context.coordinator.update(devices: devices, edges: edges, positions: positions, selected: selected)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

    @MainActor
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        weak var view: SCNView?
        private var selected: Binding<UInt16?>
        private var deviceNodes: [UInt16: SCNNode] = [:]
        private var labelNodes: [UInt16: SCNNode] = [:]
        private let edgeRoot = SCNNode()
        /// Vom Render-Thread gelesen (Delegate): Schilder bekommen je Bild eine
        /// zur Kameraentfernung passende Größe, damit sie auf dem Bildschirm
        /// gleich groß bleiben – sonst waren nahe riesig und ferne unlesbar.
        nonisolated(unsafe) private let labelRoot = SCNNode()
        nonisolated(unsafe) private let labelCamera = SCNNode()
        private var labelImages: [String: NSImage] = [:]
        private var lastEdgeKey = 0
        /// Erscheinungsbild für die Schilder (Teil des Cache-Schlüssels).
        var dark = false

        init(selected: Binding<UInt16?>) {
            self.selected = selected
            super.init()
            let camera = SCNCamera()
            camera.fieldOfView = 50
            camera.zNear = 0.05
            camera.zFar = 100
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 2.4, 6.2)
            cameraNode.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(cameraNode)
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 500
            scene.rootNode.addChildNode(ambient)
            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 900
            sun.eulerAngles = SCNVector3(-0.9, 0.5, 0)
            scene.rootNode.addChildNode(sun)
            scene.rootNode.addChildNode(edgeRoot)
            scene.rootNode.addChildNode(labelRoot)
            // Bodenring: wo Geräte ohne bekannte Verbindung stehen.
            let ring = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(Float(ZigbeeMapLayout.outerRing) * ZigbeeMap3DView.worldScale), pipeRadius: 0.006))
            ring.geometry?.firstMaterial?.diffuse.contents = NSColor.secondaryLabelColor.withAlphaComponent(0.35)
            ring.geometry?.firstMaterial?.lightingModel = .constant
            scene.rootNode.addChildNode(ring)
        }

        func update(devices: [Device], edges: [ZigbeeMapLayout.Edge], positions: [UInt16: SIMD3<Double>], selected: UInt16?) {
            let scale = ZigbeeMap3DView.worldScale
            let degree = edges.reduce(into: [UInt16: Int]()) { $0[$1.a, default: 0] += 1; $0[$1.b, default: 0] += 1 }
            let present = Set(devices.map(\.address))
            for (address, node) in deviceNodes where !present.contains(address) {
                node.removeFromParentNode()
                labelNodes[address]?.removeFromParentNode()
                deviceNodes[address] = nil
                labelNodes[address] = nil
            }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.6
            for device in devices {
                guard let p = positions[device.address] else { continue }
                let target = SCNVector3(Float(p.x) * scale, Float(p.y) * scale, Float(p.z) * scale)
                let radius = Self.radius(device, degree: degree[device.address] ?? 0)
                let node: SCNNode
                if let existing = deviceNodes[device.address] {
                    node = existing
                } else {
                    node = SCNNode(geometry: SCNSphere(radius: radius))
                    node.name = "n:\(device.address)"
                    node.position = target          // neue Geräte ohne Anflug
                    scene.rootNode.addChildNode(node)
                    deviceNodes[device.address] = node
                    let label = SCNNode()
                    label.constraints = [SCNBillboardConstraint()]
                    label.name = "l:\(device.address)"
                    labelRoot.addChildNode(label)
                    labelNodes[device.address] = label
                }
                if let sphere = node.geometry as? SCNSphere, abs(sphere.radius - radius) > 0.001 { sphere.radius = radius }
                let dimmed = selected != nil && selected != device.address
                    && !edges.contains { ($0.a == selected && $0.b == device.address) || ($0.b == selected && $0.a == device.address) }
                let material = node.geometry!.firstMaterial!
                let color = Self.color(device.role)
                material.diffuse.contents = dimmed ? color.withAlphaComponent(0.35) : color
                material.emission.contents = device.address == selected ? color.withAlphaComponent(0.6) : color.withAlphaComponent(0.15)
                material.specular.contents = NSColor.white
                node.position = target
                if let label = labelNodes[device.address] {
                    // Schilder nur für Koordinator, Router, Geräte ohne Verbindung
                    // (Außenring) und das gewählte Gerät – Endgeräte im dichten
                    // Kern bekämen sonst ein Gewirr aus überlappenden Schildern.
                    let isolated = (degree[device.address] ?? 0) == 0
                    label.isHidden = device.role == .endDevice && !isolated && device.address != selected
                    let image = labelImage(device.label, highlighted: device.address == selected, dimmed: dimmed)
                    let width = CGFloat(image.size.width / 150)
                    if label.geometry == nil || (label.geometry as? SCNPlane)?.width != width {
                        let plane = SCNPlane(width: width, height: CGFloat(image.size.height / 150))
                        plane.cornerRadius = 0.02
                        plane.firstMaterial?.lightingModel = .constant
                        plane.firstMaterial?.isDoubleSided = true
                        plane.firstMaterial?.readsFromDepthBuffer = false   // immer vor Kugeln und Stäben
                        label.geometry = plane
                    }
                    label.geometry?.firstMaterial?.diffuse.contents = image
                    label.geometry?.firstMaterial?.transparent.contents = image
                    label.geometry?.firstMaterial?.transparencyMode = .aOne
                    label.position = SCNVector3(target.x, target.y - radius - 0.085, target.z)
                    label.renderingOrder = 10
                }
            }
            SCNTransaction.commit()
            // Kanten jedes Mal neu (billig: ein Stab je Verbindung), animiert über
            // die Knotenpositionen mitzuziehen wäre aufwendiger.
            var hasher = Hasher()
            for e in edges { hasher.combine(e.a); hasher.combine(e.b); hasher.combine(Int(e.quality * 20)) }
            for (address, p) in positions { hasher.combine(address); hasher.combine(Int(p.x * 200)); hasher.combine(Int(p.y * 200)); hasher.combine(Int(p.z * 200)) }
            hasher.combine(selected)
            let key = hasher.finalize()
            guard key != lastEdgeKey else { return }
            lastEdgeKey = key
            edgeRoot.childNodes.forEach { $0.removeFromParentNode() }
            for edge in edges {
                guard let a = positions[edge.a], let b = positions[edge.b] else { continue }
                let touches = selected == edge.a || selected == edge.b
                let from = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)) * scale
                let to = SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z)) * scale
                let node = Self.rod(from: from, to: to, radius: touches ? 0.016 : 0.006 + 0.012 * CGFloat(edge.quality))
                let color = NSColor(hue: CGFloat(edge.quality) * 0.33, saturation: 0.75, brightness: 0.85, alpha: 1)
                let alpha: CGFloat = selected == nil ? 0.45 + 0.5 * CGFloat(edge.quality) : (touches ? 1 : 0.08)
                node.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(alpha)
                node.geometry?.firstMaterial?.emission.contents = color.withAlphaComponent(alpha * 0.5)
                node.geometry?.firstMaterial?.lightingModel = .constant
                edgeRoot.addChildNode(node)
            }
        }

        nonisolated func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let camera = renderer.pointOfView else { return }
            let eye = camera.simdWorldPosition
            for label in labelRoot.childNodes {
                let distance = simd_length(label.simdWorldPosition - eye)
                let s = Float(max(0.5, distance / 6.2))
                label.simdScale = SIMD3(repeating: s)
            }
        }

        private static func rod(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: CGFloat) -> SCNNode {
            let d = b - a
            let length = simd_length(d)
            let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
            cylinder.radialSegmentCount = 6
            let node = SCNNode(geometry: cylinder)
            node.position = SCNVector3((a + b) / 2)
            // Zylinder steht entlang y; auf die Richtung a→b drehen.
            let up = SIMD3<Float>(0, 1, 0)
            let dir = d / max(length, 1e-6)
            let axis = simd_cross(up, dir)
            let angle = acos(max(-1, min(1, simd_dot(up, dir))))
            if simd_length(axis) > 1e-5 { node.rotation = SCNVector4(axis.x, axis.y, axis.z, angle) }
            else if angle > 1 { node.rotation = SCNVector4(1, 0, 0, Float.pi) }
            return node
        }

        private static func radius(_ device: Device, degree: Int) -> CGFloat {
            switch device.role {
            case .coordinator: 0.13
            case .router: 0.075 + min(0.05, CGFloat(degree) * 0.004)
            case .endDevice: 0.055
            }
        }

        private static func color(_ role: Role) -> NSColor {
            switch role {
            case .coordinator: .systemOrange
            case .router: .systemBlue
            case .endDevice: .systemGreen
            }
        }

        nonisolated static func labelKey(_ text: String, highlighted: Bool, dimmed: Bool, dark: Bool) -> String {
            "\(text)|\(highlighted)|\(dimmed)|\(dark ? "dunkel" : "hell")"
        }

        /// Schild als Bild (scharf, billig): Text mit abgerundetem Hintergrund.
        private func labelImage(_ text: String, highlighted: Bool, dimmed: Bool) -> NSImage {
            let key = Self.labelKey(text, highlighted: highlighted, dimmed: dimmed, dark: dark)
            if let image = labelImages[key] { return image }
            // Alte Schilder des anderen Erscheinungsbilds nicht ewig behalten.
            if labelImages.count > 2000 { labelImages.removeAll() }
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
            let font = NSFont.systemFont(ofSize: 22, weight: highlighted ? .bold : .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(dimmed ? 0.4 : 1)
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let size = NSSize(width: ceil(textSize.width) + 20, height: ceil(textSize.height) + 8)
            // Sofort in ein Bitmap zeichnen: ein `NSImage` mit Zeichen-Closure
            // rendert SceneKit später auf seiner eigenen Render-Queue – die
            // Closure ist aber an den Main Actor gebunden, das brach mit
            // `dispatch_assert_queue` ab (Absturz 28.10.2026).
            let scale = 2
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                             pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage(size: size) }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            appearance.performAsCurrentDrawingAppearance {
                let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8)
                NSColor.windowBackgroundColor.withAlphaComponent(highlighted ? 0.95 : dimmed ? 0.3 : 0.75).setFill()
                path.fill()
                (text as NSString).draw(at: NSPoint(x: 10, y: 4), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            labelImages[key] = image
            return image
        }

        @objc func click(_ recognizer: NSClickGestureRecognizer) {
            guard let view else { return }
            let point = recognizer.location(in: view)
            let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .ignoreHiddenNodes: true])
            for hit in hits {
                guard let name = hit.node.name, name.hasPrefix("n:") || name.hasPrefix("l:"),
                      let address = UInt16(name.dropFirst(2)) else { continue }
                selected.wrappedValue = selected.wrappedValue == address ? nil : address
                return
            }
            selected.wrappedValue = nil
        }
    }
}

/// Fängt das Mausrad über einer SwiftUI-Ansicht ab (SwiftUI selbst hat dafür
/// keinen Modifier): meldet Schritte und Mausposition für das Zoomen der 2D-Karte.
struct ScrollWheelCatcher: View {
    let onScroll: (_ delta: CGFloat, _ location: CGPoint) -> Void

    /// Gemeinsamer Monitor (`ScrollWheelArea`): nur dieses Fenster, nur dieser Bereich.
    var body: some View {
        ScrollWheelArea { event in
            let delta = event.precise ? event.dy / 40 : event.dy / 3
            onScroll(delta, event.location)
            return true
        }
    }
}

/// SceneKit verschiebt beim Scrollen (Magic Mouse, Trackpad) die Kamera. Hier
/// zoomt das Mausrad: Die Kamera fährt auf den Drehpunkt zu oder von ihm weg.
/// Drehen bleibt beim Ziehen, Zoomen per Kneifen auf dem Trackpad geht weiter
/// (Fund 28.10.2026: „über Scrollrad wird nicht gezoomt, sondern geschoben“).
final class ZoomingSCNView: SCNView {
    override func scrollWheel(with event: NSEvent) {
        let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
        guard dy != 0, abs(dy) >= abs(dx), let camera = pointOfView else { return }
        let factor = exp(-dy * (event.hasPreciseScrollingDeltas ? 0.01 : 0.12))
        let target = defaultCameraController.target
        let position = camera.worldPosition
        let offset = SIMD3<Double>(Double(position.x - target.x), Double(position.y - target.y), Double(position.z - target.z))
        let distance = simd_length(offset)
        guard distance > 0 else { return }
        let next = min(max(distance * factor, 0.8), 80)
        let scaled = offset * (next / distance)
        camera.worldPosition = SCNVector3(target.x + CGFloat(scaled.x), target.y + CGFloat(scaled.y), target.z + CGFloat(scaled.z))
    }
}
