import Foundation
import os

/// Führt einen blockierenden Aufruf auf einem eigenen Thread aus und wartet
/// höchstens `timeout` Sekunden darauf.
///
/// Gedacht für `open`/`tcsetattr` auf der seriellen Schnittstelle: hängt der
/// CDC-Treiber von macOS, bleibt der aufrufende Thread im Kernel stecken und
/// ist nicht abschießbar (Fund 20.10.2026). Läuft das auf dem Main Actor,
/// friert die ganze App ein. Hier bleibt nur ein Hintergrund-Thread hängen;
/// kommt das Ergebnis doch noch, räumt `lateResult` es weg.
enum BlockingCall {
    struct TimedOut: Error, LocalizedError {
        let what: String
        let seconds: TimeInterval
        var errorDescription: String? {
            String(localized: "\(what) antwortet nicht (\(Int(seconds)) s). Der USB-Treiber hängt vermutlich – steck das PortaPack ab und wieder an.")
        }
    }

    static func run<T: Sendable>(_ what: String, timeout: TimeInterval,
                                 lateResult: @escaping @Sendable (T) -> Void = { _ in },
                                 _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let state = OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>(uncheckedState: nil)
        return try await withCheckedThrowingContinuation { continuation in
            state.withLockUnchecked { $0 = continuation }
            // Eigener Thread statt Concurrency-Pool: ein hängender Aufruf soll
            // keinen der wenigen Pool-Threads auf Dauer belegen.
            let thread = Thread {
                let result = Result { try operation() }
                let waiting = state.withLockUnchecked { pending -> CheckedContinuation<T, any Error>? in
                    defer { pending = nil }
                    return pending
                }
                if let waiting {
                    waiting.resume(with: result)
                } else if case let .success(value) = result {
                    lateResult(value)
                }
            }
            thread.name = "BlockingCall: \(what)"
            thread.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                let waiting = state.withLockUnchecked { pending -> CheckedContinuation<T, any Error>? in
                    defer { pending = nil }
                    return pending
                }
                waiting?.resume(throwing: TimedOut(what: what, seconds: timeout))
            }
        }
    }
}
