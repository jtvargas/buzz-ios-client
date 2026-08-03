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
3. CI must be green. Two jobs run on every PR, against the merge ref: **SPM tests** (NostrCore and BuzzKit, release config) and **SwiftLint**. `make format` (SwiftFormat) is available but is *not* a CI gate.
4. The two suites that boot a **simulator** run by hand rather than on every PR, because a hosted runner has repeatedly failed them under load with no defect underneath — a 60-second time limit exceeded in a suite the diff never touched, green on a re-run of the same commit. A red nobody believes is worse than no red, so:
   - **App tests** — `make build` and `xcodebuild test` locally, or the `app` job of [CI](.github/workflows/ci.yml) triggered from the Actions tab (`gh workflow run ci.yml --ref <branch>`). Run it before merging anything that touches the send path, the outbox, persistence, or the composer.
   - **The conversation shape gate** (`make uitest`) drives eight conversation shapes through a real keyboard and takes 10–20 minutes. Locally when your work touches the conversation shell, the message list, the composer, or the keyboard — or on a clean machine through the manually-triggered [Conversation UI](.github/workflows/conversation-ui.yml) workflow.
5. Parity work: check the corresponding row in [PARITY.md](PARITY.md) and the upstream `docs/nips/` spec for the feature.

Package tests run in release configuration on purpose: current toolchains abort `-Onone` runs in the connection suites, an environmental codegen defect. The assertions are the same either way — see the comment in `Makefile` and the non-blocking debug sentinel job in `.github/workflows/ci.yml`.

## Commit style

Use [Conventional Commits v1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):

```text
<type>(scope): <description>
```

The scope is optional. When it helps, prefer scopes that match this repository's layout and ownership boundaries: `ui`, `app`, `buzzkit`, `nostrcore`, `ci`, `docs`, or `deps`.

| Type | Use for |
|------|---------|
| `feat` | User-visible feature work |
| `fix` | Bug fixes |
| `docs` | Documentation-only changes |
| `style` | Formatting-only changes that do not affect behavior |
| `refactor` | Code restructuring without behavior changes |
| `perf` | Performance improvements |
| `test` | Test-only changes |
| `build` | Build system, project generation, or packaging changes |
| `ci` | CI workflow changes |
| `chore` | Maintenance that does not fit another type |
| `revert` | Reverting a previous change |

Examples:

```text
docs: update README contribution links
fix(buzzkit): preserve read state after reconnect
feat(ui): add channel details sheet
ci: lint pull request titles
```

Use imperative, lowercase descriptions with no trailing period. For breaking changes, add `!` before the colon and describe the break in the body or footer:

```text
feat(nostrcore)!: replace relay connection delegate
```

PR titles are linted in CI, and this repository squash-merges PRs, so the PR title becomes the final commit subject.

No attribution trailers.
