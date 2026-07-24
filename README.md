# Hive — buzz client

**Hive** is a 100% Swift/SwiftUI native iOS client for [Buzz](https://github.com/block/buzz) — the Nostr-based messaging platform for human–agent collaboration.

> **Status:** early foundations (Phase 0). Not yet usable. The first public milestone is feature parity with the upstream Buzz mobile app **v0.4.11** — tracked in [PARITY.md](PARITY.md).

## Why

Buzz ships an excellent Flutter mobile app. Hive is a fully native iOS client with a Slack-iOS-style UX built on the iOS 26 design language (Liquid Glass, native-first system components), aiming for the things native does best: tight scrolling/animation performance, share extensions, widgets, App Intents, Live Activities, and first-class APNs push.

Hive is not affiliated with Block, Inc. The Buzz name and bee mark are upstream's; Apache-2.0 withholds trademark rights.

## Product model

Slack-style shell:

- **Home** — channel list with unreads
- **Activity** — mentions, reactions, thread replies
- **Search** — cross-channel message search
- **You** — profile and settings

Channel view → timeline + composer; threads open as push/sheet; long-press → reactions and context menu.

## Architecture

App target plus two local SPM packages, modular from day one:

| Layer | Contents |
|-------|----------|
| `NostrCore` | Keys (secp256k1 → Keychain), event model/codec, signing, relay WebSocket actor (reconnect/backoff/heartbeat), NIP-42 auth, subscription manager (REQ/EOSE/CLOSED) |
| `BuzzKit` | Buzz domain layer: kinds & tags per Buzz's NIP extensions, channels/threads/reactions/profiles models, **SyncEngine** + **Outbox**, GRDB (SQLite) persistence |
| App | SwiftUI, iOS 26+ (Liquid Glass, Observation), Swift 6 strict concurrency, MVVM with feature folders |

Packages keep an iOS 17 / macOS 14 floor (no UI code); the app targets iOS 26 — see [ADR-0002](docs/adr/0002-minimum-ios-version.md).

### Sync reliability (client-owned)

The Buzz relay has no negentropy/NIP-77 sync, so reliability is built client-side, mirroring the upstream hybrid model:

- **NIP-CW channel windows** for history and pagination: relay-computed windows with authoritative `has_more` and composite `(created_at, id)` cursors over the NIP-98-authenticated HTTP bridge, merged at render with WS live subscriptions; head-window refetch on reconnect.
- A single **RelayConnection actor**: exponential backoff + jitter, NIP-42 re-auth on every reconnect, explicit lifecycle state machine (foreground-resume is treated exactly like reconnect: connect → auth → re-arm subs → reconcile).
- **Careful cursors**: advance only at EOSE during backfill, per event when live; persist cursors in the same transaction as their events; reconnect with an overlap window plus id-dedupe (`created_at` is author-controlled).
- The database is the single source of truth — a projected store (raw events + projected messages/channels/members/profiles) with proper replaceable, deletion, and edit semantics. Ephemeral presence/typing bypass the DB into an in-memory store.
- **Outbox pattern**: optimistic local insert → publish → confirm on relay OK → retry classified by OK/CLOSED machine-readable prefixes; unsent state visible in the UI (Slack-style "sending… / failed, tap to retry").

### Protocol references

- Upstream third-party client guide: `NOSTR.md` in [block/buzz](https://github.com/block/buzz)
- Buzz NIP extensions: `docs/nips/` in block/buzz (AA, AE, AM, AO, AP, CW, DV, ER, GS, IA, OA, PL, RS, WP)
- Base protocol: NIP-01, NIP-29 (groups), NIP-42 (auth)
- [jedbridges/comb](https://github.com/jedbridges/comb) (MIT) — an independent native iOS Buzz client; Hive borrows ideas and, where it fits, adapts code from it with attribution

Architecture decisions are recorded in `docs/adr/`.

## Building

Requires Xcode 26+ (iOS 26 SDK) for the app; packages alone build with Xcode 16+.

```sh
./Scripts/bootstrap.sh   # generates Hive.xcodeproj from project.yml (XcodeGen)
make test                # package tests (native macOS, fast)
make build               # app build for iOS Simulator, no signing
```

Personal signing config lives in `Config/Local.xcconfig` (gitignored — copy `Config/Local.xcconfig.example` and set your `DEVELOPMENT_TEAM`). CI and contributors build for the simulator with code signing disabled; no Apple team required. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Roadmap

| Phase | Scope |
|-------|-------|
| 0 | Repo, project scaffolding, CI, contribution docs |
| 1 | `NostrCore`: keys, codec, relay actor, NIP-42, subscriptions |
| 2 | `BuzzKit`: GRDB storage, SyncEngine, Outbox |
| 3 | MVP client: auth (nsec import, then QR pairing with Desktop), Home, timeline, composer, threads, reactions |
| 4 | **v0.4.11 parity** — see [PARITY.md](PARITY.md) |
| 5 | Native-only: push, share extension, widgets, App Intents / Live Activities, iPad |

## License

[Apache-2.0](LICENSE) — matching upstream block/buzz.
