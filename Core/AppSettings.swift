import ServiceManagement
import SwiftUI

// App-wide settings: anything not tied to a specific tile.
// Lives in UserDefaults, readable from anywhere — including the notch island,
// which works while the panel is closed and can't see widgets.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    /// When to show weather at the notch
    enum WeatherAlert: String, Codable, CaseIterable, Sendable {
        case off, beforeRain, hourly, severe

        var title: String {
            switch self {
            case .off: String(localized: "Never")
            case .beforeRain: String(localized: "An hour before rain")
            case .hourly: String(localized: "Every hour")
            case .severe: String(localized: "Severe weather only")
            }
        }

        var explanation: String {
            switch self {
            case .off: String(localized: "Weather never appears at the notch")
            case .beforeRain: String(localized: "Appears an hour before rain or snow and leaves after half a minute")
            case .hourly: String(localized: "Shows temperature and the near-term forecast once an hour")
            case .severe: String(localized: "Stays quiet except for downpours, storms, and heavy snow")
            }
        }
    }

    var weatherAlert: WeatherAlert {
        didSet { store(weatherAlert.rawValue, "settings.weatherAlert") }
    }

    /// Default city: used by widgets without a city of their own, and by the island
    var weatherPlace: Place? {
        didSet { storeJSON(weatherPlace, "settings.weatherPlace") }
    }

    /// Nobody has picked a city yet — take the one the time zone names. Asked for
    /// by whoever needs weather (a tile waking up, the settings section opening),
    /// never at launch: a person who doesn't use weather shouldn't pay for a request
    @ObservationIgnored private var guessingPlace = false

    func ensureWeatherPlace() {
        guard weatherPlace == nil, !guessingPlace else { return }
        guessingPlace = true
        Task { [weak self] in
            let guess = await OpenMeteo.guessPlace()
            guard let self else { return }
            guessingPlace = false
            // Someone picked a city while we were asking — their choice wins
            guard weatherPlace == nil, let guess else { return }
            weatherPlace = guess
            sillLog("[weather] city guessed from the time zone: \(guess.name)")
        }
    }

    /// What the currency tile shows — a single ordered list mixing currencies and
    /// coins in the order they were added. Order matters: a square fits one row,
    /// a rectangle fits three. The choice is app-wide
    var currencies: [CurrencyChoice] {
        didSet { storeJSON(currencies, "settings.currencies") }
    }

    /// What we price in: ruble, dollar, or euro. The central bank rate comes in
    /// rubles, everything else is converted through it
    var baseCurrency: String {
        didSet { store(baseCurrency, "settings.baseCurrency") }
    }

    /// Coins have a base of their own. The world quotes crypto in dollars, while the
    /// Central Bank rate comes in rubles — with one base for both, either bitcoin
    /// read in rubles or the euro read in dollars
    var cryptoBase: String {
        didSet { store(cryptoBase, "settings.cryptoBase") }
    }

    /// Coins only — their rate comes from a different source
    var cryptoCodes: [String] { currencies.filter(\.isCrypto).map(\.code) }

    /// Show the current track at the notch. Costs a live process — hence the toggle
    var musicInNotch: Bool {
        didSet { store(musicInNotch, "settings.musicInNotch") }
    }

    /// Show a running timer or stopwatch at the notch. Turning it off hides the
    /// capsule only — the finished-timer sound and notification still fire
    var timerInNotch: Bool {
        didSet { store(timerInNotch, "settings.timerInNotch") }
    }

    /// Pomodoro lengths, in minutes. Shared by every pomodoro tile: this is a
    /// person's rhythm, not a property of one tile
    var pomodoroWork: Int {
        didSet { store(pomodoroWork, "settings.pomodoroWork") }
    }

    var pomodoroRest: Int {
        didSet { store(pomodoroRest, "settings.pomodoroRest") }
    }

    /// Show the running pomodoro at the notch
    var pomodoroInNotch: Bool {
        didSet { store(pomodoroInNotch, "settings.pomodoroInNotch") }
    }

    /// Show battery events at the notch (plugged in, unplugged, low charge)
    var batteryInNotch: Bool {
        didSet { store(batteryInNotch, "settings.batteryInNotch") }
    }

    /// Keep clipboard history. Off by default: the app doesn't start recording
    /// what you copy until you ask it to
    var clipboardEnabled: Bool {
        didSet {
            store(clipboardEnabled, "settings.clipboardEnabled")
            ClipboardStore.shared.syncWithSettings()
            // The clipboard board appears and disappears together with this setting
            NotificationCenter.default.post(name: .sillClipboardToggled, object: nil)
        }
    }

    /// Two-column cards vs. a list of rows
    var clipboardCards: Bool {
        didSet { store(clipboardCards, "settings.clipboardCards") }
    }

    /// How many entries to keep, 1…500. Clamped at the source, not only in the
    /// settings field: a negative value written via `defaults` used to make
    /// trim() drop everything unpinned
    static let clipboardLimitRange = 1...500

    var clipboardLimit: Int {
        didSet {
            let clamped = min(max(clipboardLimit, Self.clipboardLimitRange.lowerBound),
                Self.clipboardLimitRange.upperBound)
            // Assigning inside didSet doesn't re-trigger the observer
            if clamped != clipboardLimit { clipboardLimit = clamped }
            store(clipboardLimit, "settings.clipboardLimit")
            // A lowered limit takes effect now, not on the next copy
            ClipboardStore.shared.limitChanged()
        }
    }

    /// How many days to keep history. 0 — forever
    var clipboardDays: Int {
        didSet { store(clipboardDays, "settings.clipboardDays") }
    }

    /// Shortcut for quick clipboard access. Empty — no shortcut
    var clipboardHotkey: GlobalHotkey.Combo? {
        didSet {
            storeJSON(clipboardHotkey, "settings.clipboardHotkey")
            GlobalHotkey.shared.apply(clipboardHotkey)
        }
    }

    /// Apps we never record copies from
    var clipboardExcludedApps: Set<String> {
        didSet {
            store(Array(clipboardExcludedApps), "settings.clipboardExcludedApps")
        }
    }

    /// Who we ask the model through
    var llmProvider: LLMProvider {
        didSet {
            store(llmProvider.rawValue, "settings.llmProvider")
            // Keys are per provider — "key present" is a different answer now
            LLMClient.shared.keyDidChange()
            // Each provider remembers its own model pick: a hand-chosen
            // gpt-4o used to ride into Anthropic and produce a cryptic error
            llmModel = Self.storedModel(for: llmProvider) ?? llmProvider.defaultModel
        }
    }

    private static func storedModel(for provider: LLMProvider) -> String? {
        UserDefaults.standard.string(forKey: "settings.llmModel.\(provider.rawValue)")
    }

    /// The "Ask" bar in the panel. It makes the panel taller, so it's opt-in
    var askBar: Bool {
        didSet {
            store(askBar, "settings.askBar")
            NotificationCenter.default.post(name: .sillPanelSizeChanged, object: nil)
        }
    }

    var llmModel: String {
        // Stored per provider so a switch and a switch back keep both picks
        didSet { store(llmModel, "settings.llmModel.\(llmProvider.rawValue)") }
    }

    /// Launch together with the system. Source of truth is the system itself
    /// (SMAppService), not UserDefaults: the user can disable the entry in
    /// Login Items, and the toggle must reflect that
    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// What went wrong with autostart — shown under the toggle
    private(set) var launchAtLoginNote: String?

    private init() {
        let defaults = UserDefaults.standard
        weatherAlert = (defaults.string(forKey: "settings.weatherAlert"))
            .flatMap(WeatherAlert.init(rawValue:)) ?? .beforeRain
        weatherPlace = defaults.data(forKey: "settings.weatherPlace")
            .flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        // Through a local: @Observable properties can't be read while the object is
        // still being initialized
        let savedBase = defaults.string(forKey: "settings.baseCurrency") ?? "RUB"
        baseCurrency = savedBase
        // No separate choice yet — coins keep showing in whatever the currencies do,
        // exactly as before this setting existed
        cryptoBase = defaults.string(forKey: "settings.cryptoBase") ?? savedBase
        // Migration from old keys: try the new list first, then the two old ones
        if let saved = Self.loadJSON([CurrencyChoice].self, "settings.currencies") {
            currencies = saved
        } else {
            let fiat = Self.loadJSON([String].self, "settings.currencyCodes")
                ?? CurrencyWidget.defaultCodes
            let crypto = Self.loadJSON([String].self, "settings.cryptoCodes") ?? []
            currencies = fiat.map { CurrencyChoice(code: $0, isCrypto: false) }
                + crypto.map { CurrencyChoice(code: $0, isCrypto: true) }
        }
        musicInNotch = defaults.object(forKey: "settings.musicInNotch") as? Bool
            ?? defaults.object(forKey: "appearance.musicInNotch") as? Bool ?? true
        timerInNotch = defaults.object(forKey: "settings.timerInNotch") as? Bool ?? true
        pomodoroWork = defaults.object(forKey: "settings.pomodoroWork") as? Int ?? 25
        pomodoroRest = defaults.object(forKey: "settings.pomodoroRest") as? Int ?? 5
        pomodoroInNotch = defaults.object(forKey: "settings.pomodoroInNotch") as? Bool ?? true
        batteryInNotch = defaults.object(forKey: "settings.batteryInNotch") as? Bool ?? true
        askBar = defaults.object(forKey: "settings.askBar") as? Bool ?? true
        let provider = (defaults.string(forKey: "settings.llmProvider"))
            .flatMap(LLMProvider.init(rawValue:)) ?? .openRouter
        llmProvider = provider
        // Per-provider key first, then the old shared key as a migration path
        llmModel = Self.storedModel(for: provider)
            ?? defaults.string(forKey: "settings.llmModel")
            ?? provider.defaultModel
        clipboardEnabled = defaults.bool(forKey: "settings.clipboardEnabled")
        clipboardCards = defaults.object(forKey: "settings.clipboardCards") as? Bool ?? false
        // Clamped on read too: a bad value may already be sitting in defaults
        clipboardLimit = min(
            max(defaults.object(forKey: "settings.clipboardLimit") as? Int ?? 200,
                Self.clipboardLimitRange.lowerBound),
            Self.clipboardLimitRange.upperBound)
        clipboardDays = defaults.object(forKey: "settings.clipboardDays") as? Int ?? 30
        clipboardHotkey = defaults.data(forKey: "settings.clipboardHotkey")
            .flatMap { try? JSONDecoder().decode(GlobalHotkey.Combo.self, from: $0) }
        clipboardExcludedApps = (defaults.array(forKey: "settings.clipboardExcludedApps")
            as? [String]).map(Set.init) ?? ClipboardStore.defaultExcludedApps
        launchAtLogin = Self.registered
        launchAtLoginNote = Self.note(for: SMAppService.mainApp.status)
    }

    /// Is autostart registered. requiresApproval means "we registered it, but the
    /// person hasn't approved it in System Settings yet" — the toggle stays on,
    /// otherwise it would flip off by itself right after being switched on
    private static var registered: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    private static func note(for status: SMAppService.Status) -> String? {
        switch status {
        case .requiresApproval:
            String(localized: "Allow Sill in System Settings → General → Login Items")
        case .notFound:
            String(localized: "The system couldn't find the app — move Sill to Applications and turn this back on")
        default:
            nil
        }
    }

    private func applyLaunchAtLogin() {
        // The toggle already matches the system — e.g. we just set it back ourselves
        guard launchAtLogin != Self.registered else {
            launchAtLoginNote = Self.note(for: SMAppService.mainApp.status)
            return
        }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginNote = Self.note(for: SMAppService.mainApp.status)
        } catch {
            launchAtLoginNote = String(localized: "Didn't work: \(error.localizedDescription)")
            // Reflect the actual state, not what was clicked
            launchAtLogin = Self.registered
        }
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func loadJSON<T: Codable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func storeJSON(_ value: (some Codable)?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension Notification.Name {
    static let sillClipboardToggled = Notification.Name("sill.clipboardToggled")
    /// The panel changed size — the window needs to be recalculated
    static let sillPanelSizeChanged = Notification.Name("sill.panelSizeChanged")
}
