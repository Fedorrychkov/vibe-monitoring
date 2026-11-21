# Persistent network lock: required behavior

Status: experimental 0.3.10 candidate. The previous 0.3.9 device test exposed a recovery failure requiring a reboot. New recovery behavior is tested in code and must still be checked on device before a stable release.

## User contract

| Intent | VPN | Ordinary direct Internet |
| --- | --- | --- |
| Protected | Connecting, connected or recovering | Blocked |
| Paused, locked | Stopped intentionally | Blocked |
| Direct access explicitly allowed | Optional / stopped | Allowed |

Only an explicit Allow direct Internet action, or an explicitly labeled Quit and allow direct Internet action, may enter the last state. Closing a popover/window, losing UI heartbeat, process termination, VPN disablement in macOS Settings, failed endpoint preparation and failed server changes are not permission to unlock. The lock intent must survive menu-process crashes and relaunches.

Quitting just the monitoring UI is distinct from unlocking. An unlock action must receive an OS acknowledgement that our VPN profile has been removed and our filter is disabled before the UI claims direct Internet is allowed. Protected/paused policies still require a matching enforcing-component acknowledgement. Failed or missing acknowledgments leave the state unverified, with no automatic fallback to direct access.

## Enforcement direction and unresolved guarantees

An independent Network Extension packet filter is the candidate enforcement layer. While protection or locked pause is requested, it must remain enabled independently of the packet-tunnel manager. An explicit direct-access action disables this filter instead of leaving an allow-all filter in the packet path. A packet handler can inspect interface/direction and decide allow/drop; a system-managed filter policy must cover traffic sent over physical interfaces while the tunnel is missing. VPN endpoint/bootstrap traffic and essential link maintenance require narrowly defined exceptions. Permitting all traffic from the menu process, an arbitrary utun interface, or an arbitrary DNS server is not an acceptable shortcut.

The candidate implements persisted rules, signed IPC and separate provisioning. Behavior if the filter itself crashes still requires on-device validation. A filter API being available is not evidence of fail-closed behavior during its replacement, OS startup, crash or removal. Do not claim a literal all-packets guarantee: bootstrap/link maintenance and Apple platform exceptions must be documented precisely.

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

## Candidate behavior and limits

The filter parses Ethernet headers and up to two VLAN tags before validating IPv4/IPv6. It allows loopback, narrowly formed ARP, DHCP, IPv6 neighbor/router discovery and incoming ICMP errors quoting TCP traffic to the selected VPN endpoint (including PMTU errors). Protected mode also allows TCP to the selected numeric server addresses and the interface bound by the authenticated tunnel provider. Other physical-interface DNS, QUIC, ordinary TCP/UDP and unparsed fragments/extension headers are dropped. These exceptions mean this is not literal silence on every interface or containment of malicious local processes.

The live interface binding is not trusted from disk on startup. The signed provider must bind its interface to the selected node again. A policy update can retain an already-live interface during server replacement. The application prepares endpoint addresses and credentials first, then changes the allowed endpoint without an intermediate direct mode. If preparation fails, it keeps the old mode. A failed uncommitted VPN-profile update attempts to restore only the previous protected policy; it never rolls back to direct access automatically. Missing acknowledgement is displayed as unverified, with a retry action.

Paused mode has no public DNS exception. Reconnecting the cached server uses saved numeric addresses. Resolving a new uncached server while paused requires explicitly permitting Internet first; the app does not open a temporary DNS escape hatch.

The app observes open browser/IDE/terminal apps and local active Codex turns for network-change warnings. This is not a complete process/network inventory. Component installation does not itself activate the lock. Initial activation is an explicit Connect VPN + lock or Pause + lock action and needs macOS filter approval.

## Recovery

Use **Retry VPN + lock** to restore a protected connection. Use **Allow direct Internet** only when intending to permit an exposed connection (another VPN may still carry traffic). **Quit and allow direct Internet** waits for the same OS configuration acknowledgements. Our VPN profile is removed before our filter is disabled; no other VPN or filter configuration is changed. Ordinary Quit/window closure preserves the current network mode.

If the enforcing component cannot acknowledge a mode change, open macOS System Settings → Network → VPN & Filters (labels vary by macOS version), locate **VibeMonitoring Network Lock** and explicitly disable that filter to restore direct networking. This is a deliberate emergency unlock, not a leak-safe repair. The application links to network settings and never disables other VPNs or filters as a recovery shortcut.

## Development validation

54 Swift tests and 6 build/diagnostic script tests passed locally. They cover endpoint/protocol restrictions, Ethernet/VLAN/ARP, IPv4/IPv6 malformed data, DHCP/discovery and PMTU exceptions, revision acknowledgements, restart binding, locked pause, server transition, a local TCP listener and diagnostics failure classification. Release targets compile without activating any extension. A matching Developer ID lock profile was created in the personal signing team. These checks are not on-device enforcement, throughput or leak tests.

Intermittent HTTPS establishment stalls were observed in the earlier tunnel; their root cause has not been established. The candidate skips identical path notifications and adds engine-start/path-change counters and phased HTTPS timing. No claim of a measured kill-switch delay or resolved throughput problem is made.

The required device tests above remain outstanding. The user requires a complete stop and explicit permission before installing the next build. Preserve the current external VPN connection.

## Repeated policy-load correction (0.3.9)

A deterministic regression test exposed a runtime binding loss: the saved protected policy can omit an interface, while authenticated IPC has bound its live instance to a tunnel. Reapplying that exact saved policy compared its missing interface against the live name and discarded the binding. Packet filtering then denied tunnel packets until a later authenticated bind. The provider normally attempts that bind every two seconds. This is an interruption of protected traffic, not a fallback to direct access.

The runtime now retains an existing authenticated binding on an active, unchanged protected policy reload only when its revision, node and endpoints match. A restart, inactive filter, changed revision/node/endpoints or a different requested interface cannot reuse that implicit binding. The existing explicit live-interface transition for server switching remains supported. No saved interface is trusted on startup. Tests reproduce the original failure and cover the rejection cases.

The read-only diagnostic reports `preservedLockPolicyReloads`, a process-lifetime count of identical unbound-policy reloads that retained a live binding. It records no packet content or endpoint addresses. A nonzero count after a device test can establish that the corrected reload path occurred. This code defect is verified in a pure regression test; its contribution to the previously observed HTTPS timeouts has not yet been demonstrated on the device. Crash, reboot and replacement leak checks remain outstanding.


## Explicit recovery and coexistence (0.3.10)

- **Allow direct Internet**: disable legacy On Demand; stop/remove our VPN profile; disable our filter and read back the saved disabled policy. This can recover even when our filter's status IPC is unavailable. No automatic unlock is triggered by a timeout, app exit, another VPN starting, or tunnel crash.
- **Pause**: acknowledge a deny policy, then disable/stop our tunnel, retaining its cached endpoint configuration.
- **Connect/Retry**: explicitly enable our independent filter and tunnel. Do not install OS On Demand rules: automatic restarting of our whole tunnel would supersede Happ. The provider's existing core watchdog continues recovering a stopped core while that provider is alive. Whole-provider crashes leave the lock requested and require explicit Retry.
- The UI confirms saved OS removal/disablement; this is not a claim that every existing socket was repaired. An unavailable or failed acknowledgement remains unverified.

Required device acceptance: protected → direct → Happ; paused → retry; direct recovery with unavailable provider IPC; direct recovery after a failed connection; app close/relaunch and reboot. No device test was run while preparing this candidate because the user's current Happ connection must remain untouched.
