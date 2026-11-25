import SwiftUI
import UniformTypeIdentifiers
import VibeMonitoringCore

struct PreferencesView: View {
    @ObservedObject var store: MonitorStore
    @State private var path = ""
    @State private var choosingDirectory = false

    var body: some View {
        Form {
            VPNPreferencesView(store: store.vpn, activeTurns: store.snapshot.activeCount())
            Section("Agents") {
                ForEach(AgentKind.allCases) { agent in
                    Toggle("Monitor \(agent.title)", isOn: Binding(
                        get: { store.enabledAgents.contains(agent) }, set: { store.setAgent(agent, enabled: $0) }
                    ))
                }
                Text("Claude Code: ~/.claude/projects (or $CLAUDE_CONFIG_DIR). Cursor: ~/.cursor/projects/*/agent-transcripts. Cursor transcripts have no timestamps or token counts, so its status is inferred from file writes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Codex") {
                TextField("Codex home", text: $path).onSubmit { store.applyHome(path) }
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Choose folder…") { choosingDirectory = true }
                    Button("Apply") { store.applyHome(path) }
                    Button("Use default") { path = CodexScanner.defaultHome().path; store.applyHome(path) }
                }
                Text("Choose the directory containing sessions/, normally ~/.codex. Only recent journal tails are read; unchanged files are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Notify when an observed active turn finishes", isOn: Binding(
                    get: { store.notifyOnFinish }, set: { store.setNotifications($0) }
                ))
                if let issue = store.notificationIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            }
            Section("Privacy") {
                Text("Agent monitoring is local. Quickping contacts its selected server for authorization and monitoring. VPN subscription requests contact the subscription provider; an enabled VPN routes traffic through the selected server. Agent transcripts and conversation content are never uploaded by the monitor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            QuickpingPreferencesView(store: store.quickping)
            Section("Browser · optional") {
                Text("Brave can keep a separate browser profile for your web tools and offers WebRTC privacy controls. Browser settings apply to browser traffic; system VPN protection also covers CLI tools and other apps.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Get Brave", destination: URL(string: "https://brave.com/download/")!)
                    Link("WebRTC privacy settings", destination: URL(string: "https://support.brave.app/hc/en-us/articles/360017989132-How-do-I-change-my-Privacy-Settings")!)
                }
                Text("For a browser proxy, review WebRTC's Disable Non-Proxied UDP option. With the built-in system VPN, DNS belongs to the tunnel configuration. Brave is optional and is not bundled with VibeMonitoring.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(12).frame(width: 570, height: 610)
        .onAppear { path = store.codexHome }
        .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { path = url.path; store.applyHome(path) }
        }
    }
}
