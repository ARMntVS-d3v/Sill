import SwiftUI

// Panel edge style. Variants that didn't make the cut (a plain outer hairline
// outline) aren't in the set — see docs/design.md.
enum PanelEdgeStyle: String, Codable, CaseIterable, Sendable {
    case innerGlow      // sheen on the inner edge + outer shadow (default)
    case depth          // no line, just a soft shadow
    case underLight     // glowing arc along the bottom edge
    case softThick       // thick soft line with a greenish halo
    case phosphorRim    // rim that brightens toward the bottom corners
    case none           // nothing

    var label: String {
        switch self {
        case .innerGlow: String(localized: "Gleam")
        case .depth: String(localized: "Depth")
        case .underLight: String(localized: "Underglow")
        case .softThick: String(localized: "Soft")
        case .phosphorRim: String(localized: "Rim")
        case .none: String(localized: "None")
        }
    }
}

// Panel background. The notch strip stays black in every variant: the notch
// must dissolve into it, otherwise it shows up as a dark rectangle.
enum PanelBackgroundStyle: String, Codable, CaseIterable, Sendable {
    case graphite       // flat dark graphite (default)
    case black          // pure black, as it originally was
    case halo           // accent-colored glow under the notch, fading toward the middle
    case material       // desktop blur under a veil, like system panels
    case aurora         // two patches of light on the sides, below the notch
    case underGlow      // light from below, as if the panel sits on a backlight
    case spot           // soft neutral spot at the center of the board

    var label: String {
        switch self {
        case .graphite: String(localized: "Graphite")
        case .black: String(localized: "Black")
        case .halo: String(localized: "Halo")
        case .material: String(localized: "Material")
        case .aurora: String(localized: "Glow")
        // Not "Underglow": the edge picker right above has an item with that
        // exact label, and one catalog string can't be two different translations
        // (the same collision "Clear" once had)
        case .underGlow: String(localized: "Backlight")
        case .spot: String(localized: "Spotlight")
        }
    }
}

// Tile style.
enum TileStyle: String, Codable, CaseIterable, Sendable {
    case flat           // flat fill, no lines (default)
    case screen         // phosphor screen: glow at the top, fading to black at the bottom
    case topHighlight   // dark fill + a light streak along the top edge
    case outline        // no fill, just a hairline outline
    case raised         // lighter fill + shadow: a card sitting above the panel
    case bare           // no fill, no lines; background only under the cursor
    case glass          // glass with a light film — how Apple does surfaces
    case glassDark      // darker glass: film tinted like the tile
    case matte          // same surface, but no glass: film and a thin edge

    var label: String {
        switch self {
        case .flat: String(localized: "Flat")
        case .screen: String(localized: "Screen")
        case .topHighlight: String(localized: "Sheen")
        case .outline: String(localized: "Outline")
        case .raised: String(localized: "Raised")
        case .bare: String(localized: "Bare")
        case .glass: String(localized: "Glass")
        case .glassDark: String(localized: "Dark Glass")
        case .matte: String(localized: "Matte")
        }
    }
}

// Shell appearance settings. Not a theme: a theme is colors, this is the shape of surfaces.
@MainActor @Observable
final class Appearance {
    var edge: PanelEdgeStyle {
        didSet { UserDefaults.standard.set(edge.rawValue, forKey: "appearance.edge") }
    }
    var tile: TileStyle {
        didSet { UserDefaults.standard.set(tile.rawValue, forKey: "appearance.tile") }
    }
    var background: PanelBackgroundStyle {
        didSet { UserDefaults.standard.set(background.rawValue, forKey: "appearance.background") }
    }
    init() {
        let defaults = UserDefaults.standard
        edge = defaults.string(forKey: "appearance.edge")
            .flatMap(PanelEdgeStyle.init(rawValue:)) ?? .innerGlow
        tile = defaults.string(forKey: "appearance.tile")
            .flatMap(TileStyle.init(rawValue:)) ?? .glassDark
        background = defaults.string(forKey: "appearance.background")
            .flatMap(PanelBackgroundStyle.init(rawValue:)) ?? .graphite
    }
}
