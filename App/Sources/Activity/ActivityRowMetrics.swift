import SwiftUI

/// Where an activity row's content sits, and where its press highlight sits around it.
///
/// # The split this type exists to hold
///
/// The row's spacing used to be entirely `listRowInsets` — 16 across and 10 down, applied to the
/// cell, *outside* the row's `Button`. That put the content in the right place and left the press
/// wash with nothing to draw in: ``PressTreatment`` fills the button's own frame, and the button's
/// frame was exactly the content, so the highlight ended flush against the avatar and the text.
/// The owner's word for it was that the highlight needed *some spacing in its area*.
///
/// So the same total is now split in two, and the split is the whole point:
///
/// - ``rowInsets`` — the cell's inset. It stops where the **highlight** starts, so this is what
///   decides how far the wash sits from the screen edge and from the row above it;
/// - ``labelPaddingH`` / ``labelPaddingV`` — inside the button, between the wash and the content.
///   This is the breathing room that did not exist before.
///
/// **Their sum is where the content lands, and it has not moved**: 8 + 8 across and 4 + 6 down,
/// the same 16 and 10 as before. `ActivityRowMetricsTests` asserts that, because the whole change
/// is meant to be invisible except for the highlight, and the arithmetic is the only thing saying
/// so.
///
/// A namespace rather than literals in two files, for the reason ``SidebarRowMetrics`` is one:
/// these numbers are only correct *relative to each other*, and the pair got split across a view
/// and a row precisely so a later hand could change one of them.
enum ActivityRowMetrics {
    /// How far the highlight sits from the cell's edges.
    ///
    /// 8 across is not a fresh choice — it is ``SidebarRowMetrics/insetH``, so a pressed activity
    /// row and a marked sidebar row are the same distance from the same screen edge. 4 down is
    /// this list's own: its rows are much taller than the sidebar's and carry three lines, so the
    /// 1pt the sidebar uses would read as two highlights touching.
    static let highlightInsetH: CGFloat = SidebarRowMetrics.insetH
    static let highlightInsetV: CGFloat = 4

    /// Where the content ends up — unchanged from when this was all one inset.
    static let contentInsetH: CGFloat = 16
    static let contentInsetV: CGFloat = 10

    /// The cell's inset: up to the highlight, and no further.
    static let rowInsets = EdgeInsets(
        top: highlightInsetV,
        leading: highlightInsetH,
        bottom: highlightInsetV,
        trailing: highlightInsetH
    )

    /// The rest of the way in, inside the button, so the wash has something to draw in.
    /// Derived rather than typed: these two and ``rowInsets`` must add up to the content insets.
    static let labelPaddingH = contentInsetH - highlightInsetH
    static let labelPaddingV = contentInsetV - highlightInsetV
}
