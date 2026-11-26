import AppKit
import SwiftUI
import VibeMonitoringCore

extension MonitorStore {
    var codexLimits: AgentLimitReport? {
        isDemo ? DemoData.limits().first { $0.agent == .codex } : AgentLimits.codex(from: snapshot.sessions)
    }

    func connectClaudeLimits() {
        let bridge = ClaudeStatusLineBridge()
        let alert = NSAlert()
        alert.messageText = "Show Claude Code usage limits?"
        var text = """
        VibeMonitoring will set a status line command in \(bridge.settingsURL.path). \
        Claude Code passes its 5-hour and weekly limit percentages to that command, which saves them to \
        ~/Library/Application Support/VibeMonitoring. No token is read and nothing is sent anywhere.

        A backup is written to \(bridge.backupURL.lastPathComponent). settings.json is rewritten with sorted keys.
        """
        if let existing = bridge.existingCommand() {
            text += "\n\nYour current status line keeps working; it is called after the bridge:\n\(existing)"
        }
        text += "\n\nLimits appear after the next Claude Code reply in a subscription (not API key) session."
        alert.informativeText = text
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try bridge.install(); limitsIssue = nil } catch { limitsIssue = error.localizedDescription }
        refreshClaudeLimits()
    }

    func disconnectClaudeLimits() {
        do { try ClaudeStatusLineBridge().uninstall(); limitsIssue = nil } catch { limitsIssue = error.localizedDescription }
        refreshClaudeLimits()
    }

    func refreshClaudeLimits() {
        if isDemo { claudeLimits = DemoData.limits().first { $0.agent == .claude }; claudeBridgeInstalled = true; return }
        let bridge = ClaudeStatusLineBridge()
        claudeBridgeInstalled = bridge.isInstalled
        if claudeBridgeInstalled && !bridgeScriptChecked {
            bridge.updateScriptIfInstalled()
            bridgeScriptChecked = true
        }
        claudeLimits = bridge.latestReport()
    }
}

struct LimitsCard: View {
    @ObservedObject var store: MonitorStore
    @State private var expanded = false

    var body: some View {
        let agents = AgentKind.allCases.filter { store.enabledAgents.contains($0) }
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.50percent").foregroundStyle(.indigo).frame(width: 18)
                    Text("Usage limits").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(expanded ? "Hide limit details" : "Show limit details")
                }
                if expanded {
                    ForEach(agents) { agent in row(agent) }
                } else {
                    ForEach(agents) { agent in compactRow(agent) }
                }
                if let issue = store.limitsIssue {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.13)))
        }
    }

    @ViewBuilder private func row(_ agent: AgentKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(agent.title).font(.system(size: 11, weight: .semibold))
                if let plan = report(agent)?.plan { Text(plan.capitalized).foregroundStyle(.secondary) }
                Spacer()
                if let observed = report(agent)?.observedAt {
                    Text("reported").foregroundStyle(.tertiary)
                    Text(observed, format: .relative(presentation: .numeric)).foregroundStyle(.secondary)
                }
            }.font(.system(size: 10))
            if let report = report(agent) {
                ForEach(Array(report.windows.enumerated()), id: \.offset) { _, window in
                    QuotaView(window: window, agent: agent)
                }
            } else {
                missing(agent)
            }
        }
    }

    @ViewBuilder private func missing(_ agent: AgentKind) -> some View {
        switch agent {
        case .codex:
            note("No quota report in recent Codex journals yet.")
        case .claude:
            if store.claudeBridgeInstalled {
                note("Connected. Waiting for the next Claude Code reply; API-key sessions have no plan limits.")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    note("Claude Code reports limits only to its status line.")
                    Spacer()
                    Button("Connect…") { store.connectClaudeLimits() }.controlSize(.small)
                }
            }
        case .cursor:
            note("Cursor does not store usage locally. Live limits would require reading its sign-in token, which is not done.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func report(_ agent: AgentKind) -> AgentLimitReport? {
        switch agent {
        case .codex: return store.codexLimits
        case .claude: return store.claudeLimits
        case .cursor: return nil
        }
    }

    /// One line per agent: a short bar per window; details (reset times, sources) on expand.
    @ViewBuilder private func compactRow(_ agent: AgentKind) -> some View {
        HStack(spacing: 10) {
            Text(agent.title).font(.system(size: 10, weight: .semibold)).frame(width: 74, alignment: .leading)
            if let report = report(agent) {
                ForEach(Array(report.windows.enumerated()), id: \.offset) { _, window in
                    MiniQuota(window: window)
                }
                Spacer(minLength: 0)
            } else if agent == .claude && !store.claudeBridgeInstalled {
                Text("Not connected").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { store.connectClaudeLimits() } label: { Text("Connect…").foregroundStyle(.tint) }
                    .buttonStyle(.plain)
            } else {
                Text(agent == .cursor ? "Not available locally" : "No report yet").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }.font(.system(size: 10))
    }
}

private struct MiniQuota: View {
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 5) {
            Text(shortTitle).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.12))
                Capsule().fill(QuotaView.tint(window)).frame(width: 46 * min(100, max(0, window.usedPercent)) / 100)
            }.frame(width: 46, height: 4)
            Text(window.isExpired ? "—" : "\(Int(window.usedPercent.rounded()))%").monospacedDigit()
                .foregroundStyle(window.isExpired ? .secondary : .primary)
        }
        .help(window.resetsAt.map { "\(window.title): resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? window.title)
    }

    private var shortTitle: String {
        if window.label != nil { return "$" }
        switch window.minutes {
        case 10_080: return "7d"
        case let minutes? where minutes % 60 == 0: return "\(minutes / 60)h"
        case let minutes?: return "\(minutes)m"
        case nil: return "·"
        }
    }
}

extension UsageWindow {
    var isExpired: Bool { resetsAt.map { $0 <= Date() } ?? false }
}

struct QuotaView: View {
    let window: UsageWindow
    var agent: AgentKind = .codex

    private var tint: Color { Self.tint(window) }

    static func tint(_ window: UsageWindow) -> Color {
        if window.isExpired { return .secondary }
        if window.usedPercent >= 90 { return .red }
        if window.usedPercent >= 70 { return .orange }
        return .indigo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.title)
                Spacer()
                Text("\(window.usedPercent, specifier: "%.0f")% used").monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.10))
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * min(100, max(0, window.usedPercent)) / 100)
                }
            }.frame(height: 4)
            if window.isExpired {
                Text("Window has reset since this report. Waiting for a new \(agent.title) report.").foregroundStyle(.secondary)
            } else if let reset = window.resetsAt {
                HStack(spacing: 3) {
                    Text("Resets")
                    Text(reset, format: .relative(presentation: .named))
                    Text("· \(reset.formatted(date: .abbreviated, time: .shortened))")
                }.foregroundStyle(.secondary)
            }
        }.font(.system(size: 10))
    }
}
