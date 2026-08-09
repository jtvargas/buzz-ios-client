import BuzzKit

/// The pushed conversation's row, resolved from the three sources that can know it.
///
/// Internal rather than private, static rather than a method, and `nonisolated`, so the
/// priority below is asserted directly instead of through a navigation stack — the defect it
/// covers *is* the ordering. Same shape and same reason as
/// ``ThreadReadMarks/pruned(_:)``.
extension ChannelListView {
    /// The row a pushed conversation is drawn with, in order of authority.
    ///
    /// The live list first, always: it is the only source with this channel's unread
    /// counts, mute flag and last message, and a conversation reached through the browser
    /// must render identically to the same one reached from the sidebar.
    ///
    /// Then a row handed in by the surface that pushed. Since the membership flip the live
    /// list carries only channels whose roster names this identity, so a channel browsed
    /// but not joined is legitimately absent from it — and a freshly joined one is absent
    /// for as long as it takes the sidebar's own observation to see the roster commit. In
    /// both cases the pushing surface knows the channel's name and the list does not yet.
    /// This is what ``ConversationRoute/knownPeers`` already does for a DM's people: carry
    /// what is known but not yet projected, and let the projection take over when it lands.
    ///
    /// **Display only.** This row names the conversation and nothing else; it is a snapshot
    /// taken while the browse sheet was open and it stays frozen for the life of the push,
    /// so no gate may read it. What a reader may *do* here is read live from the store by
    /// ``ChannelAccessModel`` on every commit.
    ///
    /// Only then the placeholder, which names nothing — ``EntityNames/channelName(for:)``
    /// resolves it to *Untitled conversation*. That is the honest answer for a channel this
    /// app has genuinely never heard of, and the wrong one for a channel a browse row was
    /// showing by name a moment earlier.
    ///
    /// `nonisolated` is load-bearing, not tidiness. `ChannelListView` is a `View` and so is
    /// `@MainActor`; a static declared on it inherits that, and the isolation of the
    /// `first(where:)` closure below is then checked at *runtime* when a synchronous
    /// non-isolated caller reaches it. A test calling this off the main actor traps in
    /// `dispatch_assert_queue` — and only when `live` is non-empty, because an empty array
    /// never runs the closure. That is a crash which hides behind whichever cases happen to
    /// pass no rows.
    nonisolated static func conversationRow(
        for channelID: String,
        in live: [ChannelListRow],
        fallback: ChannelListRow?
    ) -> ChannelListRow {
        if let existing = live.first(where: { $0.id == channelID }) { return existing }
        // Matched on id: a row handed in for a different channel is not a name for this
        // one, and taking it would put a stranger's title on the conversation.
        if let fallback, fallback.id == channelID { return fallback }
        return ChannelListRow(
            id: channelID,
            name: nil,
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
    }

    /// The route an outside navigation request becomes, or `nil` for a plain screen — which
    /// the caller already knows how to open on its own.
    ///
    /// Here rather than beside its caller for the same reason as the row above: it reads
    /// nothing the view holds. The snapshot is the only source of a name at this moment — an
    /// intent can arrive before the sidebar's model exists — and ``conversationRow(for:in:)``
    /// composes the live list over whatever is handed in, so a channel the sidebar already
    /// knows still draws its real row.
    nonisolated static func route(for target: AppTarget) -> InAppNotificationRoute? {
        switch target {
        case .destination:
            return nil
        case let .conversation(id):
            let named = ConversationEntitySnapshotStore().fallbackRow(id: id)
            return InAppNotificationRoute(
                location: .channel(id.native),
                fallbackChannel: conversationRow(for: id.native, in: [], fallback: named)
            )
        case let .thread(channelID, rootID):
            return InAppNotificationRoute(
                location: .thread(channelID: channelID, rootID: rootID),
                fallbackChannel: conversationRow(for: channelID, in: [], fallback: nil)
            )
        }
    }

    /// The static above fed this view's live channel list — the form every caller inside the
    /// view wants, and the reason ``ChannelListView/model`` is not `private`.
    func conversationRow(for channelID: String, fallback: ChannelListRow? = nil) -> ChannelListRow {
        Self.conversationRow(for: channelID, in: model.channels, fallback: fallback)
    }
}
