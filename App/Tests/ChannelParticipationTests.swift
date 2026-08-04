import BuzzKit
@testable import Hive
import Testing

/// The participation rule, asserted directly.
///
/// Pure over ``BuzzKit/ChannelParticipationFacts``, so every branch is reachable without a
/// store, a relay or a view — including the two that only exist for a few hundred
/// milliseconds on a real device.
@Suite("Channel participation")
struct ChannelParticipationTests {
    private static func facts(
        access: ChannelAccessState? = .active,
        isPrivate: Bool = false,
        isArchived: Bool = false,
        isDirectMessage: Bool = false,
        isMember: Bool
    ) -> ChannelParticipationFacts {
        ChannelParticipationFacts(
            access: access,
            channel: ChannelFacts(
                isPrivate: isPrivate,
                isArchived: isArchived,
                isDirectMessage: isDirectMessage
            ),
            isMember: isMember
        )
    }

    /// The case this whole feature exists for.
    @Test("an open channel you have not joined asks you to join")
    func openNonMemberJoins() {
        #expect(ChannelParticipation.resolve(Self.facts(isMember: false)) == .joinRequired)
    }

    @Test("an open channel you are on the roster of keeps its composer")
    func openMemberIsAllowed() {
        #expect(ChannelParticipation.resolve(Self.facts(isMember: true)) == .allowed)
    }

    /// The state that must not be read out of column defaults. A channel row that has not
    /// been projected yet has no privacy flag, no archive flag and no roster — which is
    /// bit-for-bit the shape of an open channel you have not joined. A freshly opened DM
    /// is exactly that until its kind-39000 read-back lands, and raising the bar there
    /// would take the composer away from a conversation the reader just opened.
    @Test("a channel with no projected row keeps today's composer")
    func unprojectedChannelIsAllowed() {
        let facts = ChannelParticipationFacts(access: .active, channel: nil, isMember: false)

        #expect(ChannelParticipation.resolve(facts) == .allowed)
    }

    /// Ordering, not just membership: archived is tested before the roster is, so an
    /// archived channel a reader is not a member of resolves `.readOnly` and never offers
    /// a Join. The relay refuses an archived self-join with `invalid:`, so the other order
    /// would paint a guaranteed error.
    @Test("archived wins over join-required, and never offers to join")
    func archivedBeatsJoinRequired() {
        #expect(ChannelParticipation.resolve(Self.facts(isArchived: true, isMember: false)) == .readOnly)
        #expect(ChannelParticipation.resolve(Self.facts(isArchived: true, isMember: true)) == .readOnly)
    }

    /// Named for its own sake rather than left to `isPrivate`. Every DM the relay serves
    /// today carries the private tag, so the privacy term does cover them — but only as a
    /// side effect of that tagging, and this is the codebase's documented DM gate.
    @Test("a direct message keeps its composer even with the private tag absent")
    func directMessageIsAllowed() {
        let facts = Self.facts(isPrivate: false, isDirectMessage: true, isMember: false)

        #expect(ChannelParticipation.resolve(facts) == .allowed)
    }

    /// A private channel is not joinable by asking, and being able to read one at all
    /// means the relay already let this identity in.
    @Test("a private channel keeps its composer")
    func privateChannelIsAllowed() {
        #expect(ChannelParticipation.resolve(Self.facts(isPrivate: true, isMember: false)) == .allowed)
    }

    /// The gate is a product rule and `isWritable` is a claim about the relay, so
    /// participation does not read the access state at all — the two are ANDed by the
    /// caller. A `.notMember` channel still resolves `.joinRequired` here; what stops the
    /// composer is `isWritable`, exactly as before.
    @Test("participation does not second-guess the access state")
    func participationIgnoresAccessState() {
        #expect(ChannelParticipation.resolve(Self.facts(access: .notMember, isMember: false)) == .joinRequired)
        #expect(ChannelParticipation.resolve(Self.facts(access: nil, isMember: true)) == .allowed)
    }

    /// The one-liner that fails loudly if anyone ever folds membership back into
    /// `isWritable`. A hidden DM is writable on purpose — hiding is a sidebar choice, not
    /// a lock — and it is the state that would punish a collapsed Bool first: JT has
    /// sixteen of them.
    @Test("hiding a direct message never makes it read-only")
    func hiddenStaysWritable() {
        #expect(ChannelAccessState.hidden.isWritable)
        #expect(ChannelAccessState.active.isWritable)
        // And membership is not one of the things this property is allowed to know.
        let hiddenNonMember = Self.facts(access: .hidden, isDirectMessage: true, isMember: false)
        #expect(ChannelParticipation.resolve(hiddenNonMember) == .allowed)
    }
}
