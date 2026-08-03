# Security Policy

## Supported versions

This project is pre-1.0. Only `main` is supported; there are no maintained
release branches, so security fixes land there first.

| Version | Supported |
| ------- | --------- |
| `main`  | ✅        |
| Other   | ❌        |

## Scope

This app stores a Nostr private key in the iOS Keychain and uses it to sign
and decrypt protocol events. Reports involving any of the following are in
scope:

- Private key handling, storage, or export (Keychain usage, Secure Enclave,
  backup/restore)
- Device pairing (NIP-AB) and its confirmation flow
- Relay authentication (NIP-42) and session/token handling
- Any other flow that could leak or misuse the private key

Bugs that only affect protocol behavior common to all Nostr clients (not
specific to this app) should go to the upstream
[block/buzz](https://github.com/block/buzz) repository instead.

## Reporting a vulnerability

**Do not open a public issue for a vulnerability, and do not include a public
proof of concept.**

Report privately using GitHub's [private vulnerability
reporting](https://github.com/jtvargas/buzz-ios-client/security/advisories/new)
for this repository. We do not maintain a separate security email address —
use GitHub private reporting so the report and any follow-up stay
confidential.

We'll acknowledge the report and follow up with next steps once triaged.
