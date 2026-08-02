import SwiftUI

/// The seam where a conversation is not continuous: history the screen holds on both
/// sides, with a stretch in between it has never read.
///
/// # Why this exists rather than nothing
///
/// Landing on a linked message from deep history reads a *window* around it instead of
/// paging the whole way down, so the loaded set arrives with a hole in it. Without a seam
/// the hole is not invisible — it is worse than invisible. ``ConversationGrouping`` puts a
/// day separator between the window and the head because they genuinely are different
/// days, so a three-week gap renders as an ordinary change of date. The reader is told
/// something, and what they are told is wrong.
///
/// # Why it loads on appearance rather than offering a button
///
/// It is the mirror of the top-of-history sentinel: scrolling into it is the request. A
/// reader moving down from the linked message toward the present is asking for exactly the
/// messages this stands for, and a control they have to find and press between them and
/// the rest of the conversation is a stile in the middle of a corridor.
///
/// # Fixed height, and deliberately not bound to the load
///
/// The same lesson the top sentinel records: `closeGap()` has no suspension point, so its
/// in-flight flag is set and cleared inside one MainActor turn and no frame is ever drawn
/// while it is `true`. Binding this row's appearance to it would look honest and be dead.
/// The row stands for "the conversation is broken here", which is true until the page
/// lands and removes the row altogether.
struct ConversationGapRow: View {
    /// Fired when the seam comes into view. Idempotent at the model, because a lazy stack
    /// can create this row more than once across one load.
    let onAppear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            rule
            Text(Self.label)
                .font(.hive(.caption2, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            rule
        }
        .padding(.horizontal, DaySeparatorView.leadingInset)
        .frame(height: Self.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.label)
        .onAppear(perform: onAppear)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 0.5)
    }

    /// What the seam says.
    ///
    /// Not "older messages" and not "newer messages": the reader arrives here from either
    /// direction, so a word about which way the missing history lies is wrong half the time.
    /// What is true from both sides is that the conversation does not join up here.
    static let label = "Messages in between aren't loaded"

    /// A constant, so the row does not change the content height while it is on screen —
    /// see the note above. Removing it does change the height, which is an ordinary
    /// content change the surface already declares.
    static var height: CGFloat { 32 }
}
