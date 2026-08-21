import SwiftUI

// Battery at the notch behaves like a notification, not an indicator: it shows
// on an event — plugged in, unplugged, charge dropped below twenty — and goes
// away a few seconds later. A permanently visible percentage isn't useful here:
// it's already in the menu bar.
@MainActor
enum BatteryActivity {
    static let id = "battery"
    /// Warning thresholds — same as macOS: twenty and ten percent
    private static let thresholds = [20, 10]
    /// How long the capsule stays up after an event
    private static let showTime: TimeInterval = 5

    private static var lastPlugged: Bool?
    /// Charge at the last check. nil on purpose, not 100: this used to be a
    /// "was low" flag starting from false, so an app launched at 17% would show
    /// the warning immediately even though the threshold was crossed long before launch
    private static var lastPercent: Int?
    private static var hideAt: Date?

    static func refresh() {
        guard AppSettings.shared.batteryInNotch, let battery = SystemProbe.batteryDetails() else {
            LiveActivityCenter.shared.clear(id)
            return
        }

        var event: (icon: String, value: String, tint: Color, priority: Int)?

        // Power source switched — that's the event
        if let lastPlugged, lastPlugged != battery.plugged {
            event = battery.plugged
                ? ("battery.100.bolt", "\(battery.percent)%", .green, 12)
                : (BatteryWidget.icon(for: battery), "\(battery.percent)%", .white, 12)
        }
        lastPlugged = battery.plugged

        // A threshold only counts as crossed if we've actually seen the charge
        // above it. The warning is about the event "charge just dropped", not the fact "it's low"
        if let previous = lastPercent, !battery.plugged,
           let crossed = Self.thresholds.first(where: { previous > $0 && battery.percent <= $0 }) {
            _ = crossed
            event = (BatteryWidget.icon(for: battery), "\(battery.percent)%", .red, 30)
        }
        lastPercent = battery.percent

        if let event {
            hideAt = Date().addingTimeInterval(showTime)
            LiveActivityCenter.shared.update(
                LiveActivity(
                    id: id,
                    icon: event.icon,
                    value: event.value,
                    tint: event.tint,
                    priority: event.priority))
            return
        }

        // Display time is up — clear it
        if let deadline = hideAt, Date() >= deadline {
            hideAt = nil
            LiveActivityCenter.shared.clear(id)
        }
    }

    #if DEBUG
    /// Dev trigger (kill -INFO): the capsule behaves exactly as if the charger
    /// were plugged in, just shorter. Otherwise there's no way to test the charging animation without a cable
    static func debugShow() {
        hideAt = Date().addingTimeInterval(3)
        let percent = SystemProbe.batteryDetails()?.percent ?? 100
        LiveActivityCenter.shared.update(
            LiveActivity(
                id: id, icon: "battery.100.bolt", value: "\(percent)%",
                tint: .green, priority: 12))
    }
    #endif
}
