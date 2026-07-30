import Foundation

/// The relay's tally of a thread, as the `content` of a `kind:39005` carries it.
///
/// This is the number that lets a message advertise its own replies without this
/// device holding any of them. A channel window is `top_level: true` by definition —
/// that is what NIP-CW exists for — so replies are never page rows, and a tally
/// counted only from what this device has fetched reads zero for all of history on a
/// cold launch. The relay computes this one server-side, ships it beside every page,
/// and pushes a freshly signed replacement on every reply insert and every deletion.
///
/// # Which field the client uses
///
/// ``descendantCount``, not ``replyCount``. The two differ for a nested reply, and the
/// local count this composes with (`thread.root_id = <root>` in
/// ``BuzzEventStore/eventBranch(where:)``) is keyed on the NIP-10 **root**, so it
/// counts a whole subtree. Taking the direct-child count instead would agree with the
/// local count in every flat thread and quietly disagree in every nested one.
///
/// # Why every field is optional
///
/// A relay may add fields, and an older client must not choke on them; a relay may
/// also send something this client cannot read. Both cases must degrade to *silence* —
/// a summary that contributes nothing — never to a zero. Zero is a claim that a thread
/// has no replies, and a zero conjured from a parse failure would take a CTA away from
/// a message that really does have a thread. Absent means "this says nothing about the
/// count", and the composition treats it that way.
struct ThreadSummaryPayload: Decodable, Equatable {
    /// Direct children of the root only — decoded, and deliberately not stored.
    ///
    /// It is the field a reader reaches for by name, and the wrong one, so it is kept
    /// here where the distinction above is written down rather than left out of the
    /// type for someone to rediscover from the relay's source.
    let replyCount: Int?
    /// The whole subtree beneath the root — the field the tally reads.
    let descendantCount: Int?
    /// `created_at` of the newest surviving reply anywhere in the subtree, or `nil`
    /// when the relay sent JSON `null` (a thread whose replies were all withdrawn).
    let lastReplyAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case replyCount = "reply_count"
        case descendantCount = "descendant_count"
        case lastReplyAt = "last_reply_at"
    }

    /// The payload of a `kind:39005`'s content, or `nil` when it is not JSON this
    /// client can read.
    ///
    /// Total on its inputs by design — it is called from the projector, which runs
    /// inside the ingest transaction, and a relay's malformed overlay must not be able
    /// to fail the write of the page it rode in on.
    static func decode(_ content: String) -> ThreadSummaryPayload? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ThreadSummaryPayload.self, from: data)
    }

    /// A negative count is not a smaller number of replies, it is a broken payload —
    /// and floored here rather than in SQL so the stored column can be trusted by
    /// whatever reads it next.
    var storedDescendantCount: Int? {
        descendantCount.map { max(0, $0) }
    }

    /// Floored for the same reason, and additionally `nil` at zero: a timestamp of
    /// zero would render as a date in 1970 the moment anything mapped it into a
    /// `Date`, which is what ``TimelineRow/lastReplyDate`` does.
    var storedLastReplyAt: Int64? {
        guard let lastReplyAt, lastReplyAt > 0 else { return nil }
        return lastReplyAt
    }
}
