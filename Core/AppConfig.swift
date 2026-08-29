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

    enum CodingKeys: String, CodingKey {
        case id, widgetID, size, origin
    }

    init(id: UUID, widgetID: String, size: TileSize, origin: GridPoint) {
        self.id = id
        self.widgetID = widgetID
        self.size = size
        self.origin = origin
    }

    // An unknown size value (config from a newer version after a downgrade)
    // must not throw: one unreadable enum used to take the whole file down
    // with it — every board replaced by the defaults
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        widgetID = try container.decode(String.self, forKey: .widgetID)
        let rawSize = try container.decodeIfPresent(String.self, forKey: .size)
        size = rawSize.flatMap { TileSize(rawValue: $0) } ?? .small
        origin = try container.decode(GridPoint.self, forKey: .origin)
    }
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
        // Unknown kind (a newer version's board after a downgrade) falls back
        // to a tile board instead of throwing away the whole config
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap { Kind(rawValue: $0) } ?? .tiles
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
        // Out-of-grid origins come from hand-edited or imported JSON. They
        // can't be let through: any pass over cells computes origin + size,
        // and an origin near Int.max traps the whole app. A displaced tile
        // moves to the first free spot; with no room left it's dropped, logged
        for boardIndex in result.boards.indices {
            var kept: [Tile] = []
            var displaced: [Tile] = []
            for tile in result.boards[boardIndex].tiles {
                if BoardLayout.isInsideBoard(origin: tile.origin, size: tile.size) {
                    kept.append(tile)
                } else {
                    displaced.append(tile)
                }
            }
            guard !displaced.isEmpty else { continue }
            for var tile in displaced {
                if let spot = BoardLayout.firstFreeSpot(for: tile.size, in: kept) {
                    tile.origin = spot
                    kept.append(tile)
                    sillLog("[config] \(tile.widgetID) tile was outside the grid, moved to \(spot.col),\(spot.row)")
                } else {
                    sillLog("[config] \(tile.widgetID) tile was outside the grid, no room left — dropped")
                }
            }
            result.boards[boardIndex].tiles = kept
        }
        // Duplicate tile ids (hand-edited or imported JSON) collapse two tiles
        // into one host: the dictionary is keyed by id, and the second tile
        // silently showed the first one's widget. The duplicate gets a fresh
        // id; its per-tile settings belong to the original and stay with it
        var seenTiles: Set<UUID> = []
        for boardIndex in result.boards.indices {
            for tileIndex in result.boards[boardIndex].tiles.indices {
                let id = result.boards[boardIndex].tiles[tileIndex].id
                if seenTiles.contains(id) {
                    result.boards[boardIndex].tiles[tileIndex].id = UUID()
                    sillLog("[config] duplicate tile id \(id) — reassigned")
                }
                seenTiles.insert(result.boards[boardIndex].tiles[tileIndex].id)
            }
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
