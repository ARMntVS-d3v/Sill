import Foundation

struct GridPoint: Codable, Sendable, Equatable, Hashable {
    var col: Int
    var row: Int
}

struct Tile: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var widgetID: String
    var size: TileSize
    var origin: GridPoint
}

struct Board: Codable, Identifiable, Sendable, Equatable {
    /// A regular board is a grid of tiles. Clipboard takes over the whole board:
    /// it's a searchable list that doesn't fit a 152×152 tile and shouldn't be a widget
    enum Kind: String, Codable, Sendable {
        case tiles, clipboard
    }

    var id: UUID
    var name: String
    var icon: String
    var themeName: String?
    var tiles: [Tile]
    var kind: Kind = .tiles

    // Old configs don't know about kind — decode with a default
    enum CodingKeys: String, CodingKey {
        case id, name, icon, themeName, tiles, kind
    }

    init(id: UUID, name: String, icon: String, themeName: String?, tiles: [Tile], kind: Kind = .tiles) {
        self.id = id
        self.name = name
        self.icon = icon
        self.themeName = themeName
        self.tiles = tiles
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        themeName = try container.decodeIfPresent(String.self, forKey: .themeName)
        tiles = try container.decode([Tile].self, forKey: .tiles)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .tiles
    }
}

struct AppConfig: Codable, Sendable {
    static let currentVersion = 2

    var version: Int
    var boards: [Board]
    var activeBoardID: UUID

    static func makeDefault() -> AppConfig {
        let board = Board(
            id: UUID(),
            name: String(localized: "Board 1"),
            icon: "square.grid.2x2",
            themeName: nil,
            tiles: [
                Tile(id: UUID(), widgetID: "calendar", size: .large, origin: GridPoint(col: 0, row: 0)),
                Tile(id: UUID(), widgetID: "calendar", size: .medium, origin: GridPoint(col: 2, row: 0)),
                Tile(id: UUID(), widgetID: "calendar", size: .small, origin: GridPoint(col: 2, row: 1)),
                Tile(id: UUID(), widgetID: "weather", size: .small, origin: GridPoint(col: 3, row: 1)),
            ]
        )
        return AppConfig(version: AppConfig.currentVersion, boards: [board], activeBoardID: board.id)
    }
}

@MainActor
enum ConfigStore {
    static var fileURL: URL {
        URL.homeDirectory.appending(path: ".config/sill/config.json")
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            let config = AppConfig.makeDefault()
            save(config)
            return config
        }
        do {
            var config = try JSONDecoder().decode(AppConfig.self, from: data)
            if config.version != AppConfig.currentVersion {
                // Repair BEFORE writing: otherwise broken state (no boards, active
                // board doesn't exist) could hit disk unrepaired
                config = repaired(migrate(config))
                save(config)
                return config
            }
            return repaired(config)
        } catch {
            // Back up the broken file and log it: manual recovery always beats
            // silently losing someone's boards
            sillLog("[config] couldn't parse, falling back to default: \(error)")
            let backup = fileURL.deletingLastPathComponent()
                .appending(path: "config.broken.json")
            try? data.write(to: backup, options: .atomic)
            let config = AppConfig.makeDefault()
            save(config)
            return config
        }
    }

    /// Migrate from an older version. So far the format has only gained fields,
    /// so bumping the version number is enough — but the extension point needs to
    /// exist ahead of time: the first post-release update must never wipe boards
    private static func migrate(_ config: AppConfig) -> AppConfig {
        var migrated = config
        sillLog("[config] migrating \(config.version) → \(AppConfig.currentVersion)")
        migrated.version = AppConfig.currentVersion
        return migrated
    }

    /// Repair obviously broken state: with no boards the panel is a dead end,
    /// and the active board must exist
    private static func repaired(_ config: AppConfig) -> AppConfig {
        var result = config
        if result.boards.isEmpty {
            result.boards = AppConfig.makeDefault().boards
        }
        if !result.boards.contains(where: { $0.id == result.activeBoardID }) {
            result.activeBoardID = result.boards[0].id
        }
        return result
    }

    static func save(_ config: AppConfig) {
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            // Config failed to save — that's lost work, can't stay silent
            sillLog("[config] failed to save: \(error)")
        }
    }
}
