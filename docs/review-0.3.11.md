# Review of PR #1 and PR #2

What this change does: PR #1 hardens network-lock recovery and live-interface permissions. PR #2 adds local Claude Code/Cursor monitoring alongside Codex. Review assumes one local Mac polling its own journals every two seconds; no transcript content is uploaded or included in diagnostic output.

## Must fix — resolved before release

1. **A reused utun name could inherit permission before lease expiry** (`NetworkLockRuntime.swift`, `PacketLockProvider.swift`).
   - What this is: the filter allows all packets on the tunnel interface bound by authenticated IPC.
   - Problem: the 15-second lease bounded permission duration, but a different interface using that name within the lease still matched.
   - Fix: bind the nonzero kernel interface index, validate the current name/index on IPC and compare the packet's index. A mismatch discards the binding. Test covers reuse while the old lease is still valid and saved-policy reloads.
   - If skipped: another tunnel can inherit the old interface-name allowance within that window. This is not a measured native leak test; kernel-index/reboot behavior still needs device acceptance.

2. **Cursor could be assigned to the wrong existing project** (`AgentJournalFormats.swift`).
   - What this is: Cursor replaces path separators with hyphens in its project folder names.
   - Problem: both `a-b/work` and `a/b/work` encode identically. The resolver returned the first existing path although its contract required uniqueness.
   - Fix: accept only one match within the bounded search budget. A synthetic filesystem fixture fails before this fix and passes after it.
   - If skipped: a session can display another project's name/path.

3. **Malformed usage numbers could terminate the monitor** (`AgentJournalFormats.swift`).
   - What this is: Claude usage is summed per message and across the scanned session.
   - Problem: positive values fitting Int64 individually can overflow when added. Swift arithmetic traps.
   - Fix: reject overflowing per-message/aggregate usage updates while preserving lifecycle parsing and the prior valid totals. Synthetic records cover both overflow points.
   - If skipped: one malformed local usage record can crash the menu application.

## Should fix — resolved before release

4. **Cursor cold scans read unnecessary old history** (`JournalScanner.swift`).
   - What this is: lifecycle formats search before the tail to recover a turn start.
   - Problem: Cursor has no reverse lifecycle events, so the scanner walked every earlier line without a stopping marker. This grows with transcript size despite the bounded-tail design.
   - Fix: reverse recovery is opt-in for Codex/Claude. A tail-only fixture no longer invokes reverse parsing; before the fix it examined 92 old lines in that small fixture.
   - If skipped: large Cursor transcripts make cold starts and cache resets unnecessarily expensive.

5. **Equal raw IDs across agents shared UI/notification identity** (`Models.swift`, `MonitorStore.swift`, `DashboardView.swift`).
   - What this is: sessions from three sources are merged into one list.
   - Problem: two agents with the same raw session ID reuse the SwiftUI key, previous-state lookup and notification identifier.
   - Fix: use agent-qualified identity consistently for rendering, state comparison and notification IDs; preserve the original raw ID for display/parsing. A model test covers equal raw IDs across all three agents.
   - If skipped: cards or completion notifications can be confused between sources.

Verdict: Ship as an experimental pre-release after automated checks and signed-artifact validation. Do not advertise the VPN as device-validated or leak-free.

Not checked: live filter/provider crashes, replacement gap, reboot/sleep/wake, native interface reuse, end-to-end handoff/recovery and every private agent-journal variant. Those tests would interrupt the user's active connection and remain a separate step.
