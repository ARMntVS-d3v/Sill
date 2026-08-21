import AppKit
import SwiftUI

// A Mac overview: chip, load, memory, disk, battery, uptime — all in one tile.
// Data is shared with the individual widgets (CPU, memory, network); there's one collector.
@MainActor @Observable
final class SystemWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "system",
        name: "Overview",
        icon: "desktopcomputer",
        sizes: [.small, .medium, .large],
        defaultSize: .medium
    )

    let context: WidgetContext
    var metrics: SystemMetrics { .shared }

    init(context: WidgetContext) {
        self.context = context
        context.schedule(every: .seconds(2)) { SystemMetrics.shared.refresh() }
    }

    func activate() async throws { SystemMetrics.shared.refresh() }

    var body: AnyView {
        AnyView(SystemTileView(widget: self, size: context.tileSize))
    }

    // Click opens "About This Mac"
    func primaryAction() -> Bool {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications/About This Mac.app"))
        return true
    }
}
