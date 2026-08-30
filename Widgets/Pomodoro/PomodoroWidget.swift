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
        /// The finished phase has already been counted: the tile can sit on a
        /// finished phase for an hour, and it still counts once
        var counted = false

        func duration(of phase: Phase) -> TimeInterval { phase == .work ? work : rest }

        var duration: TimeInterval { duration(of: phase) }

        init() {}

        /// Decoded field by field, every one of them optional. Swift's synthesized
        /// decoder does NOT fall back to a property's default when the key is missing
        /// — it throws. Adding `counted` therefore broke every state written by the
        /// previous build: the tile lost its phase and the day's count, and the notch
        /// lost the pomodoro entirely, because the whole dictionary failed to decode
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            phase = try values.decodeIfPresent(Phase.self, forKey: .phase) ?? .work
            startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
            accumulated = try values.decodeIfPresent(TimeInterval.self, forKey: .accumulated) ?? 0
            work = try values.decodeIfPresent(TimeInterval.self, forKey: .work) ?? 25 * 60
            rest = try values.decodeIfPresent(TimeInterval.self, forKey: .rest) ?? 5 * 60
            done = try values.decodeIfPresent(Int.self, forKey: .done) ?? 0
            day = try values.decodeIfPresent(Date.self, forKey: .day) ?? .distantPast
            counted = try values.decodeIfPresent(Bool.self, forKey: .counted) ?? false
        }
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
            countFinish()
        }
    }

    func activate() async throws {
        applySettings()
        now = Date()
        countFinish()
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

    /// The phase has run out and is waiting. The next one does NOT start by itself:
    /// a break that began without you is not a break, and coming back to a machine
    /// that has been "resting" for an hour tells you nothing
    var finished: Bool { isRunning && value <= 0 }

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
        // The phase has rung and is waiting: play moves on to the next one
        if finished {
            begin(state.phase.other)
            return
        }
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
        if state.phase == .work, !state.counted { count() }
        begin(state.phase.other)
    }

    /// Start this phase over from the top, and keep it going. A button that only
    /// clears the number leaves you looking at a stopped timer
    func restart() {
        begin(state.phase)
    }

    /// Begin a phase from zero, running
    private func begin(_ phase: PomodoroWidget.Phase) {
        state.phase = phase
        state.startedAt = Date()
        state.accumulated = 0
        state.counted = false
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

    /// The work stretch that just ran out goes into the day's count — once, however
    /// long the tile sits on the finished phase afterwards
    private func countFinish() {
        guard finished, !state.counted else { return }
        state.counted = true
        if state.phase == .work { count() }
        persist()
    }

    private func count() {
        if !Calendar.current.isDateInToday(state.day) {
            state.day = Date()
            state.done = 0
        }
        state.done += 1
        state.counted = true
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
