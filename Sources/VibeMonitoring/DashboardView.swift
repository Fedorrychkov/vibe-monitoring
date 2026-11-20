import AppKit
import SwiftUI
import VibeMonitoringCore

extension SessionPhase {
    var color: Color {
        switch self {
        case .running: return .indigo
        case .completed: return .teal
        case .attention, .stale: return .orange
        case .interrupted, .unknown: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .running: return "bolt.fill"
        case .completed: return "checkmark.circle.fill"
        case .attention: return "hand.raised.fill"
        case .stale: return "clock"
        case .interrupted: return "pause.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.openWindow) private var openWindow
    var popover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(.indigo)
                    .frame(width: 42, height: 42).background(.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("VibeMonitoring").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Your agents. One glance.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(store.isDemo ? "DEMO" : "LOCAL")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.secondary.opacity(0.10), in: Capsule())
            }
            .padding(20)

            HStack(spacing: 10) {
                MetricCard(value: "\(store.snapshot.activeCount())", title: "Active turns", symbol: "bolt.fill", color: .indigo)
                MetricCard(value: "\(store.snapshot.sessions.count)", title: "Recent sessions", symbol: "square.stack.3d.up", color: .teal)
            }.padding(.horizontal, 20)

            HStack {
                Label("Codex", systemImage: "terminal").font(.headline)
                Spacer()
                Toggle("Show finished", isOn: $store.showFinished).toggleStyle(.checkbox).font(.caption)
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)

            if let issue = store.snapshot.issue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.visibleSessions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No sessions to show").font(.headline)
                            Text("Start a local Codex session, or check the Codex home directory in Settings.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                    ForEach(store.visibleSessions) { session in
                        SessionCard(session: session, initiallyExpanded: store.isDemo && session.displayPhase() == .running)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Activity comes from local Codex journals. A quiet or crashed process may leave a stale signal.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Label("Read only", systemImage: "lock.shield").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help("Refresh local journals").disabled(store.isRefreshing)
                    if popover {
                        Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "dashboard") } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }.help("Open dashboard")
                    }
                    Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "preferences") } label: {
                        Image(systemName: "gearshape")
                    }.help("Settings")
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit VibeMonitoring")
                }.buttonStyle(.borderless)
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.secondary.opacity(0.04))
        }
        .frame(minWidth: 420, idealWidth: 440, maxWidth: .infinity)
        .frame(height: popover ? 650 : nil)
    }
}

private struct MetricCard: View {
    let value: String
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol).font(.caption).foregroundStyle(color)
            Text(value).font(.system(size: 29, weight: .semibold, design: .rounded))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SessionCard: View {
    let session: CodexSession
    @State private var expanded: Bool

    init(session: CodexSession, initiallyExpanded: Bool = false) {
        self.session = session
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var phase: SessionPhase { session.displayPhase() }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: phase.symbol).foregroundStyle(phase.color).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.projectName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(phase.title).foregroundStyle(phase.color)
                        if let date = session.statusTimestamp {
                            Text("·").foregroundStyle(.tertiary)
                            if phase != .completed && phase != .interrupted {
                                Text("Activity").foregroundStyle(.secondary)
                            }
                            Text(date, format: .relative(presentation: .numeric)).foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 10))
                }
                Spacer(minLength: 4)
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(expanded ? "Hide session details" : "Show session details")
            }

            if let usage = session.usage {
                Text("Recorded thread totals").font(.system(size: 9)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    token("IN", usage.input)
                    token("CACHE", usage.cachedInput)
                    token("OUT", usage.output)
                    Spacer(minLength: 0)
                }
            }

            if expanded {
                Divider()
                LabeledContent("Source", value: session.origin ?? "Codex")
                LabeledContent("Model", value: session.model ?? "Not in recent events")
                LabeledContent("Session", value: session.shortID)
                if let duration = session.turnDuration {
                    LabeledContent("Turn duration", value: Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                }
                if let primary = session.primaryWindow { QuotaView(window: primary) }
                if let secondary = session.secondaryWindow { QuotaView(window: secondary) }
                if let usage = session.usage {
                    Text("Recorded thread total: \(usage.total.formatted()) tokens. Cached input is part of input; reasoning is part of output. These counters are not a bill.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let path = session.projectPath {
                    Button("Open project folder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                        .font(.caption).disabled(!FileManager.default.fileExists(atPath: path))
                }
            }
        }
        .font(.caption)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.13)))
    }

    private func token(_ label: String, _ value: Int64) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            Text(value.formatted(.number.notation(.compactName)))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
    }
}

private struct QuotaView: View {
    let window: UsageWindow
    private var expired: Bool { window.resetsAt.map { $0 <= Date() } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.title)
                Spacer()
                Text("\(window.usedPercent, specifier: "%.0f")% used")
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.10))
                    Capsule().fill(expired ? Color.secondary : .indigo)
                        .frame(width: geometry.size.width * min(100, max(0, window.usedPercent)) / 100)
                }
            }.frame(height: 4)
            if expired {
                Text("Report expired. Waiting for a new Codex quota event.").foregroundStyle(.secondary)
            } else if let reset = window.resetsAt {
                Text("Reported reset: \(reset.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
            }
        }.font(.system(size: 10))
    }
}

@MainActor
enum DemoPreview {
    static func write(to path: String) throws {
        let snapshot = DemoData.snapshot()
        let content = VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform.path.ecg").font(.title).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 3) {
                    Text("VibeMonitoring").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Your agents. One glance.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("DEMO").font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(6).background(.indigo.opacity(0.08), in: Capsule())
            }.padding(.bottom, 6)
            HStack {
                MetricCard(value: "1", title: "Active turns", symbol: "bolt.fill", color: .indigo)
                MetricCard(value: "3", title: "Recent sessions", symbol: "square.stack.3d.up", color: .teal)
            }
            Label("Codex", systemImage: "terminal").font(.headline).padding(.top, 6)
            ForEach(snapshot.sessions) { session in
                SessionCard(session: session, initiallyExpanded: session.displayPhase() == .running)
            }
            Label("Local · Read only · No account required", systemImage: "lock.shield")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "VibeMonitoring.Preview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not render demo components"])
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
