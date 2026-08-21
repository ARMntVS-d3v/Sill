#if DEBUG
import AppKit
import EventKit
import Foundation

// Fills a separate "Sill Test" calendar with events for today — edge cases for
// checking layout. Run with SILL_SEED=1. Removed entirely along with the
// calendar: Calendar.app → right-click "Sill Test" → Delete.
enum DebugSeed {
    static let prefix = "Sill Test"

    // Several calendars in different colors: check how dots and the timeline read
    private static let palette: [(key: String, title: String, color: NSColor)] = [
        ("work", "Sill Test · Work", .systemBlue),
        ("personal", "Sill Test · Personal", .systemOrange),
        ("sport", "Sill Test · Sport", .systemGreen),
        ("dates", "Sill Test · Dates", .systemPurple),
        ("night", "Sill Test · Night", .systemRed),
    ]

    static func run() async {
        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            do {
                guard try await store.requestFullAccessToEvents() else {
                    sillLog("[seed] no calendar access")
                    return
                }
            } catch {
                sillLog("[seed] access error: \(error)")
                return
            }
        }

        guard let source = localSource(in: store) else {
            sillLog("[seed] no local calendar source")
            return
        }

        // A separate calendar per color; reuse and clear existing ones
        var calendars: [String: EKCalendar] = [:]
        for entry in palette {
            let calendar: EKCalendar
            if let existing = store.calendars(for: .event).first(where: { $0.title == entry.title }) {
                calendar = existing
                removeTodayEvents(in: calendar, store: store)
            } else {
                calendar = EKCalendar(for: .event, eventStore: store)
                calendar.title = entry.title
                calendar.source = source
                do { try store.saveCalendar(calendar, commit: true) } catch {
                    sillLog("[seed] couldn't create \"\(entry.title)\": \(error)")
                    continue
                }
            }
            calendar.cgColor = entry.color.cgColor
            try? store.saveCalendar(calendar, commit: true)
            calendars[entry.key] = calendar
        }
        // Previous seeder version's calendar — clear it so events don't duplicate
        if let old = store.calendars(for: .event).first(where: { $0.title == prefix }) {
            removeTodayEvents(in: old, store: store)
        }

        var created = 0
        for sample in samples() {
            guard let calendar = calendars[sample.calendarKey] else { continue }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = sample.title
            event.startDate = sample.start
            event.endDate = sample.end
            event.isAllDay = sample.allDay
            event.location = sample.location
            event.notes = sample.notes
            if let urlString = sample.url { event.url = URL(string: urlString) }
            do {
                try store.save(event, span: .thisEvent, commit: false)
                created += 1
            } catch {
                sillLog("[seed] \"\(sample.title)\" didn't save: \(error)")
            }
        }
        try? store.commit()
        sillLog("[seed] calendars: \(calendars.count), events added: \(created)")
    }

    private static func localSource(in store: EKEventStore) -> EKSource? {
        store.sources.first { $0.sourceType == .local }
            ?? store.sources.first { $0.sourceType == .calDAV && $0.title == "iCloud" }
            ?? store.defaultCalendarForNewEvents?.source
    }

    private static func removeTodayEvents(in calendar: EKCalendar, store: EKEventStore) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        for event in store.events(matching: predicate) {
            try? store.remove(event, span: .thisEvent, commit: false)
        }
        try? store.commit()
    }

    private struct Sample {
        let calendarKey: String
        let title: String
        let start: Date
        let end: Date
        var allDay = false
        var location: String?
        var notes: String?
        var url: String?
    }

    // Edge cases: long text, emoji, empty title, "all day", overlaps, events
    // outside the 8:00–22:00 timeline, very short and very long
    private static func samples() -> [Sample] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(byAdding: DateComponents(hour: hour, minute: minute), to: day) ?? day
        }

        let now = Date()
        return [
            // Happening right now, with a location and meeting link — checks the details row
            Sample(
                calendarKey: "work",
                title: "Sill design review",
                start: min(at(8, 30), now.addingTimeInterval(-20 * 60)),
                end: now.addingTimeInterval(40 * 60),
                location: "Corner café, Main St 15",
                notes: "Discuss calendar tiles",
                url: "https://meet.google.com/xyz-abcd-efg"),
            Sample(
                calendarKey: "dates",
                title: "Maria's birthday",
                start: day, end: cal.date(byAdding: .day, value: 1, to: day) ?? day,
                allDay: true),
            Sample(
                calendarKey: "sport",
                title: "Early morning run in the park",
                start: at(6, 15), end: at(7),
                location: "Central Park, main entrance"),
            Sample(
                calendarKey: "work",
                title: "Standup",
                start: at(9, 45), end: at(10),
                location: "Zoom",
                notes: "Five-minute status update",
                url: "https://zoom.us/j/9876543210"),
            Sample(
                calendarKey: "work",
                title: "Sign-off on the technical spec for the account dashboard and mobile app redesign",
                start: at(10, 30), end: at(13, 30),
                location: "Large conference room on the seventh floor, entrance from Elm Street, building 12",
                notes: "Bring printouts, discuss timeline, agree on Q2 budget"),
            Sample(
                calendarKey: "personal",
                title: "🍜 Lunch",
                start: at(13), end: at(14),
                location: "Noodle place"),
            Sample(
                calendarKey: "personal",
                title: "",
                start: at(14, 20), end: at(14, 35)),
            Sample(
                calendarKey: "work",
                title: "Call with contractor",
                start: at(15), end: at(16),
                notes: "Meeting link: https://meet.google.com/abc-defg-hij — join from your own account"),
            Sample(
                calendarKey: "work",
                title: "Overlapping meeting",
                start: at(15, 30), end: at(16, 30),
                location: "Telegram"),
            Sample(
                calendarKey: "personal",
                title: "Pick up package",
                start: at(17, 30), end: at(17, 40),
                location: "Post office"),
            Sample(
                calendarKey: "sport",
                title: "Workout",
                start: at(19, 30), end: at(21)),
            Sample(
                calendarKey: "night",
                title: "Late call with California",
                start: at(23), end: at(23, 45),
                url: "https://teams.microsoft.com/l/meetup-join/xyz"),
        ]
    }
}
#endif
