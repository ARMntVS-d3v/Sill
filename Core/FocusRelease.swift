import SwiftUI

// Panel closed — the cursor must leave every field. Otherwise it blinks on
// next open wherever it was left: in a note, the "Ask" bar, clipboard search.
// The panel isn't a document; a field's focus shouldn't survive it closing.
private struct FocusRelease: ViewModifier {
    @Environment(AppState.self) private var appState
    let focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.onChange(of: appState.isPanelVisible) { _, visible in
            if !visible { focused.wrappedValue = false }
        }
    }
}

extension View {
    /// Release focus from a field when the panel leaves the screen
    func releasesFocusOnHide(_ focused: FocusState<Bool>.Binding) -> some View {
        modifier(FocusRelease(focused: focused))
    }
}
