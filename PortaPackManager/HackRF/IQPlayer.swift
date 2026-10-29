import Foundation

/// Spielt eine `.c8`-Aufnahme in Blöcken ab und reicht sie an einen Verbraucher
/// weiter – mit demselben Datenformat wie `HackRFDevice.startReceiving`.
/// So lassen sich Spektrum, ADS-B und GPS offline auswerten.
final class IQPlayer: @unchecked Sendable {
    private let blockBytes = 262_144

    /// Liest die Datei und ruft `handler` je Block auf. `progress` 0…1.
    /// Das Tempo ist nicht echtzeitgebunden – die Auswertung läuft so schnell
    /// wie möglich, aber kooperativ abbrechbar.
    func play(url: URL,
              handler: @Sendable (Data) -> Void,
              progress: @Sendable (Double) -> Void,
              isCancelled: @Sendable () -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let total = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        var read = 0
        while !isCancelled() {
            guard let chunk = try? handle.read(upToCount: blockBytes), !chunk.isEmpty else { break }
            handler(chunk)
            read += chunk.count
            if total > 0 { progress(Double(read) / Double(total)) }
        }
        progress(1)
    }
}
