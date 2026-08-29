import SwiftUI

// Timer and stopwatch. Simple layout, the same across all sizes: mode switch
// on top, time in the middle, two buttons at the bottom. The time is an input
// field — tap the digits and type "10" or "1:30" on the keyboard.
// Presets only appear at the large size, where there's room for them.
struct TimerTileView: View {
    let widget: TimerWidget
    let size: TileSize

    @Environment(\.theme) private var theme
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    // Apple Clock's orange. Deliberately outside the theme palette: the timer is
    // recognized by this color, same as the island capsule, and should look the
    // same in every theme
    static let accent = Color(red: 1, green: 0.62, blue: 0.04)

    var body: some View {
        if size == .large {
            largeBody
        } else {
            compactBody
        }
    }

    // MARK: - Large: dial

    private var largeBody: some View {
        VStack(spacing: 0) {
            HStack {
                ModeSwitch(widget: widget)
                Spacer(minLength: 0)
                if widget.state.mode == .timer {
                    HStack(spacing: 5) {
                        ForEach([1, 5, 10], id: \.self) { minutes in
                            AddChip(widget: widget, minutes: minutes)
                        }
                    }
                }
            }

            ZStack {
                TimerDial(widget: widget)

                VStack(spacing: 3) {
                    timeField
                    Text(subtitle)
                        .font(TileFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textMuted.color)
                        .lineLimit(1)
                }
                .padding(.horizontal, 30)
            }
            .frame(height: 168)
            .padding(.top, 6)

            Spacer(minLength: 4)

            HStack(spacing: TileControlMetrics.gap(.large)) {
                TimerButton(
                    icon: widget.isRunning ? "pause.fill" : "play.fill",
                    primary: true, diameter: TileControlMetrics.primary(.large)
                ) { widget.toggle() }
                TimerButton(
                    icon: "arrow.counterclockwise", primary: false,
                    diameter: TileControlMetrics.secondary(.large)
                ) {
                    widget.restart()
                }
                Spacer(minLength: 0)
                // Presets get their own tight spacing: with the shared button gap
                // (14) a row of five chips was wider than the tile and got clipped
                if widget.state.mode == .timer {
                    HStack(spacing: 5) {
                        ForEach(TimerWidget.presets, id: \.self) { preset in
                            PresetChip(widget: widget, preset: preset)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(TileMetrics.padding)
    }

    private var subtitle: String {
        if widget.finished { return String(localized: "time's up") }
        if let endsAt = widget.endsAt {
            return String(localized: "ends at \(endsAt.formatted(date: .omitted, time: .shortened))")
        }
        return widget.state.mode == .timer ? String(localized: "tap the time") : String(localized: "stopwatch")
    }

    // MARK: - Square and rectangle

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModeSwitch(widget: widget)

            Spacer(minLength: 6)

            timeField
                .frame(maxWidth: .infinity, alignment: .leading)

            if widget.state.mode == .timer {
                TimerProgress(widget: widget)
                    .padding(.top, 7)
            }

            Spacer(minLength: 8)

            HStack(spacing: TileControlMetrics.gap(size)) {
                TimerButton(
                    icon: widget.isRunning ? "pause.fill" : "play.fill",
                    primary: true,
                    diameter: TileControlMetrics.primary(size)
                ) { widget.toggle() }

                TimerButton(
                    icon: "arrow.counterclockwise", primary: false,
                    diameter: TileControlMetrics.secondary(size)
                ) {
                    widget.restart()
                }

                Spacer(minLength: 0)

                // Preset buttons — only at the rectangle size, own tight spacing
                if size == .medium, widget.state.mode == .timer {
                    HStack(spacing: 5) {
                        ForEach(TimerWidget.presets, id: \.self) { preset in
                            PresetChip(widget: widget, preset: preset)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }

    // The time: normally a label, tap it and it becomes an input field with the
    // same font, so the digits don't jump when switching
    @ViewBuilder
    private var timeField: some View {
        let font = size == .large ? TileFont.heroLarge : TileFont.hero

        if editing, widget.state.mode == .timer {
            TextField("5:00", text: $draft)
                .textFieldStyle(.plain)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(Self.accent)
                .focused($focused)
                .releasesFocusOnHide($focused)
                .onSubmit(apply)
                .onExitCommand { editing = false }
                .onAppear { focused = true }
                .tileControl()
        } else {
            Text(TimerWidget.text(widget.value))
                .font(font)
                .monospacedDigit()
                .foregroundStyle(widget.finished ? theme.error.color : Self.accent)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard widget.state.mode == .timer else { return }
                    draft = widget.editableText
                    editing = true
                }
                .help(widget.state.mode == .timer ? "Tap to enter a time" : "")
                .tileControl()
        }
    }

    private func apply() {
        if let duration = TimerWidget.parseDuration(draft) {
            widget.setDuration(duration)
        }
        editing = false
    }
}

// The dial: sixty tick marks around the circle plus a thin arc for the
// remaining time on top of them. The ticks count off the current minute, the
// arc counts the whole interval — together they read at a glance and up close
private struct TimerDial: View {
    let widget: TimerWidget
    @Environment(\.theme) private var theme

    var body: some View {
        TileDial(remaining: remaining, secondsShare: secondsShare, tint: tint)
    }

    // Remainder over the whole interval: a full circle at the start, empty at the end
    private var remaining: Double {
        guard widget.state.mode == .timer else { return 1 }
        return max(1 - widget.progress, 0.001)
    }

    // Share of the current minute — drives the ticks even when the interval is long
    private var secondsShare: Double {
        let seconds = widget.value.truncatingRemainder(dividingBy: 60)
        return widget.state.mode == .timer ? (60 - seconds) / 60 : seconds / 60
    }

    // Color shifts to red near the end — the last minute should feel urgent.
    // A timer stopped at zero shouldn't turn red — it hasn't been started yet
    private var tint: Color {
        if widget.finished { return theme.error.color }
        guard widget.state.mode == .timer, widget.state.duration > 0, widget.isRunning else {
            return TimerTileView.accent
        }
        let left = widget.value / widget.state.duration
        return left < 0.1 ? theme.error.color : TimerTileView.accent
    }
}

// Mode switch: two icons in a capsule. The same at every size — needed in the
// square too, otherwise the stopwatch would be unreachable there
private struct ModeSwitch: View {
    let widget: TimerWidget
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimerWidget.Mode.allCases, id: \.self) { mode in
                let selected = widget.state.mode == mode
                Button {
                    widget.setMode(mode)
                } label: {
                    Image(systemName: mode == .timer ? "timer" : "stopwatch")
                        .font(TileIcon.badge)
                        .foregroundStyle(
                            selected ? theme.panelBackground.color : theme.textMuted.color)
                        .frame(width: 22, height: 16)
                        .background(Capsule().fill(selected ? TimerTileView.accent : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(mode == .timer ? "Timer" : "Stopwatch")
                .tileControl()
            }
        }
        .padding(2)
        .background(Capsule().fill(theme.tileHover.color.opacity(0.6)))
    }
}

// "+1", "+5", "+10" minutes: extend a running timer without resetting it
private struct AddChip: View {
    let widget: TimerWidget
    let minutes: Int
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            widget.add(minutes: minutes)
        } label: {
            Text("+\(minutes)m")
                .font(TileFont.caption)
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle(theme.textSecondary.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().strokeBorder(theme.border.color, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .tileControl()
    }
}

private struct PresetChip: View {
    let widget: TimerWidget
    let preset: TimeInterval
    @Environment(\.theme) private var theme

    var body: some View {
        let selected = widget.state.duration == preset
        Button {
            widget.setDuration(preset)
        } label: {
            Text(TimerWidget.presetText(preset))
                .font(TileFont.caption)
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle(selected ? theme.panelBackground.color : theme.textSecondary.color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(selected ? TimerTileView.accent : theme.tileHover.color))
        }
        .buttonStyle(.plain)
        .tileControl()
    }
}

// Remainder bar: fills up as time runs out
private struct TimerProgress: View {
    let widget: TimerWidget
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.border.color)
                    .frame(height: 3)
                Capsule()
                    .fill(widget.finished ? theme.error.color : TimerTileView.accent)
                    .frame(width: max(geo.size.width * widget.progress, 3), height: 3)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 3)
    }
}

private struct TimerButton: View {
    let icon: String
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
                        .fill(TimerTileView.accent)
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
