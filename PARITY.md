# Parity with upstream Buzz mobile

**Target version: v0.4.11** ([block/buzz](https://github.com/block/buzz) `mobile/`)

This is the living checklist for the headline milestone: feature parity with the upstream Flutter app at v0.4.11. A row is checked only when the feature works end-to-end against a real Buzz relay and matches the behavior documented in the corresponding `docs/nips/` spec.

**Legend** — ✅ done · ◐ partial (what is missing is named) · ☐ not started

## Core protocol

- ✅ Relay connection with reconnect/backoff and lifecycle handling
- ✅ NIP-42 authentication (including re-auth on reconnect)
- ◐ NIP-98 HTTP auth signing — `POST /query` is signed and in use; media upload has no client yet
- ✅ NIP-CW channel windows: history/pagination via the HTTP bridge, head-window reconcile on reconnect
- ✅ NIP-44 v2 encryption, validated against the official test vectors (`Packages/NostrCore/Tests/NostrCoreTests/nip44.vectors.json`)
- ✅ NIP-AB device pairing (target role): encrypted session, short-authentication-string confirmation, transcript binding
- ✅ Subscription management (REQ/EOSE/CLOSED), live + one-shot modes, overlap-window gap-fill
- ✅ Event signing and publish with outbox retry (OK/CLOSED prefix classification)
- ✅ Local persistence as source of truth (GRDB; projected store with replaceable/deletion/edit semantics)

## Features (upstream `mobile/lib/features/`)

| Feature | Upstream module | Status | Notes |
|---------|-----------------|--------|-------|
| Home (channel list, unreads) | `home` | ✅ | Sidebar: Channels / Direct Messages / Agents, collapsible and persisted; last message, time, unread indicator |
| Channels (timeline, composer) | `channels` | ✅ | One shared shell for channel, thread and DM |
| Threads | `channels` | ✅ | Replies row with participant faces; heading pops back to the conversation |
| Reactions | `channels` | ✅ | A long press opens a sheet: five quick reactions with the full emoji picker beside them, then Reply in thread, Copy Message and Remind Me. Chips with counts under the message, own reaction withdrawable |
| Direct messages | `channels` | ✅ | A DM is a channel whose roster is exactly two members including you; opened or created from the profile sheet |
| Activity feed (mentions/replies/reactions) | `activity` | ☐ | A tab exists and is a placeholder; nothing is collected behind it |
| Search | `search` | ☐ | No in-app search |
| Profiles | `profile` | ◐ | Profile sheet (picture, name, member/agent, presence, npub + copy, Message) opens from a message's avatar, name or mention; not yet from the sidebar or the channel roster. Own profile (display name, About) editable in Account |
| Settings | `settings` | ◐ | Account sheet: profile, key backup, own npub, sign out; relay endpoint at sign-in; connection-state pill in the sidebar. No general settings screen |
| Auth: nsec import | — | ✅ | Paste a key, or create one on device |
| Auth: QR pairing with Desktop | `pairing` | ✅ | NIP-AB, target role: encrypted transfer with short-authentication-string confirmation on both screens, plus a paste-the-`nostrpair://`-link fallback when the camera is unavailable |
| Invites + deeplinks | `invites` | ☐ | `buzz://message` links render and route in-app; no invite or pairing deep-link entry point |
| Forum | `forum` | ☐ | |
| Pulse | `pulse` | ☐ | |
| Custom emoji | `custom_emoji` | ☐ | Unicode emoji only |
| Media upload | — | ☐ | Composer `+` is a placeholder; no attachments and no inline media |
| Presence | — | ✅ | Live dots in rows, sidebar and DM heading; own heartbeat published |
| Typing indicators | — | ✅ | Shown above the composer; own typing throttled |
| Message edits (kind:40003) and deletions | `channels` | ◐ | Both are projected and rendered when they arrive; the app can author neither. The menu's Delete discards an own message still in the outbox |
| Rich content rendering (kind:40002) | `channels`/`forum` | ◐ | Headings, paragraphs, quotes, fenced code, nested lists, GFM tables (scrolled horizontally, never clipped), thematic rules, task/radio items, bold/italic/strike/code/`<u>`, plus interactive mentions, channel mentions, URLs, emails and `buzz://message` links. Not rendered: inline images/video (see *Media upload*), LaTeX, and upstream's `[1]` citation badge — the badge would eat `list[0]` in ordinary text |
| Link previews | — | ◐ | A compact card under the message for each link it points at, capped at four: GitHub pull requests, issues and repositories, Linear issues and Google Docs/Sheets/Slides/Drive files by name, every other URL by host and path. Desktop's parsing rules exactly (`desktop/src/shared/lib/linkPreview.ts`), so the same message cards identically on both. Every word comes from the URL; the only fetch is the site's `/favicon.ico`. Not done: Desktop's authenticated title lookup for Google files, which returns a sign-in page unauthenticated |
| Cross-device read state (NIP-RS) | — | ✅ | Published and adopted, NIP-44 encrypted to self |
| Channel mutes/stars/sections | `home`/`settings` | ◐ | Sidebar sections ship; no mutes or stars |
| Agent activity observer | `activity` | ☐ | The agent directory (kind 10100) is projected and agents have their own sidebar section, but there is no activity surface |
| Channel creation / membership management | `channels` | ◐ | Opening a direct message publishes the kind-41010 open-or-create command and the relay creates the channel if it does not exist. No named-channel creation and no roster editing |

## Beyond parity

Native work already in place that upstream's Flutter app does not have an equivalent for:

- Interactive keyboard dismissal with the composer attached to the keyboard, over the list *and* the composer's own band.
- Jump controls that hold an arrival back while you read history and land you on the first unread rather than the bottom.
- SVG `data:` URI avatar rendering (iOS ships no SVG decoder in its imaging pipeline).
- VoiceOver: a message read as one sentence with the author's profile as a rotor action.

## Process

On each upstream release: diff `mobile/` features and `docs/nips/`, file parity issues, and bump the target version header once 0.4.11 is fully checked.
