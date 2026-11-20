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

struct VPNMenuIndicator: View {
    @ObservedObject var store: VPNStore

    var body: some View {
        let base = NSImage(systemSymbolName: store.state.symbol, accessibilityDescription: store.state.title) ?? NSImage(size: NSSize(width: 16, height: 16))
        let icon = base.withSymbolConfiguration(.init(paletteColors: [store.state.nsColor])) ?? base
        icon.isTemplate = false
        return Image(nsImage: icon).renderingMode(.original)
            .help(store.state.title).accessibilityLabel(store.state.title)
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
                }.disabled(store.requested || store.busy)
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
            Text(store.engineAvailable
                 ? "Subscriptions and server credentials stay in Keychain. Disable protection explicitly before changing the server. Installing the network component requires a provisioned, signed VPN build."
                 : "This monitoring-only build does not contain the VPN engine. The VPN build is separate and requires macOS network-extension approval.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
