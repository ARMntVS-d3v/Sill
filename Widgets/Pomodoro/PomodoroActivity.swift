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
        // sound belongs here. Announced per tile and per phase index: without the
        // index, a phase that rolled over during a single tick would go unheard
        for state in running {
            let previous = announced[state.tileID]
            announced[state.tileID] = state.index
            guard let previous, previous != state.index else { continue }
            sillLog("[pomodoro] phase → \(state.phase.rawValue)")
            if let sound = NSSound(named: "Glass") {
                sound.play()
            } else {
                NSSound.beep()
            }
            notify(phase: state.phase)
        }

        // Of several pomodoros, the capsule shows the one closest to switching
        guard let soonest = running.min(by: { $0.left < $1.left }) else { return }
        guard AppSettings.shared.pomodoroInNotch else {
            LiveActivityCenter.shared.clear(id)
            return
        }
        LiveActivityCenter.shared.update(
            LiveActivity(
                id: id,
                icon: soonest.phase == .work ? "leaf.fill" : "cup.and.saucer.fill",
                value: PomodoroWidget.text(soonest.left),
                // Work and break are told apart by color before the icon is read:
                // green while working, blue while resting
                tint: soonest.phase == .work ? .green : .cyan,
                priority: 10))
    }

    /// Which phase each tile is in and how much of it is left. Nothing is written
    /// back: the same walk the widget does, so both agree without a shared write
    private static func current(tileID: String, state: PomodoroWidget.State) -> Current? {
        guard let startedAt = state.startedAt else { return nil }
        var phase = state.phase
        var left = state.duration(of: phase) - state.accumulated
            - Date().timeIntervalSince(startedAt)
        var index = 0
        while left <= 0, index < 500 {
            index += 1
            phase = phase.other
            left += state.duration(of: phase)
        }
        return Current(tileID: tileID, phase: phase, left: max(left, 0), index: index)
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
        guard let soonest = running.min(by: { $0.left < $1.left }) else { return nil }
        return CountingLabel.nextChange(value: soonest.left, countingDown: true)
    }

    private static var announced: [String: Int] = [:]

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
        /// How many phases have rolled over since the state was written
        let index: Int
    }
}
