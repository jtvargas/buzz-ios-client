import Foundation
import NostrCore

/// Partitions and validates a raw window response into a ``WindowResult``.
///
/// Kept apart from ``WindowClient`` so the transport orchestration and the
/// pure, synchronous classification are testable in isolation and neither type
/// body grows unwieldy. Every rule here is from NIP-CW §Client Behavior and
/// §Relay Processing; none of it does I/O.
enum WindowResponseParser {
    /// The aux-closure kinds: reactions, both deletion forms, and edits. Everything
    /// not one of these, a summary, or a bounds overlay is a row.
    static let auxKinds: Set<EventKind> = [
        .reaction, .deletion, .groupDeleteEvent, .messageEdit,
    ]

    /// Classifies a decoded response: partition strictly by kind, then run the
    /// bounds-integrity MUSTs in the order NIP-CW lists them.
    static func classify(_ events: [NostrEvent], for filter: WindowFilter) -> WindowResult {
        let partitioned = partition(events)

        // Bounds cardinality: exactly one 39006 per served window.
        switch partitioned.bounds.count {
        case 0:
            // No bounds overlay at all — the capability-absent signal (a tolerant
            // relay served a plain query, or the extension is unsupported). This is
            // the degradation trigger, distinct from a malformed page.
            return .degraded(.noBoundsOverlay)
        case 1:
            break
        default:
            return .invalidPage(.multipleBounds(count: partitioned.bounds.count))
        }

        return validate(bounds: partitioned.bounds[0], filter: filter) { validated in
            .page(WindowPage(
                rows: partitioned.rows,
                aux: partitioned.aux,
                summaries: partitioned.summaries,
                bounds: validated
            ))
        }
    }

    // MARK: - Partitioning

    private struct Partition {
        var rows: [NostrEvent] = []
        var aux: [NostrEvent] = []
        var summaries: [NostrEvent] = []
        var bounds: [NostrEvent] = []
    }

    /// Sorts every event into its role by kind, preserving relative order within
    /// each bucket so rows stay in the received keyset order. Array position is
    /// never consulted — an aux event interleaved among rows lands in `aux`
    /// wherever it sat.
    private static func partition(_ events: [NostrEvent]) -> Partition {
        var partition = Partition()
        for event in events {
            switch event.kind {
            case .windowBounds:
                partition.bounds.append(event)
            case .threadSummary:
                partition.summaries.append(event)
            case let kind where auxKinds.contains(kind):
                partition.aux.append(event)
            default:
                partition.rows.append(event)
            }
        }
        return partition
    }

    // MARK: - Bounds integrity

    /// Runs the remaining MUSTs on the single bounds overlay — request binding,
    /// parseable content, exhaustion agreement — and builds the page via `onValid`
    /// only if all pass.
    private static func validate(
        bounds: NostrEvent,
        filter: WindowFilter,
        onValid: (WindowBounds) -> WindowResult
    ) -> WindowResult {
        // The `d`-tag binding MUST echo the request cursor, binding this page to the
        // request it answered (and disambiguating concurrent pages).
        let expected = filter.expectedBoundsDTag
        let actual = bounds.addressableIdentifier ?? ""
        guard actual == expected else {
            return .invalidPage(.cursorBindingMismatch(expected: expected, actual: actual))
        }

        // Content MUST parse as the bounds object, with the right runtime types.
        guard let content = WindowBoundsContent.decode(bounds.content) else {
            return .invalidPage(.unparseableBoundsContent)
        }

        // `has_more` and `next_cursor` MUST agree: present together, absent together.
        guard content.hasMore == (content.nextCursor != nil) else {
            return .invalidPage(.exhaustionInconsistent)
        }

        // A present cursor MUST be a usable one — its id has to be a canonical
        // 64-hex event id, or echoing it as the next `before_id` would be rejected.
        var next: WindowCursor?
        if let raw = content.nextCursor {
            guard isCanonicalEventID(raw.id) else {
                return .invalidPage(.unparseableBoundsContent)
            }
            next = WindowCursor(createdAt: raw.createdAt, id: raw.id)
        }

        return onValid(WindowBounds(hasMore: content.hasMore, nextCursor: next))
    }

    /// Whether a string is a canonical Nostr event id: exactly 64 lowercase hex
    /// characters.
    private static func isCanonicalEventID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { character in
            character.isNumber || ("a" ... "f").contains(character)
        }
    }
}

/// The decoded content of a `kind:39006` overlay.
///
/// A typed `Decodable` so a wrong runtime type (a string `has_more`, a
/// non-integer `created_at`) fails the decode and is reported as unparseable
/// content — the §Client Behavior step-5 hardening, obtained for free. Unknown
/// content fields are ignored, per the NIP's forward-compat reservation.
struct WindowBoundsContent: Decodable {
    let hasMore: Bool
    let nextCursor: RawWindowCursor?

    enum CodingKeys: String, CodingKey {
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    /// Decodes from a JSON string, returning `nil` for anything that is not the
    /// expected object shape.
    static func decode(_ content: String) -> WindowBoundsContent? {
        try? JSONDecoder().decode(WindowBoundsContent.self, from: Data(content.utf8))
    }
}

/// The raw `next_cursor` object as it sits in `kind:39006` content, before the id
/// is validated as canonical and lifted into a ``WindowCursor``.
struct RawWindowCursor: Decodable {
    let createdAt: Int64
    let id: String

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case id
    }
}
