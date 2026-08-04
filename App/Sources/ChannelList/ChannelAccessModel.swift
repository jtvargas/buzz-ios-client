import BuzzKit
import Observation

/// What a reader may *do* in a conversation — the product rule, as distinct from
/// ``BuzzKit/ChannelAccessState/isWritable``, which is a factual claim about the relay.
///
/// The two are deliberately separate values. The relay accepts a non-member's writes to
/// an open channel — that is the same behaviour that resolves such a channel `.active` in
/// the first place — so `isWritable` is *true* there and folding "you have not joined"
/// into it would make the property assert something false while keeping a name and a doc
/// comment that say otherwise. This carries the product decision instead, and the two are
/// read together: an action needs `.allowed` **and** `isWritable`.
enum ChannelParticipation: Equatable {
    /// Today's behaviour in full: the composer, gated by `isWritable` as it always was.
    case allowed
    /// An open channel this identity has not joined — the "Join to participate" bar.
    case joinRequired
    /// Archived: a disabled composer and a line saying why, with no Join button. The
    /// relay refuses an archived self-join with `invalid:`, so offering one here would
    /// paint a guaranteed error.
    case readOnly

    /// The rule, over facts read in one pass — see
    /// ``BuzzKit/BuzzEventStore/channelParticipationFacts(identity:channel:)``.
    ///
    /// Pure and `nonisolated` so the ordering below is asserted directly rather than
    /// through a view. The order is the substance:
    ///
    /// 1. **No channel row → `.allowed`**, first, so nothing beneath it can read a
    ///    default. An unprojected channel is a *don't know*, and the shape a don't-know
    ///    presents — no privacy flag, no archive flag, no roster — is indistinguishable
    ///    from an open channel you have not joined. A freshly opened DM is exactly that
    ///    for as long as its metadata read-back takes, and silencing the composer on a DM
    ///    the reader just opened would be a worse defect than the one this fixes.
    /// 2. **Archived → `.readOnly`**, ahead of the membership test, so an archived channel
    ///    a reader is not a member of never offers a Join that cannot succeed.
    /// 3. **A DM or a private channel → `.allowed`.** Neither is joinable by asking, and
    ///    reaching either at all means the relay already let this identity in.
    ///    `isDirectMessage` is named rather than left to `isPrivate`: every DM the relay
    ///    serves today carries the private tag, so the privacy term does cover them, but
    ///    only as a side effect of that tagging. This states the intent, and survives a
    ///    relay that stops emitting it.
    /// 4. **Not a member → `.joinRequired`.** What is left is an open, unarchived,
    ///    non-DM channel whose roster does not name this identity.
    nonisolated static func resolve(_ facts: ChannelParticipationFacts) -> ChannelParticipation {
        guard let channel = facts.channel else { return .allowed }
        if channel.isArchived { return .readOnly }
        if channel.isDirectMessage || channel.isPrivate { return .allowed }
        return facts.isMember ? .allowed : .joinRequired
    }
}

@MainActor
@Observable
final class ChannelAccessModel {
    private(set) var state: ChannelAccessState
    /// What the reader may do here, re-read on every commit alongside ``state`` and from
    /// the same snapshot — so a join taken on this screen turns the bar back into a
    /// composer without leaving it.
    private(set) var participation: ChannelParticipation

    private let channelID: String
    private let identity: String?
    private let store: BuzzEventStore

    init(channelID: String, identity: String?, store: BuzzEventStore) {
        self.channelID = channelID
        self.identity = identity
        self.store = store
        if let identity {
            let facts = try? store.channelParticipationFacts(identity: identity, channel: channelID)
            // `.unavailable` for a failed read *and* for a missing row, exactly as the
            // single-column read this replaced resolved both to it.
            state = facts.flatMap(\.access) ?? .unavailable
            participation = facts.map(ChannelParticipation.resolve) ?? .allowed
        } else {
            // No identity is the fixture and preview path: nothing to be a member of, and
            // nothing to join. It keeps the composer, exactly as it keeps `.active`.
            state = .active
            participation = .allowed
        }
    }

    var isWritable: Bool { state.isWritable }

    /// Whether a reader may act on a message here — react, edit, reply in thread. Both
    /// values, because they answer different questions: `isWritable` is whether the relay
    /// would take it, `participation` is whether this app offers it.
    var allowsInteraction: Bool { participation == .allowed && isWritable }

    nonisolated func run() async {
        guard let identity else { return }
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let facts = try? store.channelParticipationFacts(
                    identity: identity,
                    channel: channelID
                )
                await apply(facts)
            }
        } catch {
            // Cancellation keeps the last known access state on screen.
        }
    }

    private func apply(_ facts: ChannelParticipationFacts?) {
        state = facts.flatMap(\.access) ?? .unavailable
        participation = facts.map(ChannelParticipation.resolve) ?? .allowed
    }
}
