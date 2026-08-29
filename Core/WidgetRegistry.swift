import Foundation

enum WidgetRegistry {
    @MainActor
    static let all: [any Widget.Type] = [
        CalendarWidget.self,
        RemindersWidget.self,
        ThingsWidget.self,
        WeatherWidget.self,
        MusicWidget.self,
        SystemWidget.self,
        CpuWidget.self,
        MemoryWidget.self,
        GpuWidget.self,
        NetworkWidget.self,
        DiskWidget.self,
        BatteryWidget.self,
        TimerWidget.self,
        PomodoroWidget.self,
        ScratchpadWidget.self,
        CurrencyWidget.self,
        ConverterWidget.self,
        ShelfWidget.self,
        TranslateWidget.self,
        // ← add your widget here: one file in Widgets/ + this line
    ]

    @MainActor
    static func type(for id: String) -> (any Widget.Type)? {
        all.first { $0.descriptor.id == id }
    }
}
