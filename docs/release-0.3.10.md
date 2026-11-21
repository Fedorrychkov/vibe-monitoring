# 0.3.10 — experimental network recovery candidate

This pre-release changes explicit network recovery after a failed VPN connection and handoff to Happ or another VPN.

- **Allow direct Internet** disables legacy auto-start, stops and removes only VibeMonitoring's VPN profile, then disables its packet filter and verifies the saved OS configuration. Your subscription stays in Keychain. The action no longer requires a responsive filter-status IPC channel to disable that filter.
- New VPN connections do not install OS On Demand rules, preventing our tunnel from repeatedly replacing Happ. If the whole VPN provider stops, the independent lock remains enabled and you reconnect with **Retry VPN + lock**. Core recovery within a running provider remains automatic.
- Locked pause still acknowledges the deny policy before stopping the VPN. An unsuccessful recovery remains unverified. Provider-health failures no longer imply that Internet blocking was independently verified.
- Protection controls include handoff instructions, passive traffic rates, manual TCP/DNS/HTTPS checks and external IP/service-check links. Unsupported subscription transports remain omitted.

## Validation and limits

Automated tests and release compilation cover transition ordering/failures, lock rules, credentials/signing checks and fictional native-core configurations. The DMG is Developer ID signed and notarized. No live VPN/filter activation is performed by those checks.

**Device validation of the new recovery path is still pending.** Earlier builds had intermittent HTTPS/TLS stalls and a network recovery failure requiring a reboot. This release must not be described as a verified fix for all timeouts, leak-free, or a production-grade kill switch. Do not depend on it for privacy-critical traffic.

## Download / source

Apple silicon (arm64), macOS 13+. Open the DMG and drag the app to Applications. Component installation and network protection remain explicit actions after launch. Before updating an existing VPN build, permit direct Internet explicitly and move to a working external connection.

The `.dmg.sha256` file contains the checksum. GitHub's source archives match the `v0.3.10` tag. See [installation and self-build instructions](https://github.com/Fedorrychkov/vibe-monitoring/blob/v0.3.10/docs/releases.md). Intel binaries are not included.
