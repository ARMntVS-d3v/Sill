import AppKit
import SwiftUI

// "Copied" at the notch. The panel is closing at this point, so the confirmation
// is shown by the capsule — the same motion as a track change: expands down,
// shows what went into the clipboard, then retracts.
@MainActor
enum ClipboardActivity {
    static let id = "clipboard.copied"
    /// How long the confirmation stays up
    private static let showTime: TimeInterval = 1.6
    private static var hideAt: Date?

    static func copied() {
        hideAt = Date().addingTimeInterval(showTime)
        LiveActivityCenter.shared.update(
            LiveActivity(
                id: id,
                icon: "checkmark.circle.fill",
                value: String(localized: "Copied"),
                animated: false,
                // White, not green: green at the notch is reserved for charging,
                // and the confirmation would read as a battery event
                tint: .white,
                // Above everything: this answers a human action, they're waiting on it right now
                priority: 60,
                expanded: true))
    }

    /// Called by the island's tick — clears the confirmation once time's up
    static func refresh() {
        guard let deadline = hideAt else { return }
        guard Date() >= deadline else { return }
        hideAt = nil
        LiveActivityCenter.shared.clear(id)
    }
}
