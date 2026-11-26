# Release review: 0.3.12 (build 17)

This release includes PR #4 at `cda58758394ebcac4a4025428d778ec9d5a3b823`, merged as `a8e7f165c257f932808cda7674479e48a71b426c`.

## Review findings resolved

- Missing worktrees whose HEAD is not reachable through a Git ref require explicitly approved recovery branches before pruning. Existing branch names are not overwritten, and the safety check repeats immediately before prune.
- A failed or timed-out worktree listing or prune dry run aborts the operation. The error path cannot substitute an empty safe result for an unknown state.
- Concurrent Claude status line calls use separate temporary files and atomic replacement. An existing status line is chained and can be restored; an installed older bridge script is updated.
- A deleted upstream alone no longer marks unmerged work as finished.
- Negative repository discovery expires after five minutes; manual refresh clears the discovery cache.

## Validation

The reviewed PR passed 99 Swift tests and 7 Python tests. Independent temporary-repository reproductions confirmed that failed listings, timeouts and failed dry runs preserve missing-worktree records and their unique commit references. GitHub CI for `cda5875` passed.

Release validation repeats these tests, compiles both app variants and the VPN/filter components, checks fictional native-core fixtures, and validates the signed/notarized distribution artifact. The release notes record the final artifact status.

## Limits

The live Worktrees window and the Claude bridge have not been exercised against the user's active application. Prune tests use disposable repositories; no user repository was pruned. Cursor's sign-in token and Safe Storage key are not read.

The VPN/lock source is unchanged from 0.3.11. Crash, startup, leak and handoff checks on the device remain outstanding. This remains an experimental pre-release. Notarization is not a VPN protection guarantee.

Preparing and publishing this release does not authorize local app replacement, extension activation, bridge installation, repository pruning or changes to the active connection. Installation requires a separate user go-ahead.
