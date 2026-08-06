@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Whether a row says it names the reader — the fact the conversation's grouping breaks a
/// block on, so that a message addressed to you keeps its author's name and its time.
///
/// It is answered here, at read time, off the tags the row query already decodes for
/// attachments, rather than by the surface asking ``BuzzEventStore/mentions(for:)``: that
/// read lands after the rows do, and a run that regrouped a beat after it was drawn is the
/// defect this shape exists to make impossible. What is asserted below is that the answer
/// agrees with the one the sidebar's mention badge gives, case for case.
@Suite("A row that names the reader", .timeLimit(.minutes(1)))
struct TimelineNamesSelfTests {
    @Test("a peer's message naming the reader says so, and one that names nobody does not")
    func aPeerNamingTheReader() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let me = try Fixture()
        let peer = try Fixture()

        let addressed = try peer.event(
            .channelMessage, "you around?",
            tags: [["h", "room-1"], ["p", me.pubkey]], at: 1_000
        )
        let ambient = try peer.message("morning all", in: "room-1", at: 1_001)
        _ = try await store.ingest(batch: [addressed, ambient], phase: .backfill)

        let rows = try store.timeline(channel: "room-1", selfPubkey: me.pubkey)
        #expect(rows.first { $0.id == addressed.id }?.namesSelf == true)
        #expect(rows.first { $0.id == ambient.id }?.namesSelf == false)
    }

    @Test("a tag value in upper case still names the reader")
    func tagValuesAreComparedWithoutCase() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let me = try Fixture()
        let peer = try Fixture()

        // A tag value is a raw string written by whichever client sent the message and is
        // never decoded, unlike `event.pubkey`, which went through NIP-01's
        // strictly-lowercase hex decode. `ChannelList`'s mention badge compares it
        // `COLLATE NOCASE` for that reason; two definitions of "names me" that disagreed
        // about case would badge a channel whose conversation drew no break.
        let shouted = try peer.event(
            .channelMessage, "YOU AROUND?",
            tags: [["h", "room-1"], ["p", me.pubkey.uppercased()]], at: 1_000
        )
        _ = try await store.ingest(batch: [shouted], phase: .backfill)

        let rows = try store.timeline(channel: "room-1", selfPubkey: me.pubkey)
        #expect(rows.first?.namesSelf == true)
    }

    @Test("the reader's own message never names them, and neither does any row without a key")
    func theReaderIsNeverTheirOwnMention() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let me = try Fixture()

        // This app strips the sender from a message's own `p` tags (`OutboundTags`), so
        // this shape comes from elsewhere — and a mention of yourself is not a thing to be
        // told about, which is the same exclusion the mention badge makes.
        let selfTagged = try me.event(
            .channelMessage, "note to self",
            tags: [["h", "room-1"], ["p", me.pubkey]], at: 1_000
        )
        _ = try await store.ingest(batch: [selfTagged], phase: .backfill)

        #expect(try store.timeline(channel: "room-1", selfPubkey: me.pubkey).first?.namesSelf == false)
        // An identity-less session names nobody, which is the honest answer rather than a
        // degradation: there is no reader for a message to be addressed to.
        #expect(try store.timeline(channel: "room-1").first?.namesSelf == false)
    }

    @Test("fixing a typo does not un-name the reader")
    func anEditCannotClearTheMention() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let me = try Fixture()
        let peer = try Fixture()

        let addressed = try peer.event(
            .channelMessage, "@me can you look at this",
            tags: [["h", "room-1"], ["p", me.pubkey]], at: 1_000
        )
        // The exact shape `OutboundTags/edit(channel:target:)` sends: `h` and `e`, no `p`,
        // ever. So this is what *every* edit from this client looks like, and reading the
        // missing `p` as "no longer named" would re-collapse the block on a typo fix while
        // the sidebar badge — which reads the insert-only `event_tag` — still counted it.
        let typoFix = try peer.event(
            .messageEdit, "@me can you look at this?",
            tags: [["e", addressed.id], ["h", "room-1"]], at: 1_001
        )
        _ = try await store.ingest(batch: [addressed, typoFix], phase: .backfill)

        let row = try #require(try store.timeline(channel: "room-1", selfPubkey: me.pubkey).first)
        #expect(row.isEdited)
        #expect(row.namesSelf)
    }

    @Test("an edit that adds a mention registers it")
    func anEditCanAddTheMention() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let me = try Fixture()
        let peer = try Fixture()

        let ambient = try peer.message("morning all", in: "room-1", at: 1_000)
        let addressing = try peer.event(
            .messageEdit, "morning all — @me, you around?",
            tags: [["e", ambient.id], ["h", "room-1"], ["p", me.pubkey]], at: 1_001
        )
        _ = try await store.ingest(batch: [ambient, addressing], phase: .backfill)

        // The direction an edit *can* carry, and it comes from another client — this one
        // never puts a `p` on an edit. Both tag sets are read for the mention, so an edit
        // that added it registers while an edit that merely omits it changes nothing.
        let row = try #require(try store.timeline(channel: "room-1", selfPubkey: me.pubkey).first)
        #expect(row.isEdited)
        #expect(row.namesSelf)
    }

    @Test("a thread read answers it the same way the channel page does")
    func theThreadReadAgrees() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let me = try Fixture()
        let peer = try Fixture()

        let opener = try peer.message("has anyone seen this", in: "room-1", at: 1_000)
        let reply = try peer.event(
            .channelMessage, "you know this one",
            tags: [["h", "room-1"], ["e", opener.id, "", "reply"], ["p", me.pubkey]], at: 1_001
        )
        _ = try await store.ingest(batch: [opener, reply], phase: .backfill)

        // Three reads build a row — the page, a thread, and the by-id refresh — and a row
        // assembled differently by any one of them is a second definition of what a message
        // is. Grouping runs over all three.
        let thread = try store.thread(root: opener.id, selfPubkey: me.pubkey)
        #expect(thread.first { $0.id == reply.id }?.namesSelf == true)
        #expect(thread.first { $0.id == opener.id }?.namesSelf == false)

        let refreshed = try store.rows(for: [reply.id], selfPubkey: me.pubkey)
        #expect(refreshed.first?.namesSelf == true)
    }
}
