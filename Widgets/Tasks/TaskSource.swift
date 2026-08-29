import AppKit
import EventKit
import Foundation
import os

// One task — shared shape for Reminders and Things
struct TaskItem: Identifiable, Sendable, Codable {
    let id: String
    let title: String
    let due: Date?
    let isFlagged: Bool
    let listName: String?
    let colorHex: String?

    var isOverdue: Bool {
        guard let due else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    var isToday: Bool {
        guard let due else { return false }
        return Calendar.current.isDateInToday(due)
    }
}

// Task source: Apple Reminders or Things. The widget only knows this protocol
@MainActor
protocol TaskSource: AnyObject {
    init()
    static var appName: String { get }
    static var permission: PermissionKind { get }
    var isAvailable: Bool { get }
    /// Whether reading right now is allowed. Things says no while the app
    /// isn't running: scripting a closed app launches it, and we never open
    /// an app nobody asked for (same rule that removed "play" in empty music)
    var isReady: Bool { get }
    func load() async throws -> [TaskItem]
    /// Whether the change actually landed. Showing a checkmark for a write
    /// that silently failed meant the row came back unchecked six seconds later
    func setCompleted(id: String, _ value: Bool) async -> Bool
    func openApp()
}

extension TaskSource {
    var isReady: Bool { true }
}

// MARK: - Apple Reminders

@MainActor
final class RemindersSource: TaskSource {
    static let appName = String(localized: "Reminders")
    static let permission: PermissionKind = .reminders

    private var store: EKEventStore { CalendarAccess.store }
    var isAvailable: Bool { true }

    func load() async throws -> [TaskItem] {
        // One request per app: two Reminders tiles would otherwise each prompt for access
        let status = await CalendarAccess.ensure(.reminder, store: store)
        guard status == .fullAccess else {
            throw WidgetError.permissionDenied(.reminders)
        }

        // Only today's and overdue reminders — matches the app's own "Today" list
        let endOfToday = Calendar.current.date(
            byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: endOfToday, calendars: nil)
        // The EventKit callback arrives on its own background queue. Conversion is
        // moved into a nonisolated function — otherwise the runtime treats the
        // closure as main-actor-isolated and crashes on the isolation check.
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: RemindersSource.convert(reminders ?? []))
            }
        }
    }

    nonisolated static func convert(_ reminders: [EKReminder]) -> [TaskItem] {
        Array(
            reminders
                .sorted { lhs, rhs in
                    switch (lhs.dueDateComponents?.date, rhs.dueDateComponents?.date) {
                    case let (l?, r?): l < r
                    case (nil, _?): false
                    case (_?, nil): true
                    default: lhs.priority < rhs.priority
                    }
                }
                .prefix(30)
                .map { reminder in
                    TaskItem(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? String(localized: "Untitled"),
                        due: reminder.dueDateComponents?.date,
                        isFlagged: reminder.priority > 0 && reminder.priority <= 4,
                        listName: reminder.calendar?.title,
                        colorHex: reminder.calendar?.cgColor.flatMap(hex))
                })
    }

    func setCompleted(id: String, _ value: Bool) async -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            sillLog("[tasks] reminder \(id) not found — access revoked?")
            return false
        }
        reminder.isCompleted = value
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            sillLog("[tasks] saving reminder failed: \(error)")
            return false
        }
    }

    func openApp() {
        if let url = URL(string: "x-apple-reminderkit://") { NSWorkspace.shared.open(url) }
    }

    nonisolated private static func hex(_ color: CGColor) -> String? {
        guard let c = color.components, c.count >= 3 else { return nil }
        return String(
            format: "#%02x%02x%02x",
            Int((c[0] * 255).rounded()), Int((c[1] * 255).rounded()), Int((c[2] * 255).rounded()))
    }
}

// MARK: - Things 3

// Read via AppleScript: Things has no public framework, but a full scripting
// dictionary. Lists are fetched by id (TMTodayListSource), not by name —
// names are localized.
@MainActor
final class ThingsSource: TaskSource {
    static let appName = String(localized: "Things")
    static let permission: PermissionKind = .automation

    // Result shared across all tiles: two Things tiles on the board are two
    // instances of this source, and concurrent requests to the app return
    // nothing. Reuse a fresh result so only one request is in flight.
    private static var cache: (date: Date, items: [TaskItem])?
    private static var inFlight: Task<[TaskItem], Error>?
    private static let freshness: TimeInterval = 5

    private static let bundleID = "com.culturedcode.ThingsMac"

    var isAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    /// `tell application` launches a closed app — reading must wait for Things
    /// to be running, or the widget silently starts it in the background
    var isReady: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func load() async throws -> [TaskItem] {
        guard isAvailable else { return [] }
        if let cache = Self.cache, Date().timeIntervalSince(cache.date) < Self.freshness {
            return cache.items
        }
        if let existing = Self.inFlight { return try await existing.value }
        let task = Task { try await Self.fetch() }
        Self.inFlight = task
        defer { Self.inFlight = nil }
        let items = try await task.value
        Self.cache = (Date(), items)
        return items
    }

    /// AppleScript's «class isot» prints local wall-clock time WITHOUT a timezone
    /// designator ("2026-08-20T20:07:54"). ISO8601DateFormatter refuses such
    /// strings, so every Things due date parsed to nil — overdue and today
    /// badges never fired. Parse as local time instead
    private static let dueFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()

    private static func dueDate(from raw: String) -> Date? {
        dueFormatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func fetch() async throws -> [TaskItem] {
        let script = """
        tell application "Things3"
            set out to ""
            repeat with t in to dos of list id "TMTodayListSource"
                set dd to ""
                try
                    set dd to (due date of t) as «class isot» as string
                end try
                set tagList to ""
                try
                    set tagList to tag names of t
                end try
                set pj to ""
                try
                    set pj to name of project of t
                end try
                set out to out & (id of t) & tab & (name of t) & tab & dd & tab & tagList & tab & pj & linefeed
            end repeat
            return out
        end tell
        """
        let output = try await run(script)
        return output
            .split(separator: "\n")
            .compactMap { line -> TaskItem? in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2, !parts[0].isEmpty else { return nil }
                let due = parts.count > 2 ? Self.dueDate(from: parts[2]) : nil
                let tags = parts.count > 3 ? parts[3] : ""
                let project = parts.count > 4 ? parts[4] : ""
                return TaskItem(
                    id: parts[0],
                    title: parts[1],
                    due: due,
                    // "важно" kept alongside English: tag names are user data,
                    // and Russian-language Things setups use it
                    isFlagged: tags.localizedCaseInsensitiveContains("important")
                        || tags.localizedCaseInsensitiveContains("flag")
                        || tags.localizedCaseInsensitiveContains("важно"),
                    listName: project.isEmpty ? nil : project,
                    colorHex: nil)
            }
    }

    func setCompleted(id: String, _ value: Bool) async -> Bool {
        let script = """
        tell application "Things3"
            set status of to do id "\(id)" to \(value ? "completed" : "open")
        end tell
        """
        do {
            _ = try await Self.run(script)
            Self.cache = nil
            return true
        } catch {
            sillLog("[things] setting status failed: \(error)")
            return false
        }
    }

    func openApp() {
        if let url = URL(string: "things:///show?id=today") { NSWorkspace.shared.open(url) }
    }

    enum ThingsError: Error {
        case script(Int)
        case timedOut
    }

    /// How long a script may take before the widget gives up on it. The hung
    /// call itself can't be cancelled (NSAppleScript is synchronous), but the
    /// await must not hang with it: one stuck Things call used to freeze the
    /// source — and the shared inFlight task with it — until app restart
    private static let scriptTimeout: TimeInterval = 10

    // AppleScript is synchronous and slow — keep it off the main thread.
    // A task group can't race it against a deadline: the group waits for the
    // uncancellable child, so the timeout is done with a resume-once lock
    private static func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<String, Error>) -> Void = { result in
                let first = once.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(with: result) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    // -1743: user has not granted permission to control the app
                    if code == -1743 {
                        finish(.failure(WidgetError.permissionDenied(.automation)))
                    } else {
                        // Any other error is an error, not an empty task list:
                        // "" used to decode into [] and the tile said "All done"
                        finish(.failure(ThingsError.script(code)))
                    }
                    return
                }
                finish(.success(result?.stringValue ?? ""))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.scriptTimeout) {
                finish(.failure(ThingsError.timedOut))
            }
        }
    }
}
