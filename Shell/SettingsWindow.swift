import AppKit
import SwiftUI

// Settings window in the system's own style: tabs up top, sections as a form, fixed width.
// A separate window rather than a layer in the panel: the panel is 688×374, a dozen
// settings wouldn't fit, and the window opens both via ⌘, and the gear icon.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var appState: AppState?

    private init() {}

    func attach(appState: AppState) {
        self.appState = appState
    }

    /// Above the panel (.popUpMenu = 101) and the notch trap (102) — used only
    /// while the panel is pinned and stays on screen
    private static let abovePanelLevel = NSWindow.Level(
        rawValue: NSWindow.Level.popUpMenu.rawValue + 2)

    /// The panel is opening — an unpinned settings window steps aside. Mirrors the
    /// rule above (settings opens, panel closes): otherwise settings stayed alive
    /// behind the panel and "opened by itself" the moment the panel closed. A pinned
    /// panel keeps settings on top, that's the whole point of pinning
    func hideForPanel() {
        guard appState?.pinned != true, let window, window.isVisible else { return }
        window.orderOut(nil)
    }

    func show() {
        // Settings opens — the panel closes: no need to keep both windows up, and
        // settings only looked like it was overlapping the panel because the
        // panel was covering it. A pinned panel is left alone: pinning means
        // "don't dismiss", and without this check you couldn't pick an
        // appearance while watching the panel — it kept vanishing
        let pinnedPanel = appState?.pinned == true
        if !pinnedPanel { appState?.requestHide?() }
        // With the panel pinned and staying up, a .normal window opens UNDER
        // it (0 against 101) — exactly the scenario pinning exists for. The
        // level is set on every show: pinning changes between opens
        let level: NSWindow.Level = pinnedPanel ? Self.abovePanelLevel : .normal

        if let window {
            window.level = level
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let appState else { return }

        // The theme is read live, not snapshotted at window creation: otherwise
        // picking a theme in Appearance would recolor the panel while the
        // settings window itself stayed in the old colors until relaunch
        let root = SettingsRootView()
            .environment(appState)
            .frame(minWidth: 660, minHeight: 440)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = String(localized: "Sill Settings")
        window.titlebarAppearsTransparent = true
        // The window is dark to match the panel, not system gray
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor.black
        window.isReleasedWhenClosed = false
        // A normal window, like any app's. No need to float it above the panel:
        // instead, the panel leaves the screen when settings opens. The pinned
        // panel is the exception — see `level` above
        window.level = level
        // The window follows the person to whatever desktop they're on: without
        // this it stayed on the space where it was created, and looked like
        // "settings won't open"
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct SettingsRootView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case general, boards, clipboard, model, currency, pomodoro, notch, appearance

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .boards: String(localized: "Boards")
            case .clipboard: String(localized: "Clipboard")
            case .model: String(localized: "Model")
            case .currency: String(localized: "Currencies")
            case .pomodoro: String(localized: "Pomodoro")
            case .notch: String(localized: "Notch")
            case .appearance: String(localized: "Appearance")
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .boards: "square.grid.2x2"
            case .clipboard: "doc.on.clipboard"
            case .model: "sparkles"
            case .currency: "banknote"
            case .pomodoro: "leaf"
            case .notch: "rectangle.topthird.inset.filled"
            case .appearance: "paintpalette"
            }
        }

        // Colored square behind the icon — borrowed from System Settings; it
        // helps spot the section faster than reading the label
        var badge: Color {
            switch self {
            case .general: .gray
            case .boards: Color(red: 0.25, green: 0.5, blue: 0.9)
            case .clipboard: Color(red: 0.3, green: 0.7, blue: 0.45)
            case .model: Color(red: 0.62, green: 0.36, blue: 0.9)
            case .currency: Color(red: 0.2, green: 0.65, blue: 0.4)
            case .pomodoro: Color(red: 0.85, green: 0.3, blue: 0.25)
            case .notch: Color(red: 0.55, green: 0.35, blue: 0.9)
            case .appearance: Color(red: 0.95, green: 0.45, blue: 0.2)
            }
        }
    }

    @State private var selection: Section = .general
    @Environment(AppState.self) private var appState

    /// Read live from app state and passed down: a snapshot taken at window
    /// creation didn't update, and this window would keep showing old colors
    /// after a theme change
    private var theme: Theme { appState.theme }

    // Section sidebar — modeled on System Settings, but in the panel's own colors:
    // this window should read as part of the same app, not a system dialog
    var body: some View {
        content.environment(\.theme, theme)
    }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { section in
                    SidebarRow(
                        title: section.title,
                        icon: section.icon,
                        badge: section.badge,
                        selected: selection == section
                    ) { selection = section }
                }
                Spacer(minLength: 0)
                // Quit lives at the bottom of the sidebar, where menu bar apps
                // usually keep it — not as a settings row: quitting isn't a setting
                QuitRow()
            }
            .padding(.horizontal, 8)
            .padding(.top, 34)
            .padding(.bottom, 10)
            .frame(width: 196, alignment: .topLeading)
            .background(theme.tileBackground.color.opacity(0.5))

            Rectangle()
                .fill(theme.border.color)
                .frame(width: 1)

            ScrollView {
                Group {
                    switch selection {
                    case .general: GeneralSettings()
                    case .boards: BoardSettings()
                    case .clipboard: ClipboardSettings()
                    case .model: ModelSettings()
                    case .currency: CurrencySettings()
                    case .pomodoro: PomodoroSettings()
                    case .notch: NotchSettings()
                    case .appearance: AppearanceSettings()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(theme.panelBackground.color)
        .tint(theme.accent.color)
    }
}

// Quit at the bottom of the sidebar: same row shape as the sections above,
// muted instead of badged — an exit, not a destination
private struct QuitRow: View {
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "power")
                    .font(TileFont.label.weight(.semibold))
                    .foregroundStyle(hovered ? theme.textPrimary.color : theme.textMuted.color)
                    .frame(width: 20, height: 20)
                Text(String(localized: "Quit Sill"))
                    .font(TileFont.row)
                    .foregroundStyle(hovered ? theme.textPrimary.color : theme.textMuted.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: TileMetrics.hitRadius, style: .continuous)
                    .fill(hovered ? theme.tileHover.color.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: Motion.hover), value: hovered)
        .help(String(localized: "The notch click stops working until the next launch"))
    }
}

// Sidebar row: custom-built, not system — colors come from the theme
private struct SidebarRow: View {
    let title: String
    let icon: String
    let badge: Color
    let selected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: TileMetrics.thumbRadius, style: .continuous)
                    .fill(badge)
                    .frame(width: 20, height: 20)
                    .overlay {
                        Image(systemName: icon)
                            .font(TileFont.label.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                Text(title)
                    .font(TileFont.row)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? theme.textPrimary.color : theme.textSecondary.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var background: Color {
        if selected { return theme.accent.color.opacity(0.22) }
        return hovered ? theme.tileHover.color.opacity(0.6) : .clear
    }
}

// One width for every menu picker and text field on the right side of a row:
// mixed widths made the control column read ragged, like parts from
// different windows
enum SettingsMetrics {
    static let field: CGFloat = 220
    /// One width for every menu picker: sized-to-content pickers gave a
    /// ragged right column, 120…220 depending on the longest item
    static let picker: CGFloat = 180
    /// Segmented control (base currency) — three segments need more room
    static let segmented: CGFloat = 210
}

// Settings section header: same voice as tile labels
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(TileFont.label.weight(.semibold))
                .kerning(0.4)
                .foregroundStyle(theme.textMuted.color)
                .padding(.leading, 4)

            // Card with dividers between rows — how every group is built in
            // System Settings
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.tileBackground.color))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.border.color.opacity(0.5), lineWidth: 0.5))

            if let footer {
                Text(footer)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
        }
        .padding(.bottom, 20)
    }
}

// Settings row: label on the left, control on the right, divider underneath
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var last = false
    @ViewBuilder var control: Control

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(TileFont.row)
                        .foregroundStyle(theme.textPrimary.color)
                    if let subtitle {
                        Text(subtitle)
                            .font(TileFont.caption)
                            .foregroundStyle(theme.textMuted.color)
                    }
                }
                Spacer(minLength: 12)
                control
                    // Switches, not checkboxes: in a Form, Toggle draws as a
                    // checkbox by default, and that looks like a window from
                    // the 2000s. Controls stay regular size — a row-wide .small
                    // shrank button and popup fonts to 11pt; switches opt into
                    // .small individually
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if !last {
                Divider()
                    .overlay(theme.border.color.opacity(0.4))
                    .padding(.leading, 12)
            }
        }
    }
}

// MARK: - sections

private struct GeneralSettings: View {
    @State private var settings = AppSettings.shared
    @State private var language =
        UserDefaults.standard.string(forKey: "settings.appLanguage") ?? "system"

    /// Overriding AppleLanguages is the standard per-app language switch;
    /// strings load at launch, so the app restarts itself to apply
    private func applyLanguage() {
        let defaults = UserDefaults.standard
        defaults.set(language, forKey: "settings.appLanguage")
        if language == "system" {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language], forKey: "AppleLanguages")
        }
        // Relaunch through a short sleep so the new instance starts after this
        // one is gone — `open -n` in parallel briefly ran two copies against
        // one config. And quit only if the relauncher actually started: with
        // the error swallowed, a failed `open` just made the app vanish
        let escapedPath = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open -n '\(escapedPath)'"]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            sillLog("[settings] language relaunch failed: \(error)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: String(localized: "startup"),
                footer: settings.launchAtLoginNote
                    ?? String(localized: "Clicking the notch only works while Sill is running")
            ) {
                SettingsRow(title: String(localized: "Launch at login"), last: true) {
                    Toggle("", isOn: $settings.launchAtLogin).controlSize(.small)
                }
            }

            SettingsSection(title: String(localized: "language")) {
                SettingsRow(
                    title: String(localized: "App language"),
                    subtitle: String(localized: "Sill restarts to apply"),
                    last: true
                ) {
                    Picker("", selection: $language) {
                        Text("System").tag("system")
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "Русский").tag("ru")
                    }
                    .labelsHidden()
                    .frame(width: SettingsMetrics.picker, alignment: .trailing)
                    .onChange(of: language) { _, _ in applyLanguage() }
                }
            }

        }
    }
}

// Reference value to the right of the label
private struct ValueText: View {
    let text: String
    @Environment(\.theme) private var theme

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(TileFont.status)
            .foregroundStyle(theme.textMuted.color)
    }
}

// Which currencies and coins the tile shows. Search on top, added items below,
// in the order they'll appear in the tile. Rows are built from the same
// building block as the rest of Settings: 12-pt side padding, 9 top/bottom, an
// indented divider. A custom row size here would read as a different app.
struct CurrencySettings: View {
    /// Sample data for appearance snapshots: no network in the debug renderer
    var sample: [CurrencyWidget.Rate] = []
    var sampleQuery = ""
    var sampleChosen: [CurrencyChoice] = []

    @State private var settings = AppSettings.shared
    @State private var available: [CurrencyWidget.Rate] = []
    @State private var query = ""
    @State private var loading = false
    @State private var note: String?
    @Environment(\.theme) private var theme

    private var all: [CurrencyWidget.Rate] { sample.isEmpty ? available : sample }

    /// Which base a row is priced in: coins in theirs, currencies in theirs
    private func base(of rate: CurrencyWidget.Rate) -> String {
        rate.kind == .crypto ? settings.cryptoBase : settings.baseCurrency
    }

    /// Rubles per unit of that base — rates in the rows are divided by it
    private func unit(of code: String) -> Double {
        guard code != "RUB" else { return 1 }
        return all.first { $0.code == code }?.perUnit ?? 1
    }

    private func shown(_ rate: CurrencyWidget.Rate) -> CurrencyWidget.Rate {
        let unit = unit(of: base(of: rate))
        guard unit != 1 else { return rate }
        var copy = rate
        copy.value = rate.perUnit / unit
        copy.nominal = 1
        return copy
    }
    private var chosen: [CurrencyChoice] {
        sampleChosen.isEmpty ? settings.currencies : sampleChosen
    }

    /// What we suggest adding: matches the query and isn't added yet. The base
    /// currency stays in the list — hidden, it looked like "euro isn't there at all"
    /// when the base was the euro; it's shown as a row that says so instead
    private var found: [CurrencyWidget.Rate] {
        let taken = Set(chosen.map(\.code))
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Array(
            all.filter { !taken.contains($0.code) }
                .filter { CurrencyWidget.matches($0, query: query) }
                .prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: String(localized: "shown in"),
                footer: String(
                    localized: "Currencies and coins can be shown in different ones: the central bank rate comes in rubles, coins are quoted in dollars")
            ) {
                SettingsRow(title: String(localized: "Currencies in")) {
                    Picker("", selection: $settings.baseCurrency) {
                        ForEach(CurrencyWidget.baseOptions, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: SettingsMetrics.segmented)
                }
                // Coins get their own base: the world quotes crypto in dollars,
                // while the Central Bank rate arrives in rubles
                SettingsRow(title: String(localized: "Coins in"), last: true) {
                    Picker("", selection: $settings.cryptoBase) {
                        ForEach(CurrencyWidget.baseOptions, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: SettingsMetrics.segmented)
                }
            }

            SettingsSection(
                title: String(localized: "add"),
                footer: String(
                    localized: "Currencies use the official Russian Central Bank rate, coins use CoinGecko prices in rubles. Both work without a key")
            ) {
                SearchRow(
                    text: $query, placeholder: String(localized: "Dollar, lari, BTC…"), last: found.isEmpty)
                ForEach(Array(found.enumerated()), id: \.element.id) { index, rate in
                    FoundRow(
                        rate: shown(rate), base: base(of: rate),
                        isBase: rate.code == settings.baseCurrency,
                        last: index == found.count - 1
                    ) {
                        settings.currencies.append(
                            CurrencyChoice(code: rate.code, isCrypto: rate.kind == .crypto))
                        query = ""
                    }
                }
            }

            SettingsSection(
                title: String(localized: "show"),
                footer: String(
                    localized: "The square shows the first row, the rectangle shows three, the large one shows seven. The order here is the order in the tile")
            ) {
                if chosen.isEmpty {
                    SettingsRow(title: String(localized: "Nothing selected"), subtitle: emptyNote, last: true) {
                        EmptyView()
                    }
                }
                ForEach(Array(chosen.enumerated()), id: \.element.id) { index, choice in
                    ChosenRow(
                        choice: choice,
                        name: name(of: choice),
                        rate: all.first { $0.code == choice.code }.map(shown),
                        base: choice.isCrypto ? settings.cryptoBase : settings.baseCurrency,
                        canMoveUp: index > 0,
                        last: index == chosen.count - 1,
                        onUp: { settings.currencies.swapAt(index, index - 1) },
                        onRemove: { settings.currencies.removeAll { $0.code == choice.code } })
                }
            }

            if let note {
                Text(note)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
            }
        }
        .onAppear { query = sampleQuery }
        .task { await load() }
    }

    private var emptyNote: String {
        String(localized: "The tile will show \(CurrencyWidget.defaultCodes.joined(separator: ", "))")
    }

    private func name(of choice: CurrencyChoice) -> String {
        all.first { $0.code == choice.code }?.title ?? ""
    }

    private func load() async {
        guard sample.isEmpty, available.isEmpty else { return }
        loading = true
        defer { loading = false }
        var loaded: [CurrencyWidget.Rate] = []
        if let rates = try? await CentralBank.rates() {
            loaded += rates.rates
        } else {
            note = String(localized: "Couldn't fetch the currency list from the Central Bank")
        }
        if let coins = try? await CoinGecko.markets() {
            loaded += coins
        } else {
            note = (note.map { $0 + "; " } ?? "") + String(localized: "Couldn't fetch the coin list")
        }
        available = loaded
    }
}

// Pomodoro: how long the work stretch is and how long the break. Shared by every
// pomodoro tile — one person has one rhythm, not one per tile
struct PomodoroSettings: View {
    @State private var settings = AppSettings.shared
    @Environment(\.theme) private var theme

    /// Round numbers only: a pomodoro is a habit, not a stopwatch, and a free-form
    /// field would only invite fiddling with 23 versus 24 minutes
    private static let workOptions = [15, 20, 25, 30, 35, 40, 45, 50, 60, 90]
    private static let restOptions = [3, 5, 7, 10, 15, 20, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: String(localized: "lengths"),
                footer: String(
                    localized: "The phase changes on its own and says so at the notch, even with the panel closed")
            ) {
                SettingsRow(title: String(localized: "Focus")) {
                    Picker("", selection: $settings.pomodoroWork) {
                        ForEach(Self.workOptions, id: \.self) { minutes in
                            Text(String(localized: "\(minutes) min")).tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: SettingsMetrics.picker, alignment: .trailing)
                }
                SettingsRow(title: String(localized: "Break")) {
                    Picker("", selection: $settings.pomodoroRest) {
                        ForEach(Self.restOptions, id: \.self) { minutes in
                            Text(String(localized: "\(minutes) min")).tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: SettingsMetrics.picker, alignment: .trailing)
                }
                SettingsRow(
                    title: String(localized: "Show at the notch"),
                    subtitle: String(localized: "The phase left, in the capsule by the cutout"),
                    last: true
                ) {
                    Toggle("", isOn: $settings.pomodoroInNotch).controlSize(.small)
                }
            }
        }
    }
}

// Boards: the list, in the order the dots stand in the wing. Deleting a board used
// to live only in the dot's context menu — invisible, and on Macs with a menu bar
// manager (Bartender, Thaw) the right-click never reaches us at all.
struct BoardSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: String(localized: "boards"),
                footer: String(
                    localized: "The order here is the order of the dots in the wing and the order swiping pages through them")
            ) {
                ForEach(Array(appState.config.boards.enumerated()), id: \.element.id) { index, board in
                    BoardRow(
                        board: board,
                        canMoveUp: index > 0,
                        // The clipboard board isn't deleted here: it comes and goes
                        // with "Keep clipboard history" in the Clipboard section
                        canRemove: appState.config.boards.count > 1 && board.kind != .clipboard,
                        last: index == appState.config.boards.count - 1,
                        onRename: { appState.renameBoard(board.id, to: $0) },
                        onUp: { appState.moveBoard(board.id, by: -1) },
                        onRemove: { appState.removeBoard(board.id) })
                }
            }
        }
    }
}

private struct BoardRow: View {
    let board: Board
    let canMoveUp: Bool
    let canRemove: Bool
    var last = false
    let onRename: (String) -> Void
    let onUp: () -> Void
    let onRemove: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false
    @State private var name = ""
    @FocusState private var editing: Bool

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != board.name else {
            name = board.name  // empty or unchanged — put the old name back
            return
        }
        onRename(trimmed)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // The clipboard board's name is the app's, not the person's: it
                // appears and disappears with the setting
                if board.kind == .clipboard {
                    Text(board.name)
                        .font(TileFont.row)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                } else {
                    // Renaming right here, no dialog: the whole rename window
                    // exists only because there was nowhere else to type
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .font(TileFont.row)
                        .foregroundStyle(theme.textPrimary.color)
                        .focused($editing)
                        // Committed on Return and when focus leaves, never per
                        // keystroke: renaming on every letter wrote the config
                        // twenty times and filled the undo stack with one rename
                        .onSubmit { commit() }
                        .onChange(of: editing) { _, focused in
                            if !focused { commit() }
                        }
                }
                Spacer(minLength: 12)
                Text(subtitle)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                RowButton(icon: "arrow.up", active: hovered && canMoveUp, action: onUp)
                    .disabled(!canMoveUp)
                    .opacity(canMoveUp ? 1 : 0.25)
                RowButton(icon: "minus", active: hovered, action: onRemove)
                    .disabled(!canRemove)
                    .opacity(canRemove ? 1 : 0.25)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(hovered ? theme.tileHover.color : .clear)
            .onHover { hovered = $0 }

            if !last { RowDivider() }
        }
        .onAppear { name = board.name }
    }

    private var subtitle: String {
        board.kind == .clipboard
            ? String(localized: "follows the clipboard setting")
            : String(localized: "\(board.tiles.count) widgets")
    }
}

// Search row: field spans the full row width, icon on the left — like Apple's
// own search lists. No separate border around the field — the card already has one
private struct SearchRow: View {
    @Binding var text: String
    let placeholder: String
    var last = false
    var onSubmit: (() -> Void)?

    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(TileIcon.caption)
                    .foregroundStyle(theme.textMuted.color)
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(TileFont.row)
                            .foregroundStyle(theme.textMuted.color)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(TileFont.row)
                        .foregroundStyle(theme.textPrimary.color)
                        .focused($focused)
                        .onSubmit { onSubmit?() }
                }
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(TileIcon.caption)
                            .foregroundStyle(theme.textMuted.color)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            if !last { RowDivider() }
        }
    }
}

// Found row: code, name, kind — and a "+" on the right
private struct FoundRow: View {
    let rate: CurrencyWidget.Rate
    var base = "RUB"
    /// This is the base currency: it can't be added (its rate against itself is 1),
    /// but it must be visible — searching for it and finding nothing read as a bug
    var isBase = false
    var last = false
    let onAdd: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CodeLabel(code: rate.code)
                Text(rate.title)
                    .font(TileFont.row)
                    .foregroundStyle(isBase ? theme.textMuted.color : theme.textPrimary.color)
                    .lineLimit(1)
                if rate.kind == .crypto { KindTag() }
                Spacer(minLength: 12)
                if isBase {
                    Text("base")
                        .font(TileFont.caption)
                        .foregroundStyle(theme.textMuted.color)
                } else {
                    PriceLabel(rate: rate, base: base)
                    Image(systemName: "plus")
                        .font(TileIcon.caption)
                        .foregroundStyle(theme.accent.color)
                        .frame(width: 20, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            // The whole row highlights, not a chunk inside it: the card is
            // already rounded, and a second rounded rect inside it looks like a sticker
            .background(hovered && !isBase ? theme.tileHover.color : .clear)
            .contentShape(Rectangle())
            .onTapGesture { if !isBase { onAdd() } }
            .onHover { hovered = $0 }

            if !last { RowDivider() }
        }
    }
}

// Added row: move it up or remove it
private struct ChosenRow: View {
    let choice: CurrencyChoice
    let name: String
    var rate: CurrencyWidget.Rate?
    var base = "RUB"
    let canMoveUp: Bool
    var last = false
    let onUp: () -> Void
    let onRemove: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CodeLabel(code: choice.code)
                Text(name)
                    .font(TileFont.row)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                if choice.isCrypto { KindTag() }
                Spacer(minLength: 12)
                // The base currency's rate against itself is "1.00 $" — nothing
                // worth reading: a label explaining why the row has no number instead
                if choice.code == base {
                    Text("base")
                        .font(TileFont.caption)
                        .foregroundStyle(theme.textMuted.color)
                } else if let rate {
                    PriceLabel(rate: rate, base: base)
                }
                // Buttons are always present: appearing only on hover made the
                // row jump — content shifted right under the cursor
                RowButton(icon: "arrow.up", active: hovered && canMoveUp, action: onUp)
                    .disabled(!canMoveUp)
                    .opacity(canMoveUp ? 1 : 0.25)
                RowButton(icon: "minus", active: hovered, action: onRemove)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(hovered ? theme.tileHover.color : .clear)
            .onHover { hovered = $0 }

            if !last { RowDivider() }
        }
    }
}

// Currency code: same width on every row, otherwise names jump around horizontally
private struct CodeLabel: View {
    let code: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(code)
            .font(TileFont.row.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(theme.textPrimary.color)
            .frame(width: 52, alignment: .leading)
    }
}

private struct KindTag: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("coin")
            .font(TileFont.caption)
            .foregroundStyle(theme.textMuted.color)
    }
}

/// Rate on the right: it shows exactly what you're adding, and the row stops
/// looking empty in the middle. Digits are monospaced so the column doesn't jitter
private struct PriceLabel: View {
    let rate: CurrencyWidget.Rate
    var base = "RUB"
    @Environment(\.theme) private var theme

    var body: some View {
        Text(CurrencyWidget.money(rate.perUnit, base: base))
            .font(TileFont.rowValue)
            .monospacedDigit()
            .foregroundStyle(theme.textMuted.color)
            .lineLimit(1)
    }
}

// Transient state as a row of its own — same padding and divider as every row
private struct StatusRow: View {
    let text: String
    var last = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(TileFont.caption)
                .foregroundStyle(theme.textMuted.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            if !last { RowDivider() }
        }
    }
}

// City search result: name, region on the right of it, checkmark when selected
private struct PlaceRow: View {
    let place: Place
    let selected: Bool
    var last = false
    /// No action means the row only reports the state — the chosen city under the
    /// search field. Such a row doesn't highlight on hover: there is nothing to click
    var onPick: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(place.name)
                    .font(TileFont.row)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Text(place.subtitle)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark")
                        .font(TileIcon.caption)
                        .foregroundStyle(theme.accent.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(hovered && onPick != nil ? theme.tileHover.color : .clear)
            .contentShape(Rectangle())
            .onTapGesture { onPick?() }
            .onHover { hovered = $0 }

            if !last { RowDivider() }
        }
    }
}

private struct RowDivider: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Divider()
            .overlay(theme.border.color.opacity(0.4))
            .padding(.leading, 12)
    }
}

private struct RowButton: View {
    let icon: String
    var active = false
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TileIcon.caption)
                .foregroundStyle(active ? theme.textPrimary.color : theme.textMuted.color)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NotchSettings: View {
    @State private var settings = AppSettings.shared
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    @State private var searchFailed = false

    // Media keys arrive as system events, and catching them from another app
    // requires Accessibility access — that is the name of the permission in
    // System Settings. "Universal Control" is a different macOS feature entirely
    private var mediaKeysSubtitle: String {
        if MediaKeys.isAvailable {
            return String(localized: "A track paused with the key shows up at the notch")
        }
        // Asked once already — the prompt won't come back, only Settings will do
        return MediaKeys.didAsk
            ? String(localized: "Access denied. Allow Sill under Privacy & Security → Accessibility")
            : String(localized: "Needs Accessibility access — otherwise the capsule won't expand")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: String(localized: "media")) {
                SettingsRow(
                    title: String(localized: "Show track at the notch"),
                    subtitle: String(localized: "Artwork and equalizer while music plays")
                ) {
                    Toggle("", isOn: $settings.musicInNotch).controlSize(.small)
                }
                SettingsRow(
                    title: String(localized: "Expand on F7 / F8 / F9"),
                    subtitle: mediaKeysSubtitle,
                    last: true
                ) {
                    if MediaKeys.isAvailable {
                        ValueText(String(localized: "working"))
                    } else if MediaKeys.didAsk {
                        // The prompt is a one-shot: after it, only Settings can grant it
                        Button("Open Settings") { MediaKeys.openSettings() }
                    } else {
                        Button("Allow") { MediaKeys.requestAccess() }
                    }
                }
            }

            SettingsSection(
                title: String(localized: "what else shows up at the notch"),
                footer: settings.weatherAlert.explanation
            ) {
                SettingsRow(
                    title: String(localized: "Timer and stopwatch"),
                    subtitle: String(localized: "While running; the finished-timer sound stays on either way")
                ) {
                    Toggle("", isOn: $settings.timerInNotch).controlSize(.small)
                }
                SettingsRow(title: String(localized: "Battery"), subtitle: String(localized: "Charging and below 20%")) {
                    Toggle("", isOn: $settings.batteryInNotch).controlSize(.small)
                }
                SettingsRow(title: String(localized: "Weather"), last: true) {
                    Picker("", selection: $settings.weatherAlert) {
                        ForEach(AppSettings.WeatherAlert.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: SettingsMetrics.picker, alignment: .trailing)
                }
            }

            // The city lives here, next to the weather capsule it feeds: tiles
            // pick their own city in place, so a whole Weather section for one
            // search field wasn't worth a sidebar entry.
            // Built from the same row bricks as the Currencies section — a raw
            // bordered field and unpadded result buttons read as a different app
            SettingsSection(
                title: String(localized: "weather city"),
                footer: String(localized: "Used by the capsule and by tiles without a city of their own")
            ) {
                SearchRow(
                    text: $query,
                    placeholder: String(localized: "Find a city"),
                    last: !searching && results.isEmpty && settings.weatherPlace == nil,
                    onSubmit: search)
                if searching {
                    StatusRow(
                        text: String(localized: "Loading…"),
                        last: results.isEmpty && settings.weatherPlace == nil)
                }
                // Same distinction the weather tile draws: a network failure
                // is not "nothing found"
                if searchFailed, !searching {
                    StatusRow(
                        text: String(localized: "Search failed"),
                        last: results.isEmpty && settings.weatherPlace == nil)
                }
                ForEach(Array(results.enumerated()), id: \.element.id) { index, place in
                    PlaceRow(
                        place: place,
                        selected: settings.weatherPlace?.id == place.id,
                        last: index == results.count - 1 && settings.weatherPlace == nil
                    ) {
                        settings.weatherPlace = place
                        results = []
                        query = ""
                    }
                }
                // The chosen city is shown as the same row as the search results,
                // with a checkmark — a "Selected — Munich" key-value row didn't read
                // as "this is your city"
                if let place = settings.weatherPlace, results.isEmpty {
                    PlaceRow(place: place, selected: true, last: true)
                }
            }
        }
        // No city chosen anywhere — offer the one the time zone names, so the
        // capsule has something to show even without a weather tile on a board
        .task { settings.ensureWeatherPlace() }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return }
        searching = true
        searchFailed = false
        Task {
            do {
                results = try await OpenMeteo.search(city: text)
            } catch {
                results = []
                searchFailed = true
            }
            searching = false
        }
    }
}

private struct AppearanceSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: String(localized: "theme")) {
                SettingsRow(title: String(localized: "Appearance theme"), last: true) {
                    Picker("", selection: themeBinding) {
                        ForEach(appState.themeEngine.names, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: SettingsMetrics.picker, alignment: .trailing)
                }
            }

            SettingsSection(title: String(localized: "panel")) {
                SettingsRow(title: String(localized: "Panel background")) {
                    Picker("", selection: backgroundBinding) {
                        ForEach(PanelBackgroundStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: SettingsMetrics.picker, alignment: .trailing)
                }
                SettingsRow(title: String(localized: "Panel edge")) {
                    Picker("", selection: edgeBinding) {
                        ForEach(PanelEdgeStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: SettingsMetrics.picker, alignment: .trailing)
                }
                SettingsRow(title: String(localized: "Tile style"), last: true) {
                    Picker("", selection: tileBinding) {
                        ForEach(TileStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: SettingsMetrics.picker, alignment: .trailing)
                }
            }
        }
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { appState.theme.name },
            set: { appState.themeEngine.select(name: $0) })
    }

    private var edgeBinding: Binding<PanelEdgeStyle> {
        Binding(
            get: { appState.appearance.edge },
            set: { appState.appearance.edge = $0 })
    }

    private var backgroundBinding: Binding<PanelBackgroundStyle> {
        Binding(
            get: { appState.appearance.background },
            set: { appState.appearance.background = $0 })
    }

    private var tileBinding: Binding<TileStyle> {
        Binding(
            get: { appState.appearance.tile },
            set: { appState.appearance.tile = $0 })
    }
}

// Clipboard: history only accumulates while the toggle is on, and everything stays local
private struct ClipboardSettings: View {
    @State private var settings = AppSettings.shared
    @State private var store = ClipboardStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: String(localized: "history"),
                footer: String(
                    localized: "Entries stay on this Mac only and are never sent anywhere. Passwords from password managers are marked with the system's \"concealed\" type and never make it into history")
            ) {
                SettingsRow(
                    title: String(localized: "Keep clipboard history"),
                    subtitle: String(localized: "Adds a separate \"Clipboard\" board")
                ) {
                    Toggle("", isOn: $settings.clipboardEnabled).controlSize(.small)
                }
                SettingsRow(title: String(localized: "Quick access")) {
                    HotkeyField(combo: $settings.clipboardHotkey)
                }
                SettingsRow(title: String(localized: "Keep entries"), subtitle: String(localized: "Up to 500")) {
                    TextField(
                        "",
                        value: Binding(
                            get: { settings.clipboardLimit },
                            set: { settings.clipboardLimit = min(max($0, 1), 500) }),
                        format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                }
                SettingsRow(title: String(localized: "Delete older than"), last: true) {
                    Picker("", selection: $settings.clipboardDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("never").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: SettingsMetrics.picker, alignment: .trailing)
                }
            }

            SettingsSection(title: String(localized: "clear")) {
                SettingsRow(title: String(localized: "Forget the last 5 minutes")) {
                    Button("Forget") { store.forgetLast(minutes: 5) }
                }
                SettingsRow(
                    title: String(localized: "All history"),
                    subtitle: String(localized: "\(store.items.count) entries"), last: true
                ) {
                    Button("Clear", role: .destructive) { store.clear() }
                }
            }
        }
        // History might never have loaded (collection off) — the counter would
        // show zero with a full file on disk, and Clear would orphan the images
        .onAppear { store.ensureLoaded() }
    }
}

// Hotkey recorder field: press "Set", and the next key combo becomes the hotkey
private struct HotkeyField: View {
    @Binding var combo: GlobalHotkey.Combo?

    @Environment(\.theme) private var theme
    @State private var recording = false
    // The monitor is kept in an object, not @State: the monitor's closure
    // captures a copy of the view, and removing it through that captured copy
    // didn't work — the monitor kept running and swallowed every modified key
    // combo app-wide
    @State private var keys = RecorderKeys()

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : record()
            } label: {
                Text(label)
                    .font(TileFont.row)
                    .monospaced()
                    .foregroundStyle(recording ? theme.accent.color : theme.textPrimary.color)
                    .frame(minWidth: 92)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.tileHover.color.opacity(recording ? 1 : 0.6)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if combo != nil, !recording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.textMuted.color)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }

            // Registration can be refused (combo taken by another app) — the
            // field must not show a shortcut that silently doesn't work
            if combo != nil, !recording, GlobalHotkey.shared.failed {
                Text("Taken by another app")
                    .font(TileFont.caption)
                    .foregroundStyle(theme.warning.color)
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return String(localized: "Press…") }
        return combo?.text ?? String(localized: "Set")
    }

    private func record() {
        recording = true
        keys.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Esc cancels; a combo with no modifiers would just catch normal typing
            if event.keyCode == 53 || flags.isEmpty {
                stop()
                return nil
            }
            combo = GlobalHotkey.Combo(
                keyCode: UInt32(event.keyCode), modifiers: flags.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        keys.stop()
    }
}

/// One live object to hold the key monitor: @State won't work here (see record)
@MainActor @Observable
private final class RecorderKeys {
    @ObservationIgnored var monitor: Any?

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// Model: provider, key, and a choice of model from what that key unlocks
private struct ModelSettings: View {
    @State private var settings = AppSettings.shared
    /// Loaded asynchronously in .task — a synchronous Keychain read at view
    /// creation is the same class of main-thread freeze already fixed for the
    /// "Ask" bar (12.7 s measured)
    @State private var key = ""
    @State private var models: [LLMClient.Model] = []
    @State private var loading = false
    @State private var note: String?
    @State private var freeOnly = false

    /// What we show in the list, filtered by "free only" if set
    private var shown: [LLMClient.Model] {
        freeOnly ? models.filter(\.free) : models
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: String(localized: "how to ask")) {
                SettingsRow(title: String(localized: "Ask bar in the panel"), last: true) {
                    Toggle("", isOn: $settings.askBar).controlSize(.small).toggleStyle(.switch)
                }
            }

            SettingsSection(title: String(localized: "provider"), footer: note) {
                SettingsRow(title: String(localized: "Ask through")) {
                    Picker("", selection: $settings.llmProvider) {
                        ForEach(LLMProvider.allCases, id: \.self) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: SettingsMetrics.picker, alignment: .trailing)
                    .onChange(of: settings.llmProvider) { old, _ in providerChanged(from: old) }
                }
                if settings.llmProvider.needsKey {
                    SettingsRow(title: String(localized: "Key")) {
                        SecureField("", text: $key)
                            .textFieldStyle(.roundedBorder)
                                    .frame(width: SettingsMetrics.field)
                            // Saved shortly after the last keystroke, not on each
                            // one: SecItemUpdate is synchronous and per-character
                            // writes stuttered typing. Relying on Enter or the
                            // window closing alone isn't safe — the window can go
                            // away first, and the debounce task outlives the view
                            .onChange(of: key) { _, _ in scheduleSave() }
                            .onSubmit { save(); reload() }
                    }
                }
                // Shown by provider, not by fetched data: OpenRouter always
                // carries pricing, and gating the row on the network response
                // made it pop in later and shift the section
                if settings.llmProvider == .openRouter || models.contains(where: { $0.free }) {
                    SettingsRow(title: String(localized: "Free only")) {
                        Toggle("", isOn: $freeOnly).controlSize(.small).toggleStyle(.switch)
                    }
                }
                SettingsRow(title: String(localized: "Model"), last: true) {
                    HStack(spacing: 8) {
                        if models.isEmpty {
                            TextField("", text: $settings.llmModel)
                                .textFieldStyle(.roundedBorder)
                                            .frame(width: SettingsMetrics.field)
                        } else {
                            Picker("", selection: $settings.llmModel) {
                                ForEach(shown) { model in
                                    Text(model.free ? String(localized: "\(model.id) · free") : model.id)
                                        .tag(model.id)
                                }
                            }
                            .labelsHidden()
                                    .frame(maxWidth: SettingsMetrics.field, alignment: .trailing)
                        }
                        Button(loading ? "…" : "Update") { save(); reload() }
                            .disabled(loading)
                    }
                }
            }
        }
        .task {
            key = await LLMClient.shared.keyValue(for: settings.llmProvider) ?? ""
            reload()
        }
        .onDisappear(perform: save)
    }

    @State private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        let value = key
        // Pin the provider at typing time: if the person switches provider
        // before the debounce fires, the key must still land under the
        // provider it was typed for
        let provider = settings.llmProvider
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await LLMClient.shared.storeKey(value, for: provider)
            LLMClient.shared.keyDidChange()
        }
    }

    private func save() {
        saveTask?.cancel()
        let value = key
        let provider = settings.llmProvider
        Task {
            await LLMClient.shared.storeKey(value, for: provider)
            LLMClient.shared.keyDidChange()
        }
    }

    /// Keys are per provider: flush the typed key under the provider it
    /// belongs to, then show the new provider's own key in the field
    private func providerChanged(from old: LLMProvider) {
        let typed = key
        let hadPendingSave = saveTask != nil
        saveTask?.cancel()
        saveTask = nil
        key = ""
        Task {
            if hadPendingSave {
                await LLMClient.shared.storeKey(typed, for: old)
            }
            key = await LLMClient.shared.keyValue(for: settings.llmProvider) ?? ""
            LLMClient.shared.keyDidChange()
            reload()
        }
    }

    /// The model list comes straight from the provider — keeping our own copy
    /// makes no sense, it'd be stale within a month
    private func reload() {
        let provider = settings.llmProvider
        guard !provider.needsKey || !key.isEmpty else {
            models = []
            note = nil
            return
        }
        save()
        loading = true
        note = nil
        Task {
            do {
                let list = try await LLMClient.shared.models(provider: provider)
                models = list
                // We don't touch an existing choice: the default model is only
                // filled in when the current one is empty. Silently overriding
                // the user's pick would be rude
                if settings.llmModel.isEmpty {
                    settings.llmModel = list.contains(where: { $0.id == provider.defaultModel })
                        ? provider.defaultModel : (list.first?.id ?? "")
                }
                note = list.isEmpty ? String(localized: "Provider returned no models") : nil
            } catch {
                models = []
                note = error.localizedDescription
            }
            loading = false
        }
    }
}
