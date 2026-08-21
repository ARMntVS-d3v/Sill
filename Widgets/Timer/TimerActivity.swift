import AppKit
import SwiftUI
import UserNotifications

// Timer shown on the notch island. State is read straight from tile settings,
// not from the widget: widgets sleep while the panel is closed, but the timer
// must keep going — it's computed from a timestamp, so "running" costs nothing.
@MainActor
enum TimerActivity {
    static let id = "timer"
    /// The one key the island reads: scanning every setting in the background is expensive.
    /// Holds a dictionary of tile -> state, since a board can have several timers
    static let stateKey = "island.timer.states"

    /// The widget stores its state here (or removes it once stopped).
    /// Each tile has its own key — otherwise a second timer would overwrite the first
    static func publish(_ state: TimerWidget.State?, for tileID: UUID) {
        var all = states()
        if let state {
            all[tileID.uuidString] = state
        } else {
            all.removeValue(forKey: tileID.uuidString)
            announced.remove(tileID.uuidString)
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }

    private static func states() -> [String: TimerWidget.State] {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let all = try? JSONDecoder().decode([String: TimerWidget.State].self, from: data)
        else { return [:] }
        return all
    }

    static func refresh() {
        guard let state = runningState() else {
            LiveActivityCenter.shared.clear(id)
            return
        }

        let value = TimerWidget.text(state.value)
        let finished = state.mode == .timer && state.value <= 0
        // The timer can go off while the panel is closed: the widget is asleep and
        // won't notice, so the island fires the sound and notification. Tracked per
        // tile — otherwise a second timer would clear the first one's flag
        if finished, !announced.contains(state.tileID) {
            announced.insert(state.tileID)
            // System sound: we don't bundle our own. Fall back to the system beep
            if let sound = NSSound(named: "Glass") {
                sound.play()
            } else {
                NSSound.beep()
            }
            notify()
        }
        if !finished { announced.remove(state.tileID) }
        // The toggle hides the capsule only — the sound and notification above
        // still fire: silencing a finished timer would lose the whole point of it
        guard AppSettings.shared.timerInNotch else {
            LiveActivityCenter.shared.clear(id)
            return
        }
        LiveActivityCenter.shared.update(
            LiveActivity(
                id: id,
                icon: finished ? "bell.fill" : (state.mode == .timer ? "timer" : "stopwatch"),
                value: value,
                // Orange is the iPhone Clock app's color, and it's the fastest way to
                // recognize the timer on the island. A finished timer blinks white on orange
                tint: finished ? .white : .orange,
                // A finished timer outranks a running one — it needs to be noticed
                priority: finished ? 20 : 10))
    }

    private static var announced: Set<String> = []

    // System notification: the panel may be closed and the sound missed.
    // Can't hook into the Apple Clock app — it has no public API
    private static func notify() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Timer")
            content.body = String(localized: "Time's up")
            content.sound = .default
            center.add(
                UNNotificationRequest(
                    identifier: "sill.timer.\(Date().timeIntervalSince1970)",
                    content: content, trigger: nil))
        }
    }

    private struct Running {
        let tileID: String
        let mode: TimerWidget.Mode
        let value: TimeInterval
        let progress: Double
    }

    // Of all running timers, the capsule shows just the most urgent one:
    // finished first, then whichever has the least time left, stopwatches last
    private static func runningState() -> Running? {
        let all = states().compactMap { running(tileID: $0.key, state: $0.value) }
        guard !all.isEmpty else {
            announced.removeAll()
            return nil
        }
        return all.min { urgency($0) < urgency($1) }
    }

    private static func urgency(_ running: Running) -> Double {
        switch running.mode {
        case .timer: running.value <= 0 ? -1 : running.value
        case .stopwatch: .greatestFiniteMagnitude
        }
    }

    private static func running(tileID: String, state: TimerWidget.State) -> Running? {
        guard let startedAt = state.startedAt else { return nil }
        let elapsed = state.accumulated + Date().timeIntervalSince(startedAt)
        switch state.mode {
        case .stopwatch:
            return Running(tileID: tileID, mode: .stopwatch, value: elapsed, progress: 0)
        case .timer:
            let left = max(state.duration - elapsed, 0)
            let progress = state.duration > 0 ? min(max(1 - left / state.duration, 0), 1) : 0
            return Running(tileID: tileID, mode: .timer, value: left, progress: progress)
        }
    }
}
