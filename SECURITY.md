# Security

This release is a read-only local monitor. It does not provide a firewall, VPN or kill switch.

Please do not post secrets, VPN subscriptions, real journals or account data in public issues. Use private vulnerability reporting on the repository when enabled. If no private contact is available, open an issue asking for a private reporting channel without including the vulnerability details or sensitive data.

The application reads recent Codex journal metadata. It does not read `auth.json`, run tools from session content, send requests on the user's behalf or change system network configuration.
