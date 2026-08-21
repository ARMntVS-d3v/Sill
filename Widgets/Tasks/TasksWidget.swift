import SwiftUI

// Tasks widget. Two widgets in the registry — "Reminders" and "Things" — differ
// only by source: the user picks the one they want when adding it.
@MainActor @Observable
class TasksWidget<Source: TaskSource>: Widget {
    class var descriptor: WidgetDescriptor {
        WidgetDescriptor(
            id: "tasks", name: "Tasks", icon: "checklist",
            sizes: [.small, .medium, .large], defaultSize: .medium,
            permissions: [Source.permission])
    }

    let context: WidgetContext
    let source: Source

    private(set) var tasks: [TaskItem] = []
    private(set) var completedToday = 0
    private(set) var now = Date()
    // A completed task stays in the list, struck through: tapping it again during
    // this window undoes the completion — a stray click doesn't lose the task for good
    private(set) var justCompleted: Set<String> = []
    private var hidden: Set<String> = []

    required init(context: WidgetContext) {
        self.context = context
        self.source = Source()
        tasks = context.cache.load("tasks", as: [TaskItem].self) ?? []
        context.schedule(every: .seconds(60)) { [weak self] in
            self?.now = Date()
            try? await self?.refresh()
        }
    }

    var visible: [TaskItem] { tasks.filter { !hidden.contains($0.id) } }

    var appName: String { Source.appName }

    func refresh() async throws {
        tasks = try await source.load()
        context.cache.save("tasks", tasks)
        now = Date()
    }

    // First tap marks the task done; a second tap within the window undoes it
    func toggle(_ task: TaskItem) {
        if justCompleted.contains(task.id) {
            justCompleted.remove(task.id)
            completedToday = max(completedToday - 1, 0)
            Task { await source.setCompleted(id: task.id, false) }
            return
        }
        justCompleted.insert(task.id)
        completedToday += 1
        Task {
            await source.setCompleted(id: task.id, true)
            try? await Task.sleep(for: .seconds(6))  // undo window
            guard justCompleted.contains(task.id) else { return }
            justCompleted.remove(task.id)
            hidden.insert(task.id)
            try? await refresh()
            hidden.remove(task.id)
        }
    }

    func primaryAction() -> Bool {
        source.openApp()
        return true
    }

    var body: AnyView {
        AnyView(TasksTileView(widget: AnyTasksWidget(self), size: context.tileSize))
    }
}

// Wrapper so the view doesn't depend on a concrete source
@MainActor
struct AnyTasksWidget {
    let visible: () -> [TaskItem]
    let appName: String
    let isAvailable: Bool
    let completedToday: () -> Int
    let toggle: (TaskItem) -> Void
    let isDone: (TaskItem) -> Bool

    init<Source: TaskSource>(_ widget: TasksWidget<Source>) {
        visible = { widget.visible }
        appName = widget.appName
        isAvailable = widget.source.isAvailable
        completedToday = { widget.completedToday }
        toggle = { widget.toggle($0) }
        isDone = { widget.justCompleted.contains($0.id) }
    }
}

@MainActor @Observable
final class RemindersWidget: TasksWidget<RemindersSource> {
    override class var descriptor: WidgetDescriptor {
        WidgetDescriptor(
            id: "reminders", name: "Reminders", icon: "checklist",
            sizes: [.small, .medium, .large], defaultSize: .medium,
            permissions: [.reminders])
    }
}

@MainActor @Observable
final class ThingsWidget: TasksWidget<ThingsSource> {
    override class var descriptor: WidgetDescriptor {
        WidgetDescriptor(
            id: "things", name: "Things", icon: "checkmark.circle",
            sizes: [.small, .medium, .large], defaultSize: .medium,
            permissions: [.automation])
    }
}
