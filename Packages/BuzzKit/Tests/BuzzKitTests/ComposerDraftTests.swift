@testable import BuzzKit
import Foundation
import Testing

/// The composer-draft table: what a draft is keyed by, when it is dropped, and what
/// bounds it.
@Suite("Composer drafts")
struct ComposerDraftTests {
    @Test("a draft round-trips its text and its opaque token payload")
    func roundTrip() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        try await store.saveComposerDraft(
            channel: "room-1",
            root: nil,
            text: "half a thought",
            tokens: #"[{"entity":"abc"}]"#
        )

        let draft = try #require(try store.composerDraft(channel: "room-1", root: nil))
        #expect(draft.text == "half a thought")
        #expect(draft.tokens == #"[{"entity":"abc"}]"#)
        #expect(draft.rootID == nil)
    }

    /// The product requirement, at the level the key is enforced: a channel and a thread
    /// inside it are different composers, and neither can read the other's text.
    @Test("a channel and its threads hold separate drafts")
    func channelAndThreadAreSeparate() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        try await store.saveComposerDraft(channel: "room-1", root: nil, text: "for the channel", tokens: "")
        try await store.saveComposerDraft(channel: "room-1", root: "opener", text: "for the thread", tokens: "")
        try await store.saveComposerDraft(channel: "room-2", root: nil, text: "for elsewhere", tokens: "")

        #expect(try store.composerDraft(channel: "room-1", root: nil)?.text == "for the channel")
        #expect(try store.composerDraft(channel: "room-1", root: "opener")?.text == "for the thread")
        #expect(try store.composerDraft(channel: "room-2", root: nil)?.text == "for elsewhere")
        #expect(try store.composerDraft(channel: "room-2", root: "opener") == nil)
        #expect(try store.composerDrafts().count == 3)
    }

    /// A nullable `root_id` would not do: SQLite treats two `NULL`s as distinct in a
    /// primary key, so a channel's composer would accumulate one row per save.
    @Test("re-saving a channel's composer replaces its row rather than adding one")
    func savingReplaces() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        for text in ["a", "ab", "abc"] {
            try await store.saveComposerDraft(channel: "room-1", root: nil, text: text, tokens: "")
        }

        #expect(try store.composerDrafts().count == 1)
        #expect(try store.composerDraft(channel: "room-1", root: nil)?.text == "abc")
    }

    @Test("clearing a composer deletes its draft, and whitespace counts as cleared")
    func emptyDeletes() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        try await store.saveComposerDraft(channel: "room-1", root: nil, text: "typed", tokens: "")
        try await store.saveComposerDraft(channel: "room-1", root: "opener", text: "typed", tokens: "")

        try await store.saveComposerDraft(channel: "room-1", root: nil, text: "   \n ", tokens: "")
        try await store.deleteComposerDraft(channel: "room-1", root: "opener")

        #expect(try store.composerDrafts().isEmpty)
    }

    @Test("the table keeps the most recently edited drafts and drops the rest")
    func capacityTrim() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let clock = MutableDateClock(Date(timeIntervalSince1970: 1_000))
        let store = try BuzzEventStore(path: database.path, projector: NullProjector(), clock: clock.reader)

        for index in 0 ..< 5 {
            clock.advance(by: 1)
            try await store.saveComposerDraft(
                channel: "room-\(index)",
                root: nil,
                text: "draft \(index)",
                tokens: "",
                keeping: 3
            )
        }

        let kept = try store.composerDrafts()
        #expect(kept.map(\.channelID) == ["room-4", "room-3", "room-2"])
    }

    /// Editing an old draft is what saves it from the trim — the order is last *edited*,
    /// not first written.
    @Test("editing an old draft moves it out of the eviction order")
    func editingDefersEviction() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let clock = MutableDateClock(Date(timeIntervalSince1970: 1_000))
        let store = try BuzzEventStore(path: database.path, projector: NullProjector(), clock: clock.reader)

        for index in 0 ..< 3 {
            clock.advance(by: 1)
            try await store.saveComposerDraft(channel: "room-\(index)", root: nil, text: "x", tokens: "", keeping: 3)
        }
        clock.advance(by: 1)
        try await store.saveComposerDraft(channel: "room-0", root: nil, text: "revisited", tokens: "", keeping: 3)
        clock.advance(by: 1)
        try await store.saveComposerDraft(channel: "room-9", root: nil, text: "new", tokens: "", keeping: 3)

        let kept = try store.composerDrafts().map(\.channelID)
        #expect(kept == ["room-9", "room-0", "room-2"])
        #expect(!kept.contains("room-1"))
    }

    // MARK: - The Drafts screen

    @Test("summaries come back newest edit first, clipped, and counted")
    func summaries() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let clock = MutableDateClock(Date(timeIntervalSince1970: 1_000))
        let store = try BuzzEventStore(path: database.path, projector: NullProjector(), clock: clock.reader)

        clock.advance(by: 1)
        try await store.saveComposerDraft(channel: "room-1", root: nil, text: "older", tokens: "")
        clock.advance(by: 1)
        try await store.saveComposerDraft(channel: "room-1", root: "opener", text: "newer", tokens: "")

        let rows = try store.composerDraftSummaries()
        #expect(rows.map(\.snippet) == ["newer", "older"])
        #expect(rows.map(\.rootID) == ["opener", nil])
        #expect(try store.composerDraftCount() == 2)
        // A row's identity is its composer's coordinate, so the two are distinct even
        // though they share a channel.
        #expect(Set(rows.map(\.id)).count == 2)
    }

    /// A draft may run to the message ceiling and the row shows one line of it. Reading the
    /// whole column to draw a hundred single lines is the one shape of this that could cost
    /// something.
    @Test("a long draft is clipped in SQL, not in the row")
    func summariesClip() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        try await store.saveComposerDraft(
            channel: "room-1",
            root: nil,
            text: String(repeating: "a", count: 5_000),
            tokens: ""
        )

        let clipped = try #require(try store.composerDraftSummaries(snippetLength: 32).first)
        #expect(clipped.snippet.count == 32)
        // And the draft itself is untouched — the clip is the list's, not the store's.
        #expect(try store.composerDraft(channel: "room-1", root: nil)?.text.count == 5_000)
    }

    @Test("several drafts are discarded together, and only the named ones")
    func batchDelete() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        try await store.saveComposerDraft(channel: "room-1", root: nil, text: "a", tokens: "")
        try await store.saveComposerDraft(channel: "room-1", root: "opener", text: "b", tokens: "")
        try await store.saveComposerDraft(channel: "room-2", root: nil, text: "c", tokens: "")

        try await store.deleteComposerDrafts([
            (channel: "room-1", root: nil),
            (channel: "room-1", root: "opener"),
        ])

        #expect(try store.composerDraftSummaries().map(\.channelID) == ["room-2"])
        #expect(try store.composerDraftCount() == 1)
    }

    /// The reason drafts live in this database rather than in `UserDefaults`: this is the
    /// only unsent-words store an identity change is guaranteed to erase.
    @Test("an identity change wipes every stored draft")
    func wipeClearsDrafts() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        try await store.saveComposerDraft(channel: "room-1", root: nil, text: "private", tokens: "")
        try await store.saveComposerDraft(channel: "room-1", root: "opener", text: "also private", tokens: "")
        try await store.wipe()

        #expect(try store.composerDrafts().isEmpty)
    }
}
