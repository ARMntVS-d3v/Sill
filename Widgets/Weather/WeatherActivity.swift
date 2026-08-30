import SwiftUI

// Rain alert on the notch island. The forecast is read from the weather widget's
// on-disk cache — the same one the widget writes on refresh. No network calls,
// no waking the widget: this activity has to be free.
@MainActor
enum WeatherActivity {
    static let id = "weather.rain"
    /// How far ahead we warn about precipitation
    private static let horizon: TimeInterval = 3600
    /// How long the capsule stays up and how often it repeats — it's a
    /// notification, not a status indicator
    private static let showTime: TimeInterval = 30
    private static let repeatAfter: TimeInterval = 3 * 3600

    private static var shownFor: Date?
    private static var hideAt: Date?

    static func refresh() {
        let mode = AppSettings.shared.weatherAlert
        guard mode != .off else {
            LiveActivityCenter.shared.clear(id)
            return
        }

        // Display time is up — clear it and wait for the next event
        if let deadline = hideAt, Date() >= deadline {
            hideAt = nil
            LiveActivityCenter.shared.clear(id)
            return
        }
        if hideAt != nil { return }

        guard let upcoming = nearestPrecipitation(mode: mode) else {
            LiveActivityCenter.shared.clear(id)
            return
        }
        // Never remind about the same event more than once every three hours
        if let shownFor, abs(shownFor.timeIntervalSince(upcoming.date)) < repeatAfter { return }
        shownFor = upcoming.date
        hideAt = Date().addingTimeInterval(showTime)
        LiveActivityCenter.shared.update(
            LiveActivity(
                id: id,
                icon: WeatherCode.symbol(upcoming.code, isDay: upcoming.isDay),
                // .minute() without twoDigits prints "19:0" — the leading zero gets dropped
                value: upcoming.date.formatted(
                    Date.FormatStyle(timeZone: upcoming.zone)
                        .hour(.twoDigits(amPM: .omitted))
                        .minute(.twoDigits)),
                tint: Color(red: 0.39, green: 0.72, blue: 1),
                // Quieter than the timer: rain is worth noticing, but it's not urgent
                priority: LiveActivity.Priority.weather))
    }

    private static func nearestPrecipitation(mode: AppSettings.WeatherAlert) -> (
        date: Date, code: Int, isDay: Bool, zone: TimeZone
    )? {
        let now = Date()
        for snapshot in cachedSnapshots() {
            let upcoming = snapshot.hours.first { hour in
                guard hour.date > now, hour.date < now.addingTimeInterval(horizon) else {
                    return false
                }
                switch mode {
                case .severe: return isSevere(hour.code)
                case .hourly: return true
                default: return isWet(hour.code)
                }
            }
            if let upcoming {
                return (upcoming.date, upcoming.code, upcoming.isDay, snapshot.timeZone)
            }
        }
        return nil
    }

    // Drizzle, rain, showers, snow, and thunderstorms — anything worth grabbing an umbrella for
    private static func isWet(_ code: Int) -> Bool {
        (51...67).contains(code) || (71...86).contains(code) || (95...99).contains(code)
    }

    // Severe weather: heavy rain and snow, downpours, thunderstorms
    private static func isSevere(_ code: Int) -> Bool {
        [65, 67, 75, 82, 86].contains(code) || (95...99).contains(code)
    }

    // The cache is shared across the widget's instances, keyed by tile id, so we
    // read the whole file. Parsed result is kept in memory: the island ticks
    // every couple of seconds, but the forecast changes every fifteen minutes —
    // no need to read and parse the file on every tick
    private static var parsed: (at: Date, value: [WeatherSnapshot])?
    private static let parsedTTL: TimeInterval = 60

    private static func cachedSnapshots() -> [WeatherSnapshot] {
        if let parsed, Date().timeIntervalSince(parsed.at) < parsedTTL { return parsed.value }
        let url = URL.applicationSupportDirectory.appending(path: "Sill/cache/weather.json")
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode([String: Data].self, from: data)
        else {
            parsed = (Date(), [])
            return []
        }
        let value = store.values.compactMap {
            try? JSONDecoder().decode(WeatherSnapshot.self, from: $0)
        }
        parsed = (Date(), value)
        return value
    }
}
