import CoreLocation
import MapKit

/// "Use This Mac's Location": one location fix from macOS (it asks for permission once), rounded
/// to about 1 km, named with Apple's own reverse lookup. Only when you press the button; nothing
/// tracks the location afterwards.
final class MacLocation: NSObject, CLLocationManagerDelegate {

    enum Failure: Error, CustomStringConvertible {
        case denied, unavailable
        var description: String {
            switch self {
            case .denied: "Location is off for SecondPad (System Settings → Privacy & Security → Location Services)."
            case .unavailable: "This Mac couldn't find its location. Search for a city instead."
            }
        }
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func place() async throws -> WeatherPlace {
        let location = try await fix()
        let lat = (location.coordinate.latitude * 100).rounded() / 100
        let lon = (location.coordinate.longitude * 100).rounded() / 100
        var name = ""
        if let request = MKReverseGeocodingRequest(location: CLLocation(latitude: lat, longitude: lon)),
           let item = try? await request.mapItems.first {
            name = item.addressRepresentations?.cityWithContext ?? item.addressRepresentations?.cityName ?? item.name ?? ""
        }
        return WeatherPlace(name: name.isEmpty ? String(format: "%.2f, %.2f", lat, lon) : name, latitude: lat, longitude: lon)
    }

    private func fix() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .denied, .restricted: finish(.failure(Failure.denied))
            case .notDetermined: manager.requestWhenInUseAuthorization()
            default: manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard continuation != nil else { return }
            switch status {
            case .denied, .restricted: finish(.failure(Failure.denied))
            case .notDetermined: break
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        MainActor.assumeIsolated {
            if let last { finish(.success(last)) } else { finish(.failure(Failure.unavailable)) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(Failure.unavailable)) }
    }
}
