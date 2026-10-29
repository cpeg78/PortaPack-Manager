import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScreenView: View {
    @Environment(DeviceSession.self) private var session
    @State private var typedText = ""
    @State private var apps: [(id: String, name: String)] = []
    @State private var appFilter = ""
    @State private var frequencyMHz = 100.0
    @State private var actionError: String?

    var body: some View {
        if session.device == nil {
            MayhemRequiredView(systemImage: "display",
                               text: "Bildschirm und Bedienung funktionieren nur im Mayhem-Modus.")
        } else {
            HStack(alignment: .top, spacing: 20) {
                screen
                controls
                    .frame(width: 300)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task {
                if session.screenImage == nil { await session.captureScreen() }
                apps = (try? await session.device?.appList()) ?? []
            }
            .onDisappear { session.screenMirroring = false }
        }
    }

    // MARK: - Bildschirm

    private var screen: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black)
                if let image = session.screenImage {
                    GeometryReader { geometry in
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { value in
                                tap(at: value.location, in: geometry.size, image: image)
                            })
                    }
                    .padding(8)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .aspectRatio(240.0 / 320.0, contentMode: .fit)
            .frame(minWidth: 300, maxWidth: 520)

            HStack {
                Toggle("Live", isOn: Binding(get: { session.screenMirroring }, set: { session.screenMirroring = $0 }))
                    .toggleStyle(.switch)
                if session.screenMirroring, session.screenFrameInterval > 0 {
                    Text("\((1 / session.screenFrameInterval).formatted(.number.precision(.fractionLength(1)))) Bilder/s")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await session.captureScreen() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Bild neu holen")
                    .accessibilityLabel("Bild neu holen")
                Button {
                    saveScreenshot()
                } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Bildschirmfoto sichern")
                    .accessibilityLabel("Bildschirmfoto sichern")
                    .disabled(session.screenImage == nil)
            }
            .frame(maxWidth: 520)
            Text("Ein Klick ins Bild tippt auf den Touchscreen.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private func tap(at location: CGPoint, in size: CGSize, image: CGImage) {
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let viewAspect = size.width / size.height
        var drawn = size
        if viewAspect > imageAspect { drawn.width = size.height * imageAspect } else { drawn.height = size.width / imageAspect }
        let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
        let x = Int((location.x - origin.x) / drawn.width * CGFloat(image.width))
        let y = Int((location.y - origin.y) / drawn.height * CGFloat(image.height))
        guard (0..<image.width).contains(x), (0..<image.height).contains(y) else { return }
        perform { try await $0.touch(x: x, y: y) }
    }

    // MARK: - Bedienelemente

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Tasten") {
                    VStack(spacing: 8) {
                        HStack {
                            keyButton(.encoderLeft, symbol: "arrow.counterclockwise")
                            Spacer()
                            keyButton(.up, symbol: "chevron.up")
                            Spacer()
                            keyButton(.encoderRight, symbol: "arrow.clockwise")
                        }
                        HStack {
                            keyButton(.left, symbol: "chevron.left")
                            Spacer()
                            keyButton(.select, symbol: "circle.fill")
                            Spacer()
                            keyButton(.right, symbol: "chevron.right")
                        }
                        HStack {
                            keyButton(.dfu, symbol: "questionmark.circle")
                            Spacer()
                            keyButton(.down, symbol: "chevron.down")
                            Spacer()
                            Color.clear.frame(width: 44, height: 1)
                        }
                    }
                    .padding(6)
                    Text("Pfeiltasten, Eingabe und Rücktaste der Mac-Tastatur gehen auch, solange das Fenster aktiv ist.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                GroupBox("Text eingeben") {
                    HStack {
                        TextField("Text für Eingabefelder", text: $typedText)
                            .onSubmit(sendText)
                        Button("Senden", action: sendText).disabled(typedText.isEmpty)
                    }
                }

                GroupBox("Frequenz setzen") {
                    HStack {
                        FrequencyField(value: $frequencyMHz, width: nil) { _ in setFrequency() }
                        Button("Setzen", action: setFrequency)
                    }
                    Text("Wirkt auf die gerade geöffnete Empfangs-App.").font(.caption).foregroundStyle(.secondary)
                }

                GroupBox("App starten") {
                    TextField("Suchen", text: $appFilter)
                    List(filteredApps, id: \.id) { app in
                        Button {
                            perform { try await $0.startApp(app.id) }
                        } label: {
                            HStack {
                                Text(app.name)
                                Spacer()
                                Text(app.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 220)
                }

                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .background(KeyCatcher { key in
            guard let button = key else { return }
            perform { try await $0.press(button) }
        })
    }

    private var filteredApps: [(id: String, name: String)] {
        guard !appFilter.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(appFilter) || $0.id.localizedCaseInsensitiveContains(appFilter) }
    }

    private func keyButton(_ button: DeviceButton, symbol: String) -> some View {
        Button {
            perform { try await $0.press(button) }
        } label: {
            Image(systemName: symbol).frame(width: 30, height: 22)
        }
        .help(button.label)
        .accessibilityLabel(button.label)
    }

    private func sendText() {
        let text = typedText
        typedText = ""
        perform { try await $0.type(text) }
    }

    private func setFrequency() {
        let mhz = frequencyMHz
        perform { try await $0.setFrequency(UInt64(mhz * 1_000_000)) }
    }

    private func perform(_ work: @escaping @Sendable (MayhemDevice) async throws -> Void) {
        guard let device = session.device else { return }
        Task {
            do {
                try await work(device)
                actionError = nil
                if !session.screenMirroring { await session.captureScreen() }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func saveScreenshot() {
        guard let image = session.screenImage else { return }
        let name = "PortaPack \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")).png"
        Task {
            guard let url = await SaveSheet.url(name: name, types: [.png]) else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}

/// Fängt Tastendrücke ab und übersetzt sie in PortaPack-Tasten.
private struct KeyCatcher: NSViewRepresentable {
    let onKey: (DeviceButton?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onKey = onKey
    }

    final class CatcherView: NSView {
        var onKey: ((DeviceButton?) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window == self.window else { return event }
                // Texteingaben nicht abfangen.
                if self.window?.firstResponder is NSTextView { return event }
                let button: DeviceButton? = switch event.keyCode {
                case 123: .left
                case 124: .right
                case 125: .down
                case 126: .up
                case 36, 76: .select
                case 51: .left
                case 116: .encoderLeft
                case 121: .encoderRight
                default: nil
                }
                guard let button else { return event }
                self.onKey?(button)
                return nil
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
