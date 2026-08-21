import SwiftUI

// WMO codes 0-99 from Open-Meteo: icon and human-readable description.
// Day and night differ only where the symbol includes a sun or moon.
enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: isDay ? "sun.max.fill" : "moon.fill"
        case 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57: "cloud.sleet.fill"
        case 61, 63: "cloud.rain.fill"
        case 65: "cloud.heavyrain.fill"
        case 66, 67: "cloud.sleet.fill"
        case 71, 73, 75, 77: "cloud.snow.fill"
        case 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 82: "cloud.heavyrain.fill"
        case 85, 86: "cloud.snow.fill"
        case 95: "cloud.bolt.rain.fill"
        case 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func text(_ code: Int) -> String {
        switch code {
        // Explicit key: the English word "Clear" is also the shelf's "Clear"
        // button, and one catalog key can't be both «ясно» and «Очистить»
        case 0: String(localized: "weather.clear", defaultValue: "Clear")
        case 1: String(localized: "Mostly clear")
        case 2: String(localized: "Partly cloudy")
        case 3: String(localized: "Overcast")
        case 45: String(localized: "Fog")
        case 48: String(localized: "Rime fog")
        case 51: String(localized: "Light drizzle")
        case 53: String(localized: "Drizzle")
        case 55: String(localized: "Dense drizzle")
        case 56, 57: String(localized: "Freezing drizzle")
        case 61: String(localized: "Light rain")
        case 63: String(localized: "Rain")
        case 65: String(localized: "Heavy rain")
        case 66, 67: String(localized: "Freezing rain")
        case 71: String(localized: "Light snow")
        case 73: String(localized: "Snow")
        case 75: String(localized: "Heavy snow")
        case 77: String(localized: "Snow grains")
        case 80: String(localized: "Rain showers")
        case 81: String(localized: "Showers")
        case 82: String(localized: "Heavy showers")
        case 85: String(localized: "Snow showers")
        case 86: String(localized: "Heavy snow showers")
        case 95: String(localized: "Thunderstorm")
        case 96, 99: String(localized: "Thunderstorm with hail")
        default: String(localized: "No data")
        }
    }

    // Tile color comes from the data, not the theme: sun is warm, precipitation
    // takes the accent color, clouds and fog stay neutral
    static func tint(_ code: Int, theme: Theme) -> Color {
        switch code {
        case 0, 1: theme.warning.color
        case 2: theme.textSecondary.color
        case 45, 48, 3: theme.textMuted.color
        case 95, 96, 99: theme.error.color
        case 71, 73, 75, 77, 85, 86: theme.textPrimary.color
        default: theme.accent.color
        }
    }
}

// One number format for every tile: "20°", "−3°", "1.4 m/s"
extension Double {
    var degreesText: String {
        let rounded = (self).rounded()
        let value = rounded == 0 ? 0 : rounded  // there's no such thing as "−0°"
        return value.formatted(.number.precision(.fractionLength(0))) + "°"
    }
}
