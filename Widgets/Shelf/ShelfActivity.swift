import AppKit
import SwiftUI

// A file dragged toward the notch makes the capsule expand and invite:
// "drop the file". It's the same motion as a track change, just a different
// trigger. While the capsule is open, the notch stops being just a cutout and
// becomes a visible drop target.
@MainActor
enum ShelfActivity {
    static let id = "shelf"
    /// How long the confirmation stays up after the file is dropped
    private static let showTime: TimeInterval = 1.6
    private static var hideAt: Date?

    /// File over the notch: the invitation stays up while the cursor is here.
    /// If the shelf is full, we say so right away, before the file is even dropped
    static func invite(full: Bool) {
        cancelTask?.cancel()
        cancelTask = nil
        hideAt = nil
        LiveActivityCenter.shared.update(
            LiveActivity(
                id: id,
                icon: full ? "tray.full.fill" : "tray.and.arrow.down.fill",
                value: full ? String(localized: "Shelf is full") : String(localized: "Drop the file"),
                animated: false,
                // Blue is the system color for file actions, orange means "no room"
                tint: full ? Color(red: 1, green: 0.62, blue: 0.04)
                    : Color(red: 0.04, green: 0.52, blue: 1),
                // Highest priority: this is a direct response to a gesture happening right now
                priority: LiveActivity.Priority.shelfDrop,
                expanded: true))
    }

    /// File was dropped, but there's no room
    static func full() {
        cancelTask?.cancel()
        cancelTask = nil
        hideAt = Date().addingTimeInterval(showTime)
        LiveActivityCenter.shared.update(
            LiveActivity(
                id: id,
                icon: "tray.full.fill",
                value: String(localized: "Shelf is full"),
                animated: false,
                tint: Color(red: 1, green: 0.62, blue: 0.04),
                priority: 70,
                expanded: true))
    }

    /// File landed on the shelf
    static func dropped(_ count: Int) {
        cancelTask?.cancel()
        cancelTask = nil
        hideAt = Date().addingTimeInterval(showTime)
        LiveActivityCenter.shared.update(
            LiveActivity(
                id: id,
                icon: "checkmark.circle.fill",
                value: count > 1
                    ? String(localized: "\(count) files on the shelf")
                    : String(localized: "File on the shelf"),
                animated: false,
                tint: Color(red: 0.04, green: 0.52, blue: 1),
                priority: 70,
                expanded: true))
    }

    /// Cursor left without dropping the file. We don't hide immediately: while a
    /// file is being dragged, the cursor jumps between the notch window and the
    /// capsule's own window, and hiding instantly collapsed the capsule on every
    /// such crossing — it read as stutter. Coming back within the delay leaves
    /// the capsule undisturbed
    private static let cancelDelay: TimeInterval = 0.35
    private static var cancelTask: DispatchWorkItem?

    static func cancel() {
        guard hideAt == nil else { return }
        cancelTask?.cancel()
        let task = DispatchWorkItem {
            MainActor.assumeIsolated {
                cancelTask = nil
                guard hideAt == nil else { return }
                LiveActivityCenter.shared.clear(id)
            }
        }
        cancelTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + cancelDelay, execute: task)
    }

    /// Called by the island's tick — clears the confirmation once its time is up
    static func refresh() {
        guard let deadline = hideAt, Date() >= deadline else { return }
        hideAt = nil
        LiveActivityCenter.shared.clear(id)
    }
}
