import SwiftUI

extension View {
    /// Dismisses `autocomplete`'s suggestion panel — and *only* the panel — once the
    /// list this is attached to has travelled a notch.
    ///
    /// # Why not a tap gesture
    ///
    /// The channel and the thread each used to carry
    /// `.simultaneousGesture(TapGesture().onEnded { autocomplete.dismissComposer() })`,
    /// and `dismissComposer()` resigns first responder. So *any* tap in the message
    /// list — a reaction chip, a replies button, a link — closed the keyboard. That is
    /// the reported "keyboard sometimes disappears unexpectedly". The keyboard belongs
    /// to the scroll view's interactive dismissal; the only thing a scroll should close
    /// is the panel floating over the rows.
    ///
    /// # Why not `onScrollPhaseChange`
    ///
    /// That modifier (like `onScrollGeometryChange`) binds to a scroll view found
    /// inside the view it is attached to, and ``ConversationScaffold`` holds more than
    /// one — the suggestion panel scrolls its own results. Attached high enough to see
    /// the message list, it can just as well bind to the panel, in which case scrolling
    /// the suggestions would clear them. Reading the content's own position in the
    /// `.scrollView` coordinate space is unambiguous instead: that space always
    /// resolves to the *enclosing* scroll view.
    ///
    /// The projection is quantised so the action runs once per ``notch`` of travel
    /// rather than on every scrolled frame, and it re-reads `suggestions` before
    /// writing, so a scroll with no panel up costs one comparison.
    func dismissesSuggestionsOnScroll(_ autocomplete: MentionAutocompleteModel) -> some View {
        onGeometryChange(for: Int.self) { proxy in
            let offset = proxy.frame(in: .scrollView).minY
            // An unresolved layout can hand back a non-finite origin, and `Int(_:)`
            // traps on one.
            guard offset.isFinite else { return 0 }
            return Int(offset / notch)
        } action: { _ in
            if !autocomplete.suggestions.isEmpty {
                autocomplete.dismiss()
            }
        }
    }
}

/// How far the list travels before the suggestion panel is considered stale: far
/// enough not to fire on a rubber-band settle, near enough to feel immediate.
private let notch: CGFloat = 40
