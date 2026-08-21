import SwiftUI

// Size changes depth, not font size: square is current conditions, rectangle
// adds upcoming hours, large adds the week. The city is clickable at every size.
struct WeatherTileView: View {
    let widget: WeatherWidget
    let size: TileSize

    var body: some View {
        Group {
            if widget.isPickingCity {
                CityPickerView(widget: widget, size: size)
            } else if widget.snapshot == nil {
                WeatherLoadingView(widget: widget)
            } else {
                switch size {
                case .small: WeatherSmallView(widget: widget)
                case .medium: WeatherMediumView(widget: widget)
                case .large: WeatherLargeView(widget: widget)
                }
            }
        }
        // Data arrived — the tile fades in rather than snapping to a new frame
        .animation(.easeOut(duration: Motion.content), value: widget.snapshot?.updated)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }
}

// MARK: - shared bits

// City name is a button: there's no other spot for "change city" in the tile,
// and hover chrome would just read as clutter in this grid
private struct CityLabel: View {
    let widget: WeatherWidget

    var body: some View {
        Button {
            widget.startPickingCity()
        } label: {
            TileLabel(widget.place?.name ?? String(localized: "City"))
        }
        .buttonStyle(.plain)
        .help("Change city")
        .tileControl()
    }
}

private struct ConditionIcon: View {
    let code: Int
    let isDay: Bool
    var font: Font = TileIcon.hero
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: WeatherCode.symbol(code, isDay: isDay))
            .font(font)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(WeatherCode.tint(code, theme: theme))
    }
}

// Hour column: time, icon, temperature — the same at both rectangle and large sizes
private struct HourColumn: View {
    let hour: WeatherSnapshot.Hour
    let zone: TimeZone
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            Text(hour.date.formatted(Date.FormatStyle(timeZone: zone).hour(.twoDigits(amPM: .omitted))))
                .font(TileFont.axis)
                .monospacedDigit()
                .foregroundStyle(theme.textMuted.color)
            ConditionIcon(code: hour.code, isDay: hour.isDay, font: TileIcon.glyph)
            Text(hour.temperature.degreesText)
                .font(TileFont.rowValue)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary.color)
        }
        .frame(maxWidth: .infinity)
    }
}

// No first response yet, and no cache either: nothing to show
private struct WeatherLoadingView: View {
    let widget: WeatherWidget
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: TileMetrics.rowGap) {
            TilePlaceholder(placeholderText, icon: "cloud.sun")
                .fixedSize(horizontal: false, vertical: true)
            if widget.place == nil {
                Button("Choose city") { widget.startPickingCity() }
                    .buttonStyle(.plain)
                    .tileControl()
                    .font(TileFont.caption.weight(.medium))
                    .foregroundStyle(theme.accent.color)
            } else if widget.failure != nil {
                // Network didn't respond and there's no cache: without a button
                // the tile would look stuck on "Loading…" forever
                Button("Retry") { widget.retry() }
                    .buttonStyle(.plain)
                    .tileControl()
                    .font(TileFont.caption.weight(.medium))
                    .foregroundStyle(theme.accent.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var placeholderText: String {
        if widget.place == nil { return String(localized: "No city selected") }
        return widget.failure ?? String(localized: "Loading…")
    }
}

// MARK: - Square: current conditions only

private struct WeatherSmallView: View {
    let widget: WeatherWidget
    @Environment(\.theme) private var theme

    @ViewBuilder
    var body: some View {
        // The snapshot may have been cleared while the view rebuilds (city change).
        // Force-unwrapping used to crash the app here, so an empty frame instead
        if let snapshot = widget.snapshot {
        VStack(alignment: .leading, spacing: 0) {
            CityLabel(widget: widget)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(snapshot.current.temperature.degreesText)
                    .font(TileFont.hero)
                    .foregroundStyle(theme.textPrimary.color)
                    .fixedSize()
                ConditionIcon(code: snapshot.current.code, isDay: snapshot.current.isDay)
            }
            .padding(.top, 8)

            Text(WeatherCode.text(snapshot.current.code))
                .font(TileFont.status)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(2)
                .padding(.top, 4)

            Spacer(minLength: 6)

            if let today = widget.nextDays(1).first {
                HStack(spacing: 6) {
                    Text("\(today.high.degreesText) / \(today.low.degreesText)")
                        .font(TileFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textMuted.color)
                    Spacer(minLength: 0)
                    // "Feels like" doesn't fit in the square and gets clipped —
                    // shortened here to an approximation sign instead
                    Text("≈ \(snapshot.current.apparent.degreesText)")
                        .font(TileFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textMuted.color)
                        .help("Feels like \(snapshot.current.apparent.degreesText)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Rectangle: current on the left, upcoming hours on the right

private struct WeatherMediumView: View {
    let widget: WeatherWidget
    @Environment(\.theme) private var theme

    @ViewBuilder
    var body: some View {
        // The snapshot may have been cleared while the view rebuilds (city change).
        // Force-unwrapping used to crash the app here, so an empty frame instead
        if let snapshot = widget.snapshot {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                CityLabel(widget: widget)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(snapshot.current.temperature.degreesText)
                        .font(TileFont.hero)
                        .foregroundStyle(theme.textPrimary.color)
                        .fixedSize()
                    ConditionIcon(code: snapshot.current.code, isDay: snapshot.current.isDay)
                }
                .padding(.top, 6)
                Text(WeatherCode.text(snapshot.current.code))
                    .font(TileFont.status)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(2)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                Text("feels like \(snapshot.current.apparent.degreesText)")
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)

            Rectangle()
                .fill(theme.border.color)
                .frame(width: 1)

            VStack(alignment: .leading, spacing: TileMetrics.rowGap) {
                HStack(spacing: 0) {
                    ForEach(widget.nextHours(5)) { hour in
                        HourColumn(hour: hour, zone: snapshot.timeZone)
                    }
                }
                Spacer(minLength: 0)
                // Wind and humidity — details that don't fit the headline number but sway a decision
                HStack(spacing: 10) {
                    Metric(icon: "wind", value: String(localized: "\(snapshot.current.wind.formatted(.number.precision(.fractionLength(0...1)))) m/s"))
                    Metric(icon: "humidity", value: String(localized: "\(snapshot.current.humidity)%"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
    }
}

private struct Metric: View {
    let icon: String
    let value: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(TileIcon.caption)
            Text(value)
                .font(TileFont.caption)
                .monospacedDigit()
        }
        .foregroundStyle(theme.textMuted.color)
    }
}

// MARK: - Large: current, hours, week

private struct WeatherLargeView: View {
    let widget: WeatherWidget
    @Environment(\.theme) private var theme

    @ViewBuilder
    var body: some View {
        // The snapshot may have been cleared while the view rebuilds (city change).
        // Force-unwrapping used to crash the app here, so an empty frame instead
        if let snapshot = widget.snapshot {
        VStack(alignment: .leading, spacing: 0) {
            CityLabel(widget: widget)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.current.temperature.degreesText)
                        .font(TileFont.hero)
                        .foregroundStyle(theme.textPrimary.color)
                        .fixedSize()
                    Text(WeatherCode.text(snapshot.current.code))
                        .font(TileFont.status)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ConditionIcon(code: snapshot.current.code, isDay: snapshot.current.isDay, font: TileIcon.hero)
            }
            .padding(.top, 6)

            HStack(spacing: 10) {
                Metric(icon: "thermometer.medium", value: String(localized: "feels like \(snapshot.current.apparent.degreesText)"))
                Metric(icon: "wind", value: String(localized: "\(snapshot.current.wind.formatted(.number.precision(.fractionLength(0...1)))) m/s"))
                Metric(icon: "humidity", value: String(localized: "\(snapshot.current.humidity)%"))
            }
            .padding(.top, 4)

            HStack(spacing: 0) {
                ForEach(widget.nextHours(6)) { hour in
                    HourColumn(hour: hour, zone: snapshot.timeZone)
                }
            }
            .padding(.top, TileMetrics.blockGap)

            Rectangle()
                .fill(theme.border.color)
                .frame(height: 1)
                .padding(.vertical, 9)

            VStack(spacing: 7) {
                ForEach(widget.nextDays(5)) { day in
                    DayRow(day: day, range: widget.weekRange, zone: snapshot.timeZone)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// Day row: the bar shows where the day sits within the week's range —
// "tomorrow's colder" is visible without reading the numbers
private struct DayRow: View {
    let day: WeatherSnapshot.Day
    let range: ClosedRange<Double>?
    let zone: TimeZone
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text(day.date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated)))
                .font(TileFont.caption)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: 26, alignment: .leading)
            ConditionIcon(code: day.code, isDay: true, font: TileIcon.glyph)
                .frame(width: 18)
            Text(day.low.degreesText)
                .font(TileFont.rowValue)
                .monospacedDigit()
                .foregroundStyle(theme.textMuted.color)
                .frame(width: 30, alignment: .trailing)
            GeometryReader { geo in
                let span = fraction(in: geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.border.color)
                        .frame(height: 3)
                    Capsule()
                        .fill(theme.accent.color.opacity(0.85))
                        .frame(width: span.width, height: 3)
                        .offset(x: span.start)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            Text(day.high.degreesText)
                .font(TileFont.rowValue)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func fraction(in width: CGFloat) -> (start: CGFloat, width: CGFloat) {
        guard let range, width > 0 else { return (0, width) }
        let total = range.upperBound - range.lowerBound
        let start = CGFloat((day.low - range.lowerBound) / total) * width
        let end = CGFloat((day.high - range.lowerBound) / total) * width
        return (start, max(end - start, 3))
    }
}

// MARK: - city picker

private struct CityPickerView: View {
    let widget: WeatherWidget
    let size: TileSize
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    private var rows: Int { size == .small ? 2 : (size == .medium ? 3 : 6) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                TextField(String(localized: "City"), text: Binding(
                    get: { widget.query },
                    set: { widget.query = $0; widget.queryChanged() }))
                    .textFieldStyle(.plain)
                    .font(TileFont.row)
                    .foregroundStyle(theme.textPrimary.color)
                    .focused($focused)
                    .releasesFocusOnHide($focused)
                if widget.place != nil {
                    Button {
                        widget.cancelPickingCity()
                    } label: {
                        Image(systemName: "xmark")
                            .font(TileIcon.badge)
                            .foregroundStyle(theme.textMuted.color)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                }
            }
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.border.color).frame(height: 1)
            }
            .tileControl()

            if widget.searching {
                Text("Loading…")
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
            } else if widget.searchFailed {
                Text("Search failed")
                    .font(TileFont.caption)
                    .foregroundStyle(theme.warning.color)
            } else if widget.results.isEmpty {
                Text(widget.query.count >= 2 ? "Nothing found" : "Start typing a name")
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(2)
            } else {
                ForEach(widget.results.prefix(rows)) { place in
                    Button {
                        widget.select(place)
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(place.name)
                                .font(TileFont.row)
                                .foregroundStyle(theme.textPrimary.color)
                                .lineLimit(1)
                            if !place.subtitle.isEmpty, size != .small {
                                Text(place.subtitle)
                                    .font(TileFont.caption)
                                    .foregroundStyle(theme.textMuted.color)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tileControl()
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focused = true }
    }
}
