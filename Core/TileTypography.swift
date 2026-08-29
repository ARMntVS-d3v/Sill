import SwiftUI

// Tile typography — one set for every widget and all three sizes.
// Font size doesn't depend on tile size: a different point size in the
// square vs. the large tile reads as sloppiness. Size changes how much is
// shown, not the type scale.
// Values are system ones: NSFont.systemFontSize 13, smallSystemFontSize 11,
// labelFontSize 10.
enum TileFont {
    /// The tile's headline number: event time, battery charge, exchange rate, temperature
    static let hero = Font.system(size: 28, weight: .medium, design: .rounded)
    /// Title of the main object: event name, track title, city
    static let title = Font.system(size: 14, weight: .medium)
    /// Status line under the title: "happening now", "in 20 min", "−2.4%"
    static let status = Font.system(size: 12)
    /// List row
    static let row = Font.system(size: 13)
    /// Numeric value in a list row — tabular figures
    static let rowValue = Font.system(size: 12)
    /// Secondary text: location, caption, "and 4 more"
    static let caption = Font.system(size: 11)
    /// Corner label on a tile: date, counter, "live"
    static let label = Font.system(size: 11, weight: .medium)
    /// Axis labels on charts — the only thing smaller than 11
    static let axis = Font.system(size: 10)
    /// Large number at the center of a ring: timer in the large size
    static let heroLarge = Font.system(size: 34, weight: .medium, design: .rounded)
    /// Companion to the headline number: an event's end time under its start
    /// time, "until 1:30 PM". Same rounded design as hero, but half as loud
    static let heroSecondary = Font.system(size: 12, weight: .medium, design: .rounded)
}

// Icon sizes — as closed a list as font sizes. An arbitrary size in a widget
// drifts from its neighbors: one tile's icon at 16, another's at 17, and the
// board stops looking assembled.
enum TileIcon {
    /// Icon inside a list row or next to a number
    static let glyph = Font.system(size: 13)
    /// Secondary control button: previous and next track
    static let control = Font.system(size: 14, weight: .medium)
    /// Primary control button: play and pause
    static let controlPrimary = Font.system(size: 15, weight: .semibold)
    /// Large state icon for a tile: current weather, a note in an empty music tile
    static let hero = Font.system(size: 22)
    /// Icon next to secondary text: event location, meeting link, task flag,
    /// wind and humidity. Matches TileFont.caption in size — any larger and
    /// it reads as a sticker next to the text it sits beside
    static let caption = Font.system(size: 11)
    /// Small icon in a checkbox, corner badge
    static let badge = Font.system(size: 9, weight: .bold)
}

// Padding and radii inside tiles — as closed a list as font sizes. A number
// that isn't here shouldn't show up in layout code.
enum TileMetrics {
    /// Inner padding of tile content
    static let padding: CGFloat = 13
    /// Text padding over artwork: the image itself already creates margin
    static let paddingOverArtwork: CGFloat = 11
    /// Gap between list rows inside a tile
    static let rowGap: CGFloat = 8
    /// Gap before a list block (after the headline number or a label)
    static let blockGap: CGFloat = 10
    /// Gap between the headline number and its caption
    static let captionGap: CGFloat = 6
    /// Thumbnail radius: album art in the capsule, clipboard entry preview, file icon
    static let thumbRadius: CGFloat = 6
    /// Highlight radius for a rectangular hit area
    static let hitRadius: CGFloat = 7
    /// Radius of a floating bar over content (search in the clipboard). The
    /// tile radius (14) at a height of 32 gives a pill, but the bar should
    /// read as a rounded square, like macOS controls
    static let floatRadius: CGFloat = 10
    /// Fill strip: progress, track scrubber, metric gauge
    static let trackHeight: CGFloat = 3
    /// Width of the left column in a rectangle tile: primary content left, details right
    static let sideColumn: CGFloat = 104
    /// Step between rows of the dense number table in system metrics. Denser than
    /// rowGap: five metrics with bars have to fit a 152-pt square
    static let meterGap: CGFloat = 7
    /// The same table when even that doesn't fit — with a battery there are five
    /// rows, and on a longer locale they ran off the tile edge
    static let meterGapDense: CGFloat = 4
}

// Round control buttons inside a tile: player, timer. Diameter depends on
// tile size (slightly larger in a square tile, where it's the only control);
// icon glyph size never varies. Kept in one table since a timer and a music
// widget on the same board have to match.
enum TileControlMetrics {
    /// Primary button: play and pause
    static func primary(_ size: TileSize) -> CGFloat {
        switch size {
        case .small: 32
        case .medium: 30
        case .large: 38
        }
    }

    /// Secondary: next track, reset timer — 6 smaller than primary
    static func secondary(_ size: TileSize) -> CGFloat { primary(size) - 6 }

    /// Clear button inside an input field (13-pt circled cross): the hit zone is
    /// the same as a button in a list row
    static let fieldClearHit: CGFloat = 20

    /// Gap between buttons
    static func gap(_ size: TileSize) -> CGFloat {
        switch size {
        case .small: 6
        case .medium: 10
        case .large: 14
        }
    }
}
