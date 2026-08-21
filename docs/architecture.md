# Sill architecture

The contracts that are expensive to change. Everything else (layout, shell, animations) is cheap and not pinned down here.

## Panel shell: NSStatusItem + NSPanel

MenuBarExtra(.window) was tested in a live spike (macOS 26.5, Xcode 26.3) and rejected:
- The SDK has no programmatic open/close (only `isInserted` — icon presence) → global hotkey and ⌘K are impossible
- The panel closes on any HID click outside it, with no way to disable → "pin" and the file shelf (drag from Finder) are impossible
- Position is not controllable: with the icon hidden by a menu bar manager, the panel opened off-screen (x=-9703)
- What does work: it holds a 420×700 size, becomes the key window; deactivating the app without a click does not close it

Replacement: `NSStatusItem` (manual, `NSStatusBar.system`) + `SillPanel: NSPanel` with `styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless]`, content in an `NSHostingView`. This gives: show/hide from code (hotkey), pin (ignore resignKey), positioning centered under the notch, key input without activating the app (doesn't steal focus). Click-outside-to-close is our own global `NSEvent.addGlobalMonitorForEvents`, installed on show, removed on hide.

The primary gesture is a click on the notch area (`NotchTrigger`): an NSPanel trap over the cutout (geometry from `safeAreaInsets` + `auxiliaryTop*Area`), level popUpMenu+1 (above the panel — toggle keeps working while the panel is open), an opaque black layer (otherwise clicks pass straight through), an override of `constrainFrameRect` (otherwise AppKit pushes the window out of the menu bar zone; the panel needs it too — it covers the menu bar zone). The panel is a Dynamic Island: flush with the top edge of the screen, notch inside it; animated via the content (scale from the notch rectangle, anchor top), the window itself is static.

## Widget protocol

One widget = one Swift file + one line in the registry. All contracts are `@MainActor`; the widget fetches its own data asynchronously.

```swift
struct WidgetDescriptor: Sendable {
    let id: String                      // stable, Latin ("currency"); key in config and cache
    let name: LocalizedStringResource
    let icon: String                    // SF Symbol
    let sizes: [TileSize]               // supported sizes
    let defaultSize: TileSize
    let permissions: [PermissionKind]   // [] if none needed; onboarding is built from this
}

enum TileSize: String, Codable, Sendable, CaseIterable { case s1x1, s2x1, s2x2, s4x2 }
enum PermissionKind: String, Codable, Sendable {
    case calendar, reminders, contacts, automation, accessibility, microphone, screenRecording
}

@MainActor
protocol Widget: AnyObject {
    static var descriptor: WidgetDescriptor { get }
    init(context: WidgetContext)
    var body: AnyView { get }               // tile view; takes colors only from context.theme
    func activate() async throws             // woke up: panel visible AND board active
    func deactivate()                        // went to sleep: remove subscriptions, stop timers
    func refresh() async throws              // one data update; on error the shell shows a badge
    @discardableResult
    func primaryAction() -> Bool             // tile click; true = navigated away from the panel, shell will close it
    var settingsBody: AnyView? { get }       // nil = no settings
}
extension Widget {  // a minimal widget implements only descriptor + body
    func activate() async throws { try await refresh() }
    func deactivate() {}
    func refresh() async throws {}
    func primaryAction() -> Bool { false }   // by default a click does nothing and doesn't close the panel
    var settingsBody: AnyView? { nil }
}
```

An instance is created lazily on first tile display and lives until the end of the session (keeps its data in memory — reopening the panel is instant). One instance per tile: two "clock" tiles = two instances.

## Widget context

A widget knows only its context, not the shell. Sidebar → tab bar swaps without touching widgets.

```swift
@MainActor @Observable
final class WidgetContext {
    private(set) var tileSize: TileSize      // shell updates it when the tile is resized
    private(set) var isPanelVisible: Bool    // false → the widget must sleep
    private(set) var isBoardActive: Bool     // its board is on screen
    private(set) var isFocused: Bool         // keyboard focus is on the tile
    private(set) var theme: Theme            // tokens; hardcoded color in a widget = review error
    let tileID: UUID                         // id of its own tile: per-instance data keys in the cache
    let settings: WidgetSettings             // instance settings, keys widget.<id>.<tileID>. in UserDefaults
    let cache: WidgetCache                   // on-disk JSON cache, namespace = widget id (shared across tiles)
    let secrets: SecretsStore                // API keys and tokens: Keychain, not UserDefaults and not the config
    func log(_ message: String)              // widget log, visible in debugging
    func schedule(every interval: Duration, _ tick: @escaping () async -> Void)  // the only legal timer
}
```

- `schedule` runs only while the widget is active; on deactivate the shell stops everything itself. Rolling your own Timer/Task.sleep for periodic work is a review error: this is the only mechanism through which the framework guarantees "0% in the background"
- A one-off operation in response to a user action (model request, script run, conversion) is a legal self-made Task: it is finite and not periodic. The 10 s timeout does not apply to it. When the panel closes it may finish and put its result into the cache, but must not spawn new periodic work
- A timer only where there is no system notification. Where there is one (EventKit, NSWorkspace, NSNotificationCenter) — subscribe in activate(), unsubscribe in deactivate()
- awake == isPanelVisible && isBoardActive; transitions trigger activate()/deactivate(), the widget does not watch the flags itself

## Lifecycle

1. App launch: only the NSStatusItem. The panel is not created, the config is not read, not a single timer. Idle = 0% CPU
2. First panel open: config → active board → create widget instances → render from cache immediately (no spinner) → activate() each in its own `Task` with a 10 s timeout
3. Panel close: deactivate() everyone, cancel all Tasks, remove subscriptions. Instances and data stay in memory
4. Board switch: deactivate() the outgoing, activate() the incoming
5. refresh() error: the tile shows the last data + an error badge (drawn by the shell, not the widget), the message goes to the widget log
6. Missing permission: the shell checks descriptor.permissions against the access status and draws a "grant access" placeholder instead of body. A widget with an ungranted permission is not activate()-d
7. Isolation: refresh() runs off main (data lives in async functions), main only renders. The timeout cancels a hung Task; a failing (throws) widget does not touch its neighbors. There is no protection against a crash in body — the rule: body with no force unwraps and no blocking calls

## Data layer

```swift
@MainActor
final class WidgetCache {  // namespace = widget id, file ~/Library/Application Support/Sill/cache/<id>.json
    func load<T: Codable>(_ key: String, as: T.Type) -> T?   // from memory, synchronously; disk is read once
    func save<T: Codable>(_ key: String, _ value: T)          // memory immediately, disk asynchronously
}
```

- The cache survives relaunch → offline fallback for network widgets (currencies) comes for free
- TTL'd values are checked by the widget itself (stores a timestamp next to the data)
- Per-instance data (each script-widget tile's own output, its own chat history) — keys prefixed with `context.tileID`
- UserDefaults — settings only, never data; secrets — only `context.secrets` (Keychain, service `app.sill.widget.<id>`)

```swift
@MainActor
final class SecretsStore {   // Keychain generic password, account = key
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func delete(_ key: String)
}
```

## Registry

```swift
enum WidgetRegistry {
    static let all: [any Widget.Type] = [
        ClockWidget.self,
        // ← add your widget: one file in Widgets/ + this line
    ]
    static func type(for id: String) -> (any Widget.Type)?
}
```

A tile with an unknown id (the widget was removed) renders as a placeholder; the config doesn't break.

## Data model

```swift
struct AppConfig: Codable { var version: Int; var boards: [Board]; var activeBoardID: Board.ID }
struct Board: Codable, Identifiable {
    var id: UUID; var name: String; var icon: String
    var themeName: String?              // nil = app-wide theme
    var tiles: [Tile]
}
struct Tile: Codable, Identifiable {
    var id: UUID                        // key for instance settings
    var widgetID: String                // reference into the registry
    var size: TileSize
    var origin: GridPoint               // grid column/row; a tile row = 1 unit, board width in units is a setting
}
```

- Storage: `~/.config/sill/config.json`, read on first panel open, written atomically with a debounce
- Board export = its `Board` as a JSON file; import generates new UUIDs. Same format for the config gallery
- `version` + migrations on read; unknown fields are not lost (lenient decoding)

## Theme engine

```swift
struct Theme: Codable, Sendable {
    // colors are hex strings in JSON, Color in code
    var panelBackground, tileBackground, tileHover: ThemeColor
    var textPrimary, textSecondary, textMuted: ThemeColor
    var accent, success, warning, error: ThemeColor
    var border, shadow: ThemeColor
    var cornerRadius: Double; var borderWidth: Double
}
```

- Built-in themes are JSON in the bundle (Resources/Themes/*.json), same format as user themes
- User themes: `~/.config/sill/themes/*.json`, file name = theme name, overrides a built-in with the same name
- Hot-reload: DispatchSource on the themes directory (event-driven, no ticking); a theme parse error → log + stay on the previous one
- Access: `@Environment(\.theme)` for shell views; widgets get `context.theme` (same value). The panel sits on an NSVisualEffectView, panelBackground on top with transparency
- The "system" theme is generated in code from the system accent color, not JSON

## Contract check against complex widgets

The script widget and the AI chat must fit the common protocol; an exception = a protocol bug.

Script widget: command/interval/shell — settings; periodic work — schedule; execution — Process in refresh()
or on a button press; tile output — cache keyed by tileID (instances don't collide). It must kill the
Process when its Task is cancelled (timeout/deactivate), otherwise a zombie outlives the widget's sleep.

AI chat: a request is a one-off Task on user action (a stream longer than 10 s is legal);
history — cache by tileID; prompt buttons — settings (a Codable array); provider keys — secrets;
voice/OCR — permissions .microphone/.screenRecording. Text input in the panel works:
NSPanel canBecomeKey (verified by spike). A "dedicated board" is a regular board; the board model has no special cases.

## Folder structure

```
Sill/
  project.yml               # xcodegen; build: xcodegen && xcodebuild
  App/                      # SillApp, AppDelegate, PanelController (NSStatusItem+NSPanel), hotkey
  Core/                     # Widget.swift, WidgetContext, WidgetRegistry, WidgetCache,
                            # AppConfig, ThemeEngine — the contracts from this file
  Shell/                    # PanelRootView, Sidebar, BoardGridView, TileView (chrome: error/permission/focus)
  Widgets/
    Clock/ClockWidget.swift # one directory (usually one file) per widget
  Resources/Themes/*.json
  docs/
```

Dependencies: App → Shell → Core and Widgets → Core. Widgets don't see Shell; Shell doesn't see concrete widgets (only the registry).
