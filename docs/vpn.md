# Experimental built-in VPN

**Status: system-extension activation, subscription import and the credential-storage probe have been checked on one Mac. Connection and crash/leak checks remain outstanding.** A successful compile, signature or green unit test is not a protection guarantee.

The requested persistent network lock, which must remain when the VPN is stopped, is not implemented by this candidate. Its contract and outstanding enforcement work are tracked in [network-lock.md](network-lock.md). Do not treat Disable protection or a final disconnected state as locked networking.

The candidate uses pinned XTLS/libXray v26.11.9 inside a macOS packet-tunnel system extension. The menu process is separate: quitting it does not deliberately stop an enabled VPN. No Happ process, private profile or subscription database is read.

## Implemented paths

- HTTPS subscription import, plain/Base64 share-link lists, up to 4 MiB and 200 nodes. Cookies and redirects are not used. Failed imports keep the last saved subscription.
- VLESS TLS/Reality, VMessAEAD and Trojan with compatible TCP/RAW, WebSocket, gRPC or HTTPUpgrade settings. Four fictional native-core fixtures cover VLESS/TLS, Reality/TCP, VMessAEAD/WS and Trojan/TLS.
- Legacy VMess QR JSON, arbitrary Xray JSON, Clash/YAML, XHTTP, FinalMask and advanced chained configurations are **not supported by this first candidate**. Unsupported nodes are omitted; an empty result fails. TLS verification cannot be disabled. Confirm your provider's exported format before depending on import.
- Subscription URL and nodes live in the app's private user Keychain item. Authenticated XPC passes the selected node to the system extension before a VPN configuration is enabled. Both peers require the exact bundle ID and signing team. The extension, rather than the unprivileged menu app, writes to the file-based System Keychain with an access list for its own signed code. The OS VPN profile holds the reference, node hash and validated numeric server IP addresses. A system extension cannot read the user's Data Protection Keychain. [Apple keychain contexts](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
- Full IPv4/IPv6 routes, tunnel DNS, `includeAllNetworks`, enforced routes and a match-all On Demand rule. Additional optional exclusions are disabled. The core gets only the selected proxy outbound, without a `freedom`/direct fallback.
- Provider health through `NETunnelProviderSession`, checked against the selected node and saved policy. Missing, contradictory or stale evidence never turns the shield green.
- A stopped core triggers reassertion and retry with backoff. Wake/default-path changes request a core restart. Failures do not turn off the saved protection request or delete the VPN policy.
- The menu app resolves server addresses with an eight-second deadline before saving/enabling a VPN policy. Failure leaves network settings unchanged; a late DNS result cannot continue setup. The provider validates and uses the saved numeric addresses, with no startup DNS query after `includeAllNetworks` takes effect. Recovery and On Demand reuse these addresses. Server DNS changes require explicitly disabling and enabling protection again in this candidate.
- **Disable protection** is explicit and disables the saved On Demand policy before stopping the connection. Subscription replacement stays disabled while protection is requested. Version 0.3.6 adds a server selector while connected: it prepares the new endpoint, saves its policy and asks the running provider to replace the proxy engine while retaining protection intent. Existing connections can pause or fail; seamless switching and leak behavior require on-device testing. Credentials have separate per-node Keychain accounts, so preparing a new node does not overwrite the active node's referenced credentials.

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

Both profiles must authorize `packet-tunnel-provider-systemextension`. The signing script narrows entitlements, rejects mismatched/expired/development profiles, adds system-extension installation to the host and sandboxes the provider with network access. File-based System Keychain access uses signed-code access lists rather than a Data Protection Keychain sharing entitlement.

Both bundles include `NSSystemExtensionUsageDescription`. Their macOS App Group is `TEAM_ID.dev.vibemonitoring.app`, which is a prefix of the provider's Mach service name. macOS uses the Team-ID-prefixed group for signed app/provider IPC; it is not the user Keychain sharing mechanism.

```sh
python3 scripts/sign-vpn.py \
  --identity 'Developer ID Application: YOUR NAME (TEAM_ID)' \
  --app-profile /path/to/app.provisionprofile \
  --tunnel-profile /path/to/tunnel.provisionprofile
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
