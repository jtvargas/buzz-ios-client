# Contributing

Thanks for your interest! This project aims to be a contributor-friendly, fully native iOS client for Buzz.

## Setup

```sh
./Scripts/bootstrap.sh   # installs XcodeGen if needed, generates BuzzClient.xcodeproj
```

Requires Xcode 16+ (Swift 6). The `.xcodeproj` is generated from `project.yml` and gitignored — edit `project.yml`, never the project file.

Simulator builds need no signing. For device builds, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and set your `DEVELOPMENT_TEAM`. Never commit team IDs or personal bundle identifiers.

## Layout & boundary rules

| Where | What | Rule |
|-------|------|------|
| `Packages/NostrCore` | Generic Nostr primitives (keys, codec, transport, NIP-42/98/44, subscriptions) | Knows **no** Buzz-specific kinds |
| `Packages/BuzzKit` | Buzz domain: kinds/tags, models, NIP-CW client, SyncEngine, Outbox, GRDB | **Never** touches the socket or URLSession directly |
| `App/` | SwiftUI app, MVVM with feature folders | UI reads the database, never the socket |

Architecture decisions live in [`docs/adr/`](docs/adr/) — read them before proposing structural changes, and add a new ADR when you make one.

## Workflow

1. Branch from `main`; keep PRs focused.
2. `make test` (package tests run natively on macOS), `make build` (app on simulator), `make lint`, `make format`.
3. CI must be green: SPM tests, SwiftLint, and a simulator build run on every PR.
4. Parity work: check the corresponding row in [PARITY.md](PARITY.md) and the upstream `docs/nips/` spec for the feature.

## Commit style

Plain, imperative subject lines. No attribution trailers.
