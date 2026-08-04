import SwiftUI

/// The one rounded rectangle the sidebar draws under a row, and the numbers that place it.
///
/// They live here rather than as literals in ``ChannelListView`` because **two different things
/// draw this rectangle from two different coordinate spaces**, and the owner has now caught them
/// disagreeing twice — once on their insets and once on their size under a finger. The same
/// reasoning as ``MessageRowMetrics``: values that have to agree across files are values that
/// get changed in one of them.
///
/// # The two drawers, and why they kept parting
///
/// - ``ChannelListView/resumeMark(isResumable:)`` is a `listRowBackground`. It is handed the
///   **whole row cell** and insets itself by ``insetH`` and ``insetV`` from that.
/// - the press wash is a `background` *inside* the row's `Button`, which ``rowInsets`` has
///   already pulled in by 16 and 2. Drawn plainly it lands 8pt narrower on each side and 1pt
///   shorter — which is what ``pressMark`` gives back.
///
/// Neither declaration was ever wrong on its own. That is exactly why this file exists: the
/// defect lives in the relationship, so the relationship is what gets named and tested.
///
/// # A plain `enum`, deliberately
///
/// Not static members on ``ChannelListView``, and not on ``SidebarRowMark`` either. Both of
/// those are `View`s — `Shape` refines `View` — so both are `@MainActor`, and a main-actor
/// constant cannot be read as the default value of a nonisolated test's stored property. The
/// numbers are geometry, not view state; a namespace with no isolation is what they actually are.
enum SidebarRowMetrics {
    /// The row's own insets inside its `List` cell.
    static let rowInsets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)

    /// The mark's inset from the whole cell, per axis, and its corner.
    ///
    /// Measured back off a device screenshot on 2026-08-04 to confirm they are what ships:
    /// on a 440pt-wide sidebar the mark drew 424pt across, 8pt clear of each edge, with a
    /// corner that reaches full width about 9pt in.
    static let insetH: CGFloat = 8
    static let insetV: CGFloat = 1
    static let radius: CGFloat = 10

    /// What the resume mark is filled with.
    ///
    /// Deliberately **not** ``PressFeedback/pressedFill``. This is the *place* mark and that is
    /// a press; they are one hue at two strengths on purpose, and the press is the dimmer of the
    /// two so a finger cannot be mistaken for where you were. Now that they also share a
    /// rectangle, this difference is the only thing left telling them apart — equalising them is
    /// what got the press wash removed from this list once already.
    static let opacity: Double = 0.14

    /// The mark's rectangle, expressed from inside the row's button.
    ///
    /// Computed from the numbers above rather than typed as `8` and `1`, so that moving
    /// ``rowInsets`` or the mark's own inset keeps the two aligned instead of silently parting.
    /// `SidebarRowMarkTests` holds them to each other.
    static var pressMark: SidebarRowMark {
        SidebarRowMark(
            outsetH: rowInsets.leading - insetH,
            outsetV: rowInsets.top - insetV,
            radius: radius
        )
    }
}

/// The sidebar's row mark, drawn from inside a view that already sits within the row's insets.
///
/// # Why a `Shape` and not padding
///
/// ``PressFeedbackButtonStyle`` fills the shape a control names for itself behind that control's
/// own frame. What has to be described here is a rectangle **larger** than the view it is drawn
/// behind — the press wash has to reach back out to where ``ChannelListView/resumeMark(isResumable:)``
/// sits, and that mark is measured from the whole row cell rather than from inside
/// ``SidebarRowMetrics/rowInsets``.
///
/// `path(in:)` may return a path outside the rect it is handed, and a `background` does not clip
/// its content, so an outset is expressible here and nowhere else in that API. It stays inside
/// the row cell regardless: the outset only gives back what `rowInsets` took, so the widest this
/// ever draws is exactly the mark.
struct SidebarRowMark: Shape {
    /// How far past the pressed view's own bounds the mark reaches, per axis. Always the
    /// difference between the row's insets and the mark's — never typed as a literal.
    let outsetH: CGFloat
    let outsetV: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: rect.insetBy(dx: -outsetH, dy: -outsetV))
    }
}
