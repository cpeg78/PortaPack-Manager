import AppKit
import SwiftUI

/// Empfänger, der seinen hörbaren Ton aufnehmen kann (Radio, DAB+).
@MainActor
protocol AudioRecordingHost: AnyObject, Observable {
    var running: Bool { get }
    var audioRecording: AudioRecordingInfo? { get }
    var audioRecordingIssue: String? { get }
    var audioRecordingsVersion: Int { get }
    func startAudioRecording(format: AudioFileFormat)
    func stopAudioRecording()
}

extension RadioModel: AudioRecordingHost {}
extension DABModel: AudioRecordingHost {}

/// Abschnitt „Daten & Export“ mit „Ton aufnehmen“: Format, laufende Dauer und
/// Größe, die letzten Aufnahmen dieser Quelle mit Öffnen, „Im Finder zeigen“
/// und Löschen (mit Rückfrage). Die Aufnahme endet mit dem Stopp des Empfängers.
struct AudioRecordingSection<Host: AudioRecordingHost>: View {
    let host: Host
    /// Präfix der Dateinamen (`AudioRecordingStore.radioPrefix` bzw. `.dabPrefix`).
    let source: String
    @AppStorage("audioRecordingFormat") private var formatRaw = AudioFileFormat.aac.rawValue
    @State private var files: [AudioRecordingFile] = []
    @State private var pendingDelete: DeleteConfirmation?
    @State private var reload = 0

    var body: some View {
        Section(PanelSection.daten) {
            if let info = host.audioRecording {
                Button { host.stopAudioRecording() } label: {
                    Label("Aufnahme beenden", systemImage: "stop.circle")
                }
                Label("Nimmt auf: \(Duration.seconds(info.seconds).formatted(.time(pattern: .minuteSecond))) · \(ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file))",
                      systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .monospacedDigit()
                Text(info.url.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            } else {
                Button {
                    host.startAudioRecording(format: AudioFileFormat(rawValue: formatRaw) ?? .aac)
                } label: {
                    Label("Ton aufnehmen", systemImage: "record.circle")
                }
                .disabled(!host.running)
                .help(host.running ? String(localized: "Nimmt auf, was du hörst – bis du die Aufnahme beendest oder den Empfang stoppst.")
                                   : String(localized: "Erst abspielen, dann aufnehmen."))
                Picker("Format", selection: $formatRaw) {
                    ForEach(AudioFileFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            if let issue = host.audioRecordingIssue {
                Text(issue).font(.caption).foregroundStyle(.red)
            }
            ForEach(files.prefix(5)) { file in
                row(file)
            }
            HStack {
                if files.count > 5 {
                    Text("\(files.count) Aufnahmen").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([files.first?.url ?? AudioRecordingStore.folder])
                }
            }
        }
        .deleteConfirmation($pendingDelete)
        .task(id: "\(host.audioRecordingsVersion)/\(reload)") {
            let source = source
            files = await Task.detached { AudioRecordingStore.list(source: source) }.value
        }
    }

    private func row(_ file: AudioRecordingFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.caption).lineLimit(1).truncationMode(.middle)
                Text("\(file.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSWorkspace.shared.open(file.url) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
                .help("Mit der Standard-App abspielen")
                .accessibilityLabel("Mit der Standard-App abspielen")
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Im Finder zeigen")
                .accessibilityLabel("Im Finder zeigen")
            Button(role: .destructive) { confirmDelete(file) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Löschen …")
                .accessibilityLabel("Löschen …")
        }
        .contextMenu {
            Button("Abspielen") { NSWorkspace.shared.open(file.url) }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Button("Löschen …", role: .destructive) { confirmDelete(file) }
        }
    }

    private func confirmDelete(_ file: AudioRecordingFile) {
        pendingDelete = DeleteConfirmation(
            title: String(localized: "Tonaufnahme „\(file.name)“ löschen?"),
            message: String(localized: "\(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)) werden von diesem Mac gelöscht.")) {
            AudioRecordingStore.delete(file)
            reload += 1
        }
    }
}
