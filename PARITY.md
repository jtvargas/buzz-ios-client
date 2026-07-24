# Parity with upstream Buzz mobile

**Target version: v0.4.11** ([block/buzz](https://github.com/block/buzz) `mobile/`)

This is the living checklist for the headline milestone: feature parity with the upstream Flutter app at v0.4.11. Each row is checked off only when the feature works end-to-end against a real Buzz relay and matches the behavior documented in the corresponding `docs/nips/` spec.

## Core protocol

- [ ] Relay connection with reconnect/backoff and lifecycle handling
- [ ] NIP-42 authentication (including re-auth on reconnect)
- [ ] Subscription management (REQ/EOSE/CLOSED) with `since`-cursor gap-fill
- [ ] Event signing and publish with outbox retry
- [ ] Local persistence as source of truth (GRDB)

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

## Process

On each upstream release: diff `mobile/` features and `docs/nips/`, file parity issues, and bump the target version header once 0.4.11 is fully checked.
