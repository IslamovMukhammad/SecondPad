import Foundation

nonisolated struct WeatherPlace: Codable, Equatable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
}

nonisolated struct WeatherMessage: Encodable, Equatable, Sendable {
    let type = "weather"
    let temperature: Int?
    /// Open-Meteo / WMO weather code.
    let code: Int?
    let isDay: Bool
    let city: String?
    /// Epoch seconds of the reading; nil when there's no reading yet.
    let updatedAt: Double?
    private enum CodingKeys: String, CodingKey { case type, temperature, code, isDay, city, updatedAt }
}

/// Current temperature from Open-Meteo (free, no key) for a city you type in Settings. No location
/// permission: the city name is looked up once, then only its coordinates are sent, every 15 min.
final class WeatherService {

    private(set) var place: WeatherPlace?
    private(set) var latest: WeatherMessage
    var onChange: (() -> Void)?
    private var timer: Timer?
    private let defaults: UserDefaults
    private static let placeKey = "weather.place"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.placeKey), let value = try? JSONDecoder().decode(WeatherPlace.self, from: data) {
            place = value
        }
        latest = WeatherMessage(temperature: nil, code: nil, isDay: true, city: place?.name, updatedAt: nil)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 120
    }

    func setPlace(_ value: WeatherPlace?) {
        place = value
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.placeKey) }
        else { defaults.removeObject(forKey: Self.placeKey) }
        latest = WeatherMessage(temperature: nil, code: nil, isDay: true, city: value?.name, updatedAt: nil)
        onChange?()
        refresh()
    }

    /// Demo mode.
    func setDemo(_ message: WeatherMessage) {
        timer?.invalidate()
        latest = message
        onChange?()
    }

    func refresh() {
        guard let place else { return }
        Task {
            guard let reading = await Self.fetch(place), self.place == place else { return }
            self.latest = reading
            self.onChange?()
        }
    }

    nonisolated static func forecastURL(_ place: WeatherPlace) -> URL? {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        parts?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return parts?.url
    }

    nonisolated static func parse(_ data: Data, city: String, now: Date = Date()) -> WeatherMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue else { return nil }
        return WeatherMessage(temperature: Int(temperature.rounded()),
                              code: (current["weather_code"] as? NSNumber)?.intValue,
                              isDay: ((current["is_day"] as? NSNumber)?.intValue ?? 1) == 1,
                              city: city, updatedAt: now.timeIntervalSince1970)
    }

    nonisolated private static func fetch(_ place: WeatherPlace) async -> WeatherMessage? {
        guard let url = forecastURL(place),
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, city: place.name)
    }

    // MARK: - City lookup (Settings)

    nonisolated static func geocodeURL(_ name: String) -> URL? {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        parts?.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "5"),
                             URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")]
        return parts?.url
    }

    nonisolated static func parsePlaces(_ data: Data) -> [WeatherPlace] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let name = item["name"] as? String,
                  let lat = (item["latitude"] as? NSNumber)?.doubleValue,
                  let lon = (item["longitude"] as? NSNumber)?.doubleValue else { return nil }
            let country = item["country"] as? String
            let admin = item["admin1"] as? String
            let label = [name, admin, country].compactMap { $0 }.filter { !$0.isEmpty }
            return WeatherPlace(name: label.prefix(2).joined(separator: ", "), latitude: lat, longitude: lon)
        }
    }

    nonisolated static func search(_ name: String) async -> [WeatherPlace] {
        guard let url = geocodeURL(name),
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parsePlaces(data)
    }
}
