# Parity with upstream Buzz mobile

**Target version: v0.4.11** ([block/buzz](https://github.com/block/buzz) `mobile/`)

This is the living checklist for the headline milestone: feature parity with the upstream Flutter app at v0.4.11. Each row is checked off only when the feature works end-to-end against a real Buzz relay and matches the behavior documented in the corresponding `docs/nips/` spec.

## Core protocol

- [ ] Relay connection with reconnect/backoff and lifecycle handling
- [ ] NIP-42 authentication (including re-auth on reconnect)
- [ ] NIP-98 HTTP auth signing (`POST /query`, media upload)
- [ ] NIP-CW channel windows: history/pagination via the HTTP bridge, head-window reconcile on reconnect
- [ ] NIP-44 v2 encryption (validated against official test vectors)
- [ ] Subscription management (REQ/EOSE/CLOSED), live + one-shot modes, overlap-window gap-fill
- [ ] Event signing and publish with outbox retry (OK/CLOSED prefix classification)
- [ ] Local persistence as source of truth (GRDB; projected store with replaceable/deletion/edit semantics)

## Features (upstream `mobile/lib/features/`)

| Feature | Upstream module | Status |
|---------|-----------------|--------|
| Home (channel list, unreads) | `home` | ☐ |
| Channels (timeline, composer) | `channels` | ☐ |
| Threads | `channels` | ☐ |
| Reactions | `channels` | ☐ |
| Activity feed (mentions/replies/reactions) | `activity` | ☐ |
| Search | `search` | ☐ |
| Profiles | `profile` | ☐ |
| Settings | `settings` | ☐ |
| Auth: nsec import | — | ☐ |
| Auth: QR pairing with Desktop | `pairing` | ☐ |
| Invites + deeplinks | `invites` | ☐ |
| Forum | `forum` | ☐ |
| Pulse | `pulse` | ☐ |
| Custom emoji | `custom_emoji` | ☐ |
| Media upload | — | ☐ |
| Presence | — | ☐ |
| Typing indicators | — | ☐ |
| Message edits (kind:40003) | `channels` | ☐ |
| Rich content rendering (kind:40002) | `channels`/`forum` | ☐ |
| Cross-device read state (NIP-RS) | — | ☐ |
| Channel mutes/stars/sections | `home`/`settings` | ☐ |
| Agent activity observer | `activity` | ☐ |

## Process

On each upstream release: diff `mobile/` features and `docs/nips/`, file parity issues, and bump the target version header once 0.4.11 is fully checked.
