import Foundation

// Per-instance widget settings. Keys: widget.<widgetID>.<tileID>.<key> in UserDefaults.
@MainActor
final class WidgetSettings {
    private let prefix: String

    init(widgetID: String, tileID: UUID) {
        prefix = "widget.\(widgetID).\(tileID.uuidString)."
    }

    func get<T: Codable>(_ key: String, as type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: prefix + key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func set<T: Codable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: prefix + key)
    }

    /// The tile is gone — every key of this instance goes with it. Called by
    /// the shell on removal, so no widget can forget: settings used to outlive
    /// their tiles forever (36 of 40 widget.* keys on a live machine were
    /// leftovers, notes and translator history included)
    func removeAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Launch-time sweep for tiles deleted before removal cleaned up after
    /// itself. A key names its tile: widget.<widgetID>.<tileID>.<key> —
    /// anything whose tile isn't on any board is a leftover
    static func purgeOrphans(keeping alive: Set<UUID>) {
        let defaults = UserDefaults.standard
        var removed = 0
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("widget.") {
            let parts = key.split(separator: ".")
            guard parts.count >= 4, let tileID = UUID(uuidString: String(parts[2])),
                !alive.contains(tileID)
            else { continue }
            defaults.removeObject(forKey: key)
            removed += 1
        }
        if removed > 0 { sillLog("[storage] purged \(removed) orphaned tile settings") }
    }
}

// Widget data disk cache: in-memory reads are synchronous (disk is read
// once), writes hit memory immediately and disk asynchronously. Namespace =
// widget id, shared across all its tiles.
@MainActor
final class WidgetCache {
    private let widgetID: String
    private let fileURL: URL
    /// Shared across all tiles of a widget, and lives in one place: separate
    /// per-instance copies would let one tile's write clobber keys another
    /// tile added — of two weather tiles, only one would survive on disk
    private static var stores: [String: [String: Data]] = [:]

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Sill/cache")
    }

    init(widgetID: String) {
        self.widgetID = widgetID
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "\(widgetID).json")
        if Self.stores[widgetID] == nil {
            Self.stores[widgetID] = (try? Data(contentsOf: fileURL))
                .flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
        }
    }

    func load<T: Codable>(_ key: String, as type: T.Type) -> T? {
        guard let data = Self.stores[widgetID]?[key] else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Codable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        Self.stores[widgetID, default: [:]][key] = data
        persistToDisk()
    }

    /// A tile keyed its data by its own id and is being removed — the entry
    /// must go too, or the cache file grows with every deleted tile
    func remove(_ key: String) {
        guard Self.stores[widgetID]?.removeValue(forKey: key) != nil else { return }
        persistToDisk()
    }

    private func persistToDisk() {
        guard let blob = try? JSONEncoder().encode(Self.stores[widgetID]) else { return }
        let url = fileURL
        let widgetID = widgetID
        Task.detached(priority: .utility) {
            do {
                try blob.write(to: url, options: .atomic)
            } catch {
                // A silently failed write is a silently broken offline
                // fallback — the config logs the same failure, so does this
                sillLog("[cache] failed to save \(widgetID): \(error)")
            }
        }
    }

    /// Launch-time sweep of entries left by tiles deleted before removal
    /// cleaned up. Only keys that ARE a tile id can be judged: widgets also
    /// keep non-per-tile keys ("today" in the calendar), and those stay
    static func purgeOrphans(keeping alive: Set<UUID>) {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let widgetID = file.deletingPathExtension().lastPathComponent
            var store =
                stores[widgetID]
                ?? (try? Data(contentsOf: file))
                .flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) }
                ?? [:]
            let orphans = store.keys.filter { key in
                guard let id = UUID(uuidString: key) else { return false }
                return !alive.contains(id)
            }
            guard !orphans.isEmpty else { continue }
            for key in orphans { store.removeValue(forKey: key) }
            if stores[widgetID] != nil { stores[widgetID] = store }
            if let blob = try? JSONEncoder().encode(store) {
                try? blob.write(to: file, options: .atomic)
            }
            sillLog("[storage] purged \(orphans.count) orphaned cache entries from \(widgetID)")
        }
    }
}
