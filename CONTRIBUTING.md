# Contributing

Thanks for your interest! This project aims to be a contributor-friendly, fully native iOS client for Buzz.

## Setup

```sh
./Scripts/bootstrap.sh   # installs XcodeGen if needed, generates Hive.xcodeproj
```

Requires Xcode 26+ for the app target (iOS 26 / Liquid Glass); the packages alone build with Xcode 16+. The `.xcodeproj` is generated from `project.yml` and gitignored — edit `project.yml`, never the project file.

**Re-run `xcodegen generate` after adding any file.** Sources and tests that are not in a generated project are not compiled and not run — a new test file simply never executes, and nothing reports it.

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
2. `make test` (package tests, release config, native on macOS), `make build` (app on simulator), `make lint`. App tests run from Xcode or `xcodebuild test` against an iOS 26 simulator.
3. CI must be green. Three jobs run on every PR, against the merge ref: **SPM tests** (NostrCore and BuzzKit, release config), **SwiftLint**, and **app tests on an iOS Simulator**. `make format` (SwiftFormat) is available but is *not* a CI gate.
4. Parity work: check the corresponding row in [PARITY.md](PARITY.md) and the upstream `docs/nips/` spec for the feature.

Package tests run in release configuration on purpose: current toolchains abort `-Onone` runs in the connection suites, an environmental codegen defect. The assertions are the same either way — see the comment in `Makefile` and the non-blocking debug sentinel job in `.github/workflows/ci.yml`.

## Commit style

Plain, imperative subject lines. No attribution trailers.
