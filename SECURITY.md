# Security

This release monitors Codex locally and optionally reads Quickping monitoring through a scoped connection. It does not provide a firewall, VPN or kill switch.

Please do not post secrets, VPN subscriptions, real journals or account data in public issues. Use private vulnerability reporting on the repository when enabled. If no private contact is available, open an issue asking for a private reporting channel without including the vulnerability details or sensitive data.

The application reads recent Codex journal metadata. It does not read `auth.json`, run tools from session content or change system network configuration. Optional Quickping authorization uses the system browser with PKCE S256 and per-attempt state. API traffic is limited to the selected server; tokens are stored in macOS Keychain, not UserDefaults or logs. No Codex journal data is sent to Quickping.
