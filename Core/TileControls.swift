import SwiftUI

// Active zones inside a tile: player buttons, a scrub line, text fields,
// checkboxes. The tile shouldn't move if a gesture starts on one of these —
// dragging happens on the background, not on a button. A widget marks its
// elements with `.tileControl()`, and the shell excludes those rectangles
// from the drag zone.
//
// Rule going forward: any new interactive element inside a tile gets this
// modifier. Without it, the element still works, but the tile starts
// dragging out from under the pointer when trying to use it.

struct TileControlBounds: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Mark an element as active: tile dragging won't start from it
    func tileControl() -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TileControlBounds.self,
                    value: [geometry.frame(in: .named(TileCoordinateSpace.name))])
            }
        )
    }
}

enum TileCoordinateSpace {
    static let name = "sill.tile"
}
