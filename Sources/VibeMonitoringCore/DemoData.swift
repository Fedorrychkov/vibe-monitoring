import Foundation

public enum DemoData {
    public static func quickpingSnapshot(at now: Date = Date()) -> QuickpingSnapshot {
        QuickpingSnapshot(sampledAt: now.addingTimeInterval(-12), services: [
            QuickpingService(id: "demo-api", name: "Orbit API", status: "operational", lastCheckedAt: now.addingTimeInterval(-20), latencyMs: 142, openIncidents: []),
            QuickpingService(id: "demo-assets", name: "Asset service", status: "degraded", lastCheckedAt: now.addingTimeInterval(-18), latencyMs: 1_900,
                             openIncidents: [QuickpingIncident(id: "demo-slow", reason: "slow", openedAt: now.addingTimeInterval(-600))]),
        ], truncated: false)
    }

    public static func snapshot(at now: Date = Date()) -> ScanSnapshot {
        var active = CodexSession(id: "demo-active")
        active.projectPath = "/demo/projects/orbit-api"
        active.origin = "Codex Desktop"
        active.model = "example-model"
        active.phase = .running
        active.lastActivity = now.addingTimeInterval(-8)
        active.usage = TokenUsage(input: 124_000, cachedInput: 90_000, output: 12_400,
                                  reasoningOutput: 8_000, total: 136_400)
        active.primaryWindow = UsageWindow(usedPercent: 38, minutes: 300,
                                           resetsAt: now.addingTimeInterval(7_200))
        active.secondaryWindow = UsageWindow(usedPercent: 24, minutes: 10_080,
                                             resetsAt: now.addingTimeInterval(172_800))
        active.limitsObservedAt = active.lastActivity

        var finished = CodexSession(id: "demo-finished")
        finished.projectPath = "/demo/projects/studio-web"
        finished.origin = "Codex CLI"
        finished.model = "example-model"
        finished.phase = .completed
        finished.lastActivity = now.addingTimeInterval(-74)
        finished.stateChangedAt = finished.lastActivity
        finished.turnDuration = 125
        finished.usage = TokenUsage(input: 48_000, cachedInput: 30_000, output: 4_800, total: 52_800)

        var stale = CodexSession(id: "demo-stale")
        stale.projectPath = "/demo/projects/asset-kit"
        stale.origin = "Codex Desktop"
        stale.phase = .running
        stale.lastActivity = now.addingTimeInterval(-900)

        var claude = CodexSession(id: "demo-claude", agent: .claude)
        claude.projectPath = "/demo/projects/billing-core"
        claude.origin = "Claude Code · cli"
        claude.model = "example-model"
        claude.phase = .running
        claude.lastActivity = now.addingTimeInterval(-4)
        claude.usage = TokenUsage(input: 210_000, cachedInput: 180_000, cacheWriteInput: 20_000, output: 9_600, total: 219_600)
        claude.isPartialHistory = false

        var cursor = CodexSession(id: "demo-cursor", agent: .cursor)
        cursor.projectPath = "/demo/projects/landing"
        cursor.origin = "Cursor agent"
        cursor.phase = .completed
        cursor.lastActivity = now.addingTimeInterval(-300)
        cursor.stateChangedAt = cursor.lastActivity

        return ScanSnapshot(sessions: [active, claude, finished, cursor, stale], updatedAt: now)
    }

    public static func worktrees(at now: Date = Date()) -> WorktreeSnapshot {
        func worktree(_ path: String, branch: String?, owner: WorktreeOwner, isMain: Bool = false,
                      status: WorktreeStatus? = WorktreeStatus(), merged: Bool? = false, age: TimeInterval,
                      prunable: Bool = false, active: Int = 0) -> AgentWorktree {
            var entry = WorktreeEntry(path: path)
            entry.branch = branch
            entry.head = "0123456789abcdef"
            entry.isPrunable = prunable
            var value = AgentWorktree(entry: entry, owner: owner, isMain: isMain)
            value.status = prunable ? nil : status
            value.mergedIntoDefault = prunable ? nil : merged
            value.lastCommitAt = now.addingTimeInterval(-age)
            value.activeSessions = active
            value.sessionIdentities = active > 0 ? ["demo"] : []
            return value
        }
        var dirty = WorktreeStatus(); dirty.changedFiles = 4; dirty.untrackedFiles = 1; dirty.upstream = "origin/feat/invoices"
        var ahead = WorktreeStatus(); ahead.ahead = 2; ahead.upstream = "origin/fix/retry"
        var gone = WorktreeStatus(); gone.upstreamGone = true; gone.upstream = "origin/docs/readme"
        let orbit = WorktreeRepository(commonDir: "/demo/projects/orbit-api/.git", mainPath: "/demo/projects/orbit-api",
                                       defaultBranch: "origin/main", worktrees: [
            worktree("/demo/projects/orbit-api", branch: "main", owner: .main, isMain: true, age: 600),
            worktree("/demo/home/.codex/worktrees/invoices/orbit-api", branch: "feat/invoices", owner: .codex, status: dirty, age: 40, active: 1),
            worktree("/demo/home/.codex/worktrees/retry/orbit-api", branch: "fix/retry", owner: .codex, status: ahead, age: 7_200),
            worktree("/demo/home/.codex/worktrees/readme/orbit-api", branch: "docs/readme", owner: .codex, status: gone, age: 260_000),
            worktree("/demo/tmp/orbit-review-42", branch: nil, owner: .other, age: 900_000, prunable: true),
        ])
        let billing = WorktreeRepository(commonDir: "/demo/projects/billing-core/.git", mainPath: "/demo/projects/billing-core",
                                         defaultBranch: "origin/main", worktrees: [
            worktree("/demo/projects/billing-core", branch: "main", owner: .main, isMain: true, age: 3_000),
            worktree("/demo/projects/billing-core/.claude/worktrees/ledger", branch: "worktree-ledger", owner: .claude, merged: true, age: 90_000),
            worktree("/demo/tmp/claude-501/billing/scratchpad/wt-export", branch: "feat/export", owner: .claude, age: 1_200_000, prunable: true),
        ])
        return WorktreeSnapshot(repositories: [orbit, billing], updatedAt: now)
    }

    public static func worktreeSizes() -> [String: Int64] {
        ["/demo/home/.codex/worktrees/invoices/orbit-api": 412_000_000,
         "/demo/home/.codex/worktrees/retry/orbit-api": 398_000_000,
         "/demo/home/.codex/worktrees/readme/orbit-api": 401_000_000,
         "/demo/projects/billing-core/.claude/worktrees/ledger": 96_000_000]
    }

    public static func limits(at now: Date = Date()) -> [AgentLimitReport] {
        [AgentLimitReport(agent: .codex, windows: [
            UsageWindow(usedPercent: 38, minutes: 300, resetsAt: now.addingTimeInterval(7_200)),
            UsageWindow(usedPercent: 24, minutes: 10_080, resetsAt: now.addingTimeInterval(172_800)),
         ], observedAt: now.addingTimeInterval(-8), plan: "pro"),
         AgentLimitReport(agent: .claude, windows: [
            UsageWindow(usedPercent: 72, minutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            UsageWindow(usedPercent: 41, minutes: 10_080, resetsAt: now.addingTimeInterval(400_000)),
         ], observedAt: now.addingTimeInterval(-30))]
    }
}
