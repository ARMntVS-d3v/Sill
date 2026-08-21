import Foundation

// Pure board layout logic: what fits where. No SwiftUI, so it can be tested
// independently of the views.
enum BoardLayout {
    static func cells(of tile: Tile) -> Set<GridPoint> {
        cells(at: tile.origin, size: tile.size)
    }

    static func cells(at origin: GridPoint, size: TileSize) -> Set<GridPoint> {
        var result: Set<GridPoint> = []
        for col in origin.col..<(origin.col + size.columns) {
            for row in origin.row..<(origin.row + size.rows) {
                result.insert(GridPoint(col: col, row: row))
            }
        }
        return result
    }

    static func isInsideBoard(origin: GridPoint, size: TileSize) -> Bool {
        origin.col >= 0 && origin.row >= 0
            && origin.col + size.columns <= GridMetrics.columns
            && origin.row + size.rows <= GridMetrics.rows
    }

    // A spot is free if it's inside the board and doesn't overlap other tiles
    static func canPlace(
        size: TileSize, at origin: GridPoint, ignoring tileID: UUID?, in tiles: [Tile]
    ) -> Bool {
        guard isInsideBoard(origin: origin, size: size) else { return false }
        let target = cells(at: origin, size: size)
        for tile in tiles where tile.id != tileID {
            if !cells(of: tile).isDisjoint(with: target) { return false }
        }
        return true
    }

    /// A tile to swap places with. Dragging onto an occupied spot doesn't have to
    /// fail: if both tiles fit at each other's spots, they swap — the same way
    /// icons behave on the iOS home screen
    static func swapTarget(for tile: Tile, at origin: GridPoint, in tiles: [Tile]) -> Tile? {
        let wanted = cells(at: origin, size: tile.size)
        // The candidate is whoever occupies the target cells. If there's more than
        // one, the swap is ambiguous and we don't attempt it
        let blocking = tiles.filter { $0.id != tile.id && !cells(of: $0).isDisjoint(with: wanted) }
        guard blocking.count == 1, let other = blocking.first else { return nil }

        let movedTile = Tile(
            id: tile.id, widgetID: tile.widgetID, size: tile.size, origin: other.origin)
        let movedOther = Tile(
            id: other.id, widgetID: other.widgetID, size: other.size, origin: tile.origin)

        guard isInsideBoard(origin: movedTile.origin, size: movedTile.size),
              isInsideBoard(origin: movedOther.origin, size: movedOther.size),
              cells(of: movedTile).isDisjoint(with: cells(of: movedOther))
        else { return nil }

        // The rest of the tiles must not be affected
        let rest = tiles.filter { $0.id != tile.id && $0.id != other.id }
        let taken = occupied(in: rest)
        guard cells(of: movedTile).isDisjoint(with: taken),
              cells(of: movedOther).isDisjoint(with: taken)
        else { return nil }

        return other
    }

    static func occupied(in tiles: [Tile]) -> Set<GridPoint> {
        tiles.reduce(into: Set<GridPoint>()) { $0.formUnion(cells(of: $1)) }
    }

    static func freeCells(in tiles: [Tile]) -> [GridPoint] {
        let taken = occupied(in: tiles)
        var result: [GridPoint] = []
        for row in 0..<GridMetrics.rows {
            for col in 0..<GridMetrics.columns {
                let point = GridPoint(col: col, row: row)
                if !taken.contains(point) { result.append(point) }
            }
        }
        return result
    }

    // First spot a tile of this size fits into
    static func firstFreeSpot(for size: TileSize, in tiles: [Tile]) -> GridPoint? {
        for row in 0..<GridMetrics.rows {
            for col in 0..<GridMetrics.columns {
                let point = GridPoint(col: col, row: row)
                if canPlace(size: size, at: point, ignoring: nil, in: tiles) { return point }
            }
        }
        return nil
    }

    // Where a tile lands after resizing. Growth isn't limited to right and down:
    // if the right side is occupied, try shifting the origin left or up — whatever
    // fits. Candidates are ordered from closest to the current position.
    static func placement(
        for size: TileSize, preferring origin: GridPoint, ignoring tileID: UUID?, in tiles: [Tile]
    ) -> GridPoint? {
        let maxCol = GridMetrics.columns - size.columns
        let maxRow = GridMetrics.rows - size.rows
        guard maxCol >= 0, maxRow >= 0 else { return nil }

        var candidates: [GridPoint] = []
        for deltaCol in 0...(size.columns - 1) {
            for deltaRow in 0...(size.rows - 1) {
                candidates.append(GridPoint(col: origin.col - deltaCol, row: origin.row - deltaRow))
            }
        }
        // Edge-clamped fallbacks — for a tile sitting right at the board's border
        candidates.append(GridPoint(col: min(origin.col, maxCol), row: min(origin.row, maxRow)))
        candidates.append(GridPoint(col: max(min(origin.col, maxCol), 0), row: max(min(origin.row, maxRow), 0)))

        let seen = candidates.filter { $0.col >= 0 && $0.row >= 0 && $0.col <= maxCol && $0.row <= maxRow }
        for candidate in seen where canPlace(size: size, at: candidate, ignoring: tileID, in: tiles) {
            return candidate
        }
        return nil
    }

    // Sizes a tile can grow into: allowed by the widget and that fit somewhere
    static func availableSizes(
        for tile: Tile, supported: [TileSize], in tiles: [Tile]
    ) -> [TileSize] {
        supported.filter { size in
            placement(for: size, preferring: tile.origin, ignoring: tile.id, in: tiles) != nil
        }
    }
}
