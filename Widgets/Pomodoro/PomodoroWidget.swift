import AppKit
import SwiftUI

// Pomodoro: work, then a break, then work again. Like the timer, it counts from a
// timestamp rather than ticking — the widget sleeps while the panel is closed, and
// the phase still lands where it should, because everything is computed from one
// date. Work and break lengths come from Settings → Pomodoro: they are a person's
// habit, not a property of a tile.
@MainActor @Observable
final class PomodoroWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "pomodoro",
        name: "Pomodoro",
        icon: "leaf",
        sizes: [.small, .medium, .large],
        defaultSize: .small
    )

    enum Phase: String, Codable, Sendable {
        case work, rest

        var title: String {
            self == .work ? String(localized: "Focus") : String(localized: "Break")
        }

        var other: Phase { self == .work ? .rest : .work }
    }

    /// What's running and since when. Lives in the tile's settings, so it survives a
    /// restart, and is published to the notch island, which has no widgets to ask.
    /// The durations travel with the state: the island reads one key and needs
    /// nothing else to know when the phase ends
    struct State: Codable, Sendable {
        var phase: Phase = .work
        /// When the current phase started. nil means paused
        var startedAt: Date?
        /// Time spent in the current phase before the last pause
        var accumulated: TimeInterval = 0
        var work: TimeInterval = 25 * 60
        var rest: TimeInterval = 5 * 60
        /// Work phases finished today
        var done: Int = 0
        /// Which day `done` counts — a new day starts the count over
        var day: Date = .distantPast

        func duration(of phase: Phase) -> TimeInterval { phase == .work ? work : rest }

        var duration: TimeInterval { duration(of: phase) }
    }

    private let context: WidgetContext
    private(set) var state = State()
    private(set) var now = Date()

    init(context: WidgetContext) {
        self.context = context
        state = context.settings.get("state", as: State.self) ?? State()
        applySettings()
        context.schedule(every: .seconds(1)) { [weak self] in
            guard let self, isRunning else { return }
            now = Date()
            advance()
        }
    }

    func activate() async throws {
        applySettings()
        now = Date()
        advance()
    }

    /// Lengths are shared by every pomodoro tile: they are set in Settings, and a
    /// tile that kept its own copy would drift away from them silently
    private func applySettings() {
        let settings = AppSettings.shared
        let work = TimeInterval(settings.pomodoroWork * 60)
        let rest = TimeInterval(settings.pomodoroRest * 60)
        guard state.work != work || state.rest != rest else { return }
        state.work = work
        state.rest = rest
        persist()
    }

    // MARK: - state

    var isRunning: Bool { state.startedAt != nil }

    var phase: Phase { state.phase }

    /// Time left in the current phase
    var value: TimeInterval {
        let elapsed = state.accumulated + (state.startedAt.map { now.timeIntervalSince($0) } ?? 0)
        return max(state.duration - elapsed, 0)
    }

    var progress: Double {
        guard state.duration > 0 else { return 0 }
        return min(max(1 - value / state.duration, 0), 1)
    }

    /// Work phases finished today. Yesterday's count doesn't carry over: the number
    /// answers "how much have I done today", not "ever"
    var doneToday: Int {
        Calendar.current.isDateInToday(state.day) ? state.done : 0
    }

    /// When the current phase ends — the same question the timer answers, and the
    /// same reason: otherwise it's arithmetic in your head
    var endsAt: Date? {
        guard isRunning, value > 0 else { return nil }
        return Date().addingTimeInterval(value)
    }

    // MARK: - controls

    func toggle() {
        if let startedAt = state.startedAt {
            state.accumulated += Date().timeIntervalSince(startedAt)
            state.startedAt = nil
        } else {
            state.startedAt = Date()
        }
        persist()
    }

    /// Skip to the next phase. Finishing work early still counts as a pomodoro —
    /// the count is for sessions worked, and the person decides when one is over
    func skip() {
        complete(state.phase)
        state.phase = state.phase.other
        state.accumulated = 0
        if state.startedAt != nil { state.startedAt = Date() }
        persist()
    }

    /// Back to the start of the work phase — the counter for the day stays
    func reset() {
        state.phase = .work
        state.startedAt = nil
        state.accumulated = 0
        persist()
    }

    // The tile is a controller: starting and pausing happen in place, so the click
    // must not close the panel
    func primaryAction() -> Bool {
        toggle()
        return false
    }

    /// The island reads pomodoro state from UserDefaults, which outlives the widget:
    /// without this the notch would keep counting a tile that no longer exists
    func tileWillRemove() {
        PomodoroActivity.publish(nil, for: context.tileID)
    }

    // MARK: - the clock

    /// The phase rolls over on its own, and several may pass while the panel is
    /// closed — walking them is a loop, not a special case. Bounded by the number of
    /// phases that actually fit in the elapsed time
    private func advance() {
        guard isRunning else { return }
        var guardCount = 0
        while value <= 0, guardCount < 500 {
            guardCount += 1
            let duration = state.duration
            complete(state.phase)
            state.phase = state.phase.other
            // Chained from the previous phase's end, not from "now": the next phase
            // started the moment this one ran out, even if nobody was watching
            state.startedAt = (state.startedAt ?? Date()).addingTimeInterval(duration - state.accumulated)
            state.accumulated = 0
        }
        if guardCount > 0 { persist() }
    }

    /// A finished work phase adds to today's count
    private func complete(_ phase: Phase) {
        guard phase == .work else { return }
        if !Calendar.current.isDateInToday(state.day) {
            state.day = Date()
            state.done = 0
        }
        state.done += 1
    }

    private func persist() {
        context.settings.set("state", state)
        // One cheap key for the island: it works while the panel is closed and can't
        // ask a sleeping widget anything
        PomodoroActivity.publish(state.startedAt != nil ? state : nil, for: context.tileID)
        now = Date()
    }

    // MARK: - display

    static func text(_ seconds: TimeInterval) -> String { TimerWidget.text(seconds) }

    var body: AnyView {
        AnyView(PomodoroTileView(widget: self, size: context.tileSize))
    }
}
