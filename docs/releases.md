# Downloads and source builds

Release files live on [GitHub Releases](https://github.com/Fedorrychkov/vibe-monitoring/releases). A release has a version tag, the matching source archives, a signed/notarized DMG and a SHA-256 checksum. Experimental builds are marked **Pre-release**. Drafts are visible only to repository maintainers until published.

## Install a downloaded build

The current binary architecture is **Apple silicon (arm64)**, requiring macOS 13 or later. Intel binaries are not supplied by this candidate.

1. Read the release notes and download its `.dmg` and `.dmg.sha256` files. Compare `shasum -a 256 VibeMonitoring-VERSION-arm64.dmg` with the checksum file.
2. Open the DMG and drag **VibeMonitoring.app** to **Applications**. Downloads do not require Xcode or a Developer account.
3. Launch the app. Codex, Claude Code and Cursor monitoring work without VPN installation. VPN and Network Lock components require separate explicit installation and macOS approval in the app's Protection controls.

Before replacing an existing experimental VPN build, choose **Allow direct Internet** and verify that your network works through your chosen connection. Wait for the app to finish before enabling Happ or another VPN. Updating the app/components can interrupt an active tunnel; do not update while relying on it.

**0.3.12 is an experimental candidate.** It adds agent worktrees, recovery branches before pruning unreferenced worktree commits, Codex usage reports and an optional Claude Code status line bridge. Cursor usage remains unavailable without reading its sign-in token, which the app does not do. The VPN/lock implementation is unchanged from 0.3.11; bundle versions advance to build 17 for distribution. Earlier versions experienced intermittent TLS stalls and a recovery failure requiring a reboot. Crash, handoff and explicit filter disablement still need device validation. Signing/notarization does not certify VPN privacy, absence of leaks or successful recovery.

## Build the monitoring app yourself

Install Xcode or Command Line Tools providing Swift 5.9+, then check out the release's exact tag:

```sh
git clone https://github.com/Fedorrychkov/vibe-monitoring.git
cd vibe-monitoring
git checkout v0.3.12
swift test
bash scripts/build-app.sh
open dist/VibeMonitoring.app
```

This creates a local ad-hoc-signed monitoring app; it does not install system extensions or change networking. GitHub's **Source code (zip/tar.gz)** downloads contain the same tagged source. Run the build scripts from the extracted source root if using an archive.

## Build the optional VPN candidate

```sh
python3 -m unittest discover -s Tests/BuildScriptsTests -v
bash scripts/build-vpn-app.sh
```

The script downloads and verifies the pinned libXray library and builds a local candidate with fictional configuration checks. It does not start a tunnel. Ad-hoc system extensions cannot be installed as a supported VPN build. Direct distribution requires an Apple Developer team, Developer ID certificate, and matching Network Extension provisioning profiles for the app, tunnel and filter. The repository's bundle IDs are fixed: another signing team needs to update the IDs consistently in source, bundle-generation/signing scripts and provisioning. This is an advanced development step, not a certificate bypass.

See [VPN building/signing](vpn.md) and [network-lock guarantees and outstanding tests](network-lock.md). Private keys, provisioning profiles, subscription links and diagnostic captures are not distributed with the source.
