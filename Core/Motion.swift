import SwiftUI

// Durations needed in two places at once: the animation itself, and the delay
// before something gets removed from screen. Keeping them as one number avoids
// drift between the two — change one, forget the other, and the window
// disappears mid-motion.
enum Motion {
    /// Slow-motion factor for filming the panel opening (kill -XCPU, DEBUG):
    /// a cacheDisplay capture costs ~35 ms, so at normal speed the 0.28 s
    /// motion yields only four frames. Filming runs slowed down and the GIF
    /// assembly compresses the timestamps back. Always 1 outside the take
    @MainActor static var filmSlowdown: TimeInterval = 1
    /// Panel leaves the notch
    static let panelNotch: TimeInterval = 0.28
    /// Panel slides up (clipboard invoked via keyboard). This is a spring's
    /// response, not a duration: it settles in about panelSlideSettle, and
    /// that's how long to wait before removing the window
    static let panelSlide: TimeInterval = 0.26
    static let panelSlideSettle: TimeInterval = 0.42
    /// Capsule at the notch: one spring for everything — appearance, width,
    /// and reveal. Three separate springs on related quantities read as a
    /// jerk: width would arrive before height, content after both.
    /// Computed so filming (filmSlowdown) can stretch it; outside a take
    /// the factor is 1 and these are the plain constants
    @MainActor static var island: Spring { Spring(duration: 0.34 * filmSlowdown, bounce: 0.14) }
    /// Capsule content fades in/out faster than the capsule itself moves:
    /// while the capsule is narrow, the icon and number are clipped by the
    /// notch edges anyway
    @MainActor static var islandContent: TimeInterval { 0.12 * filmSlowdown }
    /// How far content lags behind the reveal: the capsule moves first,
    /// text appears inside it once it's already widened
    @MainActor static var islandContentDelay: TimeInterval { 0.08 * filmSlowdown }
    /// How long to wait before removing the capsule window: a bit longer
    /// than the spring, otherwise the last frame of the collapse doesn't
    /// get drawn
    @MainActor static var islandCollapse: TimeInterval { 0.42 * filmSlowdown }
    /// Board strip: the same spring both for settling next to a neighbor and
    /// for springing back. A spring, not easeOut: finger velocity has to
    /// carry into the animation, otherwise releasing causes an abrupt speed
    /// change and the gesture splits into two motions. No bounce (bounce 0) —
    /// nothing is drawn behind the neighboring board, and overshoot would
    /// reveal emptiness
    static let boardStrip = Spring(duration: 0.34, bounce: 0)
    static let boardSettle: TimeInterval = 0.34
    /// Hover: highlight, outline, slight scale. One number for the whole
    /// app, so neighboring elements react to the same gesture in sync
    static let hover: TimeInterval = 0.14
    /// Edit mode: dashed outline, remove crosses, board dots
    static let editing: TimeInterval = 0.18
    /// Edit-mode shake, like the iOS home screen: period of one wobble.
    /// Amplitudes are in standards.md ("edit mode shake")
    static let jiggle: TimeInterval = 0.13
    /// Board-dot bobbing in edit mode — four times slower than tile shake:
    /// at tile frequency the small circle read as vibration, not invitation
    static let dotBob: TimeInterval = 0.5
    /// Fill: progress bar, metric ring, timer arc
    static let fill: TimeInterval = 0.3
    /// "Ask" conversation expands and collapses
    static let askOpen: TimeInterval = 0.24
    /// Tile content appears after loading
    static let content: TimeInterval = 0.2

    /// How long to wait for focus to return to another app before the
    /// synthetic ⌘V. Not an animation — time for the app switch
    static let focusHandover: TimeInterval = 0.25

    /// Board strip springs back — same spring
    static let boardCancel: TimeInterval = 0.34

    /// Delay before removing the window after an animation: two frames of
    /// margin at 60 Hz. One frame wasn't enough — the last frame of motion
    /// didn't have time to draw
    static func afterMove(_ duration: TimeInterval) -> TimeInterval { duration + 0.034 }
}
