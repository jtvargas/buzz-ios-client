import SwiftUI
import UIKit

/// What holding a finger on a link puts on the clipboard.
///
/// # The href, never the words on it
///
/// A link card's title is frequently *not* its URL — an authored `[The scroll fix](…/pull/61)`
/// puts the author's words on the card, and a known provider puts `jtvargas/buzz-ios-client #61`
/// there instead (see ``LinkPreview``). Copying what is drawn would hand back a label that
/// cannot be pasted anywhere useful, and — for a link whose label disagrees with its target —
/// would actively mislead the one reader most entitled to an answer: the one holding the link
/// *because* they want to know where it goes.
///
/// Desktop settled this the same way and it is worth matching deliberately rather than by
/// coincidence: `desktop/src/shared/ui/markdown.tsx`, `ExternalLinkAnchor`, copies `href` in its
/// right-click "Copy link", and `useVideoContextMenu.tsx` does the same for media.
///
/// # Why there is no toast
///
/// "Copy Message" in ``MessageActionsSheet`` answers with the sheet closing — the copy is
/// visible because the thing that asked for it goes away. A card has no sheet to close, so the
/// haptic is the whole answer, and it is the same one the row plays when *its* long press lands.
/// One hold, one bump, whichever of the two things under the finger took it.
enum LinkCopy {
    /// How long a link has to be held before it is a copy rather than a tap.
    ///
    /// Deliberately the same number as `TimelineRowView.longPressDuration`, and duplicated here
    /// rather than read from it: this renderer draws messages on surfaces that have no timeline
    /// row behind them at all — the sidebar snippet, the Threads summary — and reaching into a
    /// specific surface for a constant is the coupling ``ClaimRowTapAction`` exists to avoid.
    ///
    /// The two must not drift. A card that answers a hold at a different moment than the message
    /// around it reads as two different gestures on one message, and the reader cannot see which
    /// of the two they are aiming at. If one of these changes, change both.
    static let longPressDuration: TimeInterval = 0.35

    /// What a held link puts on the clipboard: where it points, as it would be opened.
    ///
    /// `absoluteString` of the ``LinkPreview/url``, which is the normalised target rather than
    /// the characters the author typed — a bare `github.com/a/b` was already promoted to
    /// `https://` so that the card and the tap agree, and a copied link that does not agree with
    /// the one that would open is the same defect one level along.
    static func value(for preview: LinkPreview) -> String {
        preview.url.absoluteString
    }

    /// Copies the link and says so with the one signal available.
    ///
    /// `@MainActor` here and deliberately *not* on the type: ``value(for:)`` above is the rule
    /// this feature is actually about, it touches nothing isolated, and a test asking what a
    /// card would copy should not have to hop an actor to find out. Only the two side effects
    /// need the main one — `UIPasteboard.general` and ``HiveHaptics`` are both isolated to it
    /// under this target's complete concurrency checking.
    @MainActor
    static func copy(_ preview: LinkPreview) {
        UIPasteboard.general.string = value(for: preview)
        HiveHaptics.play(.longPress)
    }
}
