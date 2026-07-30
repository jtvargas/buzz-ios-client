import BuzzKit
import Foundation
@testable import Hive
import Testing

/// A persistence double that records every call and can hold a write open, so the
/// coalescing rule is asserted rather than inferred from timing.
@MainActor
final class GatedDraftPersistence: ComposerDraftPersisting {
    struct Save: Equatable {
        let key: ComposerDraftKey
        let text: String
        let tokens: String
    }

    private(set) var saves: [Save] = []
    private(set) var deletes: [ComposerDraftKey] = []
    var stored: [ComposerDraftKey: ComposerDraftRecord] = [:]
    /// While set, a write suspends after recording itself until ``release()``.
    var holdsWrites = false

    private var waiting: [CheckedContinuation<Void, Never>] = []

    func load(_ key: ComposerDraftKey) -> ComposerDraftRecord? { stored[key] }

    func save(_ key: ComposerDraftKey, text: String, tokens: String) async {
        saves.append(Save(key: key, text: text, tokens: tokens))
        stored[key] = ComposerDraftRecord(
            channelID: key.channelID,
            rootID: key.rootID,
            text: text,
            tokens: tokens,
            updatedAt: 0
        )
        await pauseIfHeld()
    }

    func delete(_ key: ComposerDraftKey) async {
        deletes.append(key)
        stored[key] = nil
        await pauseIfHeld()
    }

    func release() {
        let resumable = waiting
        waiting = []
        for continuation in resumable { continuation.resume() }
    }

    private func pauseIfHeld() async {
        guard holdsWrites else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

@MainActor
@Suite("Composer drafts", .timeLimit(.minutes(1)))
struct ComposerDraftsTests {
    private static let channel = ComposerDraftKey(channel: "room-1")
    private static let thread = ComposerDraftKey(channel: "room-1", root: "opener")

    @Test("a composer opens on nothing until something is typed in it")
    func emptyByDefault() {
        let drafts = ComposerDrafts(persistence: GatedDraftPersistence())
        #expect(drafts.draft(for: Self.channel).text.isEmpty)
    }

    @Test("a stored draft is restored, and only into its own composer")
    func restoresPerComposer() {
        let persistence = GatedDraftPersistence()
        persistence.stored[Self.thread] = ComposerDraftRecord(
            channelID: "room-1",
            rootID: "opener",
            text: "half a reply",
            tokens: "",
            updatedAt: 1
        )
        let drafts = ComposerDrafts(persistence: persistence)

        #expect(drafts.draft(for: Self.thread).text == "half a reply")
        // The requirement JT stated: leaving a thread mid-sentence and landing in the
        // channel it hangs under must not carry the sentence with it.
        #expect(drafts.draft(for: Self.channel).text.isEmpty)
        #expect(drafts.draft(for: ComposerDraftKey(channel: "room-2")).text.isEmpty)
    }

    /// The reason this cache exists at all: a write is `async` and pressing back is not.
    @Test("a draft is readable before its write has landed")
    func readableBeforeTheWriteLands() async {
        let persistence = GatedDraftPersistence()
        persistence.holdsWrites = true
        let drafts = ComposerDrafts(persistence: persistence)

        drafts.record(MentionDraft(text: "typed and left"), for: Self.thread)
        #expect(drafts.draft(for: Self.thread).text == "typed and left")
        #expect(persistence.stored[Self.thread] == nil) // genuinely not written yet

        persistence.holdsWrites = false
        persistence.release()
        await drafts.flush()
        #expect(persistence.stored[Self.thread]?.text == "typed and left")
    }

    @Test("keystrokes arriving during a write collapse into one further write")
    func coalescesWhileWriting() async {
        let persistence = GatedDraftPersistence()
        persistence.holdsWrites = true
        let drafts = ComposerDrafts(persistence: persistence)

        drafts.record(MentionDraft(text: "a"), for: Self.channel)
        await waitUntil { persistence.saves.count == 1 }

        drafts.record(MentionDraft(text: "ab"), for: Self.channel)
        drafts.record(MentionDraft(text: "abc"), for: Self.channel)
        await parkBriefly()
        #expect(persistence.saves.count == 1) // still the one in flight

        persistence.holdsWrites = false
        persistence.release()
        await drafts.flush()

        // Three keystrokes, two writes, and the second one carries the newest text —
        // not the one that was current when it was queued.
        #expect(persistence.saves.map(\.text) == ["a", "abc"])
    }

    @Test("clearing a composer deletes its draft rather than storing an empty one")
    func clearingDeletes() async {
        let persistence = GatedDraftPersistence()
        let drafts = ComposerDrafts(persistence: persistence)

        drafts.record(MentionDraft(text: "written"), for: Self.channel)
        await drafts.flush()
        drafts.record(MentionDraft(text: "  \n "), for: Self.channel)
        await drafts.flush()

        #expect(drafts.draft(for: Self.channel).text.isEmpty)
        #expect(persistence.deletes == [Self.channel])
        #expect(persistence.stored[Self.channel] == nil)
    }

    @Test("mention tokens survive the round trip, so a restored @name still tags")
    func tokensRoundTrip() async {
        let persistence = GatedDraftPersistence()
        let drafts = ComposerDrafts(persistence: persistence)
        let token = ComposerMentionToken(
            kind: .user,
            entityID: "abc123",
            displayName: "Jarvis",
            range: NSRange(location: 0, length: 7)
        )
        drafts.record(MentionDraft(text: "@Jarvis have a look", tokens: [token]), for: Self.channel)
        await drafts.flush()

        // A fresh cache, so the answer comes off the stored payload rather than memory.
        let reopened = ComposerDrafts(persistence: persistence)
        let restored = reopened.draft(for: Self.channel)
        #expect(restored.text == "@Jarvis have a look")
        #expect(restored.tokens.count == 1)
        #expect(restored.tokens.first?.entityID == "abc123")
        #expect(restored.mentionedPubkeys(sender: nil) == ["abc123"])
    }

    /// These ranges are handed to UIKit's text system. A payload that no longer describes
    /// the text it was written with costs the mentions, never the draft.
    @Test("a token that overruns the restored text is dropped, and the text is kept")
    func dropsOutOfRangeTokens() {
        let payload = ComposerDraftTokens.encode([
            ComposerMentionToken(
                kind: .user,
                entityID: "abc123",
                displayName: "Jarvis",
                range: NSRange(location: 0, length: 40)
            ),
        ])
        #expect(ComposerDraftTokens.decode(payload, in: "short").isEmpty)
        #expect(ComposerDraftTokens.decode("not json", in: "short").isEmpty)
    }

    @Test("the cache is bounded, and evicting a copy does not delete the stored draft")
    func boundedByCapacity() async {
        let persistence = GatedDraftPersistence()
        let drafts = ComposerDrafts(persistence: persistence, capacity: 2)

        for index in 0 ..< 3 {
            drafts.record(MentionDraft(text: "draft \(index)"), for: ComposerDraftKey(channel: "room-\(index)"))
        }
        await drafts.flush()

        #expect(persistence.deletes.isEmpty)
        #expect(persistence.stored[ComposerDraftKey(channel: "room-0")]?.text == "draft 0")
        // Forgotten in memory, so it comes back off disk on the next visit.
        #expect(drafts.draft(for: ComposerDraftKey(channel: "room-0")).text == "draft 0")
    }

    /// Signing out and back in as somebody else must not hand them the last person's
    /// unsent words in a channel the two of them share.
    @Test("a reset forgets every held draft without deleting stored rows")
    func resetForgetsWithoutDeleting() async {
        let persistence = GatedDraftPersistence()
        let drafts = ComposerDrafts(persistence: persistence)

        drafts.record(MentionDraft(text: "mine alone"), for: Self.channel)
        await drafts.flush()
        drafts.reset()

        #expect(persistence.deletes.isEmpty)
        persistence.stored = [:] // what the store's own wipe does for a different key
        #expect(drafts.draft(for: Self.channel).text.isEmpty)
    }

    @Test("a reset drops writes that have not been made rather than turning them into deletes")
    func resetDropsPendingWrites() async {
        let persistence = GatedDraftPersistence()
        persistence.holdsWrites = true
        let drafts = ComposerDrafts(persistence: persistence)

        drafts.record(MentionDraft(text: "first"), for: Self.channel)
        await waitUntil { persistence.saves.count == 1 }
        drafts.record(MentionDraft(text: "second"), for: Self.thread)
        drafts.reset()

        persistence.holdsWrites = false
        persistence.release()
        await drafts.flush()

        // The in-flight write finished; the queued one was dropped. Neither turned into
        // a delete of a row a same-key re-login is entitled to get back.
        #expect(persistence.saves.map(\.text) == ["first"])
        #expect(persistence.deletes.isEmpty)
    }
}
