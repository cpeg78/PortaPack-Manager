import CoreLocation
import Foundation

/// Fragt einmalig den Standort des Mac ab (Ortungsdienste, meist WLAN-Ortung,
/// auf einige zehn Meter genau). Beim ersten Mal fragt macOS um Erlaubnis.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum Failure: LocalizedError {
        case denied
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .denied: String(localized: "PortaPack Manager darf deinen Standort nicht abfragen – erlaube es in den Systemeinstellungen unter „Datenschutz & Sicherheit ▸ Ortungsdienste“.")
            case let .unavailable(text): String(localized: "Standort nicht verfügbar: \(text)")
            }
        }
    }

    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            proceed()
        }
    }

    private func proceed() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // Antwort kommt über den Delegate
        case .denied, .restricted:
            finish(.failure(Failure.denied))
        default:
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume(with: result) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard !waiting.isEmpty, self.manager.authorizationStatus != .notDetermined else { return }
            proceed()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in finish(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let text = error.localizedDescription
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in finish(.failure(denied ? Failure.denied : Failure.unavailable(text))) }
    }
}
