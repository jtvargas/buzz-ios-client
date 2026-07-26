# ADR-0001: Nostr library selection

**Status:** Accepted (decided at Phase 1; outcome recorded below)

## Context

`NostrCore` needs keys/signing (secp256k1), event codec, NIP-42, NIP-98, and NIP-44 v2. Candidates: NostrSDK-ios, NostrEssentials, rust-nostr Swift bindings, a thin hand-rolled core over secp256k1.swift, or **adapting comb's `CombCore`** ([jedbridges/comb](https://github.com/jedbridges/comb), MIT — license-compatible): a hand-rolled Swift core over `21-DOT-DEV/swift-secp256k1` with NostrEvent codec, keys, signing, NIP-44, NIP-98, and test suites, built for the same Buzz relay domain. Verify its NIP-44 tests use the official vectors during evaluation.

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

**No Nostr SDK. `NostrCore` is hand-rolled over a single cryptographic dependency:
`21-DOT-DEV/swift-secp256k1`, pinned to an exact version (`Packages/NostrCore/Package.swift`).**
That package is the only third-party dependency in the protocol layer; everything else —
event codec, canonical JSON, bech32, keys and Keychain storage, Schnorr verification,
NIP-42, NIP-44, NIP-98, the relay connection actor, the subscription manager, and device
pairing — is written here.

Criterion 5 decided it, as anticipated. `EventKind` is an `Int`-backed
`RawRepresentable` with named constants, not a closed enum, *"so that kinds this client
does not recognise still survive a decode/encode round trip untouched"* — an event log
meant to be an append-only mirror of the wire cannot drop what it does not know, and Buzz
adds roughly thirty kinds of its own on top of a base protocol that grows faster than any
single client tracks.

Two consequences of the crypto note in Context, both now in the tree:

- **Raw ChaCha20 (RFC 8439) is vendored** (`ChaCha20.swift`), keystream only. CryptoKit
  ships the ChaCha20-Poly1305 AEAD, which fuses encryption and authentication; NIP-44 v2
  wants the bare cipher with a separately keyed HMAC-SHA256 over nonce and ciphertext.
  Hand-rolling is defensible for this specific primitive because it is a fixed
  add-rotate-xor permutation with no data-dependent branching or memory access, so there
  is no secret-dependent control flow for a timing side channel to observe.
- **Both crypto layers are validated against published vectors**, checked into the test
  target as resources: `nip44.vectors.json` (the official NIP-44 v2 vectors) and
  `bip340-test-vectors.csv` (Schnorr). This was listed as a thing to verify during
  evaluation; it is now a gate in CI.

comb's `CombCore` was read for shape and precedent rather than vendored, and is credited
as such in the README.
