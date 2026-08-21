import EventKit
import SwiftUI

@MainActor @Observable
final class CalendarWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "calendar",
        name: "Calendar",
        icon: "calendar",
        sizes: [.small, .medium, .large],
        defaultSize: .medium,
        permissions: [.calendar]
    )

    struct Event: Identifiable, Sendable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let colorHex: String
        let location: String?
        let joinURL: URL?
        // Video call (Zoom, Meet, Teams…) vs. a plain link — different icons
        let isMeetingLink: Bool

        var isNow: Bool { Date() >= start && Date() < end }
        var isPast: Bool { end <= Date() }
    }

    private let context: WidgetContext
    private var store: EKEventStore { CalendarAccess.store }
    @ObservationIgnored private var storeObserver: NSObjectProtocol?

    private(set) var events: [Event] = []
    // Minute tick keeps "in how long" and the "now" label alive while the panel is open
    private(set) var now = Date()
    @ObservationIgnored private var hasAccess = false
    @ObservationIgnored private var lastStatus: EKAuthorizationStatus?

    init(context: WidgetContext) {
        self.context = context
        events = context.cache.load("today", as: [CachedEvent].self)?.map(\.event) ?? []
        context.schedule(every: .seconds(30)) { [weak self] in
            self?.now = Date()
        }
        // Access is granted in System Settings, and the system sends no
        // notification about it: while we don't have it, poll status every
        // 2 s so the tile wakes up without a restart
        context.schedule(every: .seconds(2)) { [weak self] in
            self?.pollAccess()
        }
    }

    func activate() async throws {
        #if DEBUG
        // SILL_DEMO=1 — sample events for checking layout and screenshots.
        // The user's calendar is neither read nor touched.
        if ProcessInfo.processInfo.environment["SILL_DEMO"] == "1" {
            events = Self.demoEvents()
            return
        }
        // SILL_EMPTY=1 — preview the empty state without touching the calendar
        if ProcessInfo.processInfo.environment["SILL_EMPTY"] == "1" {
            events = []
            return
        }
        #endif
        // One request for the whole app: three calendar tiles on the board used
        // to each ask for access, and the system stacked the prompt window on
        // top of itself. At writeOnly we don't show the prompt at all — it
        // can't raise the access level, only the user can in System Settings,
        // and a prompt on every launch is maddening
        let status = await CalendarAccess.ensure(.event, store: store)
        guard status == .fullAccess else {
            hasAccess = false
            context.log("no full access, status \(status.rawValue)")
            throw WidgetError.permissionDenied(status == .writeOnly ? .calendarLimited : .calendar)
        }
        hasAccess = true
        if storeObserver == nil {
            // System notification instead of polling — required by docs/sill.md
            storeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in try? await self?.refresh() }
            }
        }
        try await refresh()
    }

    // Calendar status at the last check: react to a transition, not to the value
    private func pollAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        // Wake up only on a status CHANGE. This used to check every tick, and at
        // notDetermined — a status the system no longer prompts on — the tile
        // recreated itself twice a second: an endless widget restart
        guard status != lastStatus else { return }
        context.log("calendar status: \(status.rawValue)")
        lastStatus = status
        // Access appeared — wake up. Access was reset (tccutil reset) — also wake
        // up: status goes back to notDetermined, meaning the system is ready to
        // show the request prompt again
        guard !hasAccess, status == .fullAccess || status == .notDetermined else { return }
        context.requestReactivate?()
    }

    func deactivate() {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
    }

    func refresh() async throws {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 2, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let found = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(24)
            .map { ekEvent -> Event in
                Event(
                    id: ekEvent.eventIdentifier ?? UUID().uuidString,
                    title: (ekEvent.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled"),
                    start: ekEvent.startDate,
                    end: ekEvent.endDate,
                    isAllDay: ekEvent.isAllDay,
                    colorHex: Self.hex(from: ekEvent.calendar?.cgColor),
                    location: ekEvent.location,
                    joinURL: Self.anyURL(in: ekEvent),
                    isMeetingLink: Self.anyURL(in: ekEvent).map(Self.isMeeting) ?? false)
            }
        events = Array(found)
        context.cache.save("today", events.map(CachedEvent.init))
        now = Date()
    }

    var body: AnyView {
        AnyView(CalendarTileView(widget: self, size: context.tileSize))
    }

    // Clicking the tile opens Calendar on today
    func primaryAction() {
        let day = Int(Date().timeIntervalSinceReferenceDate)
        if let url = URL(string: "ical://ekevent/\(day)") {
            NSWorkspace.shared.open(url)
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // Today's events, past ones filtered out except the one happening now
    var todayEvents: [Event] {
        let calendar = Calendar.current
        return events.filter { calendar.isDateInToday($0.start) || $0.isNow }
    }

    var upcoming: Event? {
        events.first { !$0.isPast && !$0.isAllDay } ?? events.first { !$0.isPast }
    }

    // "Tue, Aug 18" — short date for the small tiles' label
    var shortDateText: String {
        now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    // Everything still ahead, including what's happening now
    var upcomingAll: [Event] {
        let calendar = Calendar.current
        return events.filter { !$0.isPast && (calendar.isDateInToday($0.start) || $0.isNow) }
    }

    // What comes after the next event — the column in the medium tile and the
    // list in the large one. "All day" doesn't belong here: it has no time
    // and it breaks the column
    func following(limit: Int) -> [Event] {
        guard let upcoming else { return [] }
        return Array(upcomingAll.filter { $0.id != upcoming.id && !$0.isAllDay }.prefix(limit))
    }

    // Tile list: all-day events first, then the nearest by time.
    // Past events aren't shown at all, struck through or dimmed: the tile
    // answers "what's next", not "how did the day go"
    func listEvents(limit: Int) -> [Event] {
        let allDay = allDayEvents.prefix(max(limit - 1, 1))
        let timed = following(limit: limit - allDay.count)
        return Array(allDay) + timed
    }

    // Events not shown in the list. All-day events are already counted in
    // upcomingAll — adding them separately would count the same thing twice,
    // and the tile said "+1 more" on the line directly above that same event.
    // Minus one — the next event itself, it's shown as its own block
    func hiddenCount(shown: Int) -> Int {
        max(upcomingAll.count - shown - 1, 0)
    }

    var allDayEvents: [Event] {
        let calendar = Calendar.current
        return events.filter { $0.isAllDay && calendar.isDateInToday($0.start) }
    }

    // Timeline bounds: normally 8:00–22:00, but stretch for early and late events
    var timelineRange: ClosedRange<Double> {
        let hours = todayEvents.filter { !$0.isAllDay }.flatMap { [hour(of: $0.start), hour(of: $0.end)] }
        let low = min(hours.min() ?? 8, 8)
        let high = max(hours.max() ?? 22, 22)
        return floor(low)...ceil(high)
    }

    private func hour(of date: Date) -> Double {
        let calendar = Calendar.current
        return Double(calendar.component(.hour, from: date))
            + Double(calendar.component(.minute, from: date)) / 60
    }

    #if DEBUG
    private static func demoEvents() -> [Event] {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: day) ?? day
        }
        return [
            Event(id: "1", title: "Team standup", start: at(9, 30), end: at(10),
                  isAllDay: false, colorHex: "#ff453a", location: "Zoom",
                  joinURL: URL(string: "https://zoom.us/j/123"), isMeetingLink: true),
            Event(id: "2", title: "Design review", start: at(11), end: at(12),
                  isAllDay: false, colorHex: "#0a84ff", location: nil, joinURL: nil, isMeetingLink: false),
            Event(id: "3", title: "Lunch with Sam", start: at(13), end: at(14),
                  isAllDay: false, colorHex: "#ff9f0a", location: "Corner café", joinURL: nil, isMeetingLink: false),
            Event(id: "4", title: "Project sync", start: at(15), end: at(16),
                  isAllDay: false, colorHex: "#bf5af2", location: "Google Meet",
                  joinURL: URL(string: "https://meet.google.com/abc"), isMeetingLink: true),
            Event(id: "5", title: "Pick up package", start: at(17, 30), end: at(18),
                  isAllDay: false, colorHex: "#30d158", location: "Post office", joinURL: nil, isMeetingLink: false),
            Event(id: "6", title: "Gym", start: at(19, 30), end: at(21),
                  isAllDay: false, colorHex: "#64d2ff", location: nil, joinURL: nil, isMeetingLink: false),
        ]
    }
    #endif

    private static func hex(from color: CGColor?) -> String {
        guard let color, let components = color.components, components.count >= 3 else { return "#0a84ff" }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    // Any link on the event: prefer a meeting link, otherwise the first one found.
    // Searched in the URL field, the location, and the notes
    private static func anyURL(in event: EKEvent) -> URL? {
        var found: [URL] = []
        if let url = event.url { found.append(url) }
        let haystack = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        if !haystack.isEmpty {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(haystack.startIndex..., in: haystack)
            found += detector?.matches(in: haystack, range: range).compactMap(\.url) ?? []
        }
        return found.first(where: Self.isMeeting) ?? found.first
    }

    private static func isMeeting(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return ["zoom.us", "meet.google.com", "teams.microsoft.com", "telemost.yandex.ru", "webex.com"]
            .contains { host.contains($0) }
    }
}

// Cache survives a restart: the panel opens with the schedule already in
// place, even before access is granted
private struct CachedEvent: Codable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let colorHex: String
    let location: String?
    let joinURL: URL?
    var isMeetingLink = false

    init(_ event: CalendarWidget.Event) {
        id = event.id
        title = event.title
        start = event.start
        end = event.end
        isAllDay = event.isAllDay
        colorHex = event.colorHex
        location = event.location
        joinURL = event.joinURL
        isMeetingLink = event.isMeetingLink
    }

    var event: CalendarWidget.Event {
        .init(id: id, title: title, start: start, end: end, isAllDay: isAllDay,
              colorHex: colorHex, location: location, joinURL: joinURL,
              isMeetingLink: isMeetingLink)
    }
}
