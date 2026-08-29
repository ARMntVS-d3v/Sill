import SwiftUI

// "Horizon" layout: large time in the calendar's color, day timeline along the
// bottom edge. Size changes depth: small — next event only (no room for the
// timeline), medium — adds a column of what's next, large — the whole day with
// room to breathe.
struct CalendarTileView: View {
    let widget: CalendarWidget
    let size: TileSize

    var body: some View {
        switch size {
        case .small: CalendarSmallView(widget: widget)
        case .medium: CalendarMediumView(widget: widget)
        case .large: CalendarLargeView(widget: widget)
        }
    }
}

// MARK: - Shared details

extension CalendarWidget.Event {
    var color: Color { ThemeColor(colorHex).color }

    var timeText: String {
        isAllDay ? String(localized: "all day") : start.formatted(date: .omitted, time: .shortened)
    }

    // End time on its own line under the start: the range doesn't fit on one
    // line, and the large start digit matters more
    var endTimeText: String? {
        guard !isAllDay, end > start else { return nil }
        return end.formatted(date: .omitted, time: .shortened)
    }

    // Under the large start time, a bare time reads as a misaligned line even
    // though it's aligned correctly — the word "until" removes the comparison.
    // Inline, on one line, the word isn't needed
    var endTimeBelow: String? { endTimeText.map { String(localized: "until \($0)") } }

    // "in 40 min", "now", "in 2 h 10 min"
    func relativeText(from now: Date) -> String {
        if isNow { return String(localized: "now") }
        let minutes = Int(start.timeIntervalSince(now) / 60)
        if minutes < 1 { return String(localized: "any moment") }
        if minutes < 60 { return String(localized: "in \(minutes) min") }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? String(localized: "in \(hours) h") : String(localized: "in \(hours) h \(rest) min")
    }
}

// List row: time, calendar color dot, title
// The tile's right column is a shared RIGHT EDGE, not a fixed width.
// Can't fix the width: reserving 37 pt for a 13 pt icon left an empty gap
// on the left that truncated text never reached.
private let valueGap: CGFloat = 6

private struct EventLine: View {
    let event: CalendarWidget.Event
    @Environment(\.theme) private var theme

    var body: some View {
        // Time sits at the row's right edge: the time column lines up on its
        // own, and titles start from one vertical line right after the dot
        HStack(spacing: valueGap) {
            Circle()
                .fill(event.color)
                .frame(width: 7, height: 7)
            Text(event.title)
                .font(TileFont.row)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Fixed-width right column: time and the "all day" icon line up
            // exactly, and the title truncates right at its edge
            Group {
                if event.isAllDay {
                    Image(systemName: "calendar").font(TileIcon.glyph)
                } else {
                    Text(event.timeText).font(TileFont.rowValue).monospacedDigit()
                }
            }
            .foregroundStyle(theme.textMuted.color)
            .fixedSize()
        }
    }
}

// Location and meeting link: location opens Maps, link opens the meeting
private struct EventDetails: View {
    let event: CalendarWidget.Event
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: valueGap) {
            if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
               !location.isEmpty {
                Button {
                    let query = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "maps://?q=\(query)") { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(alignment: .center, spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(TileIcon.caption)
                        Text(location)
                            .font(TileFont.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(theme.textMuted.color)
                }
                .buttonStyle(.plain)
                .help(location)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tileControl()
            } else {
                Spacer(minLength: 0)
            }
            if let url = event.joinURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: event.isMeetingLink ? "video.fill" : "link")
                        .font(TileIcon.caption)
                        .foregroundStyle(theme.accent.color)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Join: \(url.absoluteString)")
                .tileControl()
            }
        }
    }
}

// MARK: - Small: next event only, no timeline

private struct CalendarSmallView: View {
    let widget: CalendarWidget
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TileLabel(widget.shortDateText)
            if let next = widget.upcoming {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(next.timeText)
                        .font(TileFont.hero)
                        .foregroundStyle(theme.error.color)
                        .fixedSize()
                    if let endText = next.endTimeText {
                        Text(endText)
                            .font(TileFont.heroSecondary)
                            .foregroundStyle(theme.textMuted.color)
                    }
                }
                .padding(.top, 8)
                Text(next.title)
                    .font(TileFont.title)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                    .padding(.top, 6)
                Text(next.relativeText(from: widget.now))
                    .font(TileFont.status)
                    .foregroundStyle(next.isNow ? theme.success.color : theme.textSecondary.color)
                    .padding(.top, 3)
            } else {
                TilePlaceholder(String(localized: "No events"), icon: "calendar")
            }

            Spacer(minLength: 6)

            // What comes after the next event — one line, styled like the
            // larger tiles' list
            if let after = widget.following(limit: 1).first {
                HStack(spacing: 7) {
                    Circle()
                        .fill(after.color)
                        .frame(width: 6, height: 6)
                    Text(after.title)
                        .font(TileFont.caption)
                        .foregroundStyle(theme.textMuted.color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(after.timeText)
                        .font(TileFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textMuted.color)
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }
}

// MARK: - Medium: split view — next event on the left, upcoming on the right

private struct CalendarMediumView: View {
    let widget: CalendarWidget
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Empty day isn't split into columns: one full-width label
            if widget.upcoming == nil && widget.listEvents(limit: 1).isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    TileLabel(widget.shortDateText)
                    TilePlaceholder(String(localized: "No events"), icon: "calendar")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        TileLabel(widget.shortDateText)
                        if let next = widget.upcoming {
                            // End time on the line below: "10:30 11:00" doesn't
                            // fit in a 100 pt column, and the large time started
                            // truncating.
                            // No monospacedDigit here: monospaced digits center
                            // within their cell by point size, which made the
                            // start and end left edges drift apart more as the
                            // font got larger
                            Text(next.timeText)
                                .font(TileFont.hero)
                                .foregroundStyle(theme.error.color)
                                .fixedSize()
                                .padding(.top, 6)
                            if let endText = next.endTimeBelow {
                                Text(endText)
                                    .font(TileFont.heroSecondary)
                                    .foregroundStyle(theme.textMuted.color)
                                    .fixedSize()
                            }
                            Text(next.title)
                                .font(TileFont.title)
                                .foregroundStyle(theme.textPrimary.color)
                                .lineLimit(2)
                                .padding(.top, 5)
                            Text(next.relativeText(from: widget.now))
                                .font(TileFont.status)
                                .foregroundStyle(next.isNow ? theme.success.color : theme.textSecondary.color)
                                .padding(.top, 1)
                        } else {
                            TilePlaceholder(String(localized: "No events"), icon: "calendar")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 100, alignment: .leading)

                    Rectangle()
                        .fill(theme.border.color)
                        .frame(width: 1)

                    VStack(alignment: .leading, spacing: TileMetrics.rowGap) {
                        let list = widget.listEvents(limit: 4)
                        if list.isEmpty {
                            Text("No events")
                                .font(TileFont.caption)
                                .foregroundStyle(theme.textMuted.color)
                        } else {
                            ForEach(list) { event in
                                EventLine(event: event)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            DayTimeline(events: widget.todayEvents, now: widget.now, range: widget.timelineRange)
                .frame(height: 17)
                .padding(.top, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }
}

// MARK: - Large: the whole day, with room to breathe

private struct CalendarLargeView: View {
    let widget: CalendarWidget
    @Environment(\.theme) private var theme

    private var shown: [CalendarWidget.Event] { widget.listEvents(limit: 6) }
    private var hidden: Int { widget.hiddenCount(shown: shown.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                TileLabel(widget.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                Spacer(minLength: 8)
                Text("\(widget.todayEvents.count)")
                    .font(TileFont.label)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
            }

            if let next = widget.upcoming {
                // Time on the left, everything about the event to its right:
                // three lines of text next to the large digit instead of
                // three lines below it
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(next.timeText)
                            .font(TileFont.hero)
                            .foregroundStyle(theme.error.color)
                        if let endText = next.endTimeBelow {
                            Text(endText)
                                .font(TileFont.heroSecondary)
                                .foregroundStyle(theme.textMuted.color)
                        }
                    }
                    .fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.title)
                            .font(TileFont.title)
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(next.relativeText(from: widget.now))
                            .font(TileFont.status)
                            .foregroundStyle(next.isNow ? theme.success.color : theme.textSecondary.color)
                        EventDetails(event: next)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, TileMetrics.blockGap)

                VStack(alignment: .leading, spacing: TileMetrics.rowGap) {
                    ForEach(shown) { event in
                        EventLine(event: event)
                    }
                    if hidden > 0 {
                        Text("+\(hidden) more")
                            .font(TileFont.caption)
                            .foregroundStyle(theme.textMuted.color)
                    }
                }
                .padding(.top, 12)
            } else {
                TilePlaceholder(String(localized: "No events"), icon: "calendar")
            }

            // Timeline isn't crammed against the text: same spacing as the medium tile
            Spacer(minLength: 10)
            DayTimeline(events: widget.todayEvents, now: widget.now, range: widget.timelineRange, showScale: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }
}

// Day timeline 8:00–22:00: colored event segments, a "now" marker, optional hour scale
private struct DayTimeline: View {
    let events: [CalendarWidget.Event]
    let now: Date
    var range: ClosedRange<Double> = 8...22
    var showScale = false
    @Environment(\.theme) private var theme

    private var dayStart: Double { range.lowerBound }
    private var dayEnd: Double { range.upperBound }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(theme.textMuted.color.opacity(0.18))
                        .frame(height: 5)
                        .offset(y: 6)

                    ForEach(events.filter { !$0.isAllDay }) { event in
                        let x = position(of: event.start) * width
                        let endX = position(of: event.end) * width
                        Capsule()
                            .fill(event.color.opacity(event.isPast ? 0.4 : 1))
                            .frame(width: max(6, endX - x), height: 5)
                            .offset(x: x, y: 6)
                    }

                    Capsule()
                        .fill(theme.textPrimary.color)
                        .frame(width: 2, height: 17)
                        .offset(x: position(of: now) * width)
                }
            }
            .frame(height: 17)

            if showScale {
                HStack(spacing: 0) {
                    ForEach(scaleHours, id: \.self) { hour in
                        Text("\(hour)")
                            .font(TileFont.axis)
                            .monospacedDigit()
                            .foregroundStyle(theme.textMuted.color)
                        if hour != scaleHours.last { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .frame(height: showScale ? 33 : 17)
    }

    // Four marks across the range
    private var scaleHours: [Int] {
        let low = Int(dayStart), high = Int(dayEnd)
        let step = max((high - low) / 3, 1)
        return stride(from: low, through: high, by: step).prefix(4).map { $0 }
    }

    private func position(of date: Date) -> Double {
        let calendar = Calendar.current
        // Hour and minute alone put a moment from another day at today's
        // wall-clock hour: an event started yesterday at 23:00 and still
        // running drew as a stub at the scale's end. Off-today clamps to the edge
        let todayStart = calendar.startOfDay(for: Date())
        if date < todayStart { return 0 }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart), date >= tomorrow {
            return 1
        }
        let hour = Double(calendar.component(.hour, from: date))
            + Double(calendar.component(.minute, from: date)) / 60
        return min(max((hour - dayStart) / (dayEnd - dayStart), 0), 1)
    }
}
