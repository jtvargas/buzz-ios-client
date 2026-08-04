import BuzzKit
@testable import Hive
import Testing

/// What a conversation pushed from the browser is drawn with.
///
/// Pure, and asserted directly rather than through a navigation stack: the whole defect
/// this covers is a *priority* between three sources, and a stack test would exercise
/// SwiftUI's push instead of the ordering.
@Suite("Browse-channels route")
struct BrowseChannelsRouteTests {
    private static func row(_ id: String, name: String?) -> ChannelListRow {
        ChannelListRow(
            id: id,
            name: name,
            about: nil,
            picture: nil,
            isPrivate: false,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
    }

    /// The live list keeps its priority. It is the only source carrying unread counts, the
    /// mute flag and the last message, so a conversation reached through the browser has to
    /// render identically to the same conversation reached from the sidebar.
    @Test("the live list wins over a handed row")
    func liveRowWins() {
        let live = ChannelListRow(
            id: "general",
            name: "general",
            about: nil,
            picture: nil,
            isPrivate: false,
            lastMessageAt: 1_000,
            lastMessageSnippet: "hello there",
            lastMessageAuthor: "ana",
            unreadCount: 3
        )
        let handed = Self.row("general", name: "stale name from the catalogue")

        let resolved = ChannelListView.conversationRow(
            for: "general",
            in: [live],
            fallback: handed
        )

        #expect(resolved == live)
        #expect(resolved.unreadCount == 3)
    }

    /// The bug: since the membership flip the live list carries only channels whose roster
    /// names this identity, so a browsed-but-not-joined channel is legitimately absent from
    /// it — and used to open titled *Untitled conversation* despite the browse row having
    /// just drawn its name.
    @Test("a channel the live list does not carry is drawn with the handed row")
    func handedRowFillsTheGap() {
        let resolved = ChannelListView.conversationRow(
            for: "announcements",
            in: [Self.row("general", name: "general")],
            fallback: Self.row("announcements", name: "announcements")
        )

        #expect(resolved.name == "announcements")
    }

    /// A handed row for a *different* channel is not a name for this one. Cheap to assert
    /// and the one way the fallback could put the wrong title on a conversation.
    @Test("a handed row for another channel is ignored")
    func mismatchedFallbackIsIgnored() {
        let resolved = ChannelListView.conversationRow(
            for: "announcements",
            in: [],
            fallback: Self.row("general", name: "general")
        )

        #expect(resolved.name == nil)
    }

    /// The placeholder survives for a channel nothing knows anything about — the create
    /// path inside the browser hands `nil`, because a create returns an id and the
    /// catalogue has not read the new channel yet.
    @Test("with neither source the placeholder still stands")
    func placeholderRemains() {
        let resolved = ChannelListView.conversationRow(for: "brand-new", in: [], fallback: nil)

        #expect(resolved.id == "brand-new")
        #expect(resolved.name == nil)
        #expect(resolved.isPrivate)
    }
}
