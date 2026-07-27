import BuzzKit
@testable import Hive
import Foundation
import NostrCore
import Testing

// The composer's live candidate index and how it is ordered: one index completing people
// for `@` and channels for `#`, and Part 6's ranking of people by who was named most
// recently. An extension of ``MentionComposerTests`` rather than its own suite, because
// these drive the same model the detection and insertion tests above it do.
@MainActor
extension MentionComposerTests {
    @Test("one index completes people for @ and channels for #")
    func completesBothKinds() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let member = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("room-1", name: "general"),
            try relay.channelMetadata("room-2", name: "design", isPrivate: true),
            try relay.event(
                .groupMembers,
                "",
                tags: [["d", "room-1"], ["p", member.pubkey]],
                at: 1_001
            ),
            try member.event(.metadata, #"{"display_name":"Ada Lovelace"}"#, at: 900),
        ], phase: .backfill)

        let model = MentionAutocompleteModel(channel: "room-1", store: store, selfPubkey: nil)
        let observation = Task { await model.run() }
        defer { observation.cancel() }

        model.update(for: MentionDraft(text: "hey @ad"))
        await waitUntil { model.suggestions.map(\.label) == ["Ada Lovelace"] }
        #expect(model.suggestions.map(\.kind) == [.user])

        model.update(for: MentionDraft(text: "see #de"))
        await waitUntil { model.suggestions.map(\.label) == ["design"] }
        #expect(model.suggestions.map(\.kind) == [.channel])
        #expect(model.suggestions.first?.insertionLabel == "#design")
        #expect(model.suggestions.first?.isPrivateChannel == true)

        // A bare `#` lists every named channel, in the read's alphabetical order.
        model.update(for: MentionDraft(text: "see #"))
        await waitUntil { model.suggestions.count == 2 }
        #expect(model.suggestions.map(\.label) == ["design", "general"])

        // Picking one inserts through the same path a person goes through.
        var draft = MentionDraft(text: "see #")
        let picked = try #require(model.suggestions.last)
        model.select(picked, in: &draft)
        #expect(draft.text == "see #general ")
        #expect(draft.mentionedPubkeys(sender: nil).isEmpty)
    }

    @Test("a bare @ lists the people mentioned most recently first, then the rest alphabetically")
    func ranksPeopleByRecentUsage() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let me = try Fixture()
        // Named so the alphabetical fallback is the *opposite* of the recency order: any
        // ordering that came from the read rather than from recency would show Ada first.
        let ada = try Fixture(), bo = try Fixture(), cy = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("room-1", name: "general"),
            try relay.event(
                .groupMembers, "",
                tags: [["d", "room-1"]] + [ada, bo, cy].map { ["p", $0.pubkey] },
                at: 1_001
            ),
            try ada.event(.metadata, #"{"display_name":"Ada"}"#, at: 900),
            try bo.event(.metadata, #"{"display_name":"Bo"}"#, at: 900),
            try cy.event(.metadata, #"{"display_name":"Cy"}"#, at: 900),
            // The reader's own history: Cy most recently, then Bo. Ada has never been
            // mentioned and falls to the alphabetical tail behind both.
            try me.event(
                .channelMessage, "hi", tags: [["h", "room-1"], ["p", bo.pubkey]], at: 2_000
            ),
            try me.event(
                .channelMessage, "hi", tags: [["h", "room-1"], ["p", cy.pubkey]], at: 3_000
            ),
        ], phase: .backfill)

        // The store's answer first, synchronously. If this holds and the panel's order
        // still does not, the defect is in the ranking and not in the read — which is a
        // distinction a single assertion on the rendered list cannot make, and one that
        // cost a CI-only failure to learn.
        #expect(try store.recentMentions(by: me.pubkey, limit: 20).pubkeys
            == [cy.pubkey, bo.pubkey].map { $0.lowercased() })

        let model = MentionAutocompleteModel(channel: "room-1", store: store, selfPubkey: me.pubkey)
        let observation = Task { await model.run() }
        defer { observation.cancel() }

        model.update(for: MentionDraft(text: "hey @"))
        // Waits for the index to be *populated*, then asserts its order. Waiting on the
        // order itself makes a wrong order indistinguishable from a slow one: the poll
        // simply never ends and the suite reports a timeout instead of the list it got.
        await waitUntil { model.suggestions.count == 3 }
        #expect(model.suggestions.map(\.label) == ["Cy", "Bo", "Ada"])

        // Recency does not outrank the name being typed: `ad` matches Ada alone, and a
        // more recently mentioned person who does not match is not a candidate at all.
        model.update(for: MentionDraft(text: "hey @ad"))
        await waitUntil { model.suggestions.count == 1 }
        #expect(model.suggestions.map(\.label) == ["Ada"])
    }

}
