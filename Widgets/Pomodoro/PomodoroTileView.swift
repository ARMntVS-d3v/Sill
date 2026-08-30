import SwiftUI

// Pomodoro. One layout for every size, the way the timer does it: the phase on
// top, the time in the middle, controls at the bottom. Size changes how much is
// shown, not how big the type is — the square drops the context and keeps the
// number and the one button that matters.
struct PomodoroTileView: View {
    let widget: PomodoroWidget
    let size: TileSize

    @Environment(\.theme) private var theme

    /// Work and break are told apart by color before any label is read. From the
    /// theme, not hardcoded: this is a state, not a brand
    private var accent: Color {
        widget.phase == .work ? theme.success.color : theme.accent.color
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
                TileLabel(widget.phase.title)
                Spacer(minLength: 0)
                Text(doneText)
                    .font(TileFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
            }

            ZStack {
                TileDial(
                    remaining: max(1 - widget.progress, 0.001),
                    secondsShare: (60 - widget.value.truncatingRemainder(dividingBy: 60)) / 60,
                    tint: accent)

                VStack(spacing: 3) {
                    Text(PomodoroWidget.text(widget.value))
                        .font(TileFont.heroLarge)
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                        .contentTransition(.numericText())
                    Text(subtitle)
                        .font(TileFont.caption)
                        .foregroundStyle(theme.textMuted.color)
                        .lineLimit(1)
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
                ) { widget.restart() }
                Spacer(minLength: 0)
                // The day's history: a filled circle per finished work stretch
                SessionDots(done: widget.doneToday, tint: accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(TileMetrics.padding)
    }

    // MARK: - Square and rectangle

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TileLabel(widget.phase.title)
                Spacer(minLength: 0)
                if size != .small {
                    Text(doneText)
                        .font(TileFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textMuted.color)
                }
            }

            Text(PomodoroWidget.text(widget.value))
                .font(TileFont.hero)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
                .contentTransition(.numericText())
                .padding(.top, TileMetrics.captionGap)

            // The square shows one number and one action — everything else goes
            if size != .small {
                Text(subtitle)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            PomodoroProgress(progress: widget.progress, tint: accent)
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

                // Restart is on every size: starting this stretch over is the
                // second thing anyone wants after pausing
                PomodoroButton(
                    icon: "arrow.counterclockwise", tint: accent, primary: false,
                    diameter: TileControlMetrics.secondary(size)
                ) { widget.restart() }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }

    private var doneText: String {
        String(localized: "\(widget.doneToday) today")
    }

    private var subtitle: String {
        if widget.finished {
            return widget.phase == .work
                ? String(localized: "time for a break")
                : String(localized: "break is over")
        }
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
