import SwiftUI

// Artwork is the only place in the panel where color arrives as a whole image,
// so text on it always sits on a darkened layer, never directly on the pixels.
struct MusicTileView: View {
    let widget: MusicWidget
    let size: TileSize
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let failure = widget.failure {
                // Own icon, not a warning triangle: the tile should still look
                // like itself even when it failed to start. Human-readable
                // text — nobody's reading the helper's technical string
                TilePlaceholder(failure, icon: "music.note")
            } else if widget.track == nil {
                MusicIdleView(widget: widget, size: size)
            } else {
                switch size {
                case .small: MusicSmallView(widget: widget)
                case .medium: MusicMediumView(widget: widget)
                case .large: MusicLargeView(widget: widget)
                }
            }
        }
        // Track change is one motion, not a series of jolts: while the player
        // responds, the tile dims, then the new data appears all at once
        .opacity(widget.isSwitching ? 0.45 : 1)
        // One modifier: two stacked ones fought over the same opacity
        .animation(.easeOut(duration: Motion.content), value: widget.isSwitching)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// Empty means empty: icon and caption, no play button. A play command with an
// empty Now Playing goes to the system, which then launches Apple Music even
// if the person doesn't use it. The app has no business opening something it
// wasn't asked to
private struct MusicIdleView: View {
    let widget: MusicWidget
    let size: TileSize
    @Environment(\.theme) private var theme

    var body: some View {
        TilePlaceholder(String(localized: "Nothing playing"), icon: "music.note")
            .padding(TileMetrics.padding)
    }
}

// MARK: - Shared details

private struct Artwork: View {
    let image: NSImage?
    let corner: Double
    @Environment(\.theme) private var theme

    var body: some View {
        // Artwork sits in an overlay on top of a transparent base: without
        // this, .fill stretches the view itself to the image and it spills
        // past its allotted space — in the large tile a square cover covered
        // the title and buttons
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        theme.tileHover.color
                        Image(systemName: "music.note")
                            .font(TileIcon.hero)
                            .foregroundStyle(theme.textMuted.color)
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// Transport controls. Commands go to the system player, so they work with any
// source — from Yandex Music to a browser tab.
// Familiar layout from big players: the center button is a filled circle, the
// side ones are plain icons, so the primary action reads first
private struct TransportButton: View {
    enum Kind { case side, primary }

    let icon: String
    var kind: Kind = .side
    var diameter: CGFloat = 30
    // Theme tokens don't work over artwork: the background is someone else's
    // photo, not a tile
    var onArtwork = false
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                switch kind {
                case .side:
                    Image(systemName: icon)
                        .font(TileIcon.control)
                        .foregroundStyle(sideColor)
                        .frame(width: diameter, height: diameter)
                case .primary:
                    Circle()
                        .fill(onArtwork ? .white : theme.textPrimary.color)
                        .frame(width: diameter, height: diameter)
                        .overlay {
                            Image(systemName: icon)
                                .font(TileIcon.controlPrimary)
                                // Icon is cut out of the circle: tile color, not text color
                                .foregroundStyle(onArtwork ? .black : theme.tileBackground.color)
                        }
                        .scaleEffect(hovered ? 1.06 : 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: Motion.hover), value: hovered)
        .onHover { hovered = $0 }
        .tileControl()
    }

    private var sideColor: Color {
        if onArtwork { return hovered ? .white : .white.opacity(0.75) }
        return hovered ? theme.textPrimary.color : theme.textSecondary.color
    }
}

// Three buttons as one block: same order and spacing at every size
private struct Transport: View {
    let widget: MusicWidget
    var primaryDiameter: CGFloat = 30
    var spacing: CGFloat = 10
    var onArtwork = false

    var body: some View {
        HStack(spacing: spacing) {
            TransportButton(icon: "backward.fill", onArtwork: onArtwork) { widget.send(.prev) }
            TransportButton(
                icon: widget.track?.isPlaying == true ? "pause.fill" : "play.fill",
                kind: .primary,
                diameter: primaryDiameter,
                onArtwork: onArtwork
            ) { widget.send(.toggle) }
            TransportButton(icon: "forward.fill", onArtwork: onArtwork) { widget.send(.next) }
        }
    }
}

// Track line: doubles as the scrubber. The hit area is noticeably taller than
// the line itself — you can't aim a mouse at three pixels
private struct Scrubber: View {
    let widget: MusicWidget
    var onArtwork = false
    // Hover over the whole tile: the line lights up together with the buttons, not on its own
    var highlighted = false
    @Environment(\.theme) private var theme
    @State private var hovered = false
    @State private var scrubbing: Double?

    private var value: Double { scrubbing ?? widget.progress ?? 0 }
    private var active: Bool { hovered || highlighted || scrubbing != nil }
    private var thickness: CGFloat { active ? 5 : 3 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(onArtwork ? .black.opacity(0.35) : theme.border.color)
                    .frame(height: thickness)
                Capsule()
                    // Under the cursor the line only brightens: accent blue
                    // over artwork competes with the image for attention,
                    // white reads on any picture
                    .fill(onArtwork || active ? .white : theme.textPrimary.color.opacity(0.85))
                    .frame(width: max(geo.size.width * value, thickness), height: thickness)
                // Handle appears only under the cursor: at rest the line stays just a line
                if active {
                    Circle()
                        .fill(onArtwork ? .white : theme.textPrimary.color)
                        .frame(width: 9, height: 9)
                        .offset(x: geo.size.width * value - 4.5)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { move in
                        scrubbing = fraction(move.location.x, width: geo.size.width)
                    }
                    .onEnded { move in
                        widget.seek(toFraction: fraction(move.location.x, width: geo.size.width))
                        scrubbing = nil
                    })
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.12), value: thickness)
        .onHover { hovered = $0 }
        .help("Seek")
        .tileControl()
    }

    private func fraction(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }
}

private struct TrackTitle: View {
    let widget: MusicWidget
    var titleLines = 1
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(widget.track?.title ?? "")
                .font(TileFont.title)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(titleLines)
            if let artist = widget.track?.artist, !artist.isEmpty {
                Text(artist)
                    .font(TileFont.status)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Small: same layout as large, just tighter

private struct MusicSmallView: View {
    let widget: MusicWidget
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Artwork(image: widget.artworkImage, corner: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Text readability shouldn't depend on which artwork came in
            LinearGradient(
                colors: [.clear, .black.opacity(0.55), .black.opacity(0.88)],
                startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            // Hover dimming sits UNDER the content: otherwise it covers the
            // scrubber, which greys out while the buttons on top stay white
            if hovered {
                Color.black.opacity(0.45)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 0) {
                // Same point size as the other sizes: title uses `title`,
                // artist uses `status`. Can't shrink text in the small tile —
                // size changes how much is shown, not the font size
                Text(widget.track?.title ?? "")
                    .font(TileFont.title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let artist = widget.track?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(TileFont.status)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                // Scrubber is here too: same line, just without the time
                // labels — at 152 points they'd eat the space under the title
                if widget.isSeekable {
                    Scrubber(widget: widget, onArtwork: true, highlighted: hovered)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 8)

            // Buttons over the artwork, centered in the tile — same as the
            // large size, but shown only on hover: at rest, seeing the
            // artwork matters more
            if hovered {
                Transport(
                    widget: widget,
                    primaryDiameter: TileControlMetrics.primary(.small),
                    spacing: TileControlMetrics.gap(.small), onArtwork: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - Medium: artwork on the left, controls on the right

private struct MusicMediumView: View {
    let widget: MusicWidget
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Artwork(image: widget.artworkImage, corner: 8)
                .frame(width: 126, height: 126)

            VStack(spacing: 0) {
                TrackTitle(widget: widget, titleLines: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 6)
                // Nothing to scrub on a stream without a duration: the line at
                // zero would read as "track stuck at the start"
                if widget.isSeekable {
                    Scrubber(widget: widget)
                    TrackTimes(widget: widget)
                }
                // Buttons sit centered in the same column as the scrubber:
                // left-aligned, they read as accidentally left there
                Transport(widget: widget)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(TileMetrics.padding)
    }
}

// Elapsed time on the left, duration on the right — flanking the scrubber
private struct TrackTimes: View {
    let widget: MusicWidget
    var onArtwork = false
    @Environment(\.theme) private var theme

    var body: some View {
        if let track = widget.track, let duration = track.duration, duration > 0 {
            HStack {
                Text(MusicWidget.timeText(track.position(at: widget.now) ?? 0))
                Spacer(minLength: 0)
                Text(MusicWidget.timeText(duration))
            }
            .font(TileFont.axis)
            .monospacedDigit()
            .foregroundStyle(onArtwork ? .white.opacity(0.7) : theme.textMuted.color)
        }
    }
}

// MARK: - Large: square artwork above the player

private struct MusicLargeView: View {
    let widget: MusicWidget
    @Environment(\.theme) private var theme

    // Artwork is square, as everywhere: 168 is exactly enough for the title,
    // scrubber, and buttons underneath without crowding (168 + 122 + margins = 316)
    private let artworkSide: CGFloat = 168

    var body: some View {
        VStack(spacing: 0) {
            Artwork(image: widget.artworkImage, corner: 10)
                .frame(width: artworkSide, height: artworkSide)

            Text(widget.track?.title ?? "")
                .font(TileFont.title)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .padding(.top, TileMetrics.blockGap)

            if let artist = widget.track?.artist, !artist.isEmpty {
                Text(artist)
                    .font(TileFont.status)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .padding(.top, 1)
            }

            Spacer(minLength: 6)

            if widget.isSeekable {
                Scrubber(widget: widget)
                TrackTimes(widget: widget)
            }

            Transport(
                widget: widget,
                primaryDiameter: TileControlMetrics.primary(.large),
                spacing: TileControlMetrics.gap(.large))
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(TileMetrics.padding)
    }
}
