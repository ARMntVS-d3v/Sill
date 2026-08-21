import SwiftUI

// Tasks: check circle on the left, due date on the right. Unlike the calendar,
// this tile is for acting, not just looking — the circle is tappable right in the tile.
struct TasksTileView: View {
    let widget: AnyTasksWidget
    let size: TileSize

    var body: some View {
        switch size {
        case .small: TasksSmallView(widget: widget)
        case .medium: TasksMediumView(widget: widget)
        case .large: TasksLargeView(widget: widget)
        }
    }
}

// Checkbox styled after Things: a rounded square that fills with color and springs
// a checkmark on completion. The task doesn't disappear right away — there's an
// undo window before it does.
private struct TaskRow: View {
    let task: TaskItem
    let isDone: Bool
    let onToggle: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(isDone ? theme.accent.color : Color.clear)
                        .frame(width: 15, height: 15)
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .strokeBorder(
                            isDone ? theme.accent.color
                                : (task.isOverdue ? theme.error.color : theme.textMuted.color),
                            lineWidth: 1.4)
                        .frame(width: 15, height: 15)
                    Image(systemName: "checkmark")
                        .font(TileIcon.badge)
                        .foregroundStyle(isDone ? theme.panelBackground.color : theme.textMuted.color)
                        .opacity(isDone ? 1 : (hovered ? 0.5 : 0))
                        .scaleEffect(isDone ? 1 : 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 4.5).scale(1.7))
            }
            .buttonStyle(.plain)
            .animation(.easeOut(duration: Motion.editing), value: isDone)
            .help(isDone ? "Move back to list" : "Mark as done")
            .tileControl()

            Text(task.title)
                .font(TileFont.row)
                .foregroundStyle(isDone ? theme.textMuted.color : theme.textSecondary.color)
                .strikethrough(isDone, color: theme.textMuted.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if task.isFlagged, !isDone {
                Image(systemName: "flag.fill")
                    .font(TileIcon.caption)
                    .foregroundStyle(theme.warning.color)
            }
            if let dueText, !isDone {
                Text(dueText)
                    .font(TileFont.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(task.isOverdue ? theme.error.color : theme.textMuted.color)
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    // Due date, kept short: time for today's tasks, date for the rest
    private var dueText: String? {
        guard let due = task.due else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(due) {
            let hasTime = calendar.component(.hour, from: due) != 0
                || calendar.component(.minute, from: due) != 0
            return hasTime ? due.formatted(date: .omitted, time: .shortened) : String(localized: "today")
        }
        if calendar.isDateInTomorrow(due) { return String(localized: "tomorrow") }
        return due.formatted(.dateTime.day().month(.abbreviated))
    }
}

// Daily progress bar: how many tasks are done out of the total
private struct Progress: View {
    let done: Int
    let left: Int
    @Environment(\.theme) private var theme

    private var total: Int { max(done + left, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.textMuted.color.opacity(0.18))
                    Capsule()
                        .fill(theme.accent.color)
                        .frame(width: geo.size.width * CGFloat(done) / CGFloat(total))
                        .animation(.easeOut(duration: Motion.fill), value: done)
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Square

private struct TasksSmallView: View {
    let widget: AnyTasksWidget
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TileLabel(String(localized: "Today"))
                Spacer()
                Text("\(widget.visible().count)")
                    .font(TileFont.label)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
            }

            if !widget.isAvailable {
                TilePlaceholder(String(localized: "\(widget.appName) is not installed"), icon: "questionmark.app")
            } else if widget.visible().isEmpty {
                TilePlaceholder(String(localized: "All done"), icon: "checkmark.circle")
            } else {
                VStack(alignment: .leading, spacing: TileMetrics.rowGap) {
                    ForEach(widget.visible().prefix(4)) { task in
                        TaskRow(task: task, isDone: widget.isDone(task)) { widget.toggle(task) }
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .push(from: .bottom).combined(with: .opacity)))
                    }
                }
                .animation(.easeOut(duration: Motion.content), value: widget.visible().count)
                .padding(.top, 9)
                Spacer(minLength: 6)
                Progress(done: widget.completedToday(), left: widget.visible().count)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }
}

// MARK: - Rectangle

private struct TasksMediumView: View {
    let widget: AnyTasksWidget
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TileLabel(String(localized: "Today · \(widget.appName)"))
                Spacer()
                Text(counterText)
                    .font(TileFont.label)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
            }

            if !widget.isAvailable {
                TilePlaceholder(String(localized: "\(widget.appName) is not installed"), icon: "questionmark.app")
            } else if widget.visible().isEmpty {
                TilePlaceholder(String(localized: "All done"), icon: "checkmark.circle")
            } else {
                VStack(alignment: .leading, spacing: TileMetrics.rowGap) {
                    ForEach(widget.visible().prefix(4)) { task in
                        TaskRow(task: task, isDone: widget.isDone(task)) { widget.toggle(task) }
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .push(from: .bottom).combined(with: .opacity)))
                    }
                }
                .animation(.easeOut(duration: Motion.content), value: widget.visible().count)
                .padding(.top, TileMetrics.blockGap)
                Spacer(minLength: 8)
                Progress(done: widget.completedToday(), left: widget.visible().count)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }

    private var counterText: String {
        let done = widget.completedToday()
        return done > 0
            ? String(localized: "\(done) of \(done + widget.visible().count)")
            : "\(widget.visible().count)"
    }
}

// MARK: - Large

private struct TasksLargeView: View {
    let widget: AnyTasksWidget
    @Environment(\.theme) private var theme

    private var overdue: [TaskItem] { widget.visible().filter(\.isOverdue) }
    private var rest: [TaskItem] { widget.visible().filter { !$0.isOverdue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TileLabel(String(localized: "Today · \(widget.appName)"))
                Spacer()
                Text(counterText)
                    .font(TileFont.label)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
            }

            if !widget.isAvailable {
                TilePlaceholder(String(localized: "\(widget.appName) is not installed"), icon: "questionmark.app")
            } else if widget.visible().isEmpty {
                TilePlaceholder(String(localized: "All done"), icon: "checkmark.circle")
            } else {
                VStack(alignment: .leading, spacing: TileMetrics.rowGap) {
                    if !overdue.isEmpty {
                        Text("Overdue")
                            .font(TileFont.caption)
                            .foregroundStyle(theme.error.color)
                            .padding(.top, 12)
                        ForEach(overdue.prefix(2)) { task in
                            TaskRow(task: task, isDone: widget.isDone(task)) { widget.toggle(task) }
                        }
                    }
                    ForEach(rest.prefix(overdue.isEmpty ? 8 : 5)) { task in
                        TaskRow(task: task, isDone: widget.isDone(task)) { widget.toggle(task) }
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .push(from: .bottom).combined(with: .opacity)))
                    }
                }
                .animation(.easeOut(duration: Motion.content), value: widget.visible().count)
                .padding(.top, overdue.isEmpty ? 12 : 0)

                Spacer(minLength: 10)
                Progress(done: widget.completedToday(), left: widget.visible().count)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }

    private var counterText: String {
        let done = widget.completedToday()
        return done > 0
            ? String(localized: "\(done) of \(done + widget.visible().count)")
            : "\(widget.visible().count)"
    }
}
