@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// A relay that will not have this key at all.
///
/// The defect these cover: a closed relay (`require_relay_membership`) answers *every*
/// authenticated route `403 {"error":"relay_membership_required"}`, and the directory pass
/// absorbed that alongside the refusals it is right to absorb. `start()` therefore returned
/// without throwing, the identity gate read the join as having succeeded, and the reader
/// landed in an empty community that said connecting for ever — which is what
/// `bitcoiners.communities.buzz.xyz` and its siblings do to a key that has no invite.
///
/// The whole fix is one discrimination, so that is what is asserted here: this 403 propagates,
/// and every other 403 keeps the fallback it had. Getting it the wrong way round in either
/// direction is a live defect — absorbing it restores the "connecting for ever" screen, and
/// propagating too eagerly tells somebody a community they are already inside needs an invite.
@Suite("Closed relay membership refusal", .timeLimit(.minutes(1)))
struct ChannelDirectoryMembershipTests {
    /// The relay's own body for the closed door, verbatim from `buzz-relay/src/api/mod.rs:136`
    /// and confirmed against the three live hosts.
    private static let refusal = #"{"error":"relay_membership_required","message":"Relay membership required"}"#

    private static func client(_ transport: FakeHTTPTransport, signer: InMemorySigner) -> ChannelDirectoryClient {
        ChannelDirectoryClient(
            transport: transport,
            queryURL: URL(string: "https://relay.example.com/query")!,
            signer: signer
        )
    }

    @Test("a closed relay's refusal ends the pass rather than being absorbed as an empty answer")
    func membershipRefusalPropagates() async throws {
        let identity = try Fixture()
        let transport = FakeHTTPTransport()

        // One response is all it takes. The first query of the pass is the visibility
        // snapshot, whose refusals are otherwise swallowed — which is exactly where this was
        // being lost, because the door is shut in front of every query behind it too.
        await transport.enqueue(status: 403, body: Self.refusal)

        await #expect(throws: ChannelDirectoryError.membershipRequired) {
            try await Self.client(transport, signer: InMemorySigner(identity.key)).fetch(
                selfPubkey: identity.pubkey,
                previouslyActiveChannels: []
            )
        }
    }

    @Test("a 403 that is not the closed door keeps the fallback it always had")
    func otherRefusalsAreStillAbsorbed() async throws {
        let relay = try Fixture()
        let identity = try Fixture()
        let transport = FakeHTTPTransport()

        // A relay that has never heard of NIP-DV, or one refusing this `#p`-gated kind for
        // its own reasons. Same status, different body — and the difference has to be read
        // from the body, because the status cannot tell them apart.
        let rosters = [
            try relay.event(
                .groupMembers,
                "",
                tags: [["d", "room"], ["p", identity.pubkey]],
                at: 11
            ),
        ]
        let metadata = [
            try relay.event(.groupMetadata, #"{"name":"Room"}"#, tags: [["d", "room"]], at: 10),
        ]

        await transport.enqueue(status: 403, body: #"{"error":"forbidden_filter"}"#)
        await transport.enqueue(status: 200, body: try JSONEncoder().encode(rosters))
        await transport.enqueue(status: 200, body: try JSONEncoder().encode(metadata))
        await transport.enqueue(status: 200, body: try JSONEncoder().encode(rosters + metadata))

        let snapshot = try await Self.client(transport, signer: InMemorySigner(identity.key)).fetch(
            selfPubkey: identity.pubkey,
            previouslyActiveChannels: []
        )
        #expect(snapshot.states["room"] == .active)
    }

    @Test("the closed door is read from the machine-readable key, never from prose or an unreadable body")
    func refusalIsIdentifiedByItsErrorKey() {
        #expect(ChannelDirectoryClient.isMembershipRefusal(Data(Self.refusal.utf8)))
        // Everything below is a 403 body that is *not* the closed door. Each one wrongly
        // matched would send somebody off to find an invite for a community that has already
        // let them in.
        #expect(!ChannelDirectoryClient.isMembershipRefusal(Data(#"{"error":"forbidden_filter"}"#.utf8)))
        #expect(!ChannelDirectoryClient.isMembershipRefusal(Data("relay_membership_required".utf8)))
        #expect(!ChannelDirectoryClient.isMembershipRefusal(Data(#"{"message":"relay membership required"}"#.utf8)))
        #expect(!ChannelDirectoryClient.isMembershipRefusal(Data("restricted".utf8)))
        #expect(!ChannelDirectoryClient.isMembershipRefusal(Data()))
    }
}
