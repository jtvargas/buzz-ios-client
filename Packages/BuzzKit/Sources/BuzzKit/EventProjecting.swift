import GRDB
import NostrCore

/// Derives projection rows from a verified event.
///
/// This is the seam between the append-only log and its disposable projections.
/// Both the live ingest path and the version-bump rebuild call ``project(_:into:)``
/// — that shared route is what keeps the two from settling on different rows.
/// Because the projector runs inside the caller's write transaction, its rows land
/// atomically with the log row that produced them.
///
/// ``BuzzProjector`` is the production implementation — channel, roster, profile,
/// thread, reaction, deletion, edit, rich-content, thread-summary, and owner
/// attestation rows. ``NullProjector`` derives nothing and stays for the store and
/// rebuild tests, where injecting the projector lets a test observe exactly which
/// events the rebuild replays and in what order without depending on real row
/// shapes.
protocol EventProjecting: Sendable {
    /// Writes the projection rows for one already-verified event.
    ///
    /// The event has passed the ingest choke point, so implementations may trust
    /// its identity and signature and must not re-verify. Any write happens on the
    /// supplied `db`, inside the transaction the caller opened.
    func project(_ event: NostrEvent, into db: Database) throws
}

/// The step-1 projector: it derives nothing.
///
/// The log is fully authoritative on its own, so an empty projector is a valid
/// state of the system — timelines simply have no derived indexes to read yet.
/// It exists so the store and the rebuild path can be wired and tested end to end
/// before the real projector lands.
struct NullProjector: EventProjecting {
    func project(_: NostrEvent, into _: Database) throws {}
}
