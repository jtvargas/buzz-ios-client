<!-- This repo squash-merges pull requests: the PR title becomes the commit
subject, so it must follow Conventional Commits (e.g. `fix(sync): retry on
relay disconnect`). CI lints the title and will block merge otherwise. -->

## What

<!-- What does this PR do? Link the issue if one exists. -->

## Why

<!-- Motivation / context. For parity work, link the PARITY.md row and upstream NIP spec. -->

## Validation

<!-- How was this verified? `make test` / `make build` output, simulator screenshots for UI. -->

- [ ] `make test` passes (package tests, release config)
- [ ] App tests pass on an iOS 26 simulator (re-run `xcodegen generate` first if you added a file)
- [ ] `make lint` clean
- [ ] New decisions recorded in `docs/adr/` (if architectural)
