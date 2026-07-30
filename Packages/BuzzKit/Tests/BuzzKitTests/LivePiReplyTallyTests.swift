@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

/// The reply tally against the **real relay**, because every other test of it asserts
/// against a summary this repository wrote itself.
///
/// The composition is only as good as the claim underneath it: that the relay really
/// does ship a `kind:39005` beside a window page, really does push a fresh one on a
/// reply insert, and really does put the numbers where this client reads them. A
/// scripted fake proves the client's half and assumes the relay's — which is the half
/// that was misread for the whole life of this defect, since the summaries were
/// arriving and being stored the entire time.
///
/// Disabled unless `BUZZKIT_INTEGRATION_URL` names a relay, like the rest of the live
/// suite. Run:
/// `BUZZKIT_INTEGRATION_URL=wss://homelab.tail4bc643.ts.net swift test -c release \
///   --package-path Packages/BuzzKit --filter LivePiReplyTally`
@Suite("Live Pi reply tally", .enabled(if: LiveRelay.enabled), .serialized, .timeLimit(.minutes(5)))
struct LivePiReplyTallyTests {
    @Test("a cold store learns a message has replies without ever fetching one")
    func coldStoreSeesTheTally() async throws {
        let signer = try InMemorySigner() // creator ⇒ member, so no join flow
        let database = TempDatabase()
        defer { database.remove() }

        try await withLiveChannelFixture(namePrefix: "buzzkit-tally", signer: signer) { fixture in
            let channel = fixture.channelID
            let peer = fixture.connection

            // Published *before* any engine exists, so nothing about this thread can
            // reach the store through live fan-out. Everything below is history.
            let opener = try await channelMessageEvent("opener", channel: channel, signer: signer)
            #expect(await tryPublish(opener, on: peer) == nil)
            for index in 0 ..< 2 {
                let reply = try await signer.sign(
                    kind: .channelMessage, content: "reply\(index)",
                    tags: [
                        ["h", channel],
                        ["e", opener.id, "", "root"],
                        ["e", opener.id, "", "reply"],
                    ]
                )
                #expect(await tryPublish(reply, on: peer) == nil)
            }

            // A cold launch: a store that has never seen this channel, reconciling it
            // for the first time. The window is `top_level: true`, so the two replies
            // above are *not* rows in what it fetches.
            let store = try database.open()
            let engine = LiveEngine(store: store, signer: signer)
            try await engine.engine.start()
            guard await poll(timeout: .seconds(30), { await engine.engine.state == .running }) else {
                Issue.record("[LIVE] engine never reached running")
                await engine.engine.stop()
                return
            }

            let sawOpener = await poll(timeout: .seconds(30)) {
                ((try? store.timeline(channel: channel))?.contains { $0.id == opener.id }) == true
            }
            #expect(sawOpener, "[LIVE] the opener never reached the timeline")

            // The claim under test, and the reported defect: the tally is there with no
            // `openThread` anywhere in this test, so no reply was ever fetched.
            let advertised = await poll(timeout: .seconds(30)) {
                (try? store.timeline(channel: channel))?.first { $0.id == opener.id }?.hasThread == true
            }
            let row = try #require(try store.timeline(channel: channel).first { $0.id == opener.id })
            #expect(advertised, "[LIVE] the opener never advertised its thread; replyCount=\(row.replyCount)")
            #expect(row.replyCount == 2)

            // And the replies themselves are genuinely absent — otherwise this would be
            // measuring an ordinary local count and calling it a summary.
            let heldReplies = try await store.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE root_id = ?", arguments: [opener.id])
            }
            print("[LIVE] replies held locally: \(heldReplies ?? -1), tally: \(row.replyCount)")
            #expect(heldReplies == 0, "[LIVE] the window page carried replies; the tally proves nothing here")

            // The live half: the relay pushes a freshly signed 39005 on every insert, so
            // a reply arriving now moves the badge on a running client.
            let late = try await signer.sign(
                kind: .channelMessage, content: "late",
                tags: [["h", channel], ["e", opener.id, "", "root"], ["e", opener.id, "", "reply"]]
            )
            #expect(await tryPublish(late, on: peer) == nil)

            let moved = await poll(timeout: .seconds(30)) {
                (try? store.timeline(channel: channel))?.first { $0.id == opener.id }?.replyCount == 3
            }
            let after = try #require(try store.timeline(channel: channel).first { $0.id == opener.id })
            #expect(moved, "[LIVE] the tally did not move on a live reply; replyCount=\(after.replyCount)")

            await engine.engine.stop()
        }
    }
}
