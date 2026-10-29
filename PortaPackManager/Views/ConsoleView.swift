import SwiftUI

struct ConsoleView: View {
    @Environment(DeviceSession.self) private var session
    @State private var input = ""
    @State private var history: [String] = []
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(session.consoleLines) { line in
                            ConsoleLineView(line: line)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: session.consoleLines.count) { _, _ in
                    if let last = session.consoleLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            HStack {
                Text(verbatim: "ch>").font(.body.monospaced()).foregroundStyle(.secondary)
                TextField("Befehl, z. B. help, info, ls /APPS", text: $input)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .onSubmit(send)
                    .disabled(session.device == nil || running)
                if running { ProgressView().controlSize(.small) }
                Button("Leeren") { session.clearConsole() }
                Toggle("Mitschreiben", isOn: Binding(get: { session.consoleEnabled }, set: { session.consoleEnabled = $0 }))
                    .toggleStyle(.checkbox)
                    .help("Auch die Befehle der App (Bildschirm, Uploads) protokollieren")
            }
            .padding(10)
        }
    }

    private func send() {
        let command = input.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, let device = session.device else { return }
        input = ""
        history.append(command)
        // Diese Befehle starten neu oder legen das Gerät lahm – über die Übersicht auslösen.
        let blocked = ["reboot", "dfu", "hackrf", "flash", "fwb", "pmemreset", "settingsreset", "write_memory", "cpld_write", "sd_over_usb"]
        if let first = command.split(separator: " ").first, blocked.contains(String(first)) {
            session.note(String(localized: "„\(first)“ ist hier gesperrt – nimm dafür die Knöpfe der Übersicht bzw. der Firmware-Seite."))
            return
        }
        running = true
        Task {
            defer { running = false }
            do {
                _ = try await device.raw(command, timeout: 30)
            } catch {
                session.note(error.localizedDescription)
            }
        }
    }
}

private struct ConsoleLineView: View {
    let line: ConsoleLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(prefix).foregroundStyle(color)
            Text(line.text.trimmingCharacters(in: .newlines))
                .textSelection(.enabled)
        }
        .font(.system(.callout, design: .monospaced))
    }

    private var prefix: String {
        switch line.direction {
        case .sent: "›"
        case .received: " "
        case .note: "•"
        }
    }

    private var color: Color {
        switch line.direction {
        case .sent: .accentColor
        case .received: .secondary
        case .note: .orange
        }
    }
}
