# Architecture Decision Records

One file per decision, numbered sequentially: `NNNN-short-title.md` with **Status** (Proposed / Accepted / Superseded), **Context**, **Decision**, **Rationale**, **Consequences**.

Add an ADR whenever a change fixes a structural choice others will build on. Amend an
existing one — with a dated, named amendment section — when later work supersedes or
extends a decision rather than replacing it wholesale.

| ADR | Decision | Status |
|-----|----------|--------|
| [0001](0001-nostr-library-selection.md) | No Nostr SDK: `NostrCore` hand-rolled over `swift-secp256k1` | Accepted |
| [0002](0002-minimum-ios-version.md) | App targets iOS 26; packages keep an iOS 17 / macOS 14 floor | Accepted |
| [0003](0003-persistence-layer.md) | GRDB over SQLite as BuzzKit's store, database as source of truth | Accepted |
| [0004](0004-conversation-ui-architecture.md) | One conversation shell, one identity resolver, one clock | Accepted |
