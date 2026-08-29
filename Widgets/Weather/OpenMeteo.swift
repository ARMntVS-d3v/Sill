import Foundation

// Open-Meteo client: forecast and city search. No key needed — non-commercial
// use is free (600/min, 5000/hour, 10000/day), data is under CC BY 4.0,
// attribution is required and lives in the widget's caption.
// Verified live: api.open-meteo.com/v1/forecast and geocoding-api.open-meteo.com/v1/search.

// City: comes from the geocoder, stored in the tile's settings
struct Place: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var country: String?
    var admin1: String?
    var latitude: Double
    var longitude: Double

    // "Moscow Oblast, Russia" — the qualifier shown under the name in search results
    var subtitle: String {
        [admin1, country].compactMap { $0 }.filter { $0 != name }.joined(separator: ", ")
    }
}

struct WeatherSnapshot: Codable, Sendable {
    struct Current: Codable, Sendable {
        var temperature: Double
        var apparent: Double
        var code: Int
        var isDay: Bool
        var wind: Double
        var humidity: Int
    }

    struct Hour: Codable, Sendable, Identifiable {
        var date: Date
        var temperature: Double
        var code: Int
        var precipitation: Int
        var isDay: Bool
        var id: Date { date }
    }

    struct Day: Codable, Sendable, Identifiable {
        var date: Date
        var code: Int
        var low: Double
        var high: Double
        var id: Date { date }
    }

    var placeName: String
    var updated: Date
    // City's UTC offset: the tile shows the city's local time, not our own
    var utcOffset: Int
    var current: Current
    var hours: [Hour]
    var days: [Day]
    var sunrise: Date?
    var sunset: Date?

    var timeZone: TimeZone { TimeZone(secondsFromGMT: utcOffset) ?? .current }
}

enum OpenMeteoError: Error, LocalizedError {
    case badResponse
    var errorDescription: String? { String(localized: "Open-Meteo didn't respond") }
}

enum OpenMeteo {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Shorter than the tile's watchdog timeout (10s): the widget must fail first
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    nonisolated static func search(city query: String) async throws -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { throw OpenMeteoError.badResponse }
        let (data, response) = try await session.data(from: url)
        // An HTTP error must throw, not decode: Open-Meteo's error body
        // ({"error":true,...}) has no `results`, and it used to decode into an
        // empty list — a network failure looked like "nothing found"
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OpenMeteoError.badResponse
        }
        return (try JSONDecoder().decode(GeocodingResponse.self, from: data)).results ?? []
    }

    /// A first guess at the city, with nothing asked of the person: the system's
    /// time zone already names one ("Europe/Moscow"), and the geocoder turns that
    /// name into a place with coordinates. No permission, no third-party service —
    /// CoreLocation would ask for location access, and IP geolocation hands the
    /// address to someone else and points at the VPN's exit anyway. The guess is a
    /// starting point, not a verdict: the city is still pickable in the tile and in
    /// settings
    nonisolated static func guessPlace() async -> Place? {
        let identifier = TimeZone.current.identifier
        // Only "Region/City" identifiers name a place; UTC and GMT+3 don't
        guard let city = identifier.split(separator: "/").last, identifier.contains("/") else {
            return nil
        }
        let name = city.replacingOccurrences(of: "_", with: " ")
        guard let found = try? await search(city: name) else { return nil }
        return found.first
    }

    nonisolated static func forecast(for place: Place) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,is_day,weather_code,wind_speed_10m,relative_humidity_2m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
        ]
        guard let url = components.url else { throw OpenMeteoError.badResponse }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OpenMeteoError.badResponse
        }
        let dto = try JSONDecoder().decode(ForecastResponse.self, from: data)
        return try snapshot(from: dto, place: place)
    }

    // Times in the response are the city's local time, no offset in the string;
    // the zone comes as a separate field
    private static func snapshot(from dto: ForecastResponse, place: Place) throws -> WeatherSnapshot {
        guard let zone = TimeZone(secondsFromGMT: dto.utc_offset_seconds) else {
            throw OpenMeteoError.badResponse
        }
        let parse = { (value: String) -> Date? in Self.date(from: value, zone: zone) }

        var hours: [WeatherSnapshot.Hour] = []
        let h = dto.hourly
        // The response arrays are parallel, but nothing guarantees equal length:
        // on a partial response one array can be shorter, and reading by index
        // used to crash the whole app, not just the widget
        for index in h.time.indices {
            guard let date = parse(h.time[index]),
                  h.temperature_2m.indices.contains(index),
                  h.weather_code.indices.contains(index)
            else { continue }
            hours.append(
                WeatherSnapshot.Hour(
                    date: date,
                    temperature: h.temperature_2m[index],
                    code: h.weather_code[index],
                    precipitation: h.precipitation_probability?.element(at: index) ?? 0,
                    isDay: (h.is_day?.element(at: index) ?? 1) == 1))
        }

        var days: [WeatherSnapshot.Day] = []
        let d = dto.daily
        for index in d.time.indices {
            guard let date = parse(d.time[index]),
                  d.weather_code.indices.contains(index),
                  d.temperature_2m_min.indices.contains(index),
                  d.temperature_2m_max.indices.contains(index)
            else { continue }
            days.append(
                WeatherSnapshot.Day(
                    date: date,
                    code: d.weather_code[index],
                    low: d.temperature_2m_min[index],
                    high: d.temperature_2m_max[index]))
        }

        return WeatherSnapshot(
            placeName: place.name,
            updated: Date(),
            utcOffset: dto.utc_offset_seconds,
            current: WeatherSnapshot.Current(
                temperature: dto.current.temperature_2m,
                apparent: dto.current.apparent_temperature,
                code: dto.current.weather_code,
                isDay: dto.current.is_day == 1,
                wind: dto.current.wind_speed_10m,
                humidity: dto.current.relative_humidity_2m),
            hours: hours,
            days: days,
            sunrise: d.sunrise.first.flatMap(parse),
            sunset: d.sunset.first.flatMap(parse))
    }

    // "2026-08-18T11:00" and "2026-08-18" — ISO without a zone, hence the custom format
    private static func date(from value: String, zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = value.count == 10 ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: value)
    }

    // MARK: - API responses

    private struct GeocodingResponse: Decodable {
        let results: [Place]?
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let is_day: Int
            let weather_code: Int
            let wind_speed_10m: Double
            let relative_humidity_2m: Int
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double]
            let weather_code: [Int]
            let precipitation_probability: [Int]?
            let is_day: [Int]?
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let sunrise: [String]
            let sunset: [String]
        }
        let utc_offset_seconds: Int
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }
}


extension Array {
    /// Index-based read that doesn't crash the app on a short server response
    func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
