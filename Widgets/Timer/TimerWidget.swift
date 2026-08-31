import AppKit
import SwiftUI

// Timer and stopwatch in one tile. Counts from a timestamp rather than ticking:
// the widget sleeps while the panel is closed, but the timer stays accurate
// because it computes a date difference instead of counting ticks.
@MainActor @Observable
final class TimerWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "timer",
        name: "Timer / Stopwatch",
        icon: "timer",
        sizes: [.small, .medium, .large],
        defaultSize: .small
    )

    enum Mode: String, Codable, Sendable, CaseIterable {
        case timer, stopwatch

        var title: String { self == .timer ? String(localized: "Timer") : String(localized: "Stopwatch") }
    }

    // What's running and since when. Stored in the tile's settings, so it
    // survives an app restart and is visible to the notch island
    struct State: Codable, Sendable {
        var mode: Mode = .timer
        /// When it was started. nil means stopped
        var startedAt: Date?
        /// How much time had accumulated before the last pause
        var accumulated: TimeInterval = 0
        /// The timer's set duration
        var duration: TimeInterval = 5 * 60

        init() {}

        /// Same tolerance as the pomodoro's state, and for the same reason: a record
        /// written before a field existed has to keep loading. Swift's synthesized
        /// decoder throws on a missing key instead of using the default
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .timer
            startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
            accumulated = try values.decodeIfPresent(TimeInterval.self, forKey: .accumulated) ?? 0
            duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 5 * 60
        }
    }

    private let context: WidgetContext
    private(set) var state = State()
    private(set) var now = Date()
    // Time's up and the user hasn't reset yet — the tile glows a warning
    private(set) var finished = false

    init(context: WidgetContext) {
        self.context = context
        state = context.settings.get("state", as: State.self) ?? State()
        republish()
        context.schedule(every: .seconds(1)) { [weak self] in
            guard let self else { return }
            // A stopped timer shouldn't tick: redrawing the tile every second for
            // an unchanged number is the one idle tick in the whole project
            guard isRunning || finished else { return }
            now = Date()
            checkFinish()
        }
    }

    func activate() async throws {
        now = Date()
        checkFinish()
        republish()
    }

    /// Put the running state back in front of the island — same reason as the
    /// pomodoro's: the capsule reads one key, written only when something happens,
    /// and a state lost between launches left the notch empty while the timer ran
    private func republish() {
        guard state.startedAt != nil else { return }
        TimerActivity.publish(state, for: context.tileID)
    }

    // MARK: - controls

    var isRunning: Bool { state.startedAt != nil }

    /// What to display: remaining time for the timer, elapsed time for the stopwatch
    var value: TimeInterval {
        let elapsed = state.accumulated + (state.startedAt.map { now.timeIntervalSince($0) } ?? 0)
        guard state.mode == .timer else { return elapsed }
        return max(state.duration - elapsed, 0)
    }

    var progress: Double {
        guard state.mode == .timer, state.duration > 0 else { return 0 }
        return min(max(1 - value / state.duration, 0), 1)
    }

    func toggle() {
        if let startedAt = state.startedAt {
            state.accumulated += Date().timeIntervalSince(startedAt)
            state.startedAt = nil
        } else {
            finished = false
            state.startedAt = Date()
        }
        persist()
    }

    /// Back to the full interval, stopped. The button clears, it doesn't start
    /// anything: starting is what play is for
    func reset() {
        state.startedAt = nil
        state.accumulated = 0
        finished = false
        persist()
    }

    /// The tile is being removed: the island reads timer state from
    /// UserDefaults, which survives the widget — without this a running
    /// timer kept counting (and ringing) at the notch with no tile left to stop it
    func tileWillRemove() {
        TimerActivity.publish(nil, for: context.tileID)
    }

    func setMode(_ mode: Mode) {
        state.mode = mode
        reset()
    }

    /// Timer presets: one minute, five, ten, twenty-five (pomodoro), one hour
    static let presets: [TimeInterval] = [60, 5 * 60, 10 * 60, 25 * 60, 60 * 60]

    /// Parses typed-in time: "10" is ten minutes, "1:30" is a minute thirty,
    /// "1:30:00" is an hour thirty. Anything else is rejected
    static func parseDuration(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, parts.allSatisfy({ $0.allSatisfy(\.isNumber) && !$0.isEmpty })
        else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }

        let seconds: Int
        switch numbers.count {
        case 1: seconds = numbers[0] * 60
        case 2: seconds = numbers[0] * 60 + numbers[1]
        case 3: seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: return nil
        }
        guard seconds > 0, seconds <= 24 * 3600 else { return nil }
        return TimeInterval(seconds)
    }

    /// Text field's initial value: show the same thing the tile displayed
    var editableText: String { TimerWidget.text(state.duration) }

    func setDuration(_ duration: TimeInterval) {
        state.duration = duration
        reset()
    }

    /// Extend by minutes: the Apple Clock app has this as a separate button too,
    /// because "one more minute" is needed more often than restarting the timer
    func add(minutes: Int) {
        guard state.mode == .timer else { return }
        state.duration += TimeInterval(minutes * 60)
        // Extending a rung timer resumes the countdown: the finish cleared
        // startedAt, and without restoring it "+5m" showed 5:00 standing still
        if finished {
            state.startedAt = Date()
        }
        finished = false
        persist()
    }

    /// When the timer will go off. A string like "ends at 15:42" answers a question
    /// the user would otherwise have to work out in their head
    var endsAt: Date? {
        guard state.mode == .timer, isRunning, value > 0 else { return nil }
        return Date().addingTimeInterval(value)
    }

    // The timer lives in the tile itself: start and pause don't close the panel —
    // otherwise starting a second timer or extending this one would be impossible
    func primaryAction() -> Bool {
        toggle()
        return false
    }

    // MARK: - display

    // "25:00" and "1:05:00" — the hours component only shows up when nonzero
    static func text(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    // Short preset label: "25m", "1h"
    static func presetText(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        return minutes >= 60 ? String(localized: "\(minutes / 60)h") : String(localized: "\(minutes)m")
    }

    private func checkFinish() {
        guard state.mode == .timer, isRunning, value <= 0 else { return }
        state.startedAt = nil
        state.accumulated = state.duration
        finished = true
        persist()
        // The notch island rings — it works even while the panel is closed.
        // Ringing here too would double the sound when the panel is open
    }

    private func persist() {
        context.settings.set("state", state)
        // Separate entry for the notch island: it needs one cheap key to read in
        // the background, not a scan of every setting.
        // Each tile has its own key: two timers on the board get two independent
        // entries. A shared key would let the second overwrite the first, and
        // stopping either one would clear the capsule
        TimerActivity.publish(state.startedAt != nil ? state : nil, for: context.tileID)
        now = Date()
    }

    var body: AnyView {
        AnyView(TimerTileView(widget: self, size: context.tileSize))
    }
}
