import AppKit
import SwiftUI
import VibeMonitoringCore

@MainActor
final class WorktreeStore: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all, attention, finished, prunable
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .attention: return "Uncommitted or unpushed"
            case .finished: return "Look finished"
            case .prunable: return "Missing folders"
            }
        }
    }

    @Published private(set) var snapshot = WorktreeSnapshot()
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var isMeasuring = false
    @Published var filter: Filter = .all
    @Published var ownerFilter: WorktreeOwner?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(!enabled, forKey: "worktreesDisabled") }
    }
    let isDemo: Bool
    private let scanner = WorktreeScanner()
    private var lastScan: Date?
    private let interval: TimeInterval = 60

    init(demo: Bool) {
        isDemo = demo
        enabled = !UserDefaults.standard.bool(forKey: "worktreesDisabled")
        if demo { snapshot = DemoData.worktrees(); sizes = DemoData.worktreeSizes(); hasScanned = true }
    }

    /// Git is called per worktree, so this runs at most once a minute unless forced.
    func refreshIfDue(sessions: [CodexSession], force: Bool = false) async {
        guard enabled, !isDemo, !isScanning else { return }
        if !force, let lastScan, Date().timeIntervalSince(lastScan) < interval { return }
        isScanning = true
        if force { await scanner.forgetDiscovery() }
        defer { isScanning = false }
        snapshot = await scanner.scan(sessions: sessions)
        lastScan = Date()
        hasScanned = true
    }

    func repositories() -> [(WorktreeRepository, [AgentWorktree])] {
        snapshot.repositories.compactMap { repository in
            let rows = repository.linked.filter(matches)
            return rows.isEmpty ? nil : (repository, rows.sorted(by: order))
        }
    }

    private func matches(_ worktree: AgentWorktree) -> Bool {
        if let ownerFilter, worktree.owner != ownerFilter { return false }
        switch filter {
        case .all: return true
        case .attention: return worktree.status.map { $0.isDirty || $0.ahead > 0 } ?? false
        case .finished: return worktree.looksFinished
        case .prunable: return worktree.entry.isPrunable
        }
    }

    private func order(_ lhs: AgentWorktree, _ rhs: AgentWorktree) -> Bool {
        if lhs.entry.isPrunable != rhs.entry.isPrunable { return !lhs.entry.isPrunable }
        return (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
    }

    func measureSizes() {
        guard !isMeasuring, !isDemo else { return }
        isMeasuring = true
        let paths = snapshot.linked.filter { !$0.entry.isPrunable }.map(\.path)
        Task {
            let measured = await scanner.diskUsage(paths: paths)
            sizes.merge(measured) { $1 }
            isMeasuring = false
        }
    }

    var measuredTotal: Int64? {
        let values = snapshot.linked.compactMap { sizes[$0.path] }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// Shows git's dry-run list. Records that are the last reference to commits get recovery branches first;
    /// the core re-checks this right before pruning and refuses otherwise.
    func prune(_ repository: WorktreeRepository, sessions: [CodexSession]) {
        guard !isDemo else { return }
        Task {
            let plan = await scanner.prunePlan(commonDir: repository.commonDir)
            let alert = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            if plan.records.isEmpty {
                alert.messageText = "Nothing to prune in \(repository.name)"
                alert.informativeText = "git reports no worktree records with missing folders. Locked worktrees are never pruned."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            let count = plan.records.count
            alert.messageText = "Prune \(count) worktree record\(count == 1 ? "" : "s") in \(repository.name)?"
            var text = """
            Runs git worktree prune: removes git's records of worktree folders that no longer exist. \
            No files on disk are touched and existing branches stay; their names become available for checkout again.
            """
            if !plan.unreferenced.isEmpty {
                let names = plan.unreferenced.prefix(8).map { "• \($0.suggestedBranch)" }.joined(separator: "\n")
                text += """


                \(plan.unreferenced.count) of them hold the only reference to their commits (detached HEAD). \
                Without a branch, a later git gc may delete those commits. Recovery branches will be created first:
                \(names)\(plan.unreferenced.count > 8 ? "\n…and \(plan.unreferenced.count - 8) more" : "")
                """
            }
            text += "\n\n" + plan.records.prefix(12).joined(separator: "\n") + (count > 12 ? "\n…and \(count - 12) more" : "")
            alert.informativeText = text
            alert.addButton(withTitle: plan.unreferenced.isEmpty ? "Prune" : "Save recovery branches and prune")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                let created = try await scanner.prune(commonDir: repository.commonDir, saving: plan.unreferenced)
                pruneMessage = created.isEmpty ? nil : "Created \(created.count) recovery branch\(created.count == 1 ? "" : "es") in \(repository.name): \(created.joined(separator: ", "))"
            } catch {
                pruneMessage = error.localizedDescription
            }
            await refreshIfDue(sessions: sessions, force: true)
        }
    }

    @Published var pruneMessage: String?

    // MARK: - Opening

    func reveal(_ worktree: AgentWorktree) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
    }

    func openInTerminal(_ worktree: AgentWorktree) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: worktree.path)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens in the editor the user picked once (Cursor, VS Code, Xcode…), remembered in preferences.
    func openInEditor(_ worktree: AgentWorktree) {
        let url = URL(fileURLWithPath: worktree.path)
        if let saved = UserDefaults.standard.url(forKey: "worktreeEditor"), FileManager.default.fileExists(atPath: saved.path) {
            NSWorkspace.shared.open([url], withApplicationAt: saved, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        chooseEditor { [weak self] in self?.openInEditor(worktree) }
    }

    func chooseEditor(then: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose an editor for worktrees"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let app = panel.url else { return }
        UserDefaults.standard.set(app, forKey: "worktreeEditor")
        editorName = app.deletingPathExtension().lastPathComponent
        then?()
    }

    @Published private(set) var editorName: String? = UserDefaults.standard.url(forKey: "worktreeEditor")?
        .deletingPathExtension().lastPathComponent

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
