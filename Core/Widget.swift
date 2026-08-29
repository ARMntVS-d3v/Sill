import EventKit
import SwiftUI

// Three sizes, like Apple: square, rectangle (two squares), large square (four).
enum TileSize: String, Codable, Sendable, CaseIterable {
    case small, medium, large

    var columns: Int { self == .small ? 1 : 2 }
    var rows: Int { self == .large ? 2 : 1 }

    var label: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        }
    }

    var width: CGFloat { CGFloat(columns) * GridMetrics.unit + CGFloat(columns - 1) * GridMetrics.gap }
    var height: CGFloat { CGFloat(rows) * GridMetrics.unit + CGFloat(rows - 1) * GridMetrics.gap }
}

// The grid resolves by construction: L = 2×2 S, M = 2×1 S.
enum GridMetrics {
    static let unit: CGFloat = 152
    static let gap: CGFloat = 12
    static let columns = 4
    static let rows = 2
    static let padding: CGFloat = 22
    static let bottomPadding: CGFloat = 22
    static let wingsHeight: CGFloat = 38
    /// Gap between the top row and the grid. Zero: the wings row already has
    /// breathing room built in (38 for 26 of content — 6 on each side), and
    /// an extra 12 pushed the board lower than it's ever sat. The edit-mode
    /// close button no longer bumps into this gap — it sits flush with the
    /// tile's top edge
    static let topGap: CGFloat = 0

    static var contentWidth: CGFloat {
        CGFloat(columns) * unit + CGFloat(columns - 1) * gap
    }
    static var contentHeight: CGFloat {
        CGFloat(rows) * unit + CGFloat(rows - 1) * gap
    }
    /// Height of the "Ask" bar plus its gap — zero when it's off
    static let askBar: CGFloat = 36
    static let askGap: CGFloat = 8

    @MainActor static var askBarHeight: CGFloat {
        AppSettings.shared.askBar ? askBar + askGap : 0
    }

    @MainActor static var islandSize: CGSize {
        CGSize(
            width: contentWidth + padding * 2,
            height: wingsHeight + askBarHeight + topGap + contentHeight + bottomPadding)
    }
}

enum PermissionKind: String, Codable, Sendable {
    case calendar, calendarLimited, reminders, contacts, automation, accessibility, microphone, screenRecording

    var title: String {
        switch self {
        case .calendar: String(localized: "Calendar access needed")
        // Permission granted, but write-only: events can't be read with it
        case .calendarLimited: String(localized: "Calendar access is add-only")
        case .reminders: String(localized: "Reminders access needed")
        case .contacts: String(localized: "Contacts access needed")
        case .automation: String(localized: "App automation permission needed")
        case .accessibility: String(localized: "Accessibility access needed")
        case .microphone: String(localized: "Microphone access needed")
        case .screenRecording: String(localized: "Screen recording access needed")
        }
    }

    /// Whether the system prompt can still be shown. While status is
    /// notDetermined — yes; after the person answers, access level only
    /// changes in Settings
    @MainActor var canAsk: Bool {
        switch self {
        case .calendar, .calendarLimited: CalendarAccess.canAsk(.event)
        case .reminders: CalendarAccess.canAsk(.reminder)
        default: true
        }
    }

    // System Settings pane the placeholder's button links to
    var settingsURL: URL? {
        let anchor = switch self {
        case .calendar, .calendarLimited: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .contacts: "Privacy_Contacts"
        case .automation: "Privacy_Automation"
        case .accessibility: "Privacy_Accessibility"
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

struct WidgetDescriptor: Sendable {
    let id: String
    let name: LocalizedStringResource
    let icon: String
    let sizes: [TileSize]
    let defaultSize: TileSize
    let permissions: [PermissionKind]

    init(
        id: String,
        name: LocalizedStringResource,
        icon: String,
        sizes: [TileSize],
        defaultSize: TileSize,
        permissions: [PermissionKind] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.sizes = sizes
        self.defaultSize = defaultSize
        self.permissions = permissions
    }
}

// A widget signals missing access; the shell draws the placeholder
enum WidgetError: Error {
    case permissionDenied(PermissionKind)
}

@MainActor
protocol Widget: AnyObject {
    static var descriptor: WidgetDescriptor { get }
    init(context: WidgetContext)
    var body: AnyView { get }
    func activate() async throws
    func deactivate()
    func refresh() async throws
    var settingsBody: AnyView? { get }
    // Tap on a tile outside edit mode: open the native app, show details.
    // Returns true if the tap actually took the person out of the panel —
    // the shell then closes it. A widget that handles everything in its own
    // tile (translator, note, shelf, currency) returns false and the panel
    // stays open: otherwise a miss-tap would close it for nothing
    @discardableResult
    func primaryAction() -> Bool
    /// The tile is being removed from the board: clear anything that outlives
    /// the instance — published island state, file copies on disk, per-tile
    /// cache entries. Without this a running timer kept ringing at the notch
    /// after its tile was deleted. Instance settings need no clearing here:
    /// the shell removes them right after this hook
    func tileWillRemove()
}

extension Widget {
    func activate() async throws { try await refresh() }
    func deactivate() {}
    func refresh() async throws {}
    var settingsBody: AnyView? { nil }
    func primaryAction() -> Bool { false }
    func tileWillRemove() {}
}
