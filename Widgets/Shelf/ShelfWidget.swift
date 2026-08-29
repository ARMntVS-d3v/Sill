import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A file shelf: drag it onto the panel and it sits within reach until you take
// it where it needs to go. Files on the shelf are references, not copies: the
// app never moves anything and doesn't use disk space. The reference is stored
// as a bookmark, so it survives a rename or move, not just a restart.
@MainActor @Observable
final class ShelfWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "shelf",
        name: "Shelf",
        icon: "tray.full",
        sizes: [.small, .medium, .large],
        defaultSize: .medium
    )

    /// We hold exactly as many files as fit — exactly what's visible in the tile.
    /// Square holds one file (remove it before adding a second), rectangle holds
    /// three rows, large holds twelve cards. The shelf keeps no hidden overflow:
    /// a file you can't see is a file people consider lost anyway
    static func capacity(for size: TileSize) -> Int {
        switch size {
        case .small: 1
        case .medium: 3
        case .large: 12
        }
    }

    struct Item: Codable, Identifiable, Sendable, Equatable {
        var id: UUID
        var name: String
        /// Bookmark: survives a file move or rename
        var bookmark: Data?
        /// Path at the time it was added — fallback and the menu's label
        var path: String
        /// Where the file came from, for copied files whose `path` points at
        /// our own copy: dropping the same file again must match the existing
        /// card, and `path` alone can't — it was rewritten to the copy
        var origin: String?
        var added: Date
        var isDirectory: Bool
    }

    private let context: WidgetContext
    private(set) var items: [Item] = []

    var capacity: Int { Self.capacity(for: context.tileSize) }
    /// Tile is full: won't accept more until something is removed
    var isFull: Bool { items.count >= capacity }
    /// What's actually shown. The tile may have been shrunk — the overflow just
    /// isn't drawn, but it isn't lost either: resize back and it reappears
    var shown: [Item] { Array(items.prefix(capacity)) }

    init(context: WidgetContext) {
        self.context = context
        items = context.settings.get("items", as: [Item].self) ?? []
    }

    var body: AnyView {
        AnyView(ShelfTileView(widget: self, size: context.tileSize))
    }

    /// Clicking the tile itself doesn't open anything: the shelf is a place files
    /// are picked up from, not a launcher list. Opening happens via a double-click on a file

    // MARK: - what's on the shelf

    var isEmpty: Bool { items.isEmpty }

    /// "3 files" — the count shown in the tile's corner
    var countText: String {
        let count = shown.count
        return count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
    }

    /// The file's live address: bookmark first, then path. The file may have been
    /// deleted — then nil, and the row shows struck through instead of silently disappearing
    func url(of item: Item) -> URL? {
        if let bookmark = item.bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale),
                FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallback = URL(filePath: item.path)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    func exists(_ item: Item) -> Bool { url(of: item) != nil }

    /// File size, or "folder" — the caption under the name
    func measure(of item: Item) -> String {
        guard let url = url(of: item) else { return String(localized: "file missing") }
        if item.isDirectory { return String(localized: "folder") }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size.formatted(.byteCount(style: .file))
    }

    // MARK: - add and remove

    /// We add files while there's room. Once space runs out, the rest are
    /// dropped: the shelf must never silently bump what was added earlier
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls where url.isFileURL {
            guard items.count < capacity || items.contains(where: { Self.matches($0, url) })
            else { break }
            // The same file isn't added twice — it's moved back to the top.
            // Matching goes through `origin` too: for copied files `path`
            // points at our own copy and never equals the dropped URL
            if let index = items.firstIndex(where: { Self.matches($0, url) }) {
                var existing = items.remove(at: index)
                existing.added = Date()
                items.insert(existing, at: 0)
                added += 1
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                ?? false
            let id = UUID()
            // We store a copy of the file rather than just remembering where it
            // was. The shelf gets used to move files: drop one from Downloads,
            // remove the original, and everything used to vanish because both
            // the bookmark and the path led nowhere.
            // The copy happens off the main thread — a dropped video blocked
            // the panel for the whole duration of a synchronous copy. Until it
            // lands, the card points at the original via path and bookmark
            let target = Self.shelfTarget(for: url, id: id)
            items.insert(
                Item(
                    id: id,
                    name: url.lastPathComponent,
                    bookmark: try? url.bookmarkData(options: .minimalBookmark),
                    path: url.path,
                    origin: target == nil ? nil : url.path,
                    added: Date(),
                    isDirectory: isDirectory),
                at: 0)
            added += 1
            if let target {
                Task { [weak self] in
                    // nonisolated async — runs off the main actor
                    guard await Self.performCopy(from: url, to: target) else { return }
                    guard let self, let index = items.firstIndex(where: { $0.id == id }) else {
                        // Taken off the shelf while the copy was in flight —
                        // the finished copy belongs to nobody, delete it
                        try? FileManager.default.removeItem(
                            at: target.deletingLastPathComponent())
                        return
                    }
                    items[index].path = target.path
                    items[index].bookmark = nil
                    persist()
                }
            }
        }
        persist()
        return added
    }

    private static func matches(_ item: Item, _ url: URL) -> Bool {
        item.path == url.path || item.origin == url.path
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        Self.dropCopy(of: item)
        persist()
    }

    func clear() {
        for item in items { Self.dropCopy(of: item) }
        items.removeAll()
        persist()
    }

    /// Tile removed — the copies must go with it: a shelf tile holding a
    /// gigabyte of copies would otherwise never give the space back
    func tileWillRemove() {
        for item in items { Self.dropCopy(of: item) }
    }

    // MARK: - our own copy of the file

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Sill/shelf")
    }

    /// Where this file's copy will live. Folders aren't copied — they can be
    /// huge, so they're kept as a bookmark instead (nil)
    private static func shelfTarget(for url: URL, id: UUID) -> URL? {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard !isDirectory else { return nil }
        return directory.appending(path: id.uuidString).appending(path: url.lastPathComponent)
    }

    private nonisolated static func performCopy(from url: URL, to target: URL) async -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            return true
        } catch {
            sillLog("[shelf] failed to store copy: \(error.localizedDescription)")
            return false
        }
    }

    /// Launch sweep: a box on disk must belong to an item of a live shelf
    /// tile. Anything else is a leftover — a tile deleted before cleanup
    /// existed, or a copy that finished after its tile was removed
    static func purgeOrphanCopies(aliveTiles: [UUID]) {
        let referenced = Set(
            aliveTiles.flatMap { tileID -> [String] in
                let settings = WidgetSettings(widgetID: descriptor.id, tileID: tileID)
                return (settings.get("items", as: [Item].self) ?? []).map(\.id.uuidString)
            })
        let boxes =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for box in boxes
        where UUID(uuidString: box.lastPathComponent) != nil
            && !referenced.contains(box.lastPathComponent) {
            try? FileManager.default.removeItem(at: box)
            removed += 1
        }
        if removed > 0 { sillLog("[shelf] purged \(removed) orphaned file copies") }
    }

    /// Removed from the shelf — the copy is deleted too, or the folder grows
    /// silently. The box goes by id regardless of where `path` points:
    /// mid-copy the item still points at the original, and checking the path
    /// let the box survive removal
    private static func dropCopy(of item: Item) {
        try? FileManager.default.removeItem(at: directory.appending(path: item.id.uuidString))
    }

    private func persist() { context.settings.set("items", items) }

    // MARK: - file actions

    func open(_ item: Item) {
        guard let url = url(of: item) else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ item: Item) {
        guard let url = url(of: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// File icon — same as Finder's. Cached by path: icons are requested every
    /// frame, and asking the system for one isn't free
    func icon(of item: Item) -> NSImage {
        if let cached = Self.icons[item.path] { return cached }
        let icon = url(of: item).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .item)
        Self.icons[item.path] = icon
        return icon
    }

    private static var icons: [String: NSImage] = [:]
}
