import AppKit
import SwiftUI

// What's playing in the system — any player, including the browser and Yandex
// Music. Data comes from the helper (see NowPlayingBridge), commands go there too.
@MainActor @Observable
final class MusicWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "music",
        name: "Media",
        icon: "music.note",
        sizes: [.small, .medium, .large],
        defaultSize: .medium
    )

    private let context: WidgetContext
    // Data is shared across all music tiles, this is just a reflection of it
    var track: NowPlayingTrack? { NowPlayingCenter.shared.track }
    var failure: String? { NowPlayingCenter.shared.failure }
    // A command was sent, the new track hasn't arrived yet
    var isSwitching: Bool { NowPlayingCenter.shared.isSwitching }
    // Second tick moves progress along between helper messages
    private(set) var now = Date()

    init(context: WidgetContext) {
        self.context = context
        context.schedule(every: .seconds(1)) { [weak self] in
            guard let self, track?.isPlaying == true else { return }
            now = Date()
        }
    }

    func activate() async throws {
        NowPlayingCenter.shared.subscribe(context.tileID)
        now = Date()
    }

    // Panel closed — the helper process goes away with the last sleeping tile
    func deactivate() {
        NowPlayingCenter.shared.unsubscribe(context.tileID)
    }

    var body: AnyView {
        AnyView(MusicTileView(widget: self, size: context.tileSize))
    }

    func send(_ command: NowPlayingCommand) {
        // Button pressed in the panel itself — no need to tell the notch
        // capsule about it: the person is already looking at the tile, and
        // the animation used to catch up with them only after the panel closed
        if command == .toggle || command == .play || command == .pause {
            MusicActivity.ignorePlaybackFromApp()
        }
        NowPlayingCenter.shared.send(command)
        // The button's response doesn't wait for the helper's reply: pause is
        // visible immediately, the confirmed fact follows
        if command == .toggle, var current = track {
            current.elapsed = current.position(at: Date())
            current.isPlaying.toggle()
            current.stamp = Date()
            NowPlayingCenter.shared.applyOptimistic(current)
        }
    }

    // Clicking the tile brings the currently playing player to the front. If
    // nothing is playing — nothing is raised: the app shouldn't open
    // something the person didn't ask for
    func primaryAction() -> Bool {
        guard track != nil,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.isNowPlayingCandidate })
        else { return false }
        app.activate()
        return true
    }

    /// Whether there's anything to seek: a radio stream has no duration at all
    var isSeekable: Bool { (track?.duration ?? 0) > 0 }

    // Seek: fraction of the line → seconds. Position moves immediately,
    // without waiting for the player, otherwise the line snaps back for the
    // fraction of a second while the response is in flight
    func seek(toFraction fraction: Double) {
        guard var current = track, let duration = current.duration, duration > 0 else { return }
        let seconds = min(max(fraction, 0), 1) * duration
        NowPlayingCenter.shared.seek(to: seconds)
        current.elapsed = seconds
        current.timestamp = Date()
        current.stamp = Date()
        NowPlayingCenter.shared.applyOptimistic(current)
        now = Date()
    }

    var artworkImage: NSImage? {
        track?.artwork.flatMap { NSImage(data: $0) }
    }

    // "1:04 / 3:47"; an hour and up rolls into hours — a movie showed
    // "106:51", and nobody reads minutes past sixty
    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var progress: Double? {
        guard let track, let duration = track.duration, duration > 0,
              let position = track.position(at: now)
        else { return nil }
        return min(max(position / duration, 0), 1)
    }
}

private extension NSRunningApplication {
    // Approximate: the players that most often hold Now Playing.
    // Only the helper knows the exact audio owner, not pulled in here yet
    var isNowPlayingCandidate: Bool {
        guard let id = bundleIdentifier else { return false }
        return ["ru.yandex.desktop.music", "com.apple.Music", "com.spotify.client",
                "com.apple.podcasts", "com.google.Chrome", "com.apple.Safari"]
            .contains(id)
    }
}
