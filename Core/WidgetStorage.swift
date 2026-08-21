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

    init(widgetID: String) {
        self.widgetID = widgetID
        let dir = URL.applicationSupportDirectory.appending(path: "Sill/cache")
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
        guard let blob = try? JSONEncoder().encode(Self.stores[widgetID]) else { return }
        let url = fileURL
        Task.detached(priority: .utility) {
            try? blob.write(to: url, options: .atomic)
        }
    }
}
