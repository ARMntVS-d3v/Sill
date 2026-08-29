import AppKit
import SwiftUI

// Weather via Open-Meteo. The city is set by hand right in the tile and lives
// in the instance's settings: two tiles on the board means two cities
// (Moscow and Tbilisi side by side).
@MainActor @Observable
final class WeatherWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "weather",
        name: "Weather",
        icon: "cloud.sun",
        sizes: [.small, .medium, .large],
        defaultSize: .medium
    )

    // Data is valid for 15 minutes: Open-Meteo's model doesn't update any
    // faster, and there's no point spending the free tier's limit on identical responses
    private static let staleAfter: TimeInterval = 15 * 60

    private let context: WidgetContext
    private(set) var place: Place?
    private(set) var snapshot: WeatherSnapshot?

    // City search is tile UI state, so it lives in the widget
    var isPickingCity = false
    var query = ""
    private(set) var results: [Place] = []
    private(set) var searching = false
    private(set) var searchFailed = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(context: WidgetContext) {
        self.context = context
        // The tile's own city takes priority over the shared one: two tiles can
        // look at different cities
        place = context.settings.get("place", as: Place.self) ?? AppSettings.shared.weatherPlace
        // Instance key: the cache is shared per widget type, but each tile has its own city
        snapshot = context.cache.load(context.tileID.uuidString, as: WeatherSnapshot.self)
        isPickingCity = place == nil
        // Ticks every minute, refreshes only when the data has gone stale
        context.schedule(every: .seconds(60)) { [weak self] in
            await self?.refreshIfStale()
        }
    }

    /// The network didn't respond and there's nothing to show
    private(set) var failure: String?

    func activate() async throws {
        // No city anywhere yet: take the one the system's time zone names instead
        // of showing an empty tile. The picker stays available either way
        if place == nil {
            if let shared = AppSettings.shared.weatherPlace {
                adopt(shared)
            } else if let guess = await OpenMeteo.guessPlace() {
                // Shared, not just ours: the capsule at the notch reads this one
                AppSettings.shared.weatherPlace = guess
                adopt(guess)
                sillLog("[weather] city guessed from the time zone: \(guess.name)")
            }
        }
        await refreshIfStale()
    }

    /// Take a city that wasn't picked in this tile — the shared one or a guess.
    /// Not written to the tile's own settings: a tile without a city of its own
    /// should keep following the shared one
    private func adopt(_ place: Place) {
        self.place = place
        isPickingCity = false
        failure = nil
    }

    /// "Retry" button in the placeholder
    func retry() {
        failure = nil
        Task { await refreshIfStale() }
    }

    func deactivate() {
        searchTask?.cancel()
        searchTask = nil
    }

    /// The snapshot is keyed by tile id in the widget-wide cache — without
    /// this, every deleted weather tile left its forecast on disk forever
    func tileWillRemove() {
        context.cache.remove(context.tileID.uuidString)
    }

    func refresh() async throws {
        guard let place else { return }
        let loaded = try await OpenMeteo.forecast(for: place)
        snapshot = loaded
        context.cache.save(context.tileID.uuidString, loaded)
    }

    private func refreshIfStale() async {
        guard place != nil else { return }
        if let snapshot, Date().timeIntervalSince(snapshot.updated) < Self.staleAfter { return }
        do {
            try await refresh()
            failure = nil
        } catch {
            // The tile stays on the cache: stale weather beats an empty tile.
            // But with no cache at all, showing "Loading…" forever isn't an
            // option — the user needs to be told there's no connection, with a retry button
            context.log("refresh failed: \(error)")
            if snapshot == nil { failure = String(localized: "Couldn't load the weather") }
        }
    }

    var body: AnyView {
        AnyView(WeatherTileView(widget: self, size: context.tileSize))
    }

    // Tapping the tile opens the system Weather app — a plain launch by bundle
    // id, no private paths. Can't pass our city to it: it has no public URL
    // scheme, so it opens wherever it was last left
    func primaryAction() -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.weather")
        else { return false }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    // MARK: - city picker

    func startPickingCity() {
        query = ""
        results = []
        searchFailed = false
        isPickingCity = true
    }

    func cancelPickingCity() {
        searchTask?.cancel()
        isPickingCity = false
    }

    // Typing triggers search with a delay: otherwise it's a request per keystroke
    func queryChanged() {
        searchTask?.cancel()
        searchFailed = false
        let text = query
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            results = []
            searching = false
            return
        }
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let found = try await OpenMeteo.search(city: text)
                guard !Task.isCancelled else { return }
                self?.results = found
                self?.searching = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.results = []
                self?.searching = false
                self?.searchFailed = true
            }
        }
    }

    func select(_ place: Place) {
        self.place = place
        context.settings.set("place", place)
        // The first city chosen becomes the shared one: the notch island uses it too
        if AppSettings.shared.weatherPlace == nil { AppSettings.shared.weatherPlace = place }
        snapshot = nil
        // Same reset retry() does: the new city used to open showing the
        // previous city's error instead of "Loading…"
        failure = nil
        isPickingCity = false
        query = ""
        results = []
        Task { [weak self] in
            guard let self else { return }
            do {
                try await refresh()
            } catch {
                context.log("initial load failed: \(error)")
                // Otherwise the fresh city sat on "Loading…" forever with no Retry
                if snapshot == nil { failure = String(localized: "Couldn't load the weather") }
            }
        }
    }

    // MARK: - derived layout data

    // Upcoming hours, starting from the current one
    func nextHours(_ count: Int) -> [WeatherSnapshot.Hour] {
        guard let snapshot else { return [] }
        let now = Date()
        let upcoming = snapshot.hours.filter { $0.date >= now.addingTimeInterval(-3600) }
        return Array(upcoming.prefix(count))
    }

    func nextDays(_ count: Int) -> [WeatherSnapshot.Day] {
        guard let snapshot else { return [] }
        return Array(snapshot.days.prefix(count))
    }

    // The week's overall range — drives the min/max bars at the large size
    var weekRange: ClosedRange<Double>? {
        let days = nextDays(7)
        guard let low = days.map(\.low).min(), let high = days.map(\.high).max(), high > low else {
            return nil
        }
        return low...high
    }
}
