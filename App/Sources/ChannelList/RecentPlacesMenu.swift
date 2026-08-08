import SwiftUI

/// One line of the history, already resolved: the place, and what the app calls it *now*.
///
/// Resolution happens through the shared ``EntityNames``, so a channel renamed since the
/// visit is listed under its new name.
struct RecentPlaceRow: Identifiable, Hashable {
    let place: RecentPlace
    let conversation: ConversationIdentity

    var id: String { place.id }
}

/// The history — the last places this reader was, newest first — as the **contents of a
/// system menu**.
///
/// # Why this is a `Menu` and not a panel
///
/// Three versions of this were drawn by hand: a `.popover` whose content the app built, the
/// same list rendered inside the sidebar, and a `.popover` again. All three were wrong in
/// the same way. A hand-drawn dropdown has to re-supply, badly, everything the system gives
/// for free — the open and close animation, the arrow, the scrim, dismissal on an outside
/// tap, scrolling, the highlight under a finger, the glass — and the owner named exactly
/// that when he said it read as slop beside Slack's.
///
/// A `Menu` is the system's own dropdown. Nothing here says how it opens, how it closes,
/// how wide it is, or what it is made of; the rows below are `Button`s and the platform
/// draws the rest. That also settles, structurally, the crash this feature shipped twice: a
/// popover's content rides to UIKit as a *presentation preference*, so a content value that
/// changes tears the presentation down — and a teardown landing in the same update as a
/// navigation traps. A menu has no presentation to tear down. It is built to be updated
/// while it is open, which is how a `Toggle` inside one draws its own checkmark.
///
/// # What a menu costs
///
/// A menu row is a title, an optional subtitle and an image — it is not a view. So the
/// sidebar's marks cannot come here: a direct message is a `person` glyph rather than the
/// peer's face. That is the same vocabulary Slack's own history uses, and the name is what
/// identifies a row in a list this short anyway.
struct RecentPlacesMenu: View {
    let rows: [RecentPlaceRow]
    let open: (RecentPlace) -> Void

    var body: some View {
        // A titled section, which is what draws "History" above the rows — the header in
        // the owner's reference, supplied by the platform rather than laid out here.
        Section("History") {
            // `.fixed` because the default order is *relative to where the menu opened*:
            // a menu that has to open upward reverses its items, which would silently put
            // the oldest place under the finger. Newest-first is the whole ordering.
            ForEach(rows) { row in
                button(row)
            }
            .menuOrder(.fixed)
        }
    }

    /// One place. Split on `isThread` rather than built with a conditional inside one
    /// label, so each button hands the menu a plain title/subtitle/image triple.
    @ViewBuilder
    private func button(_ row: RecentPlaceRow) -> some View {
        if row.place.isThread {
            Button {
                open(row.place)
            } label: {
                Text(row.conversation.title)
                // The second `Text` in a menu button's label is the row's subtitle. It is
                // what tells a thread from the channel around it when both are listed —
                // and both can be, which is the point of remembering threads separately.
                Text("Thread")
                Image(systemName: ThreadView.threadSymbol)
            }
        } else if row.conversation.kind == .agent {
            Button {
                open(row.place)
            } label: {
                Text(row.conversation.title)
                // The bot, not a person — the same lucide mark this app draws in place of
                // the `@` on a mention of an agent, and the same one desktop and Flutter
                // draw. It is a picture here rather than a path because a menu row's icon
                // is a `UIImage`; see ``AgentGlyph/templateImage``.
                Image(uiImage: AgentGlyph.templateImage)
            }
        } else {
            Button {
                open(row.place)
            } label: {
                Text(row.conversation.title)
                Image(systemName: Self.symbol(for: row.conversation))
            }
        }
    }

    /// The glyph for a conversation, in the vocabulary the sidebar already uses: `#` for a
    /// channel, a lock for a private one, a person for a direct message, two for a group.
    ///
    /// An agent is absent on purpose — its mark is not a system symbol, so it is drawn by
    /// the branch above rather than named here.
    static func symbol(for conversation: ConversationIdentity) -> String {
        switch conversation.kind {
        case .channel: conversation.isPrivate ? "lock.fill" : "number"
        case .direct, .agent: "person.fill"
        case .group: "person.2.fill"
        }
    }
}
