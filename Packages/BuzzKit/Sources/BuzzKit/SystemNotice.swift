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
/// The relay emits nine more types (topic and purpose changes, channel creation,
/// archival, visibility, TTL, message deletion). They are absent here on purpose:
/// ``parse(_:)`` answers `nil` for a type it does not know, and a notice nothing can
/// render is dropped rather than drawn as an empty row. Adding one is a case here and
/// a branch at the render site.
public enum SystemNotice: Sendable, Hashable {
    /// Somebody is in the channel who was not before. `actor` and `target` are the
    /// same person when they joined under their own steam, and different when they
    /// were added by someone else — the two read as different sentences.
    case memberJoined(actor: String, target: String)
    /// Somebody left of their own accord.
    case memberLeft(actor: String)
    /// Somebody was removed by somebody else.
    case memberRemoved(actor: String, target: String)

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

    /// The people this notice is about, so a surface can resolve their display names
    /// in one pass instead of reaching into each case.
    public var participants: [String] {
        switch self {
        case let .memberJoined(actor, target): [actor, target]
        case let .memberLeft(actor): [actor]
        case let .memberRemoved(actor, target): [actor, target]
        }
    }

    /// The wire shape. Every field optional because the relay writes a different set
    /// per type and a missing one is a fact about the type, not a decoding failure.
    private struct Body: Decodable {
        let type: String
        let actor: String?
        let target: String?
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
