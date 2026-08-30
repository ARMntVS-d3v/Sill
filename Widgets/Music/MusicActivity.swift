import AppKit
import SwiftUI

// What's playing — at the notch: cover art on the left, bouncing bars on the
// right, like the compact player view on iPhone. Only works while the source
// is already up (the panel was recently open): we won't keep a background
// process alive just for one capsule.
@MainActor
enum MusicActivity {
    static let id = "music"

    // The decoded image lives until the track changes. NSImage(data:) on every
    // tick would mean decoding a JPEG twice a second, plus a new reference
    // each time: the activity would stop comparing equal to its previous
    // value, and the capsule would redraw whole
    private static var artworkCache: (key: String, image: NSImage?)?

    /// What's shown in the expanded view. Decided once, at the moment of the
    /// event, and not revisited until the display ends. This used to be
    /// recomputed on every player message, and a note icon would sometimes
    /// flash up instead of a pause icon
    private enum Event {
        case track, playing, paused

        var icon: String? {
            switch self {
            case .track: nil  // playing — so bars, same as the compact view
            case .playing: "play.fill"
            case .paused: "pause.fill"
            }
        }

        var time: TimeInterval {
            // A track change is the bigger event, so it stays up longer
            self == .track ? 2.6 : 1.6
        }
    }

    private static var event: (kind: Event, until: Date)?
    /// Pause pressed from within the panel itself — no need to show that at
    /// the notch, the person is already looking at the tile. The flag clears
    /// on the very next state change
    private static var ignoreNextPlayback = false

    static func ignorePlaybackFromApp() { ignoreNextPlayback = true }

    /// Is the player window currently frontmost? The helper reports the
    /// source's pid, the rest is a question for the system. Unknown source —
    /// assume not frontmost: better to show once too often than stay silent
    /// about a track change
    private static func playerIsInFront(_ track: NowPlayingTrack) -> Bool {
        guard let pid = track.sourcePID else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
    private static var lastTrackKey: String?
    private static var lastPlaying: Bool?

    static func refresh() {
        guard let track = NowPlayingCenter.shared.track else {
            artworkCache = nil
            lastTrackKey = nil
            lastPlaying = nil
            event = nil
            LiveActivityCenter.shared.clear(id)
            return
        }
        // Expands for two events: the track changed, or playback was toggled.
        // Artwork arrives as a separate message, so the key is computed
        // without it — otherwise the capsule expanded twice for the same track
        let trackKey = "\(track.title)|\(track.artist ?? "")"
        let changedTrack = lastTrackKey != nil && lastTrackKey != trackKey
        let changedPlayback = lastPlaying != nil && lastPlaying != track.isPlaying

        // Show when the person can't already see the player: they pressed a
        // media key, or the track changed on its own while they were doing
        // something else. Stay quiet when the player window is right in front
        // of them — it already shows the same thing. A browser playing a
        // YouTube video is the same case: it's both the source and the frontmost app
        if changedTrack || changedPlayback {
            let byKey = MediaKeys.pressedRecently()
            if ignoreNextPlayback {
                ignoreNextPlayback = false
            } else if byKey || !playerIsInFront(track) {
                if byKey { MediaKeys.consume() }
                let kind: Event = changedTrack ? .track : (track.isPlaying ? .playing : .paused)
                event = (kind, Date().addingTimeInterval(kind.time))
            }
        }
        lastTrackKey = trackKey
        lastPlaying = track.isPlaying
        if let current = event, Date() >= current.until { event = nil }

        let key = "\(trackKey)|\(track.artwork?.count ?? 0)"
        if artworkCache?.key != key {
            artworkCache = (key, track.artwork.flatMap { NSImage(data: $0) })
        }
        LiveActivityCenter.shared.update(
            LiveActivity(
                id: id,
                // Video sources (browsers, players) get a YouTube-style play
                // badge — the fallback when there's no artwork to show
                icon: NowPlayingCenter.shared.sourceLooksLikeVideo(track)
                    ? "play.rectangle.fill" : "music.note",
                value: track.title,
                image: artworkCache?.image,
                showsEqualizer: true,
                animated: track.isPlaying,
                tint: .white,
                // Below a running countdown either way: music can be heard, a
                // timer cannot. A track change still lifts music above the quiet
                // things (weather, a plugged-in cable) for a couple of seconds
                priority: event != nil
                    ? LiveActivity.Priority.musicEvent : LiveActivity.Priority.musicPlaying,
                subtitle: track.artist,
                stateIcon: event?.kind.icon,
                expanded: event != nil))
    }
}
