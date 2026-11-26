import AppKit
import SwiftUI
import VibeMonitoringCore

extension WorktreeOwner {
    var color: Color {
        switch self {
        case .codex: return .indigo
        case .claude: return .orange
        case .cursor: return .teal
        case .t3: return .purple
        case .main, .other: return .secondary
        }
    }
}

/// Compact counts in the menu bar popover; the full list lives in its own window.
struct WorktreeSummaryCard: View {
    @ObservedObject var store: WorktreeStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.enabled { card }
    }

    private var card: some View {
        let snapshot = store.snapshot
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.indigo).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent worktrees").font(.system(size: 13, weight: .semibold))
                if store.hasScanned {
                    HStack(spacing: 5) {
                        Text("\(snapshot.linked.count) in \(snapshot.repositories.filter { !$0.linked.isEmpty }.count) repos")
                        if snapshot.dirtyCount > 0 { dot; Text("\(snapshot.dirtyCount) uncommitted").foregroundStyle(.orange) }
                        if snapshot.prunableCount > 0 { dot; Text("\(snapshot.prunableCount) missing").foregroundStyle(.secondary) }
                        if snapshot.finishedCount > 0 { dot; Text("\(snapshot.finishedCount) look finished").foregroundStyle(.teal) }
                    }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(store.isScanning ? "Scanning git worktrees…" : "Waiting for first scan")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "worktrees") } label: {
                Text("Open").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }.buttonStyle(.plain).help("Open the worktree window")
        }
        .font(.caption)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.13)))
    }

    private var dot: some View { Text("·").foregroundStyle(.tertiary) }
}

struct WorktreesView: View {
    @ObservedObject var store: WorktreeStore
    @ObservedObject var monitor: MonitorStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = store.pruneMessage {
                HStack {
                    Label(message, systemImage: "info.circle").font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { store.pruneMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(.indigo.opacity(0.06))
            }
            if !store.enabled {
                placeholder("Worktree monitoring is off", "Turn it on in Settings › Agents.")
            } else if !store.hasScanned {
                placeholder("Scanning git worktrees…", "Repositories are found from agent sessions and agent worktree folders.")
            } else {
                let groups = store.repositories()
                if groups.isEmpty {
                    placeholder("No worktrees to show", store.filter == .all && store.ownerFilter == nil
                                ? "No linked worktrees were found in repositories that agents worked in." : "Nothing matches this filter.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(groups, id: \.0.id) { repository, rows in
                                RepositorySection(store: store, monitor: monitor, repository: repository, rows: rows)
                            }
                        }.padding(16)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $store.filter) {
                ForEach(WorktreeStore.Filter.allCases) { Text($0.title).tag($0) }
            }.fixedSize()
            Picker("Owner", selection: $store.ownerFilter) {
                Text("Any owner").tag(WorktreeOwner?.none)
                ForEach(WorktreeOwner.allCases.filter { $0 != .main }) { Text($0.title).tag(WorktreeOwner?.some($0)) }
            }.labelsHidden().fixedSize()
            Spacer()
            if let total = store.measuredTotal {
                Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            Button { store.measureSizes() } label: {
                if store.isMeasuring { ProgressView().controlSize(.small) } else { Label("Disk usage", systemImage: "internaldrive") }
            }.disabled(store.isMeasuring || !store.hasScanned).help("Measure folder sizes with du (can take a while)")
            Button { Task { await store.refreshIfDue(sessions: monitor.snapshot.sessions, force: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }.disabled(store.isScanning).help("Rescan worktrees")
        }.padding(12)
    }

    private var footer: some View {
        HStack {
            Text("Read only, except Prune, which removes git records of folders that no longer exist (after saving recovery branches for commits nothing else references). Nothing is deleted from disk. \"Looks finished\" means clean, no active session and contained in the default branch; squash merges are not detected.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if store.hasScanned {
                Text("Scanned \(store.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.secondary.opacity(0.04))
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

private struct RepositorySection: View {
    @ObservedObject var store: WorktreeStore
    @ObservedObject var monitor: MonitorStore
    let repository: WorktreeRepository
    let rows: [AgentWorktree]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(repository.name).font(.headline)
                Text("\(rows.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let branch = repository.defaultBranch {
                    Text("default \(branch)").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if !repository.prunable.isEmpty {
                    Button("Prune \(repository.prunable.count) missing…") {
                        store.prune(repository, sessions: monitor.snapshot.sessions)
                    }.controlSize(.small).help("Remove git records of worktree folders that no longer exist")
                }
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: repository.mainPath)) } label: {
                    Image(systemName: "folder")
                }.buttonStyle(.borderless).help("Open main checkout")
            }
            if let issue = repository.issue {
                Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            ForEach(rows) { WorktreeRow(store: store, worktree: $0) }
        }
    }
}

private struct WorktreeRow: View {
    @ObservedObject var store: WorktreeStore
    let worktree: AgentWorktree

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(worktree.owner.title).font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .foregroundStyle(worktree.owner.color)
                .background(worktree.owner.color.opacity(0.10), in: Capsule())
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(worktree.branchTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if worktree.activeSessions > 0 {
                        chip("active session", .indigo, "bolt.fill").font(.system(size: 10))
                    } else if !worktree.sessionIdentities.isEmpty {
                        chip("\(worktree.sessionIdentities.count) session\(worktree.sessionIdentities.count == 1 ? "" : "s")", .secondary, "terminal")
                    }
                }
                Text(displayPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 6) { chips }.font(.system(size: 10))
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                if let date = worktree.lastActivity {
                    Text(date, format: .relative(presentation: .numeric)).font(.caption2).foregroundStyle(.secondary)
                }
                if let size = store.sizes[worktree.path] {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                actions
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.13)))
        .opacity(worktree.entry.isPrunable ? 0.65 : 1)
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return worktree.path.hasPrefix(home) ? "~" + worktree.path.dropFirst(home.count) : worktree.path
    }

    @ViewBuilder private var chips: some View {
        if worktree.entry.isPrunable {
            chip("folder missing", .secondary, "questionmark.folder")
        } else if let status = worktree.status {
            if status.changedFiles > 0 { chip("\(status.changedFiles) changed", .orange, "pencil") }
            if status.untrackedFiles > 0 { chip("\(status.untrackedFiles) untracked", .orange, "plus") }
            if status.ahead > 0 { chip("↑\(status.ahead) unpushed", .orange) }
            if status.behind > 0 { chip("↓\(status.behind)", .secondary) }
            if status.upstream == nil && worktree.entry.branch != nil && worktree.mergedIntoDefault != true {
                chip("no upstream", .secondary)
            }
            if status.upstreamGone {
                if worktree.mergedIntoDefault == true { chip("remote branch deleted", .teal) }
                else { chip("upstream deleted · publish state unknown", .orange, "questionmark") }
            }
            if worktree.mergedIntoDefault == true { chip("merged", .teal, "checkmark") }
            if !status.isDirty && status.ahead == 0 && worktree.mergedIntoDefault != true && !status.upstreamGone {
                chip("clean", .secondary)
            }
        } else if let issue = worktree.issue {
            chip(issue, .orange, "exclamationmark.triangle")
        }
        if worktree.entry.isLocked { chip("locked", .secondary, "lock") }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { store.reveal(worktree) } label: { Image(systemName: "folder") }
                .help("Show in Finder")
            Button { store.openInTerminal(worktree) } label: { Image(systemName: "terminal") }
                .help("Open in Terminal")
            Menu {
                Button(store.editorName.map { "Open in \($0)" } ?? "Open in editor…") { store.openInEditor(worktree) }
                Button("Choose editor…") { store.chooseEditor() }
                Divider()
                Button("Copy path") { store.copy(worktree.path) }
                if let branch = worktree.entry.branch { Button("Copy branch name") { store.copy(branch) } }
                Button("Copy cd command") { store.copy("cd \(shellQuoted(worktree.path))") }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.borderless)
        .disabled(worktree.entry.isPrunable)
    }

    private func chip(_ text: String, _ color: Color, _ symbol: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8)) }
            Text(text)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.09), in: Capsule())
    }

    private func shellQuoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension DemoPreview {
    /// Renders the worktree window with fictional data (an offscreen window, so scroll content is drawn too).
    static func writeWorktrees(to path: String) throws {
        let monitor = MonitorStore(demo: true, startPolling: false)
        let content = VStack(spacing: 12) {
            WorktreeSummaryCard(store: monitor.worktrees).padding(.horizontal, 16).padding(.top, 16)
            WorktreesView(store: monitor.worktrees, monitor: monitor)
        }
        .frame(width: 700, height: 820)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 820)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "VibeMonitoring.Preview", code: 2)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "VibeMonitoring.Preview", code: 3)
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
