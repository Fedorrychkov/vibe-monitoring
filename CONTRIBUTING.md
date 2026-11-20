# Contributing

Build and run `swift test` before submitting a change. Keep the core reader independent of SwiftUI so event parsing and file handling can be tested without launching an app or using an account.

For parser bugs, provide a minimal **synthetic** JSONL record with invented IDs, paths, text and numbers. State the Codex version and the expected observed state. Do not upload an actual session, even if only the visible prompt has been removed: records can contain account identifiers, command outputs, images and credentials embedded in tool results.

Preserve these behaviors:

- Reading sessions must never write to the Codex directory or launch/resume/stop an agent.
- A missing event is unknown information, not proof of success, failure or a request for approval.
- Repeated cumulative token snapshots must not increase a total.
- Output and cached-input subcategories must not be counted twice.
- A provider estimate is not an invoice or a subscription balance.
- Future network protection must be independently testable and must never silently fall back to direct connectivity.

Use demo data for screenshots. New dependencies need a concrete reason; the initial app uses only system frameworks.
