import Foundation
import XCTest
@testable import VibeMonitoringCore

final class WorktreeTests: XCTestCase {
    func testParsesPorcelainRecords() {
        let text = """
        worktree /demo/app
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /demo/home/.codex/worktrees/fix/app
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/codex/fix
        locked agent is working

        worktree /tmp/review
        HEAD 3333333333333333333333333333333333333333
        detached
        prunable gitdir file points to non-existent location

        """
        let entries = WorktreeEntry.parse(porcelain: text)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].branch, "main")
        XCTAssertEqual(entries[1].branch, "codex/fix")
        XCTAssertTrue(entries[1].isLocked)
        XCTAssertEqual(entries[1].lockedReason, "agent is working")
        XCTAssertTrue(entries[2].isDetached)
        XCTAssertNil(entries[2].branch)
        XCTAssertTrue(entries[2].isPrunable)
    }

    func testParsesBranchStatus() {
        var status = WorktreeStatus.parse("## feat/x...origin/feat/x [ahead 2, behind 1]\n M a.swift\nA  b.swift\n?? c.txt\n")
        XCTAssertEqual(status.upstream, "origin/feat/x")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.changedFiles, 2)
        XCTAssertEqual(status.untrackedFiles, 1)
        XCTAssertTrue(status.isDirty)

        status = WorktreeStatus.parse("## docs/y...origin/docs/y [gone]\n")
        XCTAssertTrue(status.upstreamGone)
        XCTAssertFalse(status.isDirty)

        status = WorktreeStatus.parse("## HEAD (no branch)\n")
        XCTAssertNil(status.upstream)
        XCTAssertEqual(status.ahead, 0)
    }

    func testInfersOwnerFromPathThenBranch() {
        XCTAssertEqual(WorktreeOwner.infer(path: "/Users/a/.codex/worktrees/x/app", branch: "feat", isMain: false), .codex)
        XCTAssertEqual(WorktreeOwner.infer(path: "/Users/a/app/.claude/worktrees/x", branch: "feat", isMain: false), .claude)
        XCTAssertEqual(WorktreeOwner.infer(path: "/private/tmp/claude-501/p/s/scratchpad/wt", branch: nil, isMain: false), .claude)
        XCTAssertEqual(WorktreeOwner.infer(path: "/Users/a/.t3/worktrees/app/x", branch: nil, isMain: false), .t3)
        XCTAssertEqual(WorktreeOwner.infer(path: "/private/tmp/app-fix", branch: "codex/fix", isMain: false), .codex)
        XCTAssertEqual(WorktreeOwner.infer(path: "/private/tmp/review", branch: nil, isMain: false), .other)
        XCTAssertEqual(WorktreeOwner.infer(path: "/Users/a/.codex/worktrees/x/app", branch: "main", isMain: true), .main)
    }

    func testSessionGoesToMostSpecificWorktree() {
        var nested = CodexSession(id: "nested", agent: .claude)
        nested.projectPath = "/demo/app/.claude/worktrees/x/sub"
        nested.phase = .running
        nested.lastActivity = Date()
        var root = CodexSession(id: "root")
        root.projectPath = "/demo/app"
        root.phase = .completed
        let index = SessionIndex([nested, root], now: Date())
        let assigned = index.assign(to: ["/demo/app", "/demo/app/.claude/worktrees/x", "/demo/app-other"])
        XCTAssertEqual(assigned[0]?.map(\.identity), ["codex:root"])
        XCTAssertEqual(assigned[1]?.map(\.identity), ["claude:nested"])
        XCTAssertEqual(assigned[1]?.first?.active, true)
        XCTAssertNil(assigned[2])
    }

    func testFinishedRequiresCleanMergedAndIdle() {
        var worktree = AgentWorktree(entry: WorktreeEntry(path: "/demo/wt"), owner: .codex, isMain: false)
        worktree.status = WorktreeStatus()
        worktree.mergedIntoDefault = true
        XCTAssertTrue(worktree.looksFinished)
        worktree.activeSessions = 1
        XCTAssertFalse(worktree.looksFinished)
        worktree.activeSessions = 0
        worktree.status?.untrackedFiles = 1
        XCTAssertFalse(worktree.looksFinished)
        worktree.status = WorktreeStatus()
        worktree.mergedIntoDefault = false
        XCTAssertFalse(worktree.looksFinished)
        worktree.status?.upstreamGone = true
        XCTAssertTrue(worktree.looksFinished)
    }

    // MARK: - Real git

    private func git(_ arguments: String..., in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    func testScansRealRepositoryAndPrunesMissingFolders() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main", in: repo)
        try "a".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git("add", ".", in: repo)
        try git("commit", "-q", "-m", "init", in: repo)

        let agentRoot = base.appendingPathComponent("home/.codex/worktrees")
        let merged = agentRoot.appendingPathComponent("done/app")
        let dirty = agentRoot.appendingPathComponent("work/app")
        let removed = base.appendingPathComponent("gone")
        try git("worktree", "add", "-q", "-b", "codex/done", merged.path, in: repo)
        try git("worktree", "add", "-q", "-b", "codex/work", dirty.path, in: repo)
        try git("worktree", "add", "-q", "-b", "feat/gone", removed.path, in: repo)
        try "changed".write(to: dirty.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: removed)

        var session = CodexSession(id: "s", agent: .codex)
        session.projectPath = dirty.path
        session.phase = .running
        session.lastActivity = Date()

        let scanner = WorktreeScanner()
        let snapshot = await scanner.scan(sessions: [session], roots: [agentRoot])
        XCTAssertNil(snapshot.issue)
        XCTAssertEqual(snapshot.repositories.count, 1)
        let repository = try XCTUnwrap(snapshot.repositories.first)
        XCTAssertEqual(repository.defaultBranch, "main")
        XCTAssertEqual(repository.linked.count, 3)
        let byBranch = Dictionary(uniqueKeysWithValues: repository.linked.map { ($0.entry.branch ?? "", $0) })
        XCTAssertEqual(byBranch["codex/done"]?.owner, .codex)
        XCTAssertEqual(byBranch["codex/done"]?.mergedIntoDefault, true)
        XCTAssertEqual(byBranch["codex/done"]?.looksFinished, true)
        XCTAssertEqual(byBranch["codex/work"]?.status?.changedFiles, 1)
        XCTAssertEqual(byBranch["codex/work"]?.activeSessions, 1)
        XCTAssertEqual(byBranch["feat/gone"]?.entry.isPrunable, true)
        XCTAssertNotNil(byBranch["codex/done"]?.lastActivity)

        let preview = await scanner.prunePreview(commonDir: repository.commonDir)
        XCTAssertEqual(preview.count, 1)
        let pruned = await scanner.prune(commonDir: repository.commonDir)
        XCTAssertTrue(pruned)
        let after = await scanner.scan(sessions: [session], roots: [agentRoot])
        XCTAssertEqual(after.repositories.first?.linked.count, 2)
        XCTAssertEqual(after.prunableCount, 0)
        // Prune never touches checkouts that still exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirty.appendingPathComponent("a.txt").path))

        let sizes = await scanner.diskUsage(paths: [merged.path])
        XCTAssertGreaterThan(sizes[merged.path] ?? 0, 0)
    }
}
