# ADR-0001: Nostr library selection

**Status:** Proposed (decision due at Phase 1 start)

## Context

`NostrCore` needs keys/signing (secp256k1), event codec, NIP-42, NIP-98, and NIP-44 v2. Candidates: NostrSDK-ios, NostrEssentials, rust-nostr Swift bindings, or a thin hand-rolled core over secp256k1.swift.

Buzz-specific constraints (from the upstream v0.4.11 parity target):

- ~30 custom event kinds and raw tags — SDKs that model kinds as closed enums fight every Buzz extension.
- NIP-44 v2 is required (read state, channel preferences, QR pairing, agent-activity subscriptions all encrypt with it). Note: CryptoKit exposes only ChaChaPoly AEAD, not the raw ChaCha20 that NIP-44 needs — the hand-rolled option must vendor/port that primitive or take a scoped dependency, validated against the official NIP-44 test vectors.
- We build our own relay connection actor — a bundled relay pool is dead weight; codec + crypto must be usable à la carte.
- Gift-wrap (kind:1059) DM crypto is explicitly **not** weighted: upstream mobile has zero usage at v0.4.11.

## Criteria

1. NIP-29 / NIP-42 fit
2. Maintenance health
3. Binary size
4. Swift 6 readiness
5. Arbitrary-kind / raw-tag friendliness (likely deciding)
6. NIP-44 v2 with official test vectors
7. À-la-carte usability (codec + crypto standalone)
8. License compatibility with Apache-2.0

## Decision

_Pending Phase 1 evaluation._
