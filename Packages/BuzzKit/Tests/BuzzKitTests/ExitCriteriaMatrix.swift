@testable import BuzzKit
import Testing

/// The Phase-2 exit-criteria matrix (spec §"Deterministic exit-criteria tests",
/// T1–T8) mapped to the test names that cover each criterion as of step 7. This is
/// the audit deliverable: a single place a reviewer can confirm every criterion is
/// covered at the level the spec specifies, and the CI gate that closes Phase 2.
///
/// Each criterion is covered at its **specced level** — the store-local criteria at
/// the store, the sync criteria over the full wired engine — and the two criteria
/// the spec pins at more than one level (T1, T4) are covered at each. The whole
/// matrix runs in `make test` (release); only the live suite and the performance
/// measurements are env-gated.
///
/// ## T1 — kill mid-backfill, no loss
/// - `SyncEngineBackfillTests.killMidBackfill` — within-session reconnect: the
///   re-REQ carries the original filter (no EOSE ever armed a replay cursor) and the
///   ten stored events land exactly once.
/// - `SyncEngineRestartTests.killAndReopenMidBackfill` — the literal kill: the engine
///   is torn down mid-backfill and a fresh engine reopens the same database; the full
///   replay dedupes against the persisted log to ten exactly once. *(added, step 7)*
///
/// ## T2 — airplane mode mid-live, no loss or dup
/// - `SyncEngineBackfillTests.airplaneMidLive` — post-EOSE live events, a socket
///   failure, and a reconnect whose replay filter is `since = lastSeen − 5`; the
///   overlap dedupes and the store holds e1…e4 each once.
///
/// ## T3 — kill between send and OK
/// - `SyncEngineOutboxTests.killBetweenSendAndOK` — parameterized over the relay's
///   verdict on the restart resend: `OK true` and `OK false duplicate:` both confirm
///   the message exactly once, leaving zero rows in the outbox.
///
/// ## T4 — offline compose, stale drain (re-sign)
/// - Store level (step 4): `OutboxDispositionTests.reSignSwapsIdentity`,
///   `OutboxDispositionTests.resolveInvalidStaleReSigns`,
///   `OutboxDispositionTests.isStaleBoundary` — the identity-swapping re-sign and the
///   classification-plus-age trigger, at the store.
/// - Engine level end-to-end (step 7): `SyncEngineResignTests.staleDrainReSignsAndLandsOnce`
///   — the same over the wired stack: publish, the `invalid:` verdict, the engine's
///   resend of the re-signed row, and a single landed message. *(added, step 7)*
///
/// ## T5 — reconcile closes the offline gap
/// - `SyncEngineReconcileTests.closesGap` — watermark at e5, a head page and an
///   overlapping second page; the loop stops on the overlap (no third request) and the
///   watermark advances to the head's newest, only there.
/// - `SyncEngineReconcileTests.fromScratchPagesToExhaustion` — a never-synced channel
///   pages to `has_more = false`, then advances to the head.
///
/// ## T6 — projection rebuild agreement
/// - `RebuildAgreementTests.rebuildMatchesLive` — a mixed history (edits, deletions
///   including unauthorized ones, replaceables out of order, an owner-attested agent
///   message) yields byte-identical projections whether ingested live or replayed by a
///   version-bump rebuild.
///
/// ## T7 — bounds integrity
/// - `WindowBoundsIntegrityTests` — the four MUST-list variants
///   (`missingBounds`, `duplicatedBounds`, `wrongCursorBinding`,
///   `exhaustionInconsistentMoreButNull`) plus content hardening
///   (`exhaustionInconsistentDoneButCursor`, `unparseableContent`, `wrongRuntimeTypes`,
///   `nonCanonicalCursorID`): every malformed page is discarded, the watermark left
///   untouched.
/// - `SyncEngineLifecycleTests.degradationFallback` — the no-valid-39006 variant
///   engaging the engine's WebSocket-assembly fallback, at the engine level.
///
/// ## T8 — authority matrix
/// - `AuthorityTests.authorVersusStranger` — kind-5 by author deletes; by a stranger
///   it does not.
/// - `AuthorityTests.relayTombstone` — a kind-9005 relay tombstone deletes from anyone.
/// - `AuthorityTests.ownerWidening` — a verified NIP-OA owner may delete and edit an
///   agent's message; a third party may not.
/// - `AuthorityTests.unverifiableAttestation` — an unverifiable owner attestation
///   grants no authority.
/// - `RebuildAgreementTests.rebuildMatchesLive` also exercises the owner-attested case
///   through a rebuild.
///
/// ## Live instrumented run (env-gated, Pi relay)
/// - `LivePiIntegrationTests` — a second connection publishes N events while the engine
///   connection cycles stop/connect and background/foreground; asserts store
///   convergence (N present, no dups) and the drain of a message composed while
///   stopped. Runs only when `BUZZKIT_INTEGRATION_URL` names a relay, the same gating
///   the Phase-1 `RelayIntegrationTests` uses.
///
/// ## Performance measurements (env-gated)
/// - `IngestThroughputTests`, `TimelineLatencyTests`, `ColdStartReconcileTests` — run
///   only when `BUZZKIT_PERF` is set, so a release CI runner's timing noise never
///   flakes the gate. See each suite for the rationale.
enum ExitCriteriaMatrix {}

/// A compile-time guard that the audit above names suites that actually exist: if a
/// suite is renamed or removed, referencing its type here fails to build, so the
/// matrix doc cannot silently rot. The references are metatypes only — nothing runs.
@Suite("Exit-criteria matrix audit")
struct ExitCriteriaMatrixAudit {
    @Test("Every named exit-criteria suite is present in the target")
    func namedSuitesExist() {
        _ = SyncEngineBackfillTests.self          // T1 (within-session), T2
        _ = SyncEngineRestartTests.self           // T1 (literal kill)
        _ = SyncEngineOutboxTests.self            // T3
        _ = OutboxDispositionTests.self           // T4 (store)
        _ = SyncEngineResignTests.self            // T4 (engine)
        _ = SyncEngineReconcileTests.self         // T5
        _ = RebuildAgreementTests.self            // T6, T8 (owner via rebuild)
        _ = WindowBoundsIntegrityTests.self       // T7
        _ = SyncEngineLifecycleTests.self         // T7 degradation fallback
        _ = AuthorityTests.self                   // T8
    }
}
