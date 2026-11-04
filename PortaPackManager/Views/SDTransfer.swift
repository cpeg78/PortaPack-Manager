import Foundation

/// Laufende Übertragung zwischen Mac und SD-Karte (Seite „SD-Karte“). Lebt außerhalb
/// der Seite: Vorher hing der Transfer an `@State` von `FilesView` – nach einem
/// Seitenwechsel lief er unsichtbar weiter, ohne Fortschritt und ohne Abbrechen,
/// und ein zweiter ließ sich parallel starten (Review 01.11.2026). Immer nur eine
/// Übertragung; `DeviceArbiter.activeUse` fragt `activeUse` ab, damit ein
/// Moduswechsel oder Neustart vorher nachfragt.
@MainActor @Observable
final class SDTransfer {
    static let shared = SDTransfer()

    struct Progress: Equatable {
        /// Datei, die gerade übertragen wird.
        var name: String
        /// Zeile über dem Fortschrittsbalken (mit Tempo und Restzeit).
        var title: String
        var fraction: Double
    }

    /// `nil` = keine Übertragung.
    private(set) var progress: Progress?
    /// Ergebnis der letzten Übertragung (Fehler, Abbruch); `nil` = fehlerfrei.
    var message: String?
    /// Zählt beendete Übertragungen – die Seite lädt danach den Ordner neu.
    private(set) var finished = 0
    /// Ordner, in den zuletzt gesendet wurde.
    private(set) var lastDirectory: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Kennung der laufenden Übertragung; späte Fortschrittsmeldungen einer
    /// beendeten setzen den Balken nicht wieder.
    @ObservationIgnored private var run = 0

    var isRunning: Bool { task != nil }

    /// Für `DeviceArbiter.activeUse`: was gerade übertragen wird, als ganzer Satz.
    static var activeUse: String? {
        guard shared.isRunning else { return nil }
        let name = shared.progress?.name ?? ""
        return String(localized: "Gerade läuft eine Übertragung mit der SD-Karte („\(name)“).")
    }

    /// Bricht die laufende Übertragung ab (das Gerät prüft je Paket).
    func cancel() { task?.cancel() }

    /// Lädt eine Datei von der SD-Karte nach `url`. `false`, wenn schon etwas läuft.
    @discardableResult
    func download(_ entry: SDEntry, from device: MayhemDevice, to url: URL) -> Bool {
        guard task == nil else { return false }
        let id = begin(name: entry.name, title: String(localized: "Lade \(entry.name)"))
        task = Task {
            defer { end(id) }
            do {
                let started = Date()
                let data = try await device.download(entry.path) { done, total in
                    let title = String(localized: "Lade \(entry.name): \(Self.rate(done, total, since: started))")
                    Task { @MainActor in self.report(id, title: title, done: done, total: total) }
                }
                try data.write(to: url)
            } catch is CancellationError {
                message = String(localized: "Abgebrochen – \(entry.name) wurde nicht gesichert.")
            } catch {
                message = error.localizedDescription
            }
        }
        return true
    }

    /// Sendet Dateien nach `directory` auf der SD-Karte, je mit CRC-Prüfung.
    /// `false`, wenn schon etwas läuft.
    @discardableResult
    func upload(_ urls: [URL], to directory: String, on device: MayhemDevice) -> Bool {
        guard task == nil, let firstURL = urls.first else { return false }
        let id = begin(name: firstURL.lastPathComponent, title: String(localized: "Sende \(firstURL.lastPathComponent)"))
        lastDirectory = directory
        task = Task {
            defer { end(id) }
            for url in urls {
                let name = url.lastPathComponent
                let remote = (directory == "/" ? "" : directory) + "/" + name
                var partial = false
                do {
                    // Zwischen zwei Dateien abbrechen hinterlässt nichts Halbes.
                    try Task.checkCancellation()
                    let data = try Data(contentsOf: url)
                    progress = Progress(name: name, title: String(localized: "Sende \(name)"), fraction: 0)
                    let started = Date()
                    partial = true
                    try await device.upload(data, to: remote) { done, total in
                        let title = String(localized: "Sende \(name): \(Self.rate(done, total, since: started))")
                        Task { @MainActor in self.report(id, title: title, done: done, total: total) }
                    }
                    partial = false
                    progress = Progress(name: name, title: String(localized: "Prüfe \(name) …"), fraction: 1)
                    let crc = try await device.crc32(remote)
                    if crc != MayhemCRC32.checksum(data) {
                        throw MayhemError.checksumMismatch(expected: MayhemCRC32.checksum(data), actual: crc)
                    }
                } catch is CancellationError {
                    // Mitten in der Datei abgebrochen: das halbe Stück wieder entfernen
                    // (`upload` hat die Datei schon geschlossen).
                    if partial { try? await device.remove(remote) }
                    message = String(localized: "Abgebrochen – \(name) und alle folgenden Dateien wurden nicht übertragen.")
                    break
                } catch {
                    message = "\(name): \(error.localizedDescription)"
                    break
                }
            }
        }
        return true
    }

    private func begin(name: String, title: String) -> Int {
        run += 1
        message = nil
        progress = Progress(name: name, title: title, fraction: 0)
        return run
    }

    private func report(_ id: Int, title: String, done: Int, total: Int) {
        guard id == run, let current = progress else { return }
        progress = Progress(name: current.name, title: title, fraction: Double(done) / Double(max(total, 1)))
    }

    private func end(_ id: Int) {
        guard id == run else { return }
        progress = nil
        task = nil
        finished += 1
    }

    nonisolated static func rate(_ done: Int, _ total: Int, since start: Date) -> String {
        let elapsed = Date().timeIntervalSince(start)
        let speed = elapsed > 0.3 ? Double(done) / elapsed : 0
        let amount = FirmwareInstaller.ofTotal(Int64(done), Int64(total))
        guard speed > 0 else { return amount }
        return String(localized: "\(amount) · \(FirmwareInstaller.format(Int64(speed)))/s · noch \(FirmwareInstaller.duration(Double(total - done) / speed))")
    }
}
