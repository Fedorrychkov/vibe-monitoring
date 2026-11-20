# Persistent network lock: required behavior

Status: design and acceptance criteria only. Not implemented or enabled in 0.3.6. The current explicit Disable protection action permits ordinary networking. A disconnected VPN must not be presented as a persistent network lock.

## User contract

| Intent | VPN | Ordinary direct Internet |
| --- | --- | --- |
| Protected | Connecting, connected or recovering | Blocked |
| Paused, locked | Stopped intentionally | Blocked |
| Direct access explicitly allowed | Optional / stopped | Allowed |

Only an explicit Allow direct Internet action, or an explicitly labeled Quit and allow direct Internet action, may enter the last state. Closing a popover/window, losing UI heartbeat, process termination, VPN disablement in macOS Settings, failed endpoint preparation and failed server changes are not permission to unlock. The lock intent must survive menu-process crashes and relaunches.

Quitting just the monitoring UI is distinct from unlocking. An unlock action must receive confirmation from the enforcing component before the UI claims direct Internet is allowed. Failed or missing acknowledgments leave the state unverified, with no automatic fallback to direct access.

## Enforcement direction and unresolved guarantees

An independent Network Extension packet filter is the candidate enforcement layer. It must remain enabled independently of the packet-tunnel manager. A packet handler can inspect interface/direction and decide allow/drop; a system-managed filter policy must cover traffic sent over physical interfaces while the tunnel is missing. VPN endpoint/bootstrap traffic and essential link maintenance require narrowly defined exceptions. Permitting all traffic from the menu process, an arbitrary utun interface, or an arbitrary DNS server is not an acceptable shortcut.

The concrete filtering policy, persistence mechanism, signing/provisioning changes and behavior if the filter itself crashes still require implementation and validation. A filter API being available is not evidence of fail-closed behavior during its replacement, OS startup, crash or removal. Do not claim a literal all-packets guarantee: bootstrap/link maintenance and Apple platform exceptions must be documented precisely.

Use supported Network Extension APIs. Do not change PF rules or system-wide network configuration as an unreviewed fallback. Existing VPN profiles and firewall rules must not be modified as part of a diagnostic.

## Required on-device checks before enabling or distributing

- Capture physical-interface traffic while exercising established and new IPv4/IPv6 TCP, UDP, DNS and QUIC traffic to controlled endpoints.
- Stop the core, kill the tunnel process, disable only the VPN in Settings, and change server. Confirm the independent lock remains and no ordinary direct connection is possible.
- Kill the menu app; separately crash/relaunch the filter. A filter crash that permits direct traffic is a release blocker for this contract.
- Test locked pause, sleep/wake, network changes, actual reboot, extension replacement and denied system approval. Record any startup or replacement gap.
- Verify explicit unlock and Quit and allow direct Internet restore networking. Verify popover/window closure does not unlock it. Provide a documented local recovery route for an unavailable enforcing component.

No installation, permission changes, firewall configuration or connection changes are performed by this document. Activation and disruptive acceptance tests require a separate user-approved window.

## Platform references

- [Apple: routing VPN traffic and system exceptions](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic)
- [Apple: NEFilterPacketProvider](https://developer.apple.com/documentation/networkextension/nefilterpacketprovider)
- [Apple TN3165: Packet Filter is not API](https://developer.apple.com/documentation/technotes/tn3165-packet-filter-is-not-api)
