import SwiftUI
import VibeMonitoringCore

struct QuickpingView: View {
    @ObservedObject var store: QuickpingStore
    @Environment(\.openWindow) private var openWindow
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Quickping", systemImage: "server.rack").font(.headline)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                if store.hasAccess {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.buttonStyle(.plain).accessibilityLabel("Show service status details")
                } else {
                    Button("Connect…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "preferences") }
                        .font(.caption).buttonStyle(.borderless)
                }
            }
            if let snapshot = store.snapshot {
                HStack(spacing: 6) {
                    Image(systemName: store.stale ? "clock.badge.exclamationmark" : "circle.fill")
                        .foregroundStyle(summaryColor(snapshot))
                    Text(summary(snapshot)).font(.caption)
                }
                Text("Server report: \(snapshot.sampledAt.formatted(.relative(presentation: .numeric)))")
                    .font(.caption2).foregroundStyle(.secondary)
                if expanded {
                    ForEach(snapshot.services) { service in
                        HStack(alignment: .top) {
                            Circle().fill(serviceColor(service)).frame(width: 6, height: 6).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(service.name).font(.caption).lineLimit(2)
                                Text(serviceStatus(service)).font(.caption2).foregroundStyle(.secondary)
                                if !service.openIncidents.isEmpty {
                                    Text("\(service.openIncidents.count) open incident(s)").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if let latency = service.latencyMs, latency.isFinite, latency >= 0, !store.stale {
                                Text("\(latency, specifier: "%.0f") ms").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if snapshot.truncated { Text("Showing the first 100 services.").font(.caption2).foregroundStyle(.secondary) }
                }
            } else if store.hasAccess {
                Text("Waiting for a server report…").font(.caption).foregroundStyle(.secondary)
            } else if store.issue == nil {
                Text("Connect your account to see service checks and incidents.").font(.caption).foregroundStyle(.secondary)
            }
            if let issue = store.issue { Text(issue).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.13)))
    }

    private func summary(_ snapshot: QuickpingSnapshot) -> String {
        if store.stale { return "Previous report · data stale" }
        if snapshot.services.isEmpty { return "No active services" }
        let down = snapshot.services.filter { $0.status == "down" }.count
        let degraded = snapshot.services.filter { $0.status == "degraded" }.count
        let unknown = snapshot.services.filter { !["operational", "down", "degraded"].contains($0.status) }.count
        if down + degraded + unknown == 0 { return "\(snapshot.services.count) services operational" }
        return "\(down) down · \(degraded) degraded · \(unknown) pending / unknown"
    }

    private func summaryColor(_ snapshot: QuickpingSnapshot) -> Color {
        if store.stale || snapshot.services.isEmpty { return .secondary }
        if snapshot.services.contains(where: { $0.status == "down" }) { return .red }
        if snapshot.services.contains(where: { $0.status != "operational" }) { return .orange }
        return .teal
    }

    private func serviceColor(_ service: QuickpingService) -> Color {
        if store.stale { return .secondary }
        switch service.status {
        case "operational": return .teal
        case "down": return .red
        case "degraded": return .orange
        default: return .secondary
        }
    }

    private func serviceStatus(_ service: QuickpingService) -> String {
        if store.stale { return "Previous result · \(service.status)" }
        switch service.status {
        case "operational": return "Operational"
        case "down": return "Down"
        case "degraded": return "Degraded"
        case "pending": return "Monitoring not enabled"
        default: return "No recent check result"
        }
    }
}

struct QuickpingPreferencesView: View {
    @ObservedObject var store: QuickpingStore
    @State private var server = ""

    var body: some View {
        Section("Quickping") {
            if store.hasAccess {
                Text(store.serverText).font(.caption).textSelection(.enabled)
                if let expires = store.expiresAt { Text("Access expires: \(expires.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                HStack {
                    Button("Refresh") { Task { await store.refresh() } }.disabled(store.isRefreshing)
                    Button("Disconnect") { store.disconnect() }
                    if let origin = try? QuickpingServer(store.serverText) {
                        Link("Manage access", destination: origin.endpoint("integrations"))
                    }
                }
            } else {
                TextField("Quickping server, e.g. https://quickping.example", text: $server).textFieldStyle(.roundedBorder)
                    .disabled(store.isConnecting)
                HStack {
                    Button("Sign in with Quickping…") { store.connect(to: server) }.disabled(store.isConnecting)
                    if store.isConnecting {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { store.cancelConnection() }
                    }
                }
            }
            if let issue = store.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            Text("Sign in and approve read-only monitoring in your browser. Credentials are stored in macOS Keychain. The server needs the desktop integration update.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { server = store.serverText }
    }
}
