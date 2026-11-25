# 0.3.11 — agents and network-lock hardening (pre-release)

This release combines PR #1 (network lock) and PR #2 (Claude Code / Cursor monitoring), including follow-up review fixes. App, tunnel and lock use **build 16** so macOS can replace older components.

## Changes

- Monitor Codex, Claude Code and Cursor locally. Agent filters, per-agent switches and notifications identify the source. Claude usage is deduplicated by message; Cursor activity is inferred from transcript writes and explicit end markers.
- Large Cursor transcripts read only their bounded tail. Ambiguous encoded workspace paths remain unresolved rather than choosing another existing project. Session identities include the agent, and overflowing Claude usage records do not crash the monitor.
- The lock's authenticated interface binding expires without renewal. It also checks the system interface index: another interface reusing the same utun name cannot inherit its broad allowance before expiry. Saved state cannot restore the binding after restart.
- Explicit recovery handles duplicate profiles belonging to VibeMonitoring. Server-change rollback retains its live binding. Disabled filters are reported honestly; component replacement under requested protection has a warning. EAPOL is permitted as local link maintenance.

## Install/update

Apple silicon (arm64), macOS 13+. Download the DMG and its SHA-256 file. Drag **VibeMonitoring.app** to **Applications**, then launch that copy. The source tag is `v0.3.11`.

Before replacing an active experimental VPN app/components, explicitly allow direct Internet in the old app, wait for confirmation and move to a working connection such as Happ. Updating can interrupt the tunnel. In the new app, update **both** the VPN and network-lock components and approve macOS requests. Component installation does not activate protection; reconnect only when ready.

Monitoring does not require VPN component installation. The app reads local transcripts; it does not upload prompts or conversation contents.

## Validation and limits

82 Swift tests and 7 signing/build-script tests pass for the combined source. The monitoring app and optional VPN targets compile. Regression fixtures reproduce ambiguous Cursor paths and needless reverse scans before the fixes. Network tests cover lease expiry, interface-index reuse, policy reloads and invalid binding indices. Tests use synthetic journals and fictional VPN configuration; they do not switch live networking.

**This remains a pre-release.** Filter/provider crash, component replacement, reboot, sleep/wake, native interface reuse and handoff to Happ need controlled device acceptance. There is no measured kill-switch reaction time, proven absence of leaks or verified fix for every earlier HTTPS stall. Claude Code and Cursor journal formats are internal and can change with their updates.

See [network-lock behavior and acceptance checklist](network-lock.md), [downloads and source builds](releases.md), and [review findings](review-0.3.11.md).
