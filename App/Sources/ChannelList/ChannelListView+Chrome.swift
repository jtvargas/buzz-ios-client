import SwiftUI

/// The sidebar's fixed furniture: the words it says, the marks it draws, how far in it lays
/// them out, and what a heading shows when it has no rows.
///
/// Everything here is independent of what is *in* the list — none of it reads a model, a
/// route, or anything else this view holds — which is why it can live outside
/// ``ChannelListView``'s own file at all. That is also the whole reason it does: `private`
/// at file scope is `fileprivate`, so anything touching the view's `@State` cannot be moved
/// out, and this is the part that does not.
///
/// Internal rather than `fileprivate` for the reason ``ChannelListView+ConversationRow``
/// gives — the language leaves no narrower option across files. Nothing outside
/// ``ChannelListView`` calls the two view builders; ``communitySymbol`` is the one member
/// here with a caller elsewhere (``RootView``, while the identity gate is being composed).
extension ChannelListView {
    /// The fallback mark used before an active community graph exists. The running home
    /// heading uses ``activeCommunityMark`` so a cached picture or initials can replace this
    /// symbol without waiting for a relay response. RootView still needs this fallback while
    /// the identity gate is being composed.
    static let communitySymbol = "hexagon.fill"

    /// The one heading drawn in the accent: the workspace's own name is what the colour
    /// is *for*, where every other heading names a conversation inside it.
    static let communityMark = ConversationTitleBar.Mark.symbol(communitySymbol, accented: true)

    /// Carries the persisted community mark into the title-bar seam without asking the
    /// relay for anything. Kept pure so the cached-data contract can be pinned without
    /// launching a navigation stack.
    static func communityHeadingMark(
        name: String,
        iconData: Data?
    ) -> ConversationTitleBar.Mark {
        .community(name: name, iconData: iconData)
    }

    /// What VoiceOver is told about the marked row. Names the gesture rather than the
    /// colour, because the colour is not the point and cannot be perceived here anyway.
    static let resumeHint = "Last opened. Swipe left on this screen to reopen it."

    /// Why the sidebar is empty when the relay cannot be reached. It names the rule rather
    /// than apologising for it: Hive lists the conversations the relay confirms, so with no
    /// relay there is nothing it can honestly list.
    static let unreachableMessage =
        "Hive lists the conversations the relay confirms you’re in, so there’s nothing to show "
            + "until it answers. Your messages are still saved."

    /// How far a heading sits in from the screen's edges. Padding rather than `listRowInsets`,
    /// since the heading shares its cell with the rows — the same 16pt either way.
    static let headerInsetH: CGFloat = 16

    /// The cards sit slightly clear of the first heading's rule below them.
    static let cardsInsets = EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16)

    /// What a persistent heading shows instead of rows.
    ///
    /// A plain line of secondary text, not a `ContentUnavailableView`: that one centres
    /// itself in whatever space it is given and is built to own a screen, so inside a
    /// `List` row it opens a gap the size of the rest of the sidebar. This has to read
    /// as one quiet row under its heading.
    ///
    /// It is not a button. Nothing on this phone starts a direct message — a DM begins
    /// from a person, on their profile — so an empty DMs heading that offered a tap
    /// would be offering a dead end.
    func emptySectionLine(_ section: SidebarSection) -> some View {
        Text(section.emptyMessage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6 + SidebarRowMetrics.contentInsetV)
            .padding(.horizontal, SidebarRowMetrics.contentInsetH)
            .accessibilityIdentifier("sidebar-section-empty-\(section.rawValue)")
    }

    /// The relay answered, and the answer is that this key is in nothing.
    var emptyState: some View {
        ContentUnavailableView(
            "No conversations yet",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Channels and direct messages appear here as they sync from the relay.")
        )
    }
}
