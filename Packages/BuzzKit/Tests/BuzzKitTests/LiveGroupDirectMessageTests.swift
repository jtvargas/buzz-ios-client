@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// What the relay actually says about a group direct message.
///
/// The whole group-DM feature rests on one claim the deterministic suite can only
/// *assume*: that a DM of three or more arrives carrying `["t","dm"]` on its kind-39000
/// metadata, and a placeholder name of the shape `Group DM (3)`. Both are read out of the
/// relay's source (`side_effects.rs`, `RESEARCH/BUZZ_DM_OPEN_PROTOCOL.md`) — and a
/// deployment older than either would leave this app filing group DMs under Channels with
/// no test anywhere going red. So the tags are asserted against a live relay.
///
/// Every key here is thrown away, so the DM this opens is between three identities nobody
/// holds and appears in no real sidebar. Nothing is left to clean up.
///
/// Disabled unless `BUZZKIT_INTEGRATION_URL` names a relay, so `make test` and CI never
/// touch the network.
///
/// Run:
/// `BUZZKIT_INTEGRATION_URL=wss://homelab.tail4bc643.ts.net swift test -c release \
///   --package-path Packages/BuzzKit --filter LiveGroupDirectMessage`
@Suite(
    "Live group direct messages",
    .enabled(if: LiveRelay.enabled),
    .serialized,
    .timeLimit(.minutes(5))
)
struct LiveGroupDirectMessageTests {
    @Test("a DM of three carries the relay's own dm type, and a name that names nobody")
    func groupDirectMessageMetadata() async throws {
        let signer = try InMemorySigner()
        let peers = [
            try await InMemorySigner().publicKey().hex,
            try await InMemorySigner().publicKey().hex,
        ]
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        let live = LiveEngine(store: store, signer: signer)
        try await live.engine.start()
        defer { Task { await live.engine.stop() } }
        guard await poll(timeout: .seconds(30), { await live.engine.state == .running }) else {
            Issue.record("[LIVE] engine never reached running")
            return
        }

        // Signed here rather than through `openDirectMessage(with:)`, which takes one peer:
        // the app has no way to *create* a group DM, only to display one, and this suite is
        // about what the relay says when something else has.
        let command = try await signer.sign(
            kind: .directMessageOpen,
            content: "",
            tags: [["p", peers[0]], ["p", peers[1]], ["nonce", UUID().uuidString]]
        )
        let response = try await live.connection.publishAwaitingResponse(command)
        let opened = try SyncEngine.parseOpenResponse(response)
        print("[LIVE] group DM opened: \(opened.channelID) (created: \(opened.wasCreated))")
        await live.engine.adoptOpenedChannel(opened.channelID)

        let row = try #require(
            try store.channelList().first { $0.id == opened.channelID },
            "the opened group DM never reached the channel list"
        )
        print("[LIVE] name=\(row.name ?? "nil") type=\(row.channelType ?? "nil") private=\(row.isPrivate)")

        // The claim the feature is built on.
        #expect(row.channelType == "dm", "the relay did not tag this DM with its channel type")
        #expect(row.isDirectMessage)
        #expect(row.isPrivate)

        // And the second one: the name is the relay's placeholder — `Group DM (3)` — so the
        // app is right to replace it with the people in the room rather than render it.
        // Spelled out here rather than called through `EntityNames`, which lives in the app
        // target: this suite is asserting what the relay *sent*, not what the app makes of it.
        #expect(
            row.name?.lowercased().hasPrefix("group dm") == true,
            "expected the relay's placeholder name, got \(row.name ?? "nil")"
        )

        // The third: three people in the roster, which is the half of the group rule the
        // metadata does not carry. Without it a group DM classifies as a one-to-one.
        let members = try store.channelMembers(opened.channelID)
        print("[LIVE] roster: \(members.count)")
        #expect(members.count == 3)
    }
}
