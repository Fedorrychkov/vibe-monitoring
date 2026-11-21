import AppKit
import SwiftUI
import VibeMonitoringCore

extension VPNProtectionState {
    var title: String {
        switch self {
        case .unavailable: return "VPN not configured"
        case .off: return "Protection off"
        case .connecting: return "VPN connecting"
        case .connected: return "VPN active"
        case .blocked: return "VPN recovering · traffic blocked"
        case .unverified: return "Protection not confirmed"
        }
    }

    var symbol: String {
        switch self {
        case .unavailable, .off: return "shield.slash"
        case .connecting: return "shield.lefthalf.filled"
        case .connected: return "checkmark.shield.fill"
        case .blocked: return "lock.shield.fill"
        case .unverified: return "exclamationmark.shield.fill"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .unavailable, .off: return .secondaryLabelColor
        case .connecting: return .systemOrange
        case .connected: return .systemGreen
        case .blocked, .unverified: return .systemRed
        }
    }
}

enum VPNMenuIcon {
    static func make(_ state: VPNProtectionState) -> NSImage {
        let icon = NSImage(size: NSSize(width: 34, height: 18), flipped: false) { _ in
            let pulse = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemPurple]))
            let colors: [NSColor] = [.connected, .blocked, .unverified].contains(state) ? [.white, state.nsColor] : [state.nsColor]
            let shield = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.title)?
                .withSymbolConfiguration(.init(paletteColors: colors))
            pulse?.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
            shield?.draw(in: NSRect(x: 19, y: 1, width: 15, height: 16))
            return true
        }
        icon.isTemplate = false
        icon.accessibilityDescription = state.title
        return icon
    }
}

struct VPNView: View {
    @ObservedObject var store: VPNStore
    var showsSettings = true
    var activeTurns = 0
    @AppStorage("protectionExpanded") private var expanded = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: store.state.symbol).foregroundStyle(Color(nsColor: store.state.nsColor))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.statusTitle).font(.system(size: 12, weight: .semibold))
                        Text(store.subscription?.selected?.name ?? "Import a subscription in Settings.")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if store.busy { ProgressView().controlSize(.small) }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Protection details")
            if expanded {
                Divider()
                VPNQuickControls(store: store, activeTurns: activeTurns)
                VPNServerList(store: store, activeTurns: activeTurns)
                VPNDiagnosticsView(store: store)
                VPNCheckLinks()
                if showsSettings {
                    Button("Subscription settings…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "preferences") }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.13)))
    }
}

private struct VPNQuickControls: View {
    @ObservedObject var store: VPNStore
    var activeTurns: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Testing build · network lock has not passed device crash, restart and leak checks.")
                .font(.caption2).foregroundStyle(.orange)
            if !store.installed {
                Button("Install / update VPN component…") {
                    VPNActionConfirmation.perform("Update VPN component", activeTurns: activeTurns) { store.install() }
                }.disabled(store.busy || !store.engineAvailable)
            }
            if !store.networkLock.installed {
                Button("Install / update network lock…") {
                    VPNActionConfirmation.perform("Update network lock component", activeTurns: activeTurns) { store.networkLock.install() }
                }
                    .disabled(store.networkLock.busy || !store.networkLock.ready)
            }
            HStack {
                if !store.requested || store.state == .blocked || store.state == .unverified {
                    Button(store.requested ? "Retry VPN + lock" : "Connect VPN + lock") {
                        VPNActionConfirmation.perform("Connect VPN + lock", activeTurns: activeTurns) { store.enable() }
                    }.disabled(!store.installed || !store.networkLock.installed || store.subscription?.selected == nil)
                }
                Button("Pause · lock network") {
                    VPNActionConfirmation.perform("Pause and lock network", activeTurns: activeTurns) { store.pause() }
                }.disabled(!store.networkLock.installed || store.networkLock.locked)
            }.disabled(store.busy || store.networkLock.busy)
            Button("Allow direct Internet…") {
                VPNActionConfirmation.perform("Allow direct Internet", direct: true, activeTurns: activeTurns) { store.allowDirect() }
            }.disabled(store.busy || store.networkLock.busy || !store.networkLock.ready)
            Button("Open macOS network settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
            }.buttonStyle(.borderless).font(.caption)
            Text(store.networkLock.confirmed && (store.networkLock.locked || store.state == .blocked)
                 ? "Internet is blocked. Connect VPN to restore protected access, or explicitly allow direct Internet. Closing this window keeps the lock."
                 : "Pausing VPN keeps the lock. If protection is not confirmed, Internet access is not verified. To use Happ or another VPN, first choose Allow direct Internet and wait for confirmation; this removes our VPN profile and disables our filter.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let issue = store.issue ?? store.networkLock.issue {
                Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

private struct VPNServerList: View {
    @ObservedObject var store: VPNStore
    var activeTurns: Int
    var body: some View {
        if let subscription = store.subscription {
            HStack {
                Text("Servers").font(.caption.bold())
                Spacer()
                Button(store.probingServers ? "Measuring…" : "Measure TCP") { store.probeServers() }
                    .buttonStyle(.borderless).font(.caption).disabled(store.probingServers || store.busy)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(subscription.nodes) { node in
                        Button {
                            guard node.id != subscription.selectedID else { return }
                            if store.requested {
                                VPNActionConfirmation.perform("Switch VPN server", activeTurns: activeTurns) { store.select(node.id) }
                            } else { store.select(node.id) }
                        } label: {
                            HStack {
                                Image(systemName: subscription.selectedID == node.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(subscription.selectedID == node.id ? Color.accentColor : .secondary)
                                Text(node.name).lineLimit(1)
                                Spacer()
                                if let result = store.serverResults[node.id] {
                                    Text(result.reachable ? "TCP \(result.milliseconds) ms" : "TCP failed").foregroundStyle(result.reachable ? Color.secondary : .orange)
                                } else { Text("—").foregroundStyle(.secondary) }
                            }.font(.caption).padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.busy || store.networkLock.busy || (store.requested && store.state != .connected))
                    }
                }
            }.frame(height: CGFloat(min(subscription.nodes.count, 5)) * 30)
            if let time = store.serverResultsAt {
                Text("Measured \(time.formatted(date: .omitted, time: .standard)) via the connection used at that time.").font(.caption2).foregroundStyle(.secondary)
            }
            Text("TCP readiness via the current connection. A VPN can acknowledge locally before reaching the destination; this does not verify the remote server or proxy login. Switching can interrupt existing connections. Nodes can share an exit IP.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VPNPreferencesView: View {
    @ObservedObject var store: VPNStore
    var activeTurns = 0
    @State private var subscriptionURL = ""

    var body: some View {
        Section("Protection") {
            Label(store.statusTitle, systemImage: store.state.symbol).foregroundStyle(Color(nsColor: store.state.nsColor))
            VPNQuickControls(store: store, activeTurns: activeTurns)
            VPNServerList(store: store, activeTurns: activeTurns)
            VPNDiagnosticsView(store: store)
            VPNCheckLinks()
        }
        Section("VPN subscription") {
            if let subscription = store.subscription {
                HStack {
                    Text("\(subscription.nodes.count) supported servers").font(.caption)
                    Spacer()
                    Text(URL(string: subscription.sourceURL)?.host ?? "Saved subscription").font(.caption).foregroundStyle(.secondary)
                }
                Button("Refresh subscription") { store.importSubscription(subscription.sourceURL) }
                    .disabled(store.requested || store.busy || !store.engineAvailable)
            }
            SecureField("HTTPS subscription URL", text: $subscriptionURL).textFieldStyle(.roundedBorder)
                .disabled(store.requested || store.busy || !store.engineAvailable)
            Button("Import subscription") {
                store.importSubscription(subscriptionURL)
                subscriptionURL = ""
            }.disabled(store.requested || store.busy || subscriptionURL.isEmpty || !store.engineAvailable)
            Text("Subscriptions and credentials stay in Keychain. Refresh and import use the current network; a paused network lock blocks these requests.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct VPNCheckLinks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open external checks").font(.caption.bold())
            HStack {
                Link("Claude · CleanIP", destination: URL(string: "https://cleanip.io/en-US/claude")!)
                Link("Codex · CleanIP", destination: URL(string: "https://cleanip.io/en-US/codex")!)
                Link("Claude · Coffee", destination: URL(string: "https://ip.net.coffee/claude/")!)
            }.font(.caption)
            Text("Third-party checks open in your browser and see its network address. Results do not guarantee absence of leaks or service restrictions.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VPNDiagnosticsView: View {
    @ObservedObject var store: VPNStore

    var body: some View {
        if let traffic = store.traffic {
            Text("\(traffic.title) · KiB/s / MiB/s · VPN interface traffic")
                .font(.caption).monospacedDigit()
        }
        if let diagnostics = store.providerDiagnostics {
            Text("Since provider start: engine starts \(diagnostics.coreStarts) · path changes \(diagnostics.pathChanges)"
                 + (diagnostics.lastRestart.map { " · last restart: \($0.rawValue)" } ?? ""))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Test DNS / HTTPS latency") { store.checkNetwork() }.disabled(store.checkingNetwork)
            if store.checkingNetwork { ProgressView().controlSize(.small) }
        }
        if let report = store.networkReport {
            Text(store.networkReportContext).font(.caption2).foregroundStyle(.secondary)
            ForEach(report.results) { result in
                VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(result.passed ? Color.green : Color.orange)
                    Text(result.id)
                    Spacer()
                    Text(result.passed ? "\(result.milliseconds) ms" : "Failed · \(result.milliseconds) ms")
                    if let status = result.status { Text("HTTP \(status)") }
                }.font(.caption)
                if let detail = result.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Text("Measured \(report.time.formatted(date: .omitted, time: .standard)). HTTPS timing includes DNS, TCP and TLS; this is not ICMP ping or a leak test.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
