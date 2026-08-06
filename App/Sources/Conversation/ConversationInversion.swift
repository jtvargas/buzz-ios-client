import SwiftUI

/// The flip that makes a conversation list hold a reader's place.
///
/// # Why the list is upside down
///
/// A `LazyVStack` estimates the height of every row it has not measured, and inserting an
/// older page above the reader changes that estimate by thousands of points *in instalments*
/// over the frames that follow. Measured on iPhone 17 Pro / iOS 26.1, a 50-row page landing
/// above a reader, worst single-step displacement:
///
/// | | displacement |
/// |---|---|
/// | plain bottom-anchored list | 3344 pt |
/// | `.scrollTargetLayout()` | 3471 pt |
/// | id-bound `ScrollPosition` | 2551 / 3205 pt |
/// | `scrollTo(id:)` in the same update | 4843 pt |
/// | proxy `scrollTo` + computed anchor | 4063 pt |
/// | next-runloop, animation-disabled re-pin | 2743 pt |
/// | **inverted** | **9.7 pt at rest, 17.7 pt mid-flick** |
///
/// Every aimed correction loses for one reason: the extent re-computes after you aim
/// (7.9k → 12.4k → 15.2k pt inside ~50 ms), so the coordinate space the target was resolved
/// in is gone by the next frame. This is why ``ConversationReaderPlace`` says the anchor has
/// to be a row and not a number, and why even making it a row is not enough on its own.
///
/// Inversion does not correct anything. It moves the estimated rows to the far side of the
/// reader: newest-first order in a flipped scroll view means the newest message sits at the
/// scroll view's *origin*, every row between the reader and it is materialised and real, and
/// an older page appends past the end where nothing is looking. The estimation error still
/// exists — it simply pools where it cannot move anybody.
///
/// # How the two halves fit
///
/// The scroll view is flipped once, by ``ConversationScaffold``. Every row is flipped back by
/// this same modifier, so it draws the right way up. The owner supplies its items
/// **newest-first**. Miss any one of the three and the conversation renders upside down or
/// scrolls backwards, which is why they are named rather than written out at each site.
///
/// A `scaleEffect` rather than a `rotationEffect`: both invert the axis, and the scale is the
/// one that does not also mirror horizontally, so text and leading-edge alignment are
/// untouched.
extension View {
    /// Inverts this view vertically — applied once to the scroll view, and once to each row
    /// inside it to cancel that out.
    func conversationInverted() -> some View {
        scaleEffect(x: 1, y: -1, anchor: .center)
    }
}
