import SwiftUI

// Capsule wrapped around the notch. Look and motion are borrowed from Dynamic
// Island's compact state: an icon left of the notch, a short value right of it,
// both in the accent color.
//
// Important about the animation: the capsule's WIDTH changes, not its scale.
// Scaling stretches the corner radii and the text — it reads as rubbery instead
// of a real morph.
struct IslandView: View {
    var presentation = IslandPresentation.shared
    /// For snapshots: show a specific activity instead of the current one
    var preview: LiveActivity?
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// Content inset from the capsule edge and from the notch
    static let padding: CGFloat = 11
    // Gap from the notch. The physical "shade" is wider than the system reports:
    // it has rounded corners, and a value placed flush against it half-disappears
    // underneath — the leading zero in "00:00" kept vanishing
    static let gap: CGFloat = 16

    /// Content width — measured so there's something to animate to
    @State private var contentWidth: CGFloat = 0

    /// The "playing" icon isn't an icon at all, it's the equalizer bars — same as
    /// in the compact view
    static let playingIcon = "music.note"

    /// How far the capsule drops down: exactly the height of the bottom row
    /// (40 art plus 6/8 padding) — extra air below made it feel bulky
    static let expandedDrop: CGFloat = 54

    /// Width of the message capsule ("Copied"): fixed and equal to the normal
    /// music row. Can't size it to the text — a short word would give a narrow
    /// stub and the capsule would jump in width from case to case
    static let messageWidth: CGFloat = 280

    /// A message is a checkmark and a word — "Copied", "File on the shelf".
    /// Media is excluded by its equalizer flag, not by missing artwork: a video
    /// in a browser has no artwork and often no artist, and it used to fall
    /// into the message layout — centered, without the pause/play state icon
    private func isMessage(_ activity: LiveActivity?) -> Bool {
        activity?.expanded == true && activity?.image == nil
            && (activity?.subtitle ?? "").isEmpty
            && activity?.showsEqualizer != true
    }

    private func shape(radius: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous)
    }

    var body: some View {
        let activity = preview ?? presentation.activity
        // No animation in a snapshot: it needs the final look, not a mid-transition frame
        let shown = preview != nil || presentation.visible
        // What's drawn and its geometry are separate things. The activity itself
        // decides what's drawn: while retracting, an expanded capsule must stay
        // expanded, otherwise the compact row would flash through mid-collapse.
        // Only `expanded` drives the vertical drop
        let expandedKind = activity?.expanded == true
        let expanded = shown && expandedKind
        // Width stays the same whether the capsule is expanded or not — the same
        // width as the normal music row around the notch. Expanding only moves
        // the capsule down, never wider; a long title gets truncated with an ellipsis
        let target = expandedKind && isMessage(activity)
            ? max(Self.messageWidth, notchWidth)
            : max(contentWidth, notchWidth)
        // The collapsed capsule is exactly the notch rectangle: it doesn't fade,
        // it retracts into the notch and disappears there on its own (black on
        // black). On a screen without a notch the width is zero — the capsule
        // collapses to a point at the top edge
        let width = shown ? target : notchWidth
        let height = notchHeight + (expanded ? Self.expandedDrop : 0)
        let shape = shape(radius: expanded ? 26 : notchHeight * 0.55)

        VStack(spacing: 0) {
            content(activity)
                .frame(height: notchHeight)
                // The top row stays silent while expanded: the icon and bars would
                // just repeat what's shown bigger below. It fades out faster than
                // the height animates, otherwise both icons are visible mid-animation
                .opacity(expandedKind ? 0 : 1)
                .animation(
                    .easeOut(duration: Motion.islandContent)
                        .delay(expandedKind ? 0 : 0.14),
                    value: expandedKind)
            // The bottom part exists only in the expanded view: bigger artwork and
            // the full title — "what's playing now", not just "something's playing"
            if expandedKind {
                expandedRow(activity)
                    // Content fades in in place: sliding it up duplicated the
                    // capsule's own motion, and together they read as a jolt
                    .transition(.opacity)
            }
        }
        // Content fades out faster than the capsule animates, and fades in a bit
        // later than it: while the capsule is still narrow, the icon and value
        // would be clipped by the notch edges anyway
        .opacity(shown ? 1 : 0)
        .animation(
            shown
                ? .easeOut(duration: Motion.islandContent).delay(Motion.islandContentDelay)
                : .easeOut(duration: Motion.islandContent),
            value: shown)
        // Content is laid out at its own width and is never recomputed mid-animation:
        // only the outer frame moves, and the clip cuts off the rest. Expanded content
        // lays out at the target width (text shrinks to fit); compact content lays out
        // at its natural width. This is computed once. The width is fixed, not a
        // minimum — a minimum can't shrink the capsule, and with it the retraction
        // into the notch never happened, a plain fade played instead
        .frame(width: expandedKind ? target : nil, alignment: .top)
        .fixedSize(horizontal: !expandedKind, vertical: false)
        .frame(width: width, height: height, alignment: .top)
        .background { shape.fill(.black) }
        .clipShape(shape)
        .contentShape(shape)
        // Width and height animate on the same spring: different curves on linked
        // values made the motion feel warped
        .animation(.interpolatingSpring(Motion.island), value: width)
        .animation(.interpolatingSpring(Motion.island), value: height)
        // The window reads these sizes when deciding whether to take a click
        .onChange(of: width, initial: true) { presentation.capsuleWidth = width }
        .onChange(of: height, initial: true) { presentation.capsuleHeight = height }
        // The window is wider than the capsule; without this it hugged the left
        // edge and looked like it was hanging to the left of the notch
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // Artwork, title, and artist — the whole reason the capsule expands
    @ViewBuilder
    private func expandedRow(_ activity: LiveActivity?) -> some View {
        if isMessage(activity) {
            messageRow(activity)
        } else {
            mediaRow(activity)
        }
    }

    // A short message: a checkmark and a word, centered. We don't spell out what
    // was copied — the person just saw that in the panel, and the capsule should
    // stay a capsule
    @ViewBuilder
    private func messageRow(_ activity: LiveActivity?) -> some View {
        HStack(spacing: 8) {
            // Icon and word cross-fade instead of swapping frames: "Drop the file"
            // → "File on the shelf" happens within one capsule
            Image(systemName: activity?.icon ?? "checkmark")
                .font(TileIcon.hero)
                .foregroundStyle(activity?.tint ?? .white)
                .contentTransition(.symbolEffect(.replace))
            Text(activity?.value ?? "")
                .font(TileFont.title)
                .foregroundStyle(.white)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .animation(.easeOut(duration: 0.16), value: activity?.value)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(height: Self.expandedDrop)
    }

    @ViewBuilder
    private func mediaRow(_ activity: LiveActivity?) -> some View {
        HStack(spacing: 11) {
            Group {
                if let image = activity?.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.12).overlay {
                        Image(systemName: activity?.icon ?? "music.note")
                            .font(TileIcon.hero)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: TileMetrics.thumbRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(activity?.value ?? "")
                    .font(TileFont.title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = activity?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(TileFont.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Same as the compact view on the right: playing means the bars dance.
            // An icon only appears on pause and resume events
            if let icon = activity?.stateIcon, icon != Self.playingIcon {
                Image(systemName: icon)
                    .font(TileIcon.control)
                    .foregroundStyle(.white.opacity(0.9))
                    .contentTransition(.symbolEffect(.replace))
            } else if activity?.showsEqualizer == true {
                Equalizer(tint: .white, active: activity?.animated ?? true)
            } else {
                Image(systemName: activity?.icon ?? "circle")
                    .font(TileIcon.control)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, TileMetrics.padding)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func content(_ activity: LiveActivity?) -> some View {
        HStack(spacing: 0) {
            leading(activity)
                .padding(.leading, Self.padding)
                .padding(.trailing, Self.gap)

            // The notch: nothing goes here, it's the hardware cutout. On a screen
            // without a notch the width is zero and the capsule becomes solid
            Color.clear.frame(width: notchWidth)

            trailing(activity)
                .padding(.leading, Self.gap)
                .padding(.trailing, Self.padding)
        }
        .fixedSize()
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: IslandWidthKey.self, value: geometry.size.width)
            }
        }
        .onPreferenceChange(IslandWidthKey.self) { contentWidth = $0 }
    }

    // Left side — icon or thumbnail: says whose activity this is
    @ViewBuilder
    private func leading(_ activity: LiveActivity?) -> some View {
        if let image = activity?.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: notchHeight - 12, height: notchHeight - 12)
                .clipShape(RoundedRectangle(cornerRadius: TileMetrics.thumbRadius, style: .continuous))
        } else {
            Image(systemName: activity?.icon ?? "circle")
                .font(TileIcon.glyph)
                .foregroundStyle(activity?.tint ?? .white)
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeOut(duration: 0.2), value: activity?.icon)
        }
    }

    // Right side — short value or equalizer: the part that changes
    @ViewBuilder
    private func trailing(_ activity: LiveActivity?) -> some View {
        if activity?.showsEqualizer == true {
            Equalizer(tint: activity?.tint ?? .white, active: activity?.animated ?? true)
        } else {
            Text(activity?.value ?? "")
                .font(TileFont.row.weight(.medium))
                .monospacedDigit()
                // Digits roll over instead of snapping — like the Clock app on iPhone
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: activity?.value)
                .foregroundStyle(activity?.tint ?? .white)
                .lineLimit(1)
        }
    }
}

private struct IslandWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Equalizer bars. What matters here is the motion: if all bars ride the same sine
// wave with a phase offset, you get a traveling wave that reads as a screensaver,
// not sound. So each bar gets its own frequency and its own second harmonic — the
// pattern never repeats and reads as alive.
struct Equalizer: View {
    let tint: Color
    let active: Bool
    /// For snapshots: freeze at a specific moment to show a storyboard frame
    var frozenTime: TimeInterval?

    // Incommensurate frequencies so the pattern never resolves into a shared period,
    // and slow enough that fast bars would read as flicker, not sound
    private static let speeds: [Double] = [2.3, 3.4, 2.8, 4.1]
    private static let harmonics: [Double] = [4.3, 5.6, 3.8, 5.1]
    private static let phases: [Double] = [0, 1.9, 3.4, 0.7]

    // Bars never drop to zero: a live equalizer always breathes a little
    private static let minHeight: CGFloat = 4.5
    private static let maxHeight: CGFloat = 13

    // Animation step: 12 frames per second. `.animation` inside a TimelineView
    // means the screen refresh rate — on ProMotion that's 120 capsule redraws a
    // second for four bars, costing four times the CPU time in the background.
    // The bars move slowly enough that 12 and 120 look identical
    private static let step: TimeInterval = 1.0 / 12

    var body: some View {
        // No ticking at all while paused: the bars sit still, nothing to redraw
        if active && frozenTime == nil {
            TimelineView(.periodic(from: .now, by: Self.step)) { timeline in
                bars(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(at: frozenTime ?? 0)
        }
    }

    private func bars(at time: TimeInterval) -> some View {
        Group {
            // Canvas instead of four views: a single drawing pass, no layout and
            // no tree rebuild every frame
            Canvas { context, size in
                let barWidth: CGFloat = 3
                let gap: CGFloat = 2.5
                let total = barWidth * 4 + gap * 3
                for index in 0..<4 {
                    let height = self.height(for: index, at: time)
                    let x = (size.width - total) / 2 + CGFloat(index) * (barWidth + gap)
                    let y = (size.height - height) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tint))
                }
            }
        }
        .frame(width: 4 * 3 + 3 * 2.5, height: Self.maxHeight)
    }

    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        guard active else { return Self.minHeight }
        let base = sin(time * Self.speeds[index] + Self.phases[index])
        let detail = sin(time * Self.harmonics[index] + Self.phases[index] * 2) * 0.22
        // The sum of two waves gives an uneven but smooth pattern — like a
        // response to sound
        let value = (base + detail + 1.22) / 2.44
        return Self.minHeight + CGFloat(min(max(value, 0), 1)) * (Self.maxHeight - Self.minHeight)
    }
}
