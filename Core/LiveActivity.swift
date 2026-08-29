import AppKit
import SwiftUI

// The live activity: what's visible at the notch while the panel is closed.
// Modeled on the iPhone's Dynamic Island — an icon to the left of the notch,
// a value to the right, the notch itself stays a hole. The panel is closed
// and widgets are asleep the whole time.
//
// Important constraint: an activity must never poll the system. Anything that
// computes itself (a timer from a stored timestamp) is fine — but nothing that
// needs a live process or network, or "≈0% CPU in the background" stops being true.
struct LiveActivity: Equatable, Identifiable {
    /// Who's showing it: activities are updated and cleared by this key
    let id: String
    let icon: String
    /// Short string to the right of the notch: "4:32", "19:00". No room for
    /// long text there — same as the iPhone, only a short value fits
    let value: String
    /// A thumbnail instead of an icon: track artwork
    var image: NSImage?
    /// Bouncing bars instead of a value (music)
    var showsEqualizer = false
    /// The bars only move while something is actually playing
    var animated = true
    var tint: Color = .white
    /// Higher means more important: an active timer outranks a quiet one
    var priority: Int = 0
    /// Second line in the expanded view: the artist
    var subtitle: String?
    /// Icon on the right in the expanded view: note, pause, or play
    var stateIcon: String?
    /// The capsule expands downward to show what just started. Mirrors how the
    /// iPhone handles a track change: the island expands for a couple seconds
    /// and collapses back
    var expanded = false
}

// When a seconds label next changes. The value on the capsule is computed from a
// timestamp and the label is rounded, so it flips on its own phase — half a second
// off the wall clock. Polling twice a second showed the digits late and unevenly;
// waking exactly at the flip is both smoother and cheaper.
enum CountingLabel {
    static func nextChange(value: TimeInterval, countingDown: Bool) -> TimeInterval {
        let shown = value.rounded()
        let delay = countingDown ? value - (shown - 0.5) : (shown + 0.5) - value
        // Never spin, never sleep past a second: the label can't hold longer than that
        return min(max(delay, 0.05), 1)
    }
}

// Capsule presentation state: the controller sets a flag, the view plays the
// animation, and only then does the window leave the screen. Without this the
// disappearance was instant — on the iPhone the capsule retracts into the notch,
// it doesn't just vanish on a frame.
@MainActor @Observable
final class IslandPresentation {
    static let shared = IslandPresentation()
    var visible = false
    /// What's drawn in the capsule right now. Held by the controller, not read
    /// from the activity center: while the capsule is retracting, its content
    /// must stay the same. Reading the center directly meant the view got nil
    /// on the very first frame of retraction — the icon collapsed to an empty
    /// circle, the number rolled away, and the width jumped to its narrow
    /// state instantly with no animation
    var activity: LiveActivity?
    /// Current capsule width. The window needs this: it's wider than the
    /// capsule, and clicks must only be captured where the capsule is actually
    /// drawn — otherwise it would eat clicks meant for the menu bar
    @ObservationIgnored var capsuleWidth: CGFloat = 0
    /// Current height: in the expanded view the capsule is taller, and clicks
    /// need to be captured accordingly
    @ObservationIgnored var capsuleHeight: CGFloat = 0
    /// The capsule was measured. The window listens: it is bigger than the capsule
    /// so the motion has room, and once the motion settles it shrinks down to it —
    /// invisible margins over the menu bar still swallow clicks
    @ObservationIgnored var onCapsuleSize: ((CGSize) -> Void)?
    private init() {}
}

@MainActor @Observable
final class LiveActivityCenter {
    static let shared = LiveActivityCenter()

    private(set) var activities: [LiveActivity] = []
    /// The island subscribes here: a copy confirmation must appear the instant
    /// it happens, not on the next tick — that can be up to two seconds away
    @ObservationIgnored var onChange: (() -> Void)?

    /// What to show right now — the most important activity
    var current: LiveActivity? {
        activities.max { $0.priority < $1.priority }
    }

    private init() {}

    func update(_ activity: LiveActivity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            guard activities[index] != activity else { return }
            activities[index] = activity
        } else {
            activities.append(activity)
        }
        onChange?()
    }

    func clear(_ id: String) {
        guard activities.contains(where: { $0.id == id }) else { return }
        activities.removeAll { $0.id == id }
        onChange?()
    }
}
