# Experimental built-in VPN

**Status: experimental 0.3.10 recovery candidate. Earlier builds connected on one Mac but had intermittent HTTPS stalls and a network-recovery failure requiring a reboot. The new recovery path and crash/leak behavior still need device checks.** A successful compile, signature or green unit test is not a protection guarantee.

A separate packet-filter system extension implements the experimental persistent network lock. Its contract, recovery steps and outstanding enforcement checks are in [network-lock.md](network-lock.md). Closing the app preserves protection intent. An explicitly permitted direct-access transition retires our VPN profile and disables our filter.

The candidate uses pinned XTLS/libXray v26.11.9 inside a macOS packet-tunnel system extension. The menu process is separate: quitting it does not deliberately stop an enabled VPN. No Happ process, private profile or subscription database is read.

## Implemented paths

- HTTPS subscription import, plain/Base64 share-link lists, up to 4 MiB and 200 nodes. Cookies and redirects are not used. Failed imports keep the last saved subscription.
- VLESS TLS/Reality, VMessAEAD and Trojan with compatible TCP/RAW, WebSocket, gRPC or HTTPUpgrade settings. Four fictional native-core fixtures cover VLESS/TLS, Reality/TCP, VMessAEAD/WS and Trojan/TLS.
- Legacy VMess QR JSON, arbitrary Xray JSON, Clash/YAML, XHTTP, FinalMask and advanced chained configurations are **not supported by this first candidate**. Unsupported nodes are omitted; an empty result fails. TLS verification cannot be disabled. Confirm your provider's exported format before depending on import.
- Subscription URL and nodes live in the app's private user Keychain item. Authenticated XPC passes the selected node to the system extension before a VPN configuration is enabled. Both peers require the exact bundle ID and signing team. The extension, rather than the unprivileged menu app, writes to the file-based System Keychain with an access list for its own signed code. The OS VPN profile holds the reference, node hash and validated numeric server IP addresses. A system extension cannot read the user's Data Protection Keychain. [Apple keychain contexts](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
- Full IPv4/IPv6 routes, tunnel DNS, `includeAllNetworks`, enforced routes. OS On Demand is disabled to avoid repeatedly replacing a different VPN such as Happ. Additional optional exclusions are disabled. The core gets only the selected proxy outbound, without a `freedom`/direct fallback.
- Provider health through `NETunnelProviderSession`, checked against the selected node and saved policy. Missing, contradictory or stale evidence never turns the shield green.
- A stopped core triggers reassertion and retry with backoff. Wake/default-path changes request a core restart. Failures do not turn off the saved protection request or delete the VPN policy.
- The menu app resolves server addresses with an eight-second deadline before saving/enabling a VPN policy. Failure leaves network settings unchanged; a late DNS result cannot continue setup. The provider validates and uses the saved numeric addresses, with no startup DNS query after `includeAllNetworks` takes effect. Core recovery reuses these addresses. A stopped or crashed tunnel provider leaves the independent lock enabled; reconnect with **Retry VPN + lock**. There is no OS On Demand auto-start. Server DNS changes require explicitly disabling and enabling protection again in this candidate.
- **Allow direct Internet** explicitly disables any legacy On Demand policy, stops and removes only our VPN profile, then disables only our packet filter and verifies the saved OS configuration. **Pause · lock network** establishes the deny policy before stopping the VPN and retains its cached server addresses. Subscription replacement stays disabled while protection is requested. Version 0.3.6 adds a server selector while connected: it prepares the new endpoint, saves its policy and asks the running provider to replace the proxy engine while retaining protection intent. Existing connections can pause or fail; seamless switching and leak behavior require on-device testing. Credentials have separate per-node Keychain accounts, so preparing a new node does not overwrite the active node's referenced credentials.

Version 0.3.6 also adds a single composite menu icon (pulse plus colored status shield), passive interface receive/send rates, and explicit DNS/HTTPS latency checks. Rates are measured from the provider-reported utun interface's byte counters and shown in KiB/s or MiB/s; they are current traffic, not available bandwidth. Checks contact Apple/GitHub via the current connection using unauthenticated HEAD requests, with ephemeral sessions and no redirects. Their elapsed time is not ICMP ping, a throughput benchmark or evidence of leak protection. Tests do not run automatically. The green shield still describes OS/provider state, not guaranteed Internet reachability.

Colors: grey = off/unavailable; amber = connecting; green = OS policy and provider report active; red lock = reasserting with a stopped core; red warning = protection unverified. “VPN active” describes current evidence, not an external connectivity/IP test.

Apple documents `includeAllNetworks` routing and transition behavior, including system traffic exceptions. It is not a promise of managed-device Always On behavior before connection or during boot. Reboot and final-disconnected states require testing; disconnected with a saved protection request is deliberately shown as **unverified**, not “blocked.” [Apple routing documentation](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic).

## Build without installing

Requires the existing Swift/macOS toolchain and Python 3.11+:

```sh
./scripts/build-vpn-app.sh
```

The script verifies a pinned ~98 MiB release archive and per-file hashes, retains only the ~75 MiB universal macOS library, builds the app/provider and runs fictional conversion/constructor checks. Constructor checks remove TUN/env before calling upstream `testXray`; that upstream API is not a general sandbox. No live tunnel or network probe is started by these checks.

Output: `dist/VibeMonitoring-VPN.app`, ad-hoc signed. It can preview the UI/import path, but network installation/enablement is gated. It is separate from `dist/VibeMonitoring.app`. No Go toolchain, extra simulator runtimes or source build of all platforms is needed.

## Signing and activation

For direct macOS distribution Apple requires a packet-tunnel **system extension**, not the App Store-only app-extension packaging. The app and system extension need matching signing teams. [Apple deployment requirements](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

Prepare a Developer ID Application identity and Developer ID provisioning profiles for:

- `dev.vibemonitoring.app`
- `dev.vibemonitoring.app.tunnel`
- `dev.vibemonitoring.app.lock` (0.3.7 candidate)

The host profile must authorize both `packet-tunnel-provider-systemextension` and `content-filter-provider-systemextension`. The tunnel profile needs the former, and the lock profile needs the latter. The signing script narrows entitlements, rejects mismatched/expired/development profiles, adds system-extension installation to the host and sandboxes the provider with network access. File-based System Keychain access uses signed-code access lists rather than a Data Protection Keychain sharing entitlement.

Both bundles include `NSSystemExtensionUsageDescription`. Their macOS App Group is `TEAM_ID.dev.vibemonitoring.app`, which is a prefix of the provider's Mach service name. macOS uses the Team-ID-prefixed group for signed app/provider IPC; it is not the user Keychain sharing mechanism.

```sh
python3 scripts/sign-vpn.py \
  --identity 'Developer ID Application: YOUR NAME (TEAM_ID)' \
  --app-profile /path/to/app.provisionprofile \
  --tunnel-profile /path/to/tunnel.provisionprofile \
  --lock-profile /path/to/lock.provisionprofile
```

This only signs the candidate. Complete notarization and the third-party dependency-notice review before distributing a VPN binary. Move the properly signed app to `/Applications`, then use its explicit **Install network component** action and approve macOS's request. No scripts here install profiles, register Apple IDs, create certificates, disable system protections or connect automatically.

An older installed provider is not treated as ready for a newer app; install the matching component before enabling protection. To check the credential path without creating a VPN configuration or starting a tunnel:

```sh
/Applications/VibeMonitoring.app/Contents/MacOS/VibeMonitoring --check-vpn-storage
```

The check uses the same authenticated XPC and storage code to create, update, read and delete a separate non-secret probe item, verifying that its persistent reference survives the update. Existing credentials are updated without changing their signed-code access list; replacing that list can require authorization UI unavailable to a system extension. The check does not read or change the selected server, subscription or any VPN's network configuration. Only the correctly signed app can call this service; a regular unsigned CLI process cannot write System Keychain data through it.

The listener starts after `NEProvider.startSystemExtensionMode()`, using the Network Extension's App Group-prefixed Mach service, as in [Apple's Network Extension sample](https://developer.apple.com/documentation/networkextension/filtering-network-traffic). Both listener and client additionally apply explicit peer code-signing requirements.

The Mach service name ends in the numeric build number. This avoids a stale service registration after system-extension replacement, tracked by Apple as FB17032197; see [Apple's upgrade discussion](https://developer.apple.com/forums/thread/779395). Signing validates matching app/provider build numbers and writes the resolved service name into the provider plist.

On-device check, 2026-11-20, version 0.3.2 (7): the signed app's create/read/delete probe passed; a separate unsigned client was rejected with XPC error 4097. The probe item was absent afterward. A subsequent user connection attempt created the VPN configuration but did not establish a working tunnel; a repeated enable failed with credential write error -25308. Version 0.3.3 adds the missing update check and preserves existing ACLs. Tunnel startup failures record only a fixed stage and numeric code, not server details or credentials. Connectivity and leak protection remain unverified.

Version 0.3.4 (9) passed repeated create/update/read/delete probes after extension replacement, and rejected an unsigned client. A later live connection attempt failed during server DNS resolution after 30 seconds. Version 0.3.5 moves that lookup before policy activation, bounds its wait and passes validated numeric addresses to the provider. No working live tunnel or leak protection has been confirmed yet.

## GitHub release packaging

Distribution is through GitHub Releases, with public source in the same repository. No App Store submission is planned. Developer ID signing and Apple notarization also apply to this distribution route.

After signing and the acceptance checks below, use an existing `notarytool` Keychain credential profile:

```sh
bash scripts/release-dmg.sh \
  "$PWD/dist/VibeMonitoring-VPN.app" \
  'Developer ID Application: YOUR NAME (TEAM_ID)' \
  YOUR_NOTARY_KEYCHAIN_PROFILE
```

The script rejects ad-hoc/non-hardened builds, packages the app and an Applications shortcut, signs the DMG, submits it to Apple for notarization, staples and validates the ticket, and writes a SHA-256 checksum. It does not publish to GitHub or install the app. The filename records the architectures actually present; a native build is not advertised as universal. Signing keys and notarization credentials must stay outside the public repository. An App Store Connect API key is optional for notarization, not required; `notarytool` also supports Apple ID authentication with an app-specific password stored in Keychain.

## Required on-device acceptance checks

Use a controlled HTTPS echo endpoint and packet capture to record pass/fail. Do not use a sensitive service account as a leak test.

1. Confirm endpoint reachability and VPN egress for IPv4/IPv6; check DNS packets on the physical interface. UI green and a synthetic TUN ping are insufficient evidence.
2. Keep new and established TCP/UDP traffic active while force-quitting the **menu app**. The VPN must continue, with no direct fallback.
3. Force-terminate the specific tunnel-provider process. Confirm OS policy remains enforced during termination/relaunch; inspect physical-interface capture for direct traffic. The UI must not stay green on missing health reports.
4. Simulate unreachable VPN endpoints and core startup failure. Confirm backoff, retained protection intent and no direct fallback. Verify that explicit Disable restores ordinary networking.
5. Test Wi-Fi changes, Wi-Fi off/on, sleep/wake and actual reboot. Record the interval before the VPN starts and any final-disconnected state. A boot/startup gap is a release blocker for claiming continuous protection.
6. Deny extension approval, lock Keychain, revoke/mismatch profiles and modify the saved policy. Confirm a clear unverified/off state and no fabricated green status.
7. Repeat with real supported provider exports and server changes. Confirm credentials/subscription URLs never appear in logs, screenshots, notifications or crash reports.

These leak checks remain outstanding. Builds and the storage probe do not change VPN connection settings.

## 0.3.7 network lock candidate

The source candidate includes a separate packet-filter system extension, `VibeLock`. Its lifetime and saved policy are independent of the packet tunnel. **Pause** installs a deny policy before stopping VPN; **Allow direct Internet** explicitly installs an allow policy and requires a matching acknowledgement. The filter stays enabled in direct mode. Neither closing the UI nor a failed connection requests an unlock. See [the network-lock contract and device acceptance tests](network-lock.md).

This is experimental: actual crash/startup/replacement behavior has not been verified. An active filter report is evidence of the loaded rules, not proof that macOS never bypassed the filter. Do not distribute it as a guaranteed persistent kill switch before device tests pass.

The expandable protection card contains component updates, connect/retry, locked pause, explicit direct access, server selection, manual TCP handshakes and external browser-check links. TCP handshakes use the current network. The local TUN can acknowledge TCP before opening the upstream connection, so a low value is not remote-node reachability or latency, even through our own VPN. These probes never verify proxy authentication. Server selection prepares credentials/DNS, restricts outer traffic to the new endpoint and instructs the running engine to switch. It does not disable the network lock or silently allow direct traffic. Existing connections can fail during switching; shared upstream exit addresses can keep the same visible IP.

HTTPS diagnostics now expose DNS/connect/TLS/response timing where URLSession provides it and distinguish fixed error categories without recording URLs, headers or credentials. Provider diagnostics count engine starts and actual path changes since provider launch; equal KVO path notifications no longer restart the engine. The counters help distinguish restart churn from connection failures, but a throughput or timeout fix is not yet established.

For a small reproducible A/B sample, manually select a client and the same subscription node, then run:

```sh
python3 scripts/diagnose-vpn.py --label Happ --rounds 3 > /tmp/happ-network.json
# Switch clients yourself during an approved test window, then:
python3 scripts/diagnose-vpn.py --label VibeMonitoring --rounds 3 > /tmp/vibe-network.json
```

The script performs bounded, unauthenticated HEAD requests to Apple and GitHub over IPv4/IPv6. It never switches a VPN, changes a proxy or route, records an exit IP, follows redirects or writes network settings. The label is supplied by the operator; it does not detect the active client. Raw curl errors are omitted. Keep reports local until reviewed.

Diagnostic follow-up on 0.3.7: the selected NL node showed one engine start and no path changes in the user's screenshot. Twelve short HEAD probes produced ten successful responses and two five-second pre-HTTP timeouts. This does not establish where the tunnel's upstream connection stalled. In particular, a local TCP SYN-ACK is not proof that the remote proxy or target finished connecting. IPv6-flagged curl requests can use IPv4-mapped destinations; the diagnostic script now reports the effective address family without recording target addresses. A current controlled Happ comparison on the same node is still needed; do not change the active connection automatically to obtain it.

## 0.3.8 resolver correction and read-only diagnostics

On the tested NL node, repeated DNS queries to `2606:4700:4700::1111` timed out over UDP and failed to produce a DNS reply over TCP. An independent DNS client reproduced this result. Both IPv4 resolvers, `1.1.1.1` and `1.0.0.1`, answered; AAAA lookups over IPv4 also worked. A native IPv6 HTTPS request succeeded, so IPv6 traffic itself was not disabled as a workaround.

The candidate uses the two tested IPv4 resolver addresses for tunnel DNS. IPv4/IPv6 default routes, the existing MTU, include-all protection and packet-filter policy remain unchanged. This removes an unreachable configured resolver; it does not prove every pre-HTTP timeout was caused by DNS. The default resolver transport assumes the selected proxy has IPv4 egress. IPv6-only proxy exits without IPv4 translation need a separate resolver configuration and are not covered by this correction. See [Cloudflare's resolver address list](https://developers.cloudflare.com/1.1.1.1/ip-addresses/).

56 Swift tests and 7 script tests passed. The routing regression test verifies that the DNS transport change retains both IPv4 and IPv6 default capture without adding excluded routes. No live configuration is changed by a build or test.

The next signed build also supports `--vpn-diagnostics`. It reads our saved VPN/lock status and an allowlisted summary of transport options; it does not save preferences, activate components, store credentials or connect a tunnel. Hosts, node names, subscription URLs, credentials and raw node configurations are omitted. `--network-check` additionally sends the same fixed, unauthenticated Apple/GitHub HEAD checks through the current OS network policy.

```sh
/path/to/updated-signed/VibeMonitoring.app/Contents/MacOS/VibeMonitoring --vpn-diagnostics
/path/to/updated-signed/VibeMonitoring.app/Contents/MacOS/VibeMonitoring --vpn-diagnostics --network-check
```

The installed 0.3.7 predates these flags: do not use these commands with that binary. A temporary signed diagnostic bundle was tested without installation. A transient missing provider-message reply is reported as unavailable without discarding other diagnostics. The utility never changes the active VPN/filter to obtain a report.

On-device boot, component-crash/replacement leak tests, and the post-correction latency comparison still require a separately approved test window. No continuous-kill-switch or fully resolved-timeout claim is made.

After manual installation of both 0.3.8 components, read-only checks confirmed matching build 13, VPN disabled with On Demand off, and a valid filter in `directAllowed` mode without a bound tunnel. With Happ active, the signed 0.3.8 diagnostic returned Apple HTTP 200 in 327 ms and GitHub HTTP 200 in 460 ms. This verifies component registration/status IPC and current-network checks, not the DNS correction under our tunnel. No VPN or deny policy was enabled for this check.

The next source revision labels the connection duration **Connect incl. TLS** when TLS metrics are present: [Apple's `connectEndDate`](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/connectenddate) includes security handshakes. The separate TLS value is part of that duration and must not be added to it. This changes diagnostic wording only; the installed 0.3.8 remains unchanged.

### Live 0.3.8 follow-up

After the user manually connected our VPN, system resolver records showed `1.1.1.1` and `1.0.0.1` on the tunnel interface. The lock reported a valid protected policy with a bound tunnel; a subsequent provider status reported one engine start, zero path changes, running and not reasserting. The first diagnostic invocation missed a provider reply, so a single unavailable reply must not be treated as a proven core restart.

The signed app's fresh-process checks passed Apple HTTP 200 in 403 ms and GitHub HTTP 200 in 343 ms. The user also confirmed that both checks passed in the existing GUI. A five-round curl sample returned 18 of 20 successful HEAD responses; Apple and GitHub each had one five-second pre-TLS-completion timeout. Successful response medians were 323 ms for Apple and 347 ms for GitHub.

An additional IPv4/HTTP 1.1 sample used `curl --resolve` with valid TLS verification and pre-resolved addresses, preserving hostnames for TLS and HTTP. Fifteen of sixteen requests passed, with another five-second timeout and negligible DNS time. Eight further pre-resolved requests using a ten-second connection deadline all passed in 303–348 ms; this small sample does not establish that increasing deadlines fixes the intermittent failure. Across the three curl samples, three of forty-four requests timed out. These are bounded samples rather than a measured long-term failure rate, and a local TUN TCP acknowledgement does not prove the remote proxy connection completed.

For DNS, nineteen of twenty-four direct queries (A, AAAA and HTTPS records; both resolvers; UDP and TCP) received NOERROR within a two-second deadline. Successful query times were 227–359 ms. Five queries did not receive a reply by that deadline. An independent raw DNS client then received eight of eight valid A replies over UDP/TCP in 232–250 ms with a six-second deadline. The resolvers are reachable, but intermittent stalls remain and are not confined to DNS or HTTP/2.

No VPN/filter settings, server, route, MTU or DNS configuration was changed during these checks, and no process was restarted. The remaining stall cannot yet be attributed specifically to the native TUN stack, proxy handshake, filter or upstream server. Further isolation must preserve the user's active connection and require a separately approved window for disruptive comparisons.

### Matched Happ comparison and 0.3.9 candidate

After a later user-controlled switch to the same NL node in Happ, per-process socket observations confirmed the same physical VPN endpoint and Wi-Fi interface. Median outer TCP RTT was about 39–40 ms for both clients; a different resolved gateway did not explain this comparison. Loopback sockets used internally by Happ were excluded from the gateway comparison.

Happ passed ten of ten IPv4 curl checks, five IPv4-mapped checks and all thirty-two additional pre-resolved HTTP/1.1 probes, including alternating serial/parallel pairs. Five forced-native-IPv6 Apple checks failed immediately because IPv6 connectivity was unavailable in that configuration; these were not five-second stalls. Both configured public IPv4 DNS resolvers answered all twenty-four identical UDP/TCP queries with a 245 ms median and 528 ms maximum. The signed application's Apple/GitHub checks returned HTTP 200 in 326/427 ms. The OS-configured DNS server was the LAN router, unlike our explicit tunnel resolvers; no packet capture was performed to infer actual DNS privacy from that setting alone.

The preceding late-session tests on our VPN also stopped reproducing the stall: 155 successful HEAD requests across the ordinary curl, system-libcurl and OpenSSL probes, including serial/parallel pairs and a short bounded watch. The initial suspicion of concurrency was therefore not confirmed. These separated samples cannot establish a permanent failure-rate difference or isolate all intermittent behavior.

Version 0.3.9 corrects a separately reproduced lock-policy reload defect, described in [the network-lock notes](network-lock.md#repeated-policy-load-correction-039). It also clarifies that diagnostic connection time includes TLS. Fifty-nine Swift tests passed. The new lock counter is intended to check whether the corrected reload path occurs during a later approved on-device run; the fix must not be advertised as a proven explanation for every observed timeout. Preparing a signed candidate does not install it, enable either component or change the active Happ connection.


### Network recovery and other VPNs (0.3.10)

The new direct-access transition disables legacy auto-start, stops and removes our VPN profile (including its `includeAllNetworks` configuration), then saves our filter as disabled and reads it back. It does not depend on a reply from a potentially unresponsive packet-filter process to remove that filter. Subscription and per-node credentials remain in Keychain. A later explicit Connect recreates the VPN profile and enables the independent filter.

New connections do not install OS On Demand rules. The provider's internal core watchdog still retries while the provider is running. If the provider stops or crashes, the independent lock remains enabled; the user reconnects explicitly. This prevents our stopped tunnel from repeatedly superseding Happ. Another VPN cannot bypass the lock implicitly: choose **Allow direct Internet** first, wait for confirmation, and then connect the other VPN. The transition touches only our profiles.

A failed tunnel retirement or filter save/readback is reported as unverified; the UI does not claim recovery succeeded. Pause still establishes a deny policy before stopping the tunnel. Status text no longer equates every unavailable provider-health reply with a proven traffic block. Privacy-preserving lifecycle logs record start/stop and transition stages without node names, addresses or credentials.

Unit tests cover transition order and failures. Compile, signing and notarization do not prove that this resolves the device's previous network stall, TLS timeouts, or all crash/reboot leak cases. Those remain explicit acceptance checks before promoting the candidate to a stable release. See [release downloads and source builds](releases.md).
