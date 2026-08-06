import SwiftUI

/// The one rounded rectangle the sidebar draws under a row, and the numbers that place it.
///
/// They live here rather than as literals in ``ChannelListView`` because **two different things
/// draw this rectangle from two different coordinate spaces**, and the owner has now caught them
/// disagreeing twice — once on their insets and once on their size under a finger. The same
/// reasoning as ``MessageRowMetrics``: values that have to agree across files are values that
/// get changed in one of them.
///
/// # The two drawers, and the two attempts at making them agree
///
/// ``ChannelListView/resumeMark(isResumable:)`` is a `listRowBackground`: it is handed the
/// **whole row cell** and insets itself by ``insetH`` and ``insetV``. The press wash is a
/// `background` behind the row's `Button`, so it can only ever be the size of that button.
///
/// The first attempt gave the button a `Shape` that returned a path *larger* than the rect it
/// was handed, reaching back out to the mark. A render test proved the path really is drawn
/// unclipped by `.background` — and the owner reported the rows still not matching. The
/// remaining explanation is the one that fix could not reach: a `List` row's content is laid out
/// inside a container inset by `listRowInsets`, and that container clips. A path can escape its
/// own background. It cannot escape the cell.
///
/// **So the spacing moved instead of the drawing.** ``rowInsets`` is now the *mark's* inset, and
/// ``labelPaddingH``/``labelPaddingV`` carry the content the rest of the way in. The button's
/// frame is therefore the mark's rectangle exactly, by construction — there is nothing left to
/// escape, and the wash, the mark and the row's hit area are one rectangle. It is also the same
/// shape as ``ActivityRowMetrics``, which had the same fix for a different reason.
///
/// # A plain `enum`, deliberately
///
/// Not static members on ``ChannelListView``: a `View` is `@MainActor`, and a main-actor
/// constant cannot be read as the default value of a nonisolated test's stored property. The
/// numbers are geometry, not view state; a namespace with no isolation is what they actually are.
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

    /// The cell's inset: up to the highlight, and no further. This is what makes the button's
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
