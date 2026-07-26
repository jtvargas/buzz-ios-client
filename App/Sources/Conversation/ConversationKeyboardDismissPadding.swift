import SwiftUI
import UIKit

extension View {
    /// Extends the interactive keyboard-dismissal gesture upward by `points`, so it
    /// engages at the composer's top edge instead of the keyboard's.
    ///
    /// See ``ConversationKeyboardDismissPadding`` for what was measured and why this is
    /// the only lever that exists for it.
    func keyboardDismissPadding(_ points: CGFloat) -> some View {
        background {
            ConversationKeyboardDismissPadding(points: points)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// Tells UIKit that the band the composer occupies is part of the keyboard's dismissal
/// gesture.
///
/// # What is wrong without it
///
/// `.scrollDismissesKeyboard(.interactively)` does not start moving the keyboard when the
/// drag starts. It starts when the touch **reaches the keyboard's own top edge** — so the
/// composer's band is a dead zone, and a drag that ends inside it does nothing at all.
/// WWDC23's "Keep up with the keyboard" names this directly: *"the keyboard dismiss
/// gesture doesn't begin until the touch intersects the keyboard"*, and
/// `keyboardDismissPadding` is the property it introduces to fix it.
///
/// Whether SwiftUI's own `ScrollView` honours a property set on a UIKit layout guide is
/// documented nowhere, so it was measured on iPhone 17 Pro / iOS 26.0 in a harness built
/// around the shipping ``ConversationScaffold`` (`~/.buzz/.scratch/kbdragharness`), with a
/// `CADisplayLink` recording the keyboard's and the composer's positions every frame while
/// XCUITest held a real finger mid-drag. The same drag, ending inside the composer band
/// and 70pt above the keyboard:
///
/// | | frames the keyboard moved | keyboard after release |
/// |---|---|---|
/// | without the padding | **0** | still up |
/// | with the padding | **17**, one per display frame | dismissed |
///
/// With it, the composer's top edge tracks the fingertip exactly, and the gap between the
/// composer and the keyboard held at its resting 112pt on every frame.
///
/// # Why the app's root view
///
/// The dismissal is UIKit's, driven by the scroll view's own pan; this only widens where
/// that gesture engages. Set on the window's root view, where the guide spans the whole
/// window — a guide is clamped to its owning view's bounds, and asked of a small view it
/// answers with that view's own edge (measured: 418 with the keyboard at 529). It is put
/// back to zero on the way out, so the widened band belongs to a conversation and does not
/// outlive one.
///
/// # What this is not
///
/// Not keyboard avoidance. Nothing here reads a keyboard height, insets anything, or moves
/// the composer — the shell still has exactly one bottom inset and no observer (see
/// ``ConversationScaffold``). It changes *when the gesture engages*, not where anything is
/// laid out.
struct ConversationKeyboardDismissPadding: UIViewRepresentable {
    let points: CGFloat

    func makeUIView(context _: Context) -> UIView {
        let view = Applier()
        view.isUserInteractionEnabled = false
        view.points = points
        return view
    }

    func updateUIView(_ view: UIView, context _: Context) {
        (view as? Applier)?.points = points
    }

    final class Applier: UIView {
        /// The one that arrived most recently. Pushing a thread over a channel puts two
        /// of these in the hierarchy at once, and which of "the new one arrives" and "the
        /// old one leaves" happens first is UIKit's business — so arriving always claims
        /// the value, and leaving only gives it back if it is still this one's to give.
        /// Comparing the *value* instead would not do: a thread's composer is usually
        /// exactly as tall as the channel's it came from.
        private static weak var owner: Applier?

        var points: CGFloat = 0 {
            didSet {
                guard points != oldValue, Self.owner === self else { return }
                apply(points)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Also the way back: popping a thread returns this view to the window, and
            // nothing else would re-state the channel's own band.
            guard window != nil else { return }
            Self.owner = self
            apply(points)
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            // Given back while the window is still attached — the last moment the host can
            // be reached at all, the same asymmetry ``ConversationKeyboardRelease`` exists
            // for.
            guard newWindow == nil, Self.owner === self else { return }
            Self.owner = nil
            apply(0)
        }

        private func apply(_ points: CGFloat) {
            guard let host = window?.rootViewController?.view else { return }
            host.keyboardLayoutGuide.keyboardDismissPadding = points
        }
    }
}
