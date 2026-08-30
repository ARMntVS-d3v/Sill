import AppKit
import SwiftUI
import UserNotifications

// Pomodoro at the notch. Same arrangement as the timer: state is read from
// UserDefaults, not from the widget — widgets sleep while the panel is closed, and
// the phase still has to end on time and say so out loud.
@MainActor
enum PomodoroActivity {
    static let id = "pomodoro"
    /// The single key the island reads. A dictionary of tile -> state: a board can
    /// hold more than one pomodoro, and a shared key would let one erase the other
    static let stateKey = "island.pomodoro.states"

    static func publish(_ state: PomodoroWidget.State?, for tileID: UUID) {
        var all = states()
        if let state {
            all[tileID.uuidString] = state
        } else {
            all.removeValue(forKey: tileID.uuidString)
            announced.removeValue(forKey: tileID.uuidString)
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }

    private static func states() -> [String: PomodoroWidget.State] {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let all = try? JSONDecoder().decode([String: PomodoroWidget.State].self, from: data)
        else { return [:] }
        return all
    }

    static func refresh() {
        let running = states().compactMap { current(tileID: $0.key, state: $0.value) }
        guard !running.isEmpty else {
            announced.removeAll()
            LiveActivityCenter.shared.clear(id)
            return
        }

        // A phase ends while the panel is closed and the widget is asleep — so the
        // sound belongs here. Announced per tile by the phase's own start moment:
        // an index into a rolling sequence shifted under us the moment the widget
        // woke up and rewrote the state, and the same phase end rang twice
        for state in running where state.left <= 0 {
            guard announced[state.tileID] != state.phaseStart else { continue }
            announced[state.tileID] = state.phaseStart
            // The capsule says it out loud for a moment, then settles into the bell
            expandedUntil[state.tileID] = Date().addingTimeInterval(Motion.signalHold)
            sillLog("[pomodoro] \(state.phase.rawValue) ended")
            if let sound = NSSound(named: "Glass") {
                sound.play()
            } else {
                NSSound.beep()
            }
            // Say what comes next, not what just ended
            notify(phase: state.phase.other)
        }

        // Of several pomodoros, the capsule shows the one closest to switching
        guard let soonest = running.min(by: { $0.left < $1.left }) else { return }
        guard AppSettings.shared.pomodoroInNotch else {
            LiveActivityCenter.shared.clear(id)
            return
        }
        // A phase that has run out waits for a decision — the next one doesn't start
        // by itself. While it waits, the capsule already wears the phase that is
        // coming: its icon, its color, its length, the same as the tile
        let done = soonest.left <= 0
        let next = soonest.phase.other
        let waiting = done ? next : soonest.phase
        // Work and break are told apart by color before the icon is read:
        // green for work, blue for the break
        let tint: Color = waiting == .work ? .green : .cyan
        let announcing = done && (expandedUntil[soonest.tileID].map { Date() < $0 } ?? false)
        LiveActivityCenter.shared.update(
            LiveActivity(
                id: id,
                icon: waiting == .work ? "leaf.fill" : "cup.and.saucer.fill",
                // For a couple of seconds the capsule drops down and says what just
                // happened — the same movement a track change or "Copied" uses
                value: announcing
                    ? (next == .rest
                        ? String(localized: "Time for a break")
                        : String(localized: "Back to work"))
                    : PomodoroWidget.text(done ? soonest.nextLength : soonest.left),
                tint: tint,
                // A phase waiting to be picked up outranks one still running
                priority: done
                    ? LiveActivity.Priority.countdownDone : LiveActivity.Priority.countdown,
                expanded: announcing))
    }

    /// What each tile shows and how much of it is left. Nothing is written back: the
    /// same arithmetic the widget does, so both agree without a shared write
    private static func current(tileID: String, state: PomodoroWidget.State) -> Current? {
        guard let startedAt = state.startedAt else { return nil }
        let left = state.duration - state.accumulated - Date().timeIntervalSince(startedAt)
        return Current(
            tileID: tileID, phase: state.phase, left: max(left, 0),
            // What the phase waiting behind this one lasts — shown once this one ends
            nextLength: state.duration(of: state.phase.other),
            // The moment this phase began — stable no matter who rewrites the state
            phaseStart: startedAt.addingTimeInterval(-state.accumulated))
    }

    /// Launch sweep: state for a tile that is on no board is a ghost from a quit
    /// that outran the deferred cleanup — it would keep ringing forever
    static func purgeOrphans(keeping alive: Set<UUID>) {
        var all = states()
        let dead = all.keys.filter { UUID(uuidString: $0).map { !alive.contains($0) } ?? true }
        guard !dead.isEmpty else { return }
        for key in dead {
            all.removeValue(forKey: key)
            announced.removeValue(forKey: key)
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
        sillLog("[pomodoro] purged \(dead.count) orphaned island states")
    }

    /// How long until the number on the capsule changes — the island sleeps exactly
    /// that long instead of polling (see CountingLabel)
    static func nextChange() -> TimeInterval? {
        let running = states().compactMap { current(tileID: $0.key, state: $0.value) }
        guard let soonest = running.min(by: { $0.left < $1.left }), soonest.left > 0
        else { return nil }
        return CountingLabel.nextChange(value: soonest.left, countingDown: true)
    }

    /// Which phase end each tile has already rung for, by the phase's start moment
    private static var announced: [String: Date] = [:]
    /// Until when the capsule stays expanded with the message it just announced
    private static var expandedUntil: [String: Date] = [:]

    private static func notify(phase: PomodoroWidget.Phase) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Pomodoro")
            content.body = phase == .work
                ? String(localized: "Back to work")
                : String(localized: "Time for a break")
            content.sound = .default
            center.add(
                UNNotificationRequest(
                    identifier: "sill.pomodoro.\(Date().timeIntervalSince1970)",
                    content: content, trigger: nil))
        }
    }

    private struct Current {
        let tileID: String
        let phase: PomodoroWidget.Phase
        let left: TimeInterval
        /// Length of the phase that comes next
        let nextLength: TimeInterval
        /// When this phase began — the ring is announced by it
        let phaseStart: Date
    }
}
