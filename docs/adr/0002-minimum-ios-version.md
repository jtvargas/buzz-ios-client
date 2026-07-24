# ADR-0002: Minimum iOS version

**Status:** Accepted (2026-07-24)

## Context

Upstream Buzz mobile (Flutter) targets iOS 16.0. This project's state layer is the Observation framework (`@Observable`), which requires iOS 17.

## Decision

**Minimum deployment target: iOS 17.0.**

## Rationale

- Supporting iOS 16 would forfeit Observation or force a dual `ObservableObject` code path — the worst of both worlds.
- Hardware cost is small: iOS 17 runs on everything back to iPhone XS (2018); only iPhone 8/X-era devices are excluded.
- Upstream's 16.0 floor is a Flutter constraint, not a product requirement — nothing in the v0.4.11 parity list needs iOS 16.

## Consequences

Free use of iOS 17+ APIs (Observation, SwiftData-era SwiftUI improvements) throughout. Revisit the floor annually against adoption data.
