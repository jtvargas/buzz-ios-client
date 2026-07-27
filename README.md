# Hive — a Buzz client

**Hive** is a 100% Swift/SwiftUI native iOS client for [Buzz](https://github.com/block/buzz) — the Nostr-based messaging platform for human–agent collaboration.

> **Status:** usable daily driver, pre-1.0. You can pair with Buzz Desktop, read and send in channels, DMs and threads, react, and mention people and agents — agents being first-class identities here, with their own sidebar section and their own DMs. Several upstream features are not built yet — [Features & support](#features--support) is the honest list, and [PARITY.md](PARITY.md) tracks the v0.4.11 milestone.

## Why

Buzz ships an excellent Flutter mobile app. Hive is a fully native iOS client with a Slack-iOS-style UX built on the iOS 26 design language (Liquid Glass, native-first system components), aiming for the things native does best: tight scrolling and animation performance, share extensions, widgets, App Intents, Live Activities, and first-class APNs push.

Hive is not affiliated with Block, Inc. The Buzz name and bee mark are upstream's; Apache-2.0 withholds trademark rights.

## Features & support

What follows describes the app as it is on `main`, not as it is planned. Anything not under **Working today** is not in the app.

### Working today

**Identity and pairing**

- Create a new identity on device, or paste an existing `nsec`.
- **QR pairing with Buzz Desktop** (NIP-AB) — scan the code, confirm the short authentication string on both screens, and the desktop hands over the identity and its relay over an encrypted channel. If the camera is unavailable, paste the `nostrpair://` link instead.
- The private key lives in the Keychain and signs locally. Hive is a pairing *target* only: it receives a key, and has no path that sends one anywhere.
- **Key backup** behind Face ID / Touch ID, and a sign-out that removes the key from this device. Local history is kept — it is wiped only when a *different* identity signs in.
- **Edit your own profile** — display name and About, published as a kind-0 event — and copy your own `npub`, from the Account sheet.
- The relay endpoint is configurable at sign-in; a paired identity brings the desktop's relay with it. A status pill in the sidebar shows the live connection: Offline, Connecting, Live or Paused.

**Conversations**

- **Sidebar** with three sections — Channels, Direct Messages, Agents — each collapsible, with its state remembered across launches. Rows carry the newest message, its time, and an unread indicator: a quiet dot for ordinary unread, a numeric badge when the unread messages mention you.
- **Channels, direct messages and threads** all render through one shell, so a new surface inherits its scrolling, keyboard and layout behaviour rather than reimplementing it. (A thread deliberately opts out of one part: it does not page into history.)
- A **direct message is a channel whose roster is exactly two members including you** — derived in one place rather than treated as a separate surface. An agent DM is the same thing with an agent on the other end.
- **Open a DM from a profile sheet** — its `Message` button opens the existing conversation if there is one and asks the relay to create it if there is not.
- **Thread replies**, with a replies row on the opening message showing the participants' faces.
- **Day separators**, and timestamps that age in place on one shared clock.
- **Scroll back through history**, paged from the local database by `(created_at, id)` keyset cursor, with your position preserved as older pages land. The engine closes gaps against the relay's channel windows (NIP-CW) on connect and reconnect.

**Reading and writing**

- **Rich text**: a markdown subset rendered from Buzz's rich-message events — headings, quotes, fenced code blocks with a language, bullet and ordered lists, and inline bold, italic, strikethrough, code spans and links.
- **Interactive mentions and links.** Member mentions, agent mentions, channel mentions, web URLs, email addresses and Buzz's own `buzz://message` links are tinted rounded pills that act when pressed: a mention opens its profile sheet, a channel mention opens that channel, links go to the system handler. Identity travels as the pubkey resolved from the message's own tags — never as the visible name.
- **A mention of you is emphasised**, so your own name stands out from every other mention in the message.
- **Mention autocomplete** for `@people` and `#channels`, anchored to the caret, so it works mid-sentence and on any line of a multiline draft.
- **A composer that grows** to six lines and then scrolls, with a draft that survives a failed send.
- **Reactions** — a six-emoji palette, reachable from the long-press menu *or* from an add-reaction pill under the message; chips with counts, and your own reaction highlighted and withdrawable by tapping its chip.
- **Long-press menu**: react, copy, retry a failed send, and discard one of your own messages that has not been sent.
- **Optimistic send** through a durable outbox that survives relaunch. A message in flight is dimmed; one the relay rejected says so with the reason it gave — "Not delivered (rate-limited) — tap to retry". An over-long message is caught before it is sent, with the limit named and the draft handed back.
- **Message edits and deletions** authored elsewhere are applied to what you see.

**Presence and position**

- **Presence** — a live online dot beside names, in the sidebar, and in a DM's heading.
- **Typing indicators** above the composer.
- **Cross-device read state** (NIP-RS), encrypted to yourself, so what you have read on the desktop is read here.
- **Jump controls** — an arrival while you are reading history is held back and counted rather than moving you, and the `N new messages` pill lands you on the *first* of them; `↓ Latest` appears when you are a long way up with nothing new.
- **Interactive keyboard dismissal** — drag down the message list and the keyboard follows your finger, with the composer staying attached to it. The gesture engages at the composer's top edge rather than the keyboard's, so the list and the composer read as one surface. (A drag that *begins* on the composer itself does not dismiss — see [ADR-0004](docs/adr/0004-conversation-ui-architecture.md) for why that is out of reach.)

**Identity, everywhere it is shown**

- One resolver names every person and agent — profile display name, then agent directory name, then NIP-05, then a shortened `npub`. A raw 64-character key never appears as a name.
- **Profile sheet** for the author of any message — tap their avatar, their name, or a mention of them: picture, name, whether they are a member or an agent, presence, their `npub` with copy, and `Message`.
- **Avatars** are fetched as relay thumbnails, and SVG `data:` URIs — which iOS has no decoder for — are rendered rather than silently falling back to initials.
- **Channel details** sheet: topic, visibility and member count, the members with their presence, and a Developer section carrying the channel id. A direct message shows the person instead of a roster.
- **VoiceOver**: a message reads as one sentence rather than three fragments, with the author's profile offered as a rotor action; reaction chips announce their emoji and count.
- **Dynamic Type** throughout, including the accessibility sizes.

### Not built yet

These exist upstream, or are on the roadmap, and are honestly absent here:

- **Push notifications.** There is no APNs registration; you see activity when the app is open.
- **Activity feed** and **in-app search.** No mentions/reactions inbox, no cross-channel search screen.
- **Media.** No image or file attachments — the composer's `+` opens a placeholder — and no inline media in messages. Avatars are the only images fetched.
- **Authoring an edit or a deletion.** Both render when they arrive from elsewhere; Hive can only discard one of its own messages that has not left the outbox.
- **A profile from the sidebar or the channel roster.** The sheet is reached from a message today, so someone who has not posted in the open conversation has no entry point.
- **Forum, Pulse, invites and deep links, custom emoji, channel mutes and stars.**
- **Creating a named channel, and editing a roster.** Hive asks the relay to open a direct message, and otherwise reads membership rather than changing it.
- **An iPad layout.** The app installs and runs on iPad, but nothing is laid out for it.
- **Widgets, share extension, App Intents, Live Activities.**

[PARITY.md](PARITY.md) is the same picture against upstream's module list.

## Product model

Sidebar-first, Slack-style: one navigation stack rooted on the conversation list, pushing a timeline, then a thread. Account and channel details are sheets. There is no tab bar — Activity and Search will arrive as their own surfaces when they are built.

## Architecture

App target plus two local SPM packages, modular from day one:

| Layer | Contents |
|-------|----------|
| `NostrCore` | Keys (secp256k1 → Keychain), event model/codec/kinds, signing, relay WebSocket actor (reconnect/backoff/heartbeat), NIP-42 auth, NIP-44 encryption, NIP-98 HTTP auth, subscription manager (REQ/EOSE/CLOSED), NIP-AB device pairing |
| `BuzzKit` | Buzz domain layer: projections for channels/threads/reactions/profiles/presence/read state, **SyncEngine** + **Outbox**, NIP-CW window client, GRDB (SQLite) persistence |
| App | SwiftUI, iOS 26+ (Liquid Glass, Observation), Swift 6 strict concurrency, MVVM with feature folders |

Packages keep an iOS 17 / macOS 14 floor (no UI code); the app targets iOS 26 — see [ADR-0002](docs/adr/0002-minimum-ios-version.md).

### Sync reliability (client-owned)

The Buzz relay has no negentropy/NIP-77 sync, so reliability is built client-side, mirroring the upstream hybrid model:

- **NIP-CW channel windows** for history and pagination: relay-computed windows with authoritative `has_more` and composite `(created_at, id)` cursors over the NIP-98-authenticated HTTP bridge, merged at render with WS live subscriptions; head-window refetch on reconnect.
- A single **RelayConnection actor**: exponential backoff + jitter, NIP-42 re-auth on every reconnect, explicit lifecycle state machine (foreground-resume is treated exactly like reconnect: connect → auth → re-arm subs → reconcile).
- **Careful cursors**: advance only at EOSE during backfill, per event when live; persist cursors in the same transaction as their events; reconnect with an overlap window plus id-dedupe (`created_at` is author-controlled).
- The database is the single source of truth — a projected store (raw events + projected messages/channels/members/profiles) with proper replaceable, deletion, and edit semantics. Ephemeral presence/typing bypass the DB into an in-memory store.
- **Outbox pattern**: optimistic local insert → publish → confirm on relay OK → retry classified by OK/CLOSED machine-readable prefixes; unsent state visible in the UI, with the relay's own rejection reason on the failed row.

### Conversation UI

One shell — `ConversationScaffold` — owns the message list, the floating composer, and the keyboard and safe-area behaviour for the channel, the thread and the DM alike, so a new surface inherits all of it by construction. The decisions behind it, and the measurements that settled the ones Apple does not document, are in [ADR-0004](docs/adr/0004-conversation-ui-architecture.md).

### Protocol references

- Upstream third-party client guide: `NOSTR.md` in [block/buzz](https://github.com/block/buzz)
- Base protocol: NIP-01, NIP-29 (groups), NIP-42 (auth), NIP-44 (encryption), NIP-98 (HTTP auth)
- Buzz NIP extensions Hive implements today: **AB** (device pairing), **CW** (channel windows), **RS** (read state), **OA** (agent profiles), **IA**, **WP**. The full upstream set lives in `docs/nips/` in block/buzz — AA, AE, AM, AO, AP, DV, ER, GS and PL are not implemented here.
- [jedbridges/comb](https://github.com/jedbridges/comb) (MIT) — an independent native iOS Buzz client; Hive borrows ideas and, where it fits, adapts code from it with attribution

Architecture decisions are recorded in `docs/adr/`.

## Building

Requires Xcode 26+ (iOS 26 SDK) for the app; packages alone build with Xcode 16+.

```sh
./Scripts/bootstrap.sh   # generates Hive.xcodeproj from project.yml (XcodeGen)
make test                # package tests, release config (native macOS, fast)
make build               # app build for iOS Simulator, no signing
make lint                # SwiftLint
```

`Hive.xcodeproj` is generated and gitignored — edit `project.yml`, and re-run `xcodegen generate` after adding a file, or new sources and tests are silently skipped.

Personal signing config lives in `Config/Local.xcconfig` (gitignored — copy `Config/Local.xcconfig.example` and set your `DEVELOPMENT_TEAM`). CI and contributors build for the simulator with code signing disabled; no Apple team required. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Roadmap

| Phase | Scope | State |
|-------|-------|-------|
| 0 | Repo, project scaffolding, CI, contribution docs | done |
| 1 | `NostrCore`: keys, codec, relay actor, NIP-42, subscriptions | done |
| 2 | `BuzzKit`: GRDB storage, SyncEngine, Outbox | done |
| 3 | MVP client: auth (nsec import, then QR pairing with Desktop), sidebar, timeline, composer, threads, reactions | done |
| 4 | Conversation UX: one shared shell, rich text, mentions, presence, DMs, profiles, jump controls, keyboard | done |
| 5 | **v0.4.11 parity** — activity, search, media, invites, forum, pulse — see [PARITY.md](PARITY.md) | in progress |
| 6 | Native-only: push, share extension, widgets, App Intents / Live Activities, iPad | not started |

## License

[Apache-2.0](LICENSE) — matching upstream block/buzz.
