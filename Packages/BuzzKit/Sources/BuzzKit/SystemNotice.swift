import Foundation

/// Something that happened to a channel, as the relay narrated it: a kind-40099
/// notice, decoded.
///
/// # Why this is not just a string
///
/// The relay signs these, so it could have written the sentence itself — and
/// deliberately does not. Its content is a JSON object naming who acted and who it
/// happened to (`{"type": "member_joined", "actor": "<hex>", "target": "<hex>"}`),
/// because the sentence is different on every screen: the same event reads "Sentry was
/// added by You" to the person who did it and "Sentry was added by JT" to everybody
/// else. Only a client that holds the reader's own key can write that, so the relay
/// hands over the facts and the words are ours. Desktop resolves them the same way
/// (`desktop/src/features/messages/ui/SystemMessageRow.tsx`), which is why the copy
/// matches across the two clients without either one copying the other's strings.
///
/// # Why an enum with associated values
///
/// Each notice carries exactly the participants its sentence needs and no more. A
/// departure names one person; an eviction names two and the order matters. A single
/// struct with two optional pubkeys would let "removed nobody from the channel" be
/// constructed, and every render site would have to unwrap its way back to the shape
/// this already knows.
///
/// # What is here and what is not
///
/// The eight the reference clients render, and no more. The relay also emits
/// `visibility_changed`, `ttl_changed` and the `message_deleted` tombstone; Desktop's
/// switch has no case for the first two either, and the third is a separate question —
/// a deleted message already leaves the timeline here (see ``TimelineQuery``), so
/// whether a deletion should additionally leave a *mark* is a product decision rather
/// than part of narrating the channel.
///
/// ``parse(_:)`` answers `nil` for a type it does not know, and a notice nothing can
/// render is dropped rather than drawn as an empty row. Adding one is a case here, a
/// sentence in `SystemNoticeSentence`, and nothing else.
public enum SystemNotice: Sendable, Hashable {
    /// Somebody is in the channel who was not before. `actor` and `target` are the
    /// same person when they joined under their own steam, and different when they
    /// were added by someone else — the two read as different sentences.
    case memberJoined(actor: String, target: String)
    /// Somebody left of their own accord.
    case memberLeft(actor: String)
    /// Somebody was removed by somebody else.
    case memberRemoved(actor: String, target: String)
    /// The channel's topic is now `topic`.
    case topicChanged(actor: String, topic: String)
    /// The channel's purpose is now `purpose`.
    case purposeChanged(actor: String, purpose: String)
    /// The channel exists. Always the first notice in a channel, and the only one whose
    /// subject is its own first message.
    case channelCreated(actor: String)
    /// The channel was put away.
    case channelArchived(actor: String)
    /// The channel was brought back.
    case channelUnarchived(actor: String)

    /// Decodes the JSON body of a kind-40099 event, or `nil` when it is not a notice
    /// this can render — an unknown `type`, a malformed body, or a known type missing
    /// a participant it needs.
    ///
    /// Lenient about the envelope and strict about the participants: a relay that adds
    /// fields must not break decoding, but a notice that cannot name who it is about
    /// has nothing to say and is better absent than blank.
    public static func parse(_ content: String) -> SystemNotice? {
        guard let data = content.data(using: .utf8),
              let body = try? JSONDecoder().decode(Body.self, from: data)
        else { return nil }
        // Split by what the notice is about — the roster, or the channel itself — which
        // is also the split between the ones that need two participants and the ones
        // that need one. Neither half can answer for a type belonging to the other.
        return roster(body) ?? channel(body)
    }

    /// The notices about who is in the channel.
    private static func roster(_ body: Body) -> SystemNotice? {
        let actor = body.actor?.normalizedPubkey
        let target = body.target?.normalizedPubkey
        switch body.type {
        case "member_joined":
            guard let actor, let target else { return nil }
            return .memberJoined(actor: actor, target: target)
        case "member_left":
            // The relay sets both to the same person on a self-removal; either one is
            // the leaver, and `actor` is the one it always sets.
            guard let actor else { return nil }
            return .memberLeft(actor: actor)
        case "member_removed":
            guard let actor, let target else { return nil }
            return .memberRemoved(actor: actor, target: target)
        default:
            return nil
        }
    }

    /// The notices about the channel itself. Every one of these names an actor and
    /// nobody else, so the guard is shared.
    private static func channel(_ body: Body) -> SystemNotice? {
        guard let actor = body.actor?.normalizedPubkey else { return nil }
        switch body.type {
        case "topic_changed":
            // An empty topic is the relay clearing it, which is a real change and reads
            // as one — but it is not this sentence, and there is no wording for it in
            // either reference client. Dropped rather than rendered as `changed the
            // topic to ""`.
            guard let topic = body.topic, !topic.isEmpty else { return nil }
            return .topicChanged(actor: actor, topic: topic)
        case "purpose_changed":
            guard let purpose = body.purpose, !purpose.isEmpty else { return nil }
            return .purposeChanged(actor: actor, purpose: purpose)
        case "channel_created":
            return .channelCreated(actor: actor)
        case "channel_archived":
            return .channelArchived(actor: actor)
        case "channel_unarchived":
            return .channelUnarchived(actor: actor)
        default:
            return nil
        }
    }

    /// The person the notice is *about* — whose face and name a row carries, with
    /// everybody else named inside the sentence.
    ///
    /// An arrival is about the person who arrived; everything else is about the person
    /// who acted. That asymmetry is not cosmetic and it is the reference clients' own
    /// (`SystemMessageRow.tsx`'s `displayedIdentityPubkey`, `system_rows.dart`'s
    /// `_MembershipDisplayEvent`): "Echo was added by JT" is a row announcing Echo, and
    /// "JT removed Echo from the channel" is a row announcing what JT did.
    public var subject: String {
        switch self {
        case let .memberJoined(_, target): target
        case let .memberLeft(actor): actor
        case let .memberRemoved(actor, _): actor
        case let .topicChanged(actor, _): actor
        case let .purposeChanged(actor, _): actor
        case let .channelCreated(actor): actor
        case let .channelArchived(actor): actor
        case let .channelUnarchived(actor): actor
        }
    }

    /// The people this notice is about, so a surface can resolve their display names
    /// in one pass instead of reaching into each case.
    public var participants: [String] {
        switch self {
        case let .memberJoined(actor, target): [actor, target]
        case let .memberLeft(actor): [actor]
        case let .memberRemoved(actor, target): [actor, target]
        case let .topicChanged(actor, _): [actor]
        case let .purposeChanged(actor, _): [actor]
        case let .channelCreated(actor): [actor]
        case let .channelArchived(actor): [actor]
        case let .channelUnarchived(actor): [actor]
        }
    }

    /// The wire shape. Every field optional because the relay writes a different set
    /// per type and a missing one is a fact about the type, not a decoding failure.
    private struct Body: Decodable {
        let type: String
        let actor: String?
        let target: String?
        let topic: String?
        let purpose: String?
    }
}

private extension String {
    /// A 64-character lowercase-hex pubkey, or `nil` for anything that is not one.
    ///
    /// The relay hex-encodes lowercase, so this normalizes rather than repairs — but a
    /// notice whose participant is not a pubkey at all would otherwise be resolved
    /// against the profile table forever and render as a truncated fragment of
    /// whatever it was.
    var normalizedPubkey: String? {
        let lowered = lowercased()
        guard lowered.count == 64, lowered.allSatisfy(\.isHexDigit) else { return nil }
        return lowered
    }
}
