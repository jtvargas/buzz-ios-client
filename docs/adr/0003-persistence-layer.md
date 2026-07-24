# ADR-0003: Persistence layer

**Status:** Accepted

## Context

`BuzzKit` needs local storage for the sync engine and outbox. The database is the
single source of truth: the UI reads it, never the socket. That imposes concrete
requirements — value observation to drive an observation-based UI, concurrent
reads while the sync engine writes, an append-only event log with proper
replaceable/deletion/edit semantics, and schema evolution against a wire-defined
model the client does not own.

Candidates weighed in the plan (v1.1/v1.2 §store) and Phase-1 spec §10: GRDB over
SQLite, raw `sqlite3`, and SwiftData/Core Data. The reference client comb (MIT,
same Buzz domain) proves the GRDB shape end to end in `CombStore`.

## Decision

**GRDB (v7) is BuzzKit's persistence layer.** Storage is an append-only `event`
log plus disposable projections rebuilt on a version bump. **Every table is a
rowid table — never `WITHOUT ROWID`.** The writer is a WAL `DatabasePool` owned by
the store actor; reads run against a `nonisolated` reader.

The GRDB dependency is pinned `.exact` (`7.11.1` at this PR), matching the pinning
discipline the rest of the project uses.

## Rationale

- GRDB gives `ValueObservation` (the UI layer is observation-driven), a WAL
  `DatabasePool` for concurrent reads under a single serialized writer, and
  raw-SQL migrations without an ORM abstraction tax over a schema we do not define.
- SwiftData/Core Data were not candidates: no append-only-log affinity, observation
  tied to contexts rather than tables, and schema-migration cost against a
  wire-defined model. Raw `sqlite3` would re-implement the observation and
  statement caching GRDB already proves in this exact domain.
- **Never `WITHOUT ROWID`:** SQLite's update hook does not fire for such tables and
  GRDB's `ValueObservation` silently stops noticing changes after the first fetch.
  The content-addressed `TEXT` primary keys make `WITHOUT ROWID` look attractive;
  the observation-driven architecture makes it fatal. Carried as a hard rule in the
  schema.
- The projection-version rebuild is the escape hatch that keeps a projection bug
  from ever forcing a relay resync: bump the constant, drop the projections, replay
  the log.

## Consequences

- Packages keep their iOS 17 / macOS 14 floors (ADR-0002); GRDB 7 supports them.
- Projection shape changes are a version bump and a replay, not a migration — but a
  new local (non-derived) table still needs a real migration, since a rebuild must
  never erase what the log cannot reconstruct.
- **Trust note:** NIP-CW overlays are consumed under the authenticated-transport
  profile (`NIP-CW.md:188`) — TLS to the single configured relay. Revisit only if a
  non-TLS or multi-relay configuration ever lands.

## Appendix — NIP-CW overlay trust, as built (step 5)

The `WindowClient` realizes the authenticated-transport profile concretely. Under
it, the origin of the response bytes is proven by the TLS certificate chain to the
configured relay, not by a client-side signature check, so:

- **Enforced (MUST, `NIP-CW.md:164`):** exactly one `kind:39006` per served
  window; its `d`-tag binding echoes the request cursor (`head` or
  `<created_at>:<id>`); its content parses as the bounds object; and
  `has_more ⇔ next_cursor ≠ null`. Any violation discards the page — a bounds
  overlay present-but-malformed is a retryable invalid page; a response with no
  bounds overlay at all (or a transport/HTTP error) is the degradation signal that
  falls the engine back to the standard WebSocket filter.
- **Deferred (future hardening):** cryptographic verification of each overlay's
  Schnorr signature against the advertised NIP-11 relay identity, and the SHOULD
  checks (exact tag cardinality, exhaustive runtime field-type validation). These
  are to be applied uniformly across all relay-signed reads (with NIP-DV, NIP-IA)
  rather than bolted onto this one path. The window client already gets field-type
  validation for the bounds content for free from typed decoding.

Rows and aux events carry no such exemption: they are ordinary client-signed
events and are verified where every event is — the store's ingest choke point —
when the step-6 engine pushes them through it.
