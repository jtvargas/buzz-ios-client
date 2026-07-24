import Foundation
import NostrCore

/// The validated window bounds of one page: the authoritative exhaustion fact and
/// the cursor to fetch the next page with.
///
/// Derived from the single `kind:39006` overlay after it passes every bounds-
/// integrity check, so the invariant `hasMore == (nextCursor != nil)` holds by
/// construction — a `WindowBounds` cannot represent the inconsistency the parser
/// rejects. `kind:39006` is the *only* authority on exhaustion (NIP-CW §Client
/// Behavior): a short page proves nothing, so the engine reads `hasMore` here and
/// never infers exhaustion from row count.
public struct WindowBounds: Sendable, Equatable, Hashable {
    /// Whether the relay holds further pages below this one.
    public let hasMore: Bool
    /// The cursor to echo as the next request's `until` + `before_id`. Non-nil iff
    /// ``hasMore``.
    public let nextCursor: WindowCursor?

    public init(hasMore: Bool, nextCursor: WindowCursor?) {
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}

/// One usable page of a channel window, partitioned strictly by kind.
///
/// Everything here is already sorted into its role by event kind, never by array
/// position (NIP-CW §Relay Processing): the engine reads ``rows`` in the received
/// keyset order and ignores where aux or overlays sat between them.
///
/// The client does not store anything. It hands the engine the pieces it needs:
/// the ordinary signed events (``rows`` + ``aux``) to push through the normal
/// ingest choke point, the ``summaries`` to cache into the `thread_summary`
/// projection keyed by their `d` binding, and the validated ``bounds`` for the
/// reconcile loop's cursor math — all without a second parse.
public struct WindowPage: Sendable, Equatable {
    /// Top-level row events, in received keyset order. Ordinary signed events the
    /// engine ingests through the normal choke point.
    public let rows: [NostrEvent]

    /// The aux closure: reactions (`kind:7`), deletions (`kind:5`, `kind:9005`),
    /// and edits (`kind:40003`) targeting the rows. Ordinary signed events, also
    /// ingested through the choke point.
    public let aux: [NostrEvent]

    /// The `kind:39005` thread-summary overlays. Relay-signed metadata, cached
    /// into the `thread_summary` projection keyed by their `d` tag — never a row,
    /// never a cursor input.
    public let summaries: [NostrEvent]

    /// The validated exhaustion + next-cursor facts from the page's single
    /// `kind:39006`. The overlay itself is never stored; only this cursor math
    /// survives it.
    public let bounds: WindowBounds

    public init(rows: [NostrEvent], aux: [NostrEvent], summaries: [NostrEvent], bounds: WindowBounds) {
        self.rows = rows
        self.aux = aux
        self.summaries = summaries
        self.bounds = bounds
    }
}

/// Why a window response could not be used, without a bounds overlay to guess at.
///
/// A response that carried a `kind:39006` but violated one of its per-page MUSTs
/// (NIP-CW §Client Behavior step 5) is a malformed *page*: the relay speaks the
/// extension, so the window fast path stays available and the engine MAY retry the
/// same request. It is distinct from a ``WindowDegradeReason``, which withdraws the
/// fast path entirely.
public enum WindowInvalidPageReason: Sendable, Equatable, Hashable {
    /// More than one `kind:39006` — the "exactly one" guarantee is broken. Carries
    /// the count seen.
    case multipleBounds(count: Int)
    /// The single overlay's `d`-tag binding did not echo the request cursor, so it
    /// cannot be trusted to describe this page (NIP-CW §Overlay Event Formats).
    case cursorBindingMismatch(expected: String, actual: String)
    /// The overlay's content was not the expected JSON object (unparseable, wrong
    /// runtime types, or a cursor id that is not a canonical 64-hex event id).
    case unparseableBoundsContent
    /// The content violated `has_more == (next_cursor != null)` — the exhaustion
    /// fact and the cursor disagree, so neither can be trusted.
    case exhaustionInconsistent
}

/// Why the window fast path is unavailable for a response, signalling the engine
/// to fall back to the standard WebSocket filter.
///
/// This is the NIP-CW §Degradation signal: "a response with no valid `kind:39006`,
/// or an error/unsupported-filter response." The engine reissues the clean
/// standard filter (``WindowFilter/baseFilter``) and remembers the downgrade for
/// this relay for the session — a `.degraded` result is the trivially-rememberable
/// flag that makes that per-relay memory a one-liner.
public enum WindowDegradeReason: Sendable, Equatable {
    /// The `POST /query` never produced an HTTP response (network failure).
    case transportFailure(TransportError)
    /// The exchange completed with a non-2xx status — a strict parser rejecting the
    /// extension filter (`400`), an auth failure (`401`), or a server error.
    case httpStatus(Int)
    /// A 2xx body that did not decode as a signed-event array — not a query surface
    /// this client can page.
    case unreadableResponse
    /// A decodable response carrying no `kind:39006` at all — the capability-absent
    /// signal (a tolerant relay served the filter as a plain query, or does not
    /// implement the extension).
    case noBoundsOverlay
}

/// The outcome of one window fetch: a usable page, a discardable malformed page, or
/// a degradation signal.
///
/// Three outcomes because the engine acts on each differently. ``page`` advances
/// the reconcile loop. ``invalidPage`` leaves the watermark untouched and MAY be
/// retried on the same fast path. ``degraded`` leaves the watermark untouched and
/// withdraws the fast path for the relay this session, falling back to the standard
/// filter. The client itself performs no fallback and touches no storage — it only
/// classifies.
public enum WindowResult: Sendable, Equatable {
    /// A valid, usable page.
    case page(WindowPage)
    /// A response with a bounds overlay that failed a per-page integrity MUST.
    /// Discard the page; the fast path remains available.
    case invalidPage(WindowInvalidPageReason)
    /// No usable capability signal — no bounds overlay, or the request did not
    /// complete. Fall back to the standard filter and remember the downgrade.
    case degraded(WindowDegradeReason)
}
