import SwiftUI

/// Gives a block the height its own text needs, instead of the height its parent
/// happened to offer it.
///
/// # The failure this exists to remove
///
/// A SwiftUI `Text` offered less height than its wrapped lines need does not overflow
/// its box and it does not clip: it **re-lays out into the height it was given and puts
/// an ellipsis at the cut**. With no line limit anywhere in the message, that is the
/// only way a rendered message can lose words — and a reader sees a table cell or a
/// list item ending in `…` with the rest of the sentence simply gone.
///
/// Two of the renderer's blocks put a `Text` under a parent that decides heights for it:
/// a list row (a marker and its text in an `HStack`) and a table cell (a `Grid` cell,
/// sized by a row that spans several columns). Both were reported truncated on device;
/// a paragraph, which is a direct child of the message's own `VStack` and is offered an
/// unspecified height, never was. `fixedSize(vertical:)` is the modifier that settles
/// it: the block reports the height it actually needs and is handed that height, whatever
/// the parent proposed. The quote block — the renderer's *other* `HStack` — has carried
/// exactly this since it was written, which is the same defect found and fixed once in
/// one place.
///
/// # Why it reads the line limit
///
/// `fixedSize(vertical:)` **overrides `lineLimit`**. Applied unconditionally it would
/// undo the clamp the Threads summary rows depend on — `ThreadActivityRow` renders a
/// message at six lines, and a list item inside one would expand to the whole item.
/// So the modifier is a no-op wherever a limit is in force: on a surface that has said
/// how many lines it wants, the limit is the answer, and truncation there is the point
/// rather than the bug.
struct RichTextIdealHeight: ViewModifier {
    /// The line limit the surrounding surface asked for, or `nil` on a surface reading
    /// the whole message — which is both conversation surfaces and the thread.
    @Environment(\.lineLimit) private var lineLimit

    func body(content: Content) -> some View {
        // Vertical only. The width still comes from the parent, so a table cell keeps
        // its cap and a list item keeps the row's measure.
        content.fixedSize(horizontal: false, vertical: lineLimit == nil)
    }
}

extension View {
    /// See ``RichTextIdealHeight``. On a block whose parent decides its height.
    func richTextIdealHeight() -> some View {
        modifier(RichTextIdealHeight())
    }
}
