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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: store.state.symbol).foregroundStyle(Color(nsColor: store.state.nsColor))
            VStack(alignment: .leading, spacing: 4) {
                Text(store.state.title).font(.system(size: 12, weight: .semibold))
                if let node = store.subscription?.selected {
                    Text(node.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Import a subscription in Settings.").font(.caption2).foregroundStyle(.secondary)
                }
                if store.state == .unverified {
                    Text("Do not assume traffic is protected.").font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            if store.busy { ProgressView().controlSize(.small) }
            if showsSettings {
                Button("VPN…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "preferences") }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.13)))
    }
}

struct VPNPreferencesView: View {
    @ObservedObject var store: VPNStore
    @State private var subscriptionURL = ""

    var body: some View {
        Section("VPN") {
            Label(store.state.title, systemImage: store.state.symbol).foregroundStyle(Color(nsColor: store.state.nsColor))
            Text("Testing build: VPN protection has not yet passed the on-device leak and crash checks.")
                .font(.caption).foregroundStyle(.orange)
            if let subscription = store.subscription {
                HStack {
                    Text("\(subscription.nodes.count) supported servers").font(.caption)
                    Spacer()
                    Text(URL(string: subscription.sourceURL)?.host ?? "Saved subscription").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Server", selection: Binding(get: { subscription.selectedID }, set: { store.select($0) })) {
                    ForEach(subscription.nodes) { node in Text("\(node.name) · \(node.kind.uppercased())").tag(node.id) }
                }.disabled(store.busy || (store.requested && store.state != .connected))
                if store.requested {
                    Text("Changing server keeps the VPN policy enabled and reconnects the tunnel engine. Existing connections may briefly pause.")
                        .font(.caption).foregroundStyle(.secondary)
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
            HStack {
                if !store.installed {
                    Button("Install network component…") { store.install() }.disabled(store.busy || !store.engineAvailable)
                }
                if store.requested {
                    Button("Disable protection · allow direct internet") { store.disable() }.disabled(store.busy)
                } else {
                    Button("Enable protection for testing") { store.enable() }
                        .disabled(store.busy || !store.installed || store.subscription?.selected == nil)
                }
                if store.busy { ProgressView().controlSize(.small) }
            }
            if let issue = store.issue {
                Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            VPNDiagnosticsView(store: store)
            Text(store.engineAvailable
                 ? "Subscriptions and server credentials stay in Keychain. Installing the network component requires a provisioned, signed VPN build."
                 : "This monitoring-only build does not contain the VPN engine. The VPN build is separate and requires macOS network-extension approval.")
                .font(.caption).foregroundStyle(.secondary)
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
        HStack {
            Button("Test DNS / HTTPS latency") { store.checkNetwork() }.disabled(store.checkingNetwork)
            if store.checkingNetwork { ProgressView().controlSize(.small) }
        }
        if let report = store.networkReport {
            ForEach(report.results) { result in
                HStack {
                    Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(result.passed ? Color.green : Color.orange)
                    Text(result.id)
                    Spacer()
                    Text(result.passed ? "\(result.milliseconds) ms" : "Failed · \(result.milliseconds) ms")
                    if let status = result.status { Text("HTTP \(status)") }
                }.font(.caption)
            }
            Text("Measured \(report.time.formatted(date: .omitted, time: .standard)). HTTPS timing includes DNS, TCP and TLS; this is not ICMP ping or a leak test.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
