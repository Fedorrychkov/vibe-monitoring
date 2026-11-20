# Security

The normal build monitors Codex locally and optionally reads Quickping monitoring through a scoped connection. It does not install network protection. A separate experimental VPN candidate is present in source; it is not approved for relying on leak prevention until the on-device tests in [docs/vpn.md](docs/vpn.md) pass.

Please do not post secrets, VPN subscriptions, real journals or account data in public issues. Use private vulnerability reporting on the repository when enabled. If no private contact is available, open an issue asking for a private reporting channel without including the vulnerability details or sensitive data.

The application reads recent Codex journal metadata. It does not read `auth.json` or run tools from session content. Quickping authorization uses the system browser with PKCE S256 and per-attempt state. API traffic is limited to the selected server; tokens are stored in macOS Keychain, not UserDefaults or logs. No Codex journal data is sent to Quickping.

VPN installation and enablement require explicit UI actions in a correctly signed/provisioned build. The candidate never edits PF rules, changes SIP/developer mode or disables TLS verification. It imports supported share links, not arbitrary executable scripts or full Xray configurations. Subscription failures preserve previous settings. Missing provider evidence is shown as unverified rather than green.

The credential service accepts XPC connections only from the exact signed app ID/team; the client also pins the provider ID/team. It exposes only bounded selected-node storage and a separate non-secret storage probe, with no caller-controlled file paths or Keychain service names. Preparation finishes before enabling the VPN configuration. Credential errors contain a fixed operation name and numeric status, not the submitted data.
