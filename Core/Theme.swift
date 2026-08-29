import SwiftUI

// Theme color: hex string in JSON ("#RRGGBB" or "#RRGGBBAA").
struct ThemeColor: Codable, Sendable, Equatable {
    var hex: String

    init(_ hex: String) { self.hex = hex }

    init(from decoder: Decoder) throws {
        hex = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    var color: Color {
        var value: UInt64 = 0
        var cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        // Shorthand #fff / #fffa expands to full form: read as RRGGBB it
        // silently produced dark blue instead of white
        if cleaned.count == 3 || cleaned.count == 4 {
            cleaned = cleaned.map { "\($0)\($0)" }.joined()
        }
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return .pink }
        let r, g, b, a: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// A metric's role determines its color: CPU, memory, and network must be
// distinguishable at a glance, or a board of six tiles reads as one blue wall
enum MetricRole: Int, CaseIterable, Sendable {
    case cpu, memory, gpu, network, disk, battery
}

extension Theme {
    /// Metric color. A theme can supply its own set, otherwise the default
    /// set applies: blue CPU, green memory, purple GPU, cyan network,
    /// orange disk, yellow-green battery
    func metricColor(_ role: MetricRole) -> Color {
        if let metrics, metrics.indices.contains(role.rawValue) {
            return metrics[role.rawValue].color
        }
        return Theme.defaultMetricColors[role.rawValue].color
    }

    static let defaultMetricColors: [ThemeColor] = [
        ThemeColor("#0a84ff"),  // cpu
        ThemeColor("#30d158"),  // memory
        ThemeColor("#bf5af2"),  // gpu
        ThemeColor("#64d2ff"),  // network
        ThemeColor("#ff9f0a"),  // disk
        ThemeColor("#ffd60a"),  // battery
    ]
}

struct Theme: Codable, Sendable, Equatable {
    var name: String
    var panelBackground: ThemeColor
    var tileBackground: ThemeColor
    var tileHover: ThemeColor
    var textPrimary: ThemeColor
    var textSecondary: ThemeColor
    var textMuted: ThemeColor
    var accent: ThemeColor
    var success: ThemeColor
    var warning: ThemeColor
    var error: ThemeColor
    var border: ThemeColor
    var shadow: ThemeColor
    /// Metric palette: its own color per system widget. A theme can set this,
    /// otherwise the default set applies — six distinguishable shades
    var metrics: [ThemeColor]?
    var cornerRadius: Double
    var borderWidth: Double

    // Fallback if no theme could be loaded. Mirrors tokyo-night.json.
    static let fallback = Theme(
        name: "tokyo-night",
        panelBackground: ThemeColor("#1a1b26F2"),
        tileBackground: ThemeColor("#1f2335"),
        tileHover: ThemeColor("#292e42"),
        textPrimary: ThemeColor("#c0caf5"),
        textSecondary: ThemeColor("#a9b1d6"),
        textMuted: ThemeColor("#565f89"),
        accent: ThemeColor("#7aa2f7"),
        success: ThemeColor("#9ece6a"),
        warning: ThemeColor("#e0af68"),
        error: ThemeColor("#f7768e"),
        border: ThemeColor("#3b4261"),
        shadow: ThemeColor("#000000AA"),
        metrics: nil,
        cornerRadius: 12,
        borderWidth: 1
    )
}

extension EnvironmentValues {
    @Entry var theme: Theme = .fallback
}

// Themes: built in from the bundle + user themes from ~/.config/sill/themes/
// (override built-in themes of the same name). Hot-reload via a DispatchSource
// on the directory — event-driven, not polling.
@MainActor @Observable
final class ThemeEngine {
    private(set) var current: Theme = .fallback
    private(set) var available: [String: Theme] = [:]

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedFD: Int32 = -1
    @ObservationIgnored private var loaded = false
    // Default is midnight: a neutral dark base, blue accent. Color in tiles
    // comes from data (calendar colors, statuses), not from the theme.
    @ObservationIgnored private var currentName = "midnight"

    static var userThemesDir: URL {
        URL.homeDirectory.appending(path: ".config/sill/themes")
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let saved = UserDefaults.standard.string(forKey: "appearance.theme") { currentName = saved }
        try? FileManager.default.createDirectory(at: Self.userThemesDir, withIntermediateDirectories: true)
        reload()
        startWatching()
    }

    func select(name: String) {
        currentName = name
        current = available[name] ?? .fallback
        currentLoaded = available[name] != nil
        UserDefaults.standard.set(name, forKey: "appearance.theme")
    }

    var names: [String] { available.keys.sorted() }

    private func reload() {
        var themes: [String: Theme] = [:]
        var urls: [URL] = []
        if let bundled = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Themes") {
            urls += bundled
        }
        let userDir = Self.userThemesDir
        if let user = try? FileManager.default.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil) {
            urls += user.filter { $0.pathExtension == "json" }  // user themes last — override
        }
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let theme = try JSONDecoder().decode(Theme.self, from: data)
                // Indexed by file name, as the docs promise: indexing by the
                // inner `name` field let a copied file with a new file name
                // silently displace the original it still named inside
                let key = url.deletingPathExtension().lastPathComponent
                if theme.name != key {
                    sillLog("[theme] \(url.lastPathComponent) names itself \"\(theme.name)\" — listed as \(key)")
                }
                themes[key] = theme
            } catch {
                sillLog("[theme] failed to load \(url.lastPathComponent): \(error)")
            }
        }
        available = themes
        // A theme that stopped parsing (someone is editing its JSON) keeps the
        // previous in-memory colors instead of snapping to the fallback: the
        // author sees their own theme while fixing it, as architecture.md promises.
        // The fallback only applies when there's nothing kept yet — first load
        if let found = themes[currentName] {
            current = found
            currentLoaded = true
        } else if !currentLoaded {
            current = .fallback
        }
    }

    /// Whether `current` ever held the real theme named `currentName` — the
    /// keep-previous-colors rule above needs this; comparing names can't tell
    /// a kept theme from a never-loaded one
    @ObservationIgnored private var currentLoaded = false

    private func startWatching() {
        let fd = open(Self.userThemesDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { self.reload() }
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        watcher = source
    }
}
