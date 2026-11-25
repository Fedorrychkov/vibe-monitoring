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
}
