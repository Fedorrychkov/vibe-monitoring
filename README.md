# VibeMonitoring

**Your agents. One glance.**

A native macOS menu bar app for observing local Codex sessions. See recent activity, recorded token usage and quota reports without opening every terminal or chat.

![VibeMonitoring components rendered with fictional demo data](docs/demo-preview.png)

The first release is a **read-only Codex monitor**. VPN protection, subscription imports, Quickping integration and additional agents are planned, not implemented. This version does not block direct network connections or protect against VPN failures.

## What works

- Menu bar indicator with the number of recently observed active turns.
- Session list grouped by project, with active, finished, interrupted and stale states.
- Cumulative input, cached input and output token snapshots from Codex.
- Last reported short and long usage windows, when present in the journals.
- Optional notifications when a turn observed as active finishes.
- Custom Codex home directory, refresh controls and a separate dashboard window.
- A demo mode using fictional data for screenshots and development.

No account, API key, server or third-party Swift package is required.

## Run

Requires macOS 13+ and a Swift 5.9+ toolchain, available with Xcode or Command Line Tools.

```sh
git clone https://github.com/Fedorrychkov/vibe-monitoring.git
cd vibe-monitoring
./scripts/build-app.sh
open dist/VibeMonitoring.app
```

The script builds and ad-hoc signs a local `.app`. It does not install a helper, change login items or modify system networking. Public signed/notarized downloads are not available yet.

To run with fictional demo data:

```sh
open dist/VibeMonitoring.app --args --demo
```

Development and checks:

```sh
swift test
swift run vibe-monitoring-scan --demo
swift run vibe-monitoring-scan
```

The scan command prints aggregate counts only; it does not print project paths, session IDs, prompts or credentials.

## How status is determined

VibeMonitoring reads local JSONL journals under `~/.codex/sessions`, or the configured Codex home. `CODEX_HOME` is used as the initial default when inherited by the process; Settings can override it for apps launched from Finder.

| Display | Evidence |
| --- | --- |
| Active turn | A `task_started` event with no matching completion, and a local event within the last three minutes |
| Turn finished | A matching `task_complete` event |
| Interrupted | A matching `turn_aborted` event |
| Needs attention | An explicit approval, user-input or error event, if the Codex version records one |
| No recent signal | An unfinished turn whose journal stopped emitting events |
| No turn signal | The available tail contains no recognizable turn lifecycle event |

**These are observed journal states, not a process-liveness guarantee.** A crash may leave an unfinished turn behind; long model calls may also stop producing events temporarily. Neither case is automatically declared a failed agent. Not all Codex versions persist approval events, so missing activity is never guessed to mean “waiting for permission.” Cloud-only sessions that do not have local journals are not covered.

The reader examines the 40 most recently modified journal files. On first read it loads at most a 1 MiB metadata prefix and a 2 MiB tail per file, then reads only appended bytes. It handles incomplete lines, truncation and replacement, skips symlinked journals, and bounds individual records. Unknown record types are ignored. Historical turns outside the available tail are not reconstructed.

Codex's journal format is an internal format and can change. The parser supports the `session_meta`, `turn_context`, `event_msg` and `token_usage_record` structures observed in Codex 0.160–0.169 journals. Parser tests use synthetic examples, not exported user sessions.

## Tokens and costs

Token events are **cumulative snapshots**. They are replaced, not summed on every event. Cached input is part of input; reasoning tokens are part of output and are not added a second time.

Counters describe the observed thread, not “today's bill.” The app does not sum parent/subagent counters into a potentially duplicated account total. Quotas are last reported values for the selected session, not a live billing API; expired reports are labeled accordingly.

Dollar costs are intentionally not inferred from a model name or subscription plan. Provider billing and configurable, clearly labeled API-price estimates can be added when there is a reliable source and a defined accounting scope.

## Privacy

- All monitoring runs locally. The app makes no network requests.
- No telemetry, analytics or crash-upload SDK.
- `auth.json`, API keys and subscription links are not read.
- Conversation text, command arguments and tool outputs are not displayed, persisted or uploaded. The JSONL files themselves contain these fields; the parser extracts only the metadata it needs.
- Preferences store the selected Codex directory and the notification toggle in macOS UserDefaults.
- Project folder names appear locally in the UI and, if enabled, finish notifications. Use `--demo` for public screenshots.

## Next modules

1. **Quickping:** read existing service status boards, incidents and latency. Network unavailable must show stale data, not mark every remote service down.
2. **Network protection:** a separately authorized system component, with protected/blocked/unprotected states. Protection must survive GUI and VPN-client crashes. Disabling protection must be an explicit user action.
3. **Connections:** supported subscription formats and VPN-core integration; no assumption that another app's private configuration is an import API.
4. **Other agents:** provider-specific event adapters. Claude Code is a candidate for hooks/OpenTelemetry; unknown processes must not be given invented progress or cost data.

## Contributing

Small changes and synthetic regression tests are welcome. Do not attach real Codex logs, account data, auth files, VPN subscriptions or private project paths to issues or pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md).

MIT licensed. Independent project, not affiliated with OpenAI.
