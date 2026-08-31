import SwiftUI

// Pomodoro. One layout for every size, the way the timer does it: the phase on
// top, the time in the middle, controls at the bottom. Size changes how much is
// shown, not how big the type is — the square drops the context and keeps the
// number and the one button that matters.
struct PomodoroTileView: View {
    let widget: PomodoroWidget
    let size: TileSize

    @Environment(\.theme) private var theme

    /// What the tile is about right now. A phase that has run out is waiting to be
    /// picked up, and what's waiting is the NEXT phase — so the tile already wears
    /// it: its name, its color, its full length. A green tile with a zero on it says
    /// "work", which is the opposite of what just happened
    private var shown: PomodoroWidget.Phase {
        widget.finished ? widget.phase.other : widget.phase
    }

    /// Work and break are told apart by color before any label is read. From the
    /// theme, not hardcoded: this is a state, not a brand
    private var accent: Color {
        shown == .work ? theme.success.color : theme.accent.color
    }

    /// The number: what's left of the running phase, or the full length of the one
    /// waiting to start — the same thing a stopped timer shows
    private var value: TimeInterval {
        widget.finished ? widget.duration(of: shown) : widget.value
    }

    private var progress: Double { widget.finished ? 0 : widget.progress }

    /// The moment itself, said out loud. Only while a phase waits to be picked up
    private var callout: String? {
        guard widget.finished else { return nil }
        return shown == .rest
            ? String(localized: "Time for a break")
            : String(localized: "Back to work")
    }

    /// The line that appears when a phase ends: it materializes rather than
    /// replacing the caption on a frame — this is the one moment in the widget
    /// worth noticing across the room
    @ViewBuilder
    private func calloutRow(_ text: String, icon: Bool = true) -> some View {
        HStack(spacing: 5) {
            // No icon inside the dial: there the ring is already the whole phase,
            // and the pair together runs into it
            if icon {
                Image(systemName: shown == .rest ? "cup.and.saucer.fill" : "leaf.fill")
                    .font(TileIcon.caption)
            }
            Text(text)
                .font(TileFont.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(accent)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    var body: some View {
        if size == .large {
            largeBody
        } else {
            compactBody
        }
    }

    // MARK: - Large: the same dial the timer uses. A countdown is a countdown —
    // two tiles side by side must not draw it two different ways
    private var largeBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TileLabel(shown.title)
                Spacer(minLength: 0)
                Text(doneText)
                    .font(TileFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
            }

            ZStack {
                TileDial(
                    remaining: max(1 - progress, 0.001),
                    secondsShare: (60 - value.truncatingRemainder(dividingBy: 60)) / 60,
                    tint: accent)

                VStack(spacing: 3) {
                    Text(PomodoroWidget.text(value))
                        .font(TileFont.heroLarge)
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                        .contentTransition(.numericText())
                    if let callout {
                        calloutRow(callout, icon: false)
                    } else {
                        Text(subtitle)
                            .font(TileFont.caption)
                            .foregroundStyle(theme.textMuted.color)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 30)
            }
            .frame(height: 168)
            .padding(.top, 6)

            Spacer(minLength: 4)

            HStack(spacing: TileControlMetrics.gap(.large)) {
                PomodoroButton(
                    // A finished phase waits for play: the next one doesn't start itself
                    icon: widget.isRunning && !widget.finished ? "pause.fill" : "play.fill",
                    tint: accent, primary: true,
                    diameter: TileControlMetrics.primary(.large)
                ) { widget.toggle() }
                PomodoroButton(
                    icon: "forward.end.fill", tint: accent, primary: false,
                    diameter: TileControlMetrics.secondary(.large)
                ) { widget.skip() }
                PomodoroButton(
                    icon: "arrow.counterclockwise", tint: accent, primary: false,
                    diameter: TileControlMetrics.secondary(.large)
                ) { widget.reset() }
                Spacer(minLength: 0)
                // The day's history: a filled circle per finished work stretch
                SessionDots(done: widget.doneToday, tint: accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(TileMetrics.padding)
        .animation(.easeOut(duration: Motion.fill), value: widget.finished)
    }

    // MARK: - Square and rectangle

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TileLabel(shown.title)
                Spacer(minLength: 0)
                if size != .small {
                    Text(doneText)
                        .font(TileFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textMuted.color)
                }
            }

            Text(PomodoroWidget.text(value))
                .font(TileFont.hero)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
                .contentTransition(.numericText())
                .padding(.top, TileMetrics.captionGap)

            // The square shows one number and one action — everything else goes.
            // The one exception is the moment a phase ends: that line is the whole
            // point of the widget, and it belongs on every size
            if let callout {
                calloutRow(callout)
                    .padding(.top, 2)
            } else if size != .small {
                Text(subtitle)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            PomodoroProgress(progress: progress, tint: accent)
                .padding(.top, 7)

            Spacer(minLength: 8)

            HStack(spacing: TileControlMetrics.gap(size)) {
                PomodoroButton(
                    icon: widget.isRunning && !widget.finished ? "pause.fill" : "play.fill",
                    tint: accent, primary: true,
                    diameter: TileControlMetrics.primary(size)
                ) { widget.toggle() }

                PomodoroButton(
                    icon: "forward.end.fill", tint: accent, primary: false,
                    diameter: TileControlMetrics.secondary(size)
                ) { widget.skip() }

                // Reset is on every size: clearing this stretch back to the top is
                // the second thing anyone wants after pausing
                PomodoroButton(
                    icon: "arrow.counterclockwise", tint: accent, primary: false,
                    diameter: TileControlMetrics.secondary(size)
                ) { widget.reset() }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
        // Color, number and the line arrive as one movement, not three
        .animation(.easeOut(duration: Motion.fill), value: widget.finished)
    }

    private var doneText: String {
        String(localized: "\(widget.doneToday) today")
    }

    private var subtitle: String {
        guard let endsAt = widget.endsAt else {
            return widget.phase == .work
                ? String(localized: "tap play to start")
                : String(localized: "rest until you start again")
        }
        return String(localized: "until \(endsAt.formatted(date: .omitted, time: .shortened))")
    }

}

// Today's finished stretches. Circles, not a number: the row fills up as the day
// goes, and that is the whole point of counting them
private struct SessionDots: View {
    let done: Int
    let tint: Color
    @Environment(\.theme) private var theme

    /// Beyond this the row would run into the tile edge — the rest becomes "+N"
    private static let shown = 8

    var body: some View {
        HStack(spacing: TileMetrics.captionGap) {
            ForEach(0..<Self.shown, id: \.self) { index in
                Image(systemName: index < done ? "circle.fill" : "circle")
                    .font(TileIcon.badge)
                    .foregroundStyle(index < done ? tint : theme.border.color)
            }
            if done > Self.shown {
                Text("+\(done - Self.shown)")
                    .font(TileFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
            }
        }
    }
}

// Same strip as the timer's: fill height from the standards, colored by phase
private struct PomodoroProgress: View {
    let progress: Double
    let tint: Color
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.border.color)
                    .frame(height: TileMetrics.trackHeight)
                Capsule()
                    .fill(tint)
                    .frame(
                        width: max(geo.size.width * progress, TileMetrics.trackHeight),
                        height: TileMetrics.trackHeight)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: TileMetrics.trackHeight)
        .animation(.easeOut(duration: Motion.fill), value: progress)
    }
}

// Round controls, same diameters as the player and the timer (standards.md):
// two adjacent tiles with buttons of different sizes read as two programs
private struct PomodoroButton: View {
    let icon: String
    let tint: Color
    let primary: Bool
    let diameter: CGFloat
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if primary {
                    Circle()
                        .fill(tint)
                        .frame(width: diameter, height: diameter)
                        .overlay {
                            Image(systemName: icon)
                                .font(TileIcon.controlPrimary)
                                .foregroundStyle(theme.panelBackground.color)
                        }
                        .scaleEffect(hovered ? 1.06 : 1)
                } else {
                    Image(systemName: icon)
                        .font(TileIcon.control)
                        .foregroundStyle(hovered ? theme.textPrimary.color : theme.textSecondary.color)
                        .frame(width: diameter, height: diameter)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: Motion.hover), value: hovered)
        .onHover { hovered = $0 }
        .tileControl()
    }
}
