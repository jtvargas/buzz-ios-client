import SwiftUI

/// Takes the keyboard once a pushed conversation has settled, when the arrival asked for
/// it — the "Reply in thread" arrival, and the Drafts screen's.
///
/// # Why it waits
///
/// The wait is the whole content of this. ``TokenTextView`` applies focus only once its
/// view is in a window, because `becomeFirstResponder` before that fails silently and
/// leaves SwiftUI's flag and UIKit's responder disagreeing; and
/// ``ConversationKeyboardRelease`` records the other half of the same asymmetry — a
/// keyboard arriving while the view is *not* settled leaves the root's bottom safe area at
/// the home-indicator value, because SwiftUI's keyboard avoidance is driven by the keyboard
/// appearing under a view that is on screen. A `.task` runs at the *start* of the push,
/// which is neither of those moments.
///
/// `UINavigationController`'s push is a third of a second; this clears it with room and is
/// still short enough that the keyboard reads as part of the same movement.
///
/// One modifier rather than a copy in each conversation surface: a thread and a channel are
/// the same push, so they must not drift to different delays — and the second copy is
/// exactly where a number like this goes stale.
extension View {
    func focusesComposerOnArrival(
        _ isRequested: Bool,
        focus: @escaping @MainActor () -> Void
    ) -> some View {
        task {
            guard isRequested else { return }
            try? await Task.sleep(for: ConversationComposerFocus.delay)
            guard !Task.isCancelled else { return }
            focus()
        }
    }
}

enum ConversationComposerFocus {
    /// How long the composer waits before taking the keyboard. See the note above.
    static let delay: Duration = .milliseconds(450)
}
