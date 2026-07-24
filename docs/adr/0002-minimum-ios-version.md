# ADR-0002: Minimum iOS version

**Status:** Accepted (revised 2026-07-24 — owner decision supersedes the same-day 17.0 draft)

## Context

Upstream Buzz mobile (Flutter) targets iOS 16.0. The original draft of this ADR chose iOS 17.0 for the Observation framework. The project owner then set a harder product requirement: a heavily Liquid Glass, Slack-caliber UI built on current SwiftUI — without maintaining availability shims for APIs the design depends on.

## Decision

- **App target: iOS 26.0.** The UI is built on the iOS 26 design language (Liquid Glass — `glassEffect`, `.glass` button styles) and current SwiftUI, with no back-deployment compromises.
- **`NostrCore` / `BuzzKit` packages: keep iOS 17 / macOS 14 floors.** They contain no UI; lower floors keep the protocol layer reusable by other projects and let package tests run natively on macOS CI.

## Rationale

- Liquid Glass APIs are iOS 26-only; a lower app floor means dual code paths for exactly the surfaces that define this app's identity — the worst of both worlds.
- This is a greenfield open-source client; by the time it ships broadly, iOS 26 adoption will be the norm. Early adopters of a Nostr client skew current-OS.
- The reference client comb (MIT, same domain) also targets iOS 26.0 — this floor is proven workable for the exact product shape.

## Consequences

Requires Xcode 26+ to build the app. Package development still works with Xcode 16+. Revisit annually against adoption data.
