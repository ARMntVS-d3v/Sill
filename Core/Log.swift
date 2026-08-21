import OSLog

// Single logging entry point. The name is deliberately unusual: a plain `log`
// collides with `WidgetContext.log`, and calls inside it recursed into themselves,
// crashing the app with a stack overflow. print() doesn't work here — the app launches
// via LaunchServices (otherwise TCC permissions go to the terminal instead, see Makefile),
// and stdout goes nowhere. Logger output shows up in the system log: `make logs`.
private let sillLogger = Logger(subsystem: "app.sill.Sill", category: "app")

func sillLog(_ message: String) {
    sillLogger.notice("\(message, privacy: .public)")
}
