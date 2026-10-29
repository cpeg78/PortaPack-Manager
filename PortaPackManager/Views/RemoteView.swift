import CoreImage.CIFilterBuiltins
import SwiftUI

/// Einstellungen und Stand des Fernzugriffs (Webseite für ADS-B, AIS, DAB+).
struct RemoteView: View {
    @Bindable private var hub = RemoteHub.shared
    @State private var portText = ""
    @State private var qrAddress: String?

    var body: some View {
        Form {
            Section {
                Toggle("Fernzugriff einschalten", isOn: $hub.enabled)
                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: $portText)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(applyPort)
                        Button("Übernehmen", action: applyPort)
                            .disabled(Int(portText) == hub.port || !validPort)
                    }
                }
                if !validPort {
                    Text("Wähl einen Port zwischen 1024 und 65535.").font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Zustand") {
                    if hub.running {
                        Label("läuft auf Port \(String(hub.port))", systemImage: "circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("aus").foregroundStyle(.secondary)
                    }
                }
                if let error = hub.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Eine Webseite fürs Handy mit fast allen Empfängern dieser App – Flugzeuge, Schiffe, Wetterballons, Radio (mit Ton) und mehr. Der HackRF empfängt immer nur eines davon; „Start“ in einem Reiter schaltet um. Solange der Fernzugriff an ist, bleibt der Mac wach.")
            }

            Section {
                Toggle("Nur Heimnetz und VPN", isOn: $hub.localOnly)
                if let rejected = hub.lastRejected {
                    LabeledContent("Zuletzt abgewiesen") {
                        Text(verbatim: "\(rejected.address) · \(rejected.date.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Wer darf zugreifen")
            } footer: {
                Text("Angenommen werden nur Geräte aus dem eigenen Netz (192.168.x.x, 10.x.x.x, 172.16–31.x.x, fe80::, fd…) und aus dem VPN (Tailscale 100.64–127.x.x und fd7a:…). Anfragen aus dem Internet – öffentliche IPv4- und globale IPv6-Adressen – lehnt der Mac sofort ab, auch wenn der Router sie durchlässt. Ausschalten nur, wenn dein VPN andere Adressen vergibt.")
            }

            Section("Adressen") {
                if hub.tokenUnavailable {
                    Text("Der Zugangsschlüssel ist im Schlüsselbund gerade nicht lesbar – der Fernzugriff ist ausgesetzt. Die App versucht es von selbst erneut.")
                        .foregroundStyle(.orange)
                } else if hub.addresses.isEmpty {
                    Text("Keine Netzwerkverbindung").foregroundStyle(.secondary)
                }
                ForEach(hub.tokenUnavailable ? [] : hub.addresses, id: \.self) { address in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(address.note).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(address.url).font(.callout.monospaced()).textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Kopieren", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address.url, forType: .string)
                            }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            Button("QR-Code", systemImage: "qrcode") { qrAddress = address.url }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                            Button("Öffnen", systemImage: "safari") {
                                if let url = URL(string: address.url) { NSWorkspace.shared.open(url) }
                            }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .disabled(!hub.running)
                        }
                    }
                }
                if let qrAddress, let image = Self.qrCode(qrAddress) {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                            Text("Mit der Handykamera scannen").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }

            Section {
                LabeledContent("Schlüssel") {
                    HStack {
                        if hub.tokenUnavailable {
                            Text("nicht lesbar").foregroundStyle(.orange)
                        } else {
                            Text(hub.token).font(.body.monospaced()).textSelection(.enabled)
                        }
                        Button("Neu erzeugen") { hub.regenerateToken(); qrAddress = nil }
                    }
                }
            } header: {
                Text("Zugangsschlüssel")
            } footer: {
                Text("Ohne den Schlüssel in der Adresse zeigt die Seite nichts. Ein neuer Schlüssel sperrt alle bisher geöffneten Seiten aus.")
            }

            Section("Betrieb") {
                LabeledContent("Empfänger", value: hub.activeMode?.title ?? "–")
                LabeledContent("Aus der Ferne gewählt", value: hub.remoteMode?.title ?? "–")
                LabeledContent("Radiohörer", value: "\(hub.listeners)")
                if let last = hub.lastRequest {
                    LabeledContent("Letzter Abruf") { Text(last, style: .relative) }
                }
                if hub.remoteMode != nil {
                    Button("Fernbetrieb beenden") { hub.endRemoteMode() }
                }
            }

            Section("Benachrichtigungen") {
                if Notifier.shared.anyEnabled {
                    SettingsHint(.notifications, "Meldungen über Wetterballons, Überflüge und Notrufe gehen an den Mac bzw. aufs Handy (ntfy).")
                } else {
                    SettingsHint(.notifications, "Mitteilungen am Mac und aufs Handy (ntfy) sind aus.")
                }
            }

            Section {
                Text("Im Heimnetz genügt eine der Adressen oben. Von unterwegs nur über ein VPN: Installier **Tailscale** auf Mac und Handy und nimm die Tailscale-Adresse (100.x.y.z), oder wähl dich per VPN ins Heimnetz ein (z. B. WireGuard der FRITZ!Box). Eine Portfreigabe im Router funktioniert nicht, solange „Nur Heimnetz und VPN“ an ist – Seite und Radiostrom gingen sonst unverschlüsselt durchs Internet. Fragt macOS beim ersten Start nach eingehenden Verbindungen, bestätige mit „Erlauben“.")
                    .font(.callout)
            } header: {
                Text("Zugriff von unterwegs")
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(hub.port) }
        .navigationTitle("Fernzugriff")
    }

    private var validPort: Bool {
        guard let value = Int(portText) else { return false }
        return (1024...65535).contains(value)
    }

    private func applyPort() {
        guard validPort, let value = Int(portText) else { return }
        hub.port = value
        qrAddress = nil
    }

    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
