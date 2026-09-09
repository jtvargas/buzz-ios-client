import SwiftUI

/// Shared spacing for the sidebar's press wash, last-opened mark, and row content.
///
/// Both fills are backgrounds of the same button in ``SidebarConversationButton``.
/// `rowInsets` sits outside that button; `labelPaddingH` and `labelPaddingV` sit inside.
/// Keeping this split makes the press wash, resume mark, and hit area the same rectangle,
/// while the text stays aligned with the section heading.
///
/// A plain enum keeps these geometry constants independent of the view's actor isolation.
enum SidebarRowMetrics {
    /// The mark's inset from the whole cell, per axis, and its corner.
    ///
    /// Measured back off a device screenshot on 2026-08-04 to confirm they are what ships: on a
    /// 440pt-wide sidebar the mark drew 424pt across, 8pt clear of each edge, with a corner that
    /// reaches full width about 9pt in.
    static let insetH: CGFloat = 8
    static let insetV: CGFloat = 1
    static let radius: CGFloat = 10

    /// What the resume mark is filled with.
    ///
    /// Deliberately **not** ``PressFeedback/pressedFill``. This is the *place* mark and that is
    /// a press; they share one neutral hue at two strengths, and the press is the dimmer of the
    /// two so a finger cannot be mistaken for where you were. Now that they also share a
    /// rectangle, this difference is the only thing telling them apart — equalising them is what
    /// got the press wash removed from this list once already.
    static let opacity: Double = 0.14

    /// Where the row's content sits inside its cell — unchanged through both attempts above.
    static let contentInsetH: CGFloat = 16
    static let contentInsetV: CGFloat = 2

    /// The outer inset: up to the highlight, and no further. This is what makes the button's
    /// frame the mark's rectangle.
    static let rowInsets = EdgeInsets(top: insetV, leading: insetH, bottom: insetV, trailing: insetH)

    /// The rest of the way in, inside the button, so the wash has something to draw in.
    /// Derived, so moving either number keeps the content where it has always been.
    static let labelPaddingH = contentInsetH - insetH
    static let labelPaddingV = contentInsetV - insetV

    /// For a row that is **not** a button and so draws no highlight — the empty-section line.
    /// It wants the content position directly, since it has no label padding to add.
    static let contentInsets = EdgeInsets(
        top: contentInsetV,
        leading: contentInsetH,
        bottom: contentInsetV,
        trailing: contentInsetH
    )
}
