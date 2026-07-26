import SwiftUI
import UIKit

extension View {
    /// Hands the keyboard back when this surface *begins* leaving the screen, then calls
    /// `release` so the surface can clear the focus state it owns.
    ///
    /// A keyboard belonging to a composer that is no longer on screen is the defect, not
    /// the symptom — see ``ConversationKeyboardRelease`` for what was measured and why the
    /// two cheaper hooks do not work.
    func releasesKeyboardWhenLeavingScreen(then release: @escaping () -> Void) -> some View {
        background {
            ConversationKeyboardRelease(release: release)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// Resigns whatever inside a conversation holds the keyboard, at the moment the
/// conversation starts being pushed off the screen or popped from it.
///
/// # What goes wrong without it
///
/// Measured on iPhone 17 Pro / iOS 26.0 in an isolated harness reproducing this shell
/// (`~/.buzz/.scratch/navharness`, the technique in `IOS_KEYBOARD_SCROLL_VERIFICATION.md`),
/// focusing a channel's composer and then pushing a thread:
///
/// 1. the channel's hosting view leaves the window and UIKit **force-resigns** the
///    composer's first responder on the way out — `textViewDidEndEditing` arrives with no
///    SwiftUI request behind it;
/// 2. popping back, UIKit **restores** that first responder itself, before SwiftUI's first
///    update pass on the returning view — the harness logged
///    `updateUIView … firstResponder=true` followed by an unrequested
///    `textViewDidBeginEditing`;
/// 3. the keyboard therefore comes back up, but the returning view's root **bottom
///    safe-area inset stays 34** — the home-indicator value — where a keyboard raised
///    while the view is on screen puts it at 345. SwiftUI's keyboard avoidance is driven
///    by the keyboard *appearing*, and from its point of view nothing appeared.
///
/// `safeAreaBar(edge: .bottom)` then lays the composer at 34 with the keyboard covering
/// the bottom 311 points of the screen, which is exactly the report: the composer does not
/// reattach above the keyboard after a thread pop.
///
/// # Why this hook and not a cheaper one
///
/// Both cheaper hooks were measured in the same harness and fail:
///
/// - `onDisappear` runs *after* the transition finishes. The force-resign has already
///   happened by then, and it is the force-resign that registers the responder for
///   restoration, so nothing is prevented.
/// - Clearing the SwiftUI focus flag in `viewWillDisappear` also fails: SwiftUI's next
///   update pass landed after the window had gone, and `resignFirstResponder` before the
///   view is in a window fails *silently* (the same asymmetry ``TokenTextView``'s
///   `view.window != nil` guard exists for). The harness logged the force-resign arriving
///   first, and the restoration on the way back regardless.
///
/// Only a resign performed while the view is still in its window leaves UIKit nothing to
/// restore, and `viewWillDisappear` is the last moment that is true. A child view
/// controller receives the appearance callbacks of the controller hosting it, which is
/// what makes a zero-sized representable a legitimate way to observe them.
///
/// # Why this cannot drop a keyboard someone is using
///
/// `viewWillDisappear` fires for a navigation transition, not for a presentation over the
/// top. Measured: presenting a sheet over a focused composer produced no callback, left
/// the responder alone, and the bottom inset returned to 345 when the sheet was dismissed —
/// so opening channel details or a profile mid-draft keeps the keyboard, and so does
/// typing, which is not an appearance change at all.
private struct ConversationKeyboardRelease: UIViewControllerRepresentable {
    let release: () -> Void

    func makeUIViewController(context _: Context) -> Controller {
        let controller = Controller()
        controller.release = release
        return controller
    }

    func updateUIViewController(_ controller: Controller, context _: Context) {
        controller.release = release
    }

    final class Controller: UIViewController {
        var release: () -> Void = {}

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Asked of the window rather than of `view`: this controller's own view has no
            // subtree, and `endEditing(_:)` only searches the receiver's descendants. The
            // window is the nearest ancestor guaranteed to contain the composer, and it is
            // still attached at this point — which is the whole reason the call is here.
            _ = viewIfLoaded?.window?.endEditing(true)
            // The resign above is reported through the text view's delegate, which writes
            // the observed flag back. This clears it from the other side too, so a flag
            // set programmatically while nothing held the keyboard cannot survive the
            // transition and re-raise it on the way back.
            release()
        }
    }
}
