import BuzzKit
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Channel-list model", .timeLimit(.minutes(1)))
struct ChannelListModelTests {
    @Test("reflects an ingested kind-39000 channel and its latest message without manual refresh")
    func reflectsIngestedChannel() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let author = try Fixture()
        let message = try author.event(
            .channelMessage,
            "hello there",
            tags: [["h", "general"], ["p", relay.pubkey]],
            at: 1_000
        )

        let model = ChannelListModel(store: store)
        let run = Task { await model.run() }
        defer { run.cancel() }

        // The model streams the change in — nothing calls a refresh.
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", picture: "https://x/pic", at: 500),
            message,
        ], phase: .backfill)

        await waitUntil { model.channels.first?.lastMessageSnippet == "hello there" }

        let channel = try #require(model.channels.first)
        #expect(channel.id == "general")
        #expect(channel.name == "General")
        #expect(channel.picture == "https://x/pic")
        #expect(channel.lastMessageID == message.id)
        // No kind-0 profile for the author, so the row falls back to the raw pubkey.
        #expect(channel.lastMessageAuthor == author.pubkey)
        #expect(model.channels.count == 1)
    }

    @Test("unread count reflects others' messages past the frontier and clears live when marked read")
    func unreadCountTracksReadState() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey)
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            try peer.message("one", in: "general", at: 1_000),
            try peer.message("two", in: "general", at: 2_000),
        ], phase: .backfill)
        try await store.markChannelAccess(identity: reader.pubkey, channel: "general", state: .active)

        await waitUntil { model.channels.first?.unreadCount == 2 }
        #expect(model.channels.first?.hasUnread == true)

        // Marking read up to the newest clears the badge live — `read_state` is tracked
        // by the observation, so no message needs to arrive to refresh the count.
        try await store.applyReadState(
            author: reader.pubkey, slot: "phone", contexts: ["general": 2_000],
            sourceCreatedAt: 10, sourceEventID: "e"
        )
        await waitUntil { model.channels.first?.unreadCount == 0 }
        #expect(model.channels.first?.hasUnread == false)
    }

    @Test("the mention badge counts only the unread messages addressed to the reader, live")
    func mentionCountTracksReadState() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey)
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            try peer.message("nothing to do with you", in: "general", at: 1_000),
            try peer.event(
                .channelMessage, "hey @reader",
                tags: [["h", "general"], ["p", reader.pubkey]], at: 2_000
            ),
        ], phase: .backfill)
        try await store.markChannelAccess(identity: reader.pubkey, channel: "general", state: .active)

        await waitUntil { model.channels.first?.unreadCount == 2 }
        #expect(model.channels.first?.unreadMentionCount == 1)

        // Reading past the mention clears the badge while an ordinary unread remains
        // behind it — the two counts move independently.
        try await store.applyReadState(
            author: reader.pubkey, slot: "phone", contexts: ["general": 2_000],
            sourceCreatedAt: 10, sourceEventID: "e"
        )
        await waitUntil { model.channels.first?.unreadMentionCount == 0 }
    }

    @Test("a newer message reorders the list live")
    func newerMessageUpdatesPreview() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let author = try Fixture()

        let model = ChannelListModel(store: store)
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            try author.message("first", in: "general", at: 1_000),
        ], phase: .backfill)
        await waitUntil { model.channels.first?.lastMessageSnippet == "first" }

        _ = try await store.ingest(batch: [
            try author.message("second", in: "general", at: 2_000),
        ], phase: .live)
        await waitUntil { model.channels.first?.lastMessageSnippet == "second" }

        #expect(model.channels.first?.lastMessageAt == 2_000)
    }

    @Test("initialization primes the first workspace frame from the verified snapshot")
    func initializationPrimesVerifiedSnapshot() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let reader = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
        ], phase: .backfill)
        try await store.markChannelAccess(identity: reader.pubkey, channel: "general", state: .active)

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey)

        #expect(model.hasLoaded)
        #expect(model.channels.map(\.id) == ["general"])
    }

    @Test("channel access initializes from persisted terminal state")
    func channelAccessInitializesFromStore() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let reader = try Fixture()
        try await store.markChannelAccess(identity: reader.pubkey, channel: "gone", state: .deleted)

        let model = ChannelAccessModel(
            channelID: "gone",
            identity: reader.pubkey,
            store: store
        )

        #expect(model.state == .deleted)
        #expect(model.isWritable == false)
    }

    /// Keyless is not a lock, and this is the branch that says so:
    /// ``ChannelAccessModel/init(channelID:identity:store:)`` answers `.active` outright
    /// when there is no identity, because access is recorded *per reader* and a session
    /// with nobody in it has nobody to have lost it. Falling through to the store instead
    /// would read no row, resolve `.unavailable`, and tell a reader their own conversation
    /// is read-only — a claim the relay would immediately contradict.
    ///
    /// Both readers of this flag are conversation surfaces that hide the composer and strip
    /// the actions sheet down to its read-only shape on it — `ChannelTimelineView` and
    /// `ThreadView`. So getting this wrong locks a signed-out reader out of writing
    /// anywhere, on a path no other test walks: every other keyless case in the app suite
    /// is about what gets *listed*, not what may be written.
    @Test("no identity is writable, not merely unknown")
    func channelAccessWithoutIdentityIsWritable() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()

        // Deliberately a channel the store has never heard of: with an identity that is
        // exactly the shape that resolves `.unavailable`, so the assertion below fails if
        // the nil case ever stops being answered ahead of the read.
        let model = ChannelAccessModel(channelID: "general", identity: nil, store: store)

        #expect(model.state == .active)
        #expect(model.isWritable)
    }

    @Test("launch and fallback surfaces expose stable recovery copy")
    func directoryPresentationCopy() {
        #expect(ChannelBootstrapView.message == "Connecting…")
        #expect(
            ChannelDirectoryFallbackBanner.message
                == "Couldn’t refresh channels — showing saved conversations"
        )
    }
}

/// What the sidebar is allowed to draw before the relay has answered for this identity.
@MainActor
@Suite("Channel directory surface", .timeLimit(.minutes(1)))
struct ChannelDirectorySurfaceTests {
    /// The defect this whole surface exists for: the store holds a row for a channel the
    /// relay has since removed, and until the relay has answered there is no way to tell it
    /// from a row that is still real. So a launch draws neither.
    @Test("a cached channel is held but never listed before the relay has answered")
    func cachedChannelIsNotListedBeforeAuthority() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let reader = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("stale", name: "Deleted Elsewhere", at: 500),
        ], phase: .backfill)
        try await store.markChannelAccess(identity: reader.pubkey, channel: "stale", state: .active)

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey)

        #expect(model.surface == .connecting)
        // Held, because a name still resolves from it…
        #expect(model.channels.map(\.id) == ["stale"])
        // …and not listed, because nothing has confirmed it exists.
        #expect(model.visibleChannels.isEmpty)
    }

    @Test("an authoritative verdict is what lets the sidebar list conversations")
    func authoritativeVerdictRevealsConversations() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let reader = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
        ], phase: .backfill)
        try await store.markChannelAccess(identity: reader.pubkey, channel: "general", state: .active)

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey)
        #expect(model.visibleChannels.isEmpty)

        model.adopt(.authoritative)

        #expect(model.surface == .conversations)
        #expect(model.visibleChannels.map(\.id) == ["general"])
    }

    /// The read has to land *before* the flip, in one step. The verdict stream and the
    /// store's change observation are independent, so a flip that trusted the observation
    /// to have already fired would draw the pre-snapshot rows for a frame — the flash.
    @Test("adopting an authoritative verdict re-reads the store rather than waiting to be told")
    func authoritativeVerdictReReadsTheStore() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let reader = try Fixture()

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey)
        // No observation is running: `run()` is deliberately never started here, so the
        // only thing that can put this channel on screen is the adoption itself.
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("arrived", name: "Arrived", at: 500),
        ], phase: .backfill)
        try await store.markChannelAccess(identity: reader.pubkey, channel: "arrived", state: .active)
        #expect(model.visibleChannels.isEmpty)

        model.adopt(.authoritative)

        #expect(model.visibleChannels.map(\.id) == ["arrived"])
    }

    @Test("a re-check after a good answer keeps that answer on screen")
    func recheckDoesNotBlankAnAnsweredList() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let reader = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
        ], phase: .backfill)
        try await store.markChannelAccess(identity: reader.pubkey, channel: "general", state: .active)

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey, answerDeadline: .milliseconds(30))
        model.adopt(.authoritative)

        model.adopt(.checking)
        #expect(model.surface == .conversations)
        // The same for a refresh that fails outright: the banner says so, the list stays.
        model.adopt(.cachedFallback)
        // Long enough that a deadline armed in error would have fired.
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.surface == .conversations)
        #expect(model.visibleChannels.map(\.id) == ["general"])
    }

    @Test("a first attempt that fails says so, and offers no saved list in its place")
    func failedFirstAttemptBecomesUnreachable() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let reader = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("stale", name: "Deleted Elsewhere", at: 500),
        ], phase: .backfill)
        try await store.markChannelAccess(identity: reader.pubkey, channel: "stale", state: .active)

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey, answerDeadline: .milliseconds(30))
        model.adopt(.cachedFallback)

        await waitUntil { model.surface == .unreachable }
        #expect(model.visibleChannels.isEmpty)
    }

    /// The deadline is armed by a verdict that is merely *outstanding*, not only by one that
    /// failed. Nothing bounds the signed directory request itself, so a relay that accepts
    /// the connection and never answers never produces a failure to react to — and the
    /// reader would wait on placeholder rows indefinitely.
    @Test("a relay that never answers at all is still reported")
    func outstandingVerdictAlsoArmsTheDeadline() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let reader = try Fixture()

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey, answerDeadline: .milliseconds(30))
        model.adopt(.checking)

        await waitUntil { model.surface == .unreachable }
    }

    /// The other half of the deadline: an answer inside it takes the pending word with it.
    @Test("an answer inside the deadline cancels it")
    func answerCancelsTheDeadline() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let reader = try Fixture()

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey, answerDeadline: .milliseconds(40))
        model.adopt(.checking)
        model.adopt(.authoritative)

        try await Task.sleep(for: .milliseconds(150))
        #expect(model.surface == .conversations)
    }

    /// The engine cycles between `.checking` and `.cachedFallback` while it retries. Each
    /// pass used to re-arm the wait, so the recovery screen — and the Retry button on it —
    /// flickered back to placeholder rows, sometimes under the reader's finger.
    @Test("the unreachable surface is not taken back by further retry verdicts")
    func unreachableLatchesUntilAnswered() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let reader = try Fixture()

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey, answerDeadline: .milliseconds(20))
        model.adopt(.cachedFallback)
        await waitUntil { model.surface == .unreachable }

        model.adopt(.checking)
        #expect(model.surface == .unreachable)
        model.adopt(.cachedFallback)
        #expect(model.surface == .unreachable)

        // Only an answer takes it back.
        model.adopt(.authoritative)
        #expect(model.surface == .conversations)
    }

    @Test("the pill names the connection, not the directory")
    func pillNamesTheConnection() {
        #expect(SidebarStatusPill.label(for: .stopped, hasConnectedBefore: false) == "Connecting…")
        #expect(SidebarStatusPill.label(for: .starting, hasConnectedBefore: false) == "Connecting…")
        #expect(SidebarStatusPill.label(for: .starting, hasConnectedBefore: true) == "Reconnecting…")
        // A live socket with the answer still outstanding: the connection is no longer
        // what the reader is waiting on.
        #expect(SidebarStatusPill.label(for: .running, hasConnectedBefore: true) == "Loading…")
        #expect(SidebarStatusPill.label(for: .suspended, hasConnectedBefore: true) == "Loading…")
    }
}
