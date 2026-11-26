import Foundation

/// Runs read-only git commands with a timeout. Optional locks are disabled so `git status`
/// never writes the index of a worktree an agent may be using at the same moment.
public struct GitRunner: Sendable {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var timedOut: Bool
    }

    public var executable: String
    public var timeout: TimeInterval

    public init(executable: String = "/usr/bin/git", timeout: TimeInterval = 10) {
        self.executable = executable
        self.timeout = timeout
    }

    /// `includeErrors` merges stderr into the output (git writes `worktree prune --verbose` there).
    public func run(_ arguments: [String], includeErrors: Bool = false) async -> Result {
        await Self.execute(executable, arguments, timeout: timeout, includeErrors: includeErrors, environment: [
            "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C",
        ])
    }

    static func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                        includeErrors: Bool = false, environment: [String: String] = [:]) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment { env[key] = value }
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = includeErrors ? pipe : FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: Result(status: -1, output: "", timedOut: false)); return
                }
                let timedOut = Flag()
                let watchdog = DispatchWorkItem { timedOut.set(); process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: Result(status: process.terminationStatus,
                                                      output: String(decoding: data, as: UTF8.self), timedOut: timedOut.value))
            }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.lock(); raised = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}

/// Finds git worktrees of repositories that agents work in. Everything here is read-only;
/// `prune` is a separate, explicit call.
public actor WorktreeScanner {
    private let git: GitRunner
    private let fileManager = FileManager.default
    private struct Discovery { var commonDir: String?; var checkedAt: Date }
    /// Seed folder → shared git directory, so unchanged seeds cost no git call on later scans.
    private var commonDirs: [String: Discovery] = [:]
    /// A folder found outside any repository is retried after this long (it may be `git init`ed later).
    public static let negativeDiscoveryLifetime: TimeInterval = 300

    public init(git: GitRunner = GitRunner()) { self.git = git }

    /// Directories where agents create worktrees, each scanned two levels deep for checkouts.
    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [".codex/worktrees", ".t3/worktrees", ".cursor/worktrees", ".claude/worktrees"]
            .map { home.appendingPathComponent($0) }
    }

    public func scan(sessions: [CodexSession], roots: [URL] = WorktreeScanner.defaultRoots(),
                     extraSeeds: [String] = [], now: Date = Date()) async -> WorktreeSnapshot {
        var seeds = Set(sessions.compactMap(\.projectPath).filter { !$0.isEmpty })
        seeds.formUnion(extraSeeds)
        for root in roots { seeds.formUnion(checkouts(below: root, depth: 2)) }

        var repositories: [String: Bool] = [:]
        for seed in seeds.sorted() {
            guard let common = await commonDir(for: seed, now: now) else { continue }
            repositories[common] = true
        }

        let sessionIndex = SessionIndex(sessions, now: now)
        var result: [WorktreeRepository] = []
        for common in repositories.keys.sorted() {
            result.append(await scanRepository(commonDir: common, sessions: sessionIndex))
        }
        result.sort { lhs, rhs in
            if lhs.linked.count != rhs.linked.count { return lhs.linked.count > rhs.linked.count }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let failed = result.filter { $0.issue != nil }.count
        return WorktreeSnapshot(repositories: result, updatedAt: now,
                                issue: failed > 0 ? "\(failed) repositor\(failed == 1 ? "y" : "ies") could not be read." : nil)
    }

    /// What a prune would do: git's dry-run list, plus records whose HEAD is the only reference to its commits.
    public func prunePlan(commonDir: String) async -> PrunePlan {
        PrunePlan(records: await prunePreview(commonDir: commonDir),
                  unreferenced: await unreferencedHeads(commonDir: commonDir))
    }

    /// Prunable records whose HEAD commit is not contained in any branch, tag or remote ref. Pruning such a record
    /// drops the last reference, and a later `git gc` may delete those commits.
    public func unreferencedHeads(commonDir: String) async -> [UnreferencedHead] {
        let list = await git.run(["--git-dir=\(commonDir)", "worktree", "list", "--porcelain"])
        guard list.status == 0 else { return [] }
        var result: [UnreferencedHead] = []
        for entry in WorktreeEntry.parse(porcelain: list.output) where entry.isPrunable && !entry.isLocked {
            guard let head = entry.head, !head.allSatisfy({ $0 == "0" }) else { continue }
            let refs = await git.run(["--git-dir=\(commonDir)", "for-each-ref", "--contains", head,
                                      "--count=1", "--format=%(refname)"])
            // Unknown (failed) is treated as unreferenced: the safe answer is to offer a branch.
            if refs.status == 0, !refs.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            result.append(UnreferencedHead(path: entry.path, head: head, branch: entry.branch))
        }
        return result
    }

    public enum PruneError: LocalizedError, Equatable {
        case unreferencedCommits(Int)
        case branchFailed(String)
        case pruneFailed

        public var errorDescription: String? {
            switch self {
            case .unreferencedCommits(let count):
                return "\(count) missing worktree\(count == 1 ? " holds" : "s hold") the only reference to commits. Nothing was pruned."
            case .branchFailed(let name): return "Recovery branch \(name) could not be created. Nothing was pruned."
            case .pruneFailed: return "git worktree prune failed."
            }
        }
    }

    /// Creates recovery branches for `saving`, then prunes — but only if no record would still be the last
    /// reference to its commits (re-checked right before pruning). Returns the branches created.
    public func prune(commonDir: String, saving: [UnreferencedHead]) async throws -> [String] {
        var created: [String] = []
        for item in saving {
            let name = await availableBranchName(commonDir: commonDir, base: item.suggestedBranch)
            let result = await git.run(["--git-dir=\(commonDir)", "branch", name, item.head])
            guard result.status == 0 else { throw PruneError.branchFailed(name) }
            created.append(name)
        }
        let remaining = await unreferencedHeads(commonDir: commonDir)
        guard remaining.isEmpty else { throw PruneError.unreferencedCommits(remaining.count) }
        guard await git.run(["--git-dir=\(commonDir)", "worktree", "prune", "--verbose"]).status == 0 else {
            throw PruneError.pruneFailed
        }
        return created
    }

    private func availableBranchName(commonDir: String, base: String) async -> String {
        for suffix in 0..<50 {
            let name = suffix == 0 ? base : "\(base)-\(suffix + 1)"
            let exists = await git.run(["--git-dir=\(commonDir)", "rev-parse", "--verify", "--quiet", "refs/heads/\(name)"])
            if exists.status != 0 { return name }
        }
        return "\(base)-\(UUID().uuidString.prefix(8))"
    }

    /// Shows what `git worktree prune` would remove, without removing anything.
    public func prunePreview(commonDir: String) async -> [String] {
        let result = await git.run(["--git-dir=\(commonDir)", "worktree", "prune", "--dry-run", "--verbose"], includeErrors: true)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map { line in
            line.hasPrefix("Removing ") ? String(line.dropFirst("Removing ".count)) : String(line)
        }
    }

    /// Disk usage in bytes. `du` can take a while on large dependency folders, so this is on demand only.
    public func diskUsage(paths: [String]) async -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for path in paths where fileManager.fileExists(atPath: path) {
            let result = await GitRunner.execute("/usr/bin/du", ["-sk", path], timeout: 120)
            guard result.status == 0, !result.timedOut,
                  let kib = Int64(result.output.split(separator: "\t").first ?? "") else { continue }
            sizes[path] = kib * 1024
        }
        return sizes
    }

    // MARK: - Discovery

    private func checkouts(below root: URL, depth: Int) -> [String] {
        guard depth > 0, let children = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [String] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if fileManager.fileExists(atPath: child.appendingPathComponent(".git").path) {
                found.append(child.path)
            } else {
                found += checkouts(below: child, depth: depth - 1)
            }
        }
        return found
    }

    /// Forgets repository discovery so the next scan re-resolves every folder (manual refresh).
    public func forgetDiscovery() { commonDirs.removeAll() }

    private func commonDir(for seed: String, now: Date) async -> String? {
        if let cached = commonDirs[seed] {
            if let common = cached.commonDir, fileManager.fileExists(atPath: common) { return common }
            // A negative result expires so a later `git init` is noticed; a vanished repository is re-resolved.
            if cached.commonDir == nil, now.timeIntervalSince(cached.checkedAt) < Self.negativeDiscoveryLifetime { return nil }
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: seed, isDirectory: &isDirectory), isDirectory.boolValue else {
            commonDirs[seed] = nil
            return nil
        }
        let result = await git.run(["-C", seed, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        let value = result.status == 0 ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let common = value.isEmpty ? nil : URL(fileURLWithPath: value).standardizedFileURL.path
        commonDirs[seed] = Discovery(commonDir: common, checkedAt: now)
        return common
    }

    // MARK: - Repository

    private func scanRepository(commonDir: String, sessions: SessionIndex) async -> WorktreeRepository {
        let list = await git.run(["--git-dir=\(commonDir)", "worktree", "list", "--porcelain"])
        let fallbackMain = URL(fileURLWithPath: commonDir).lastPathComponent == ".git"
            ? URL(fileURLWithPath: commonDir).deletingLastPathComponent().path : commonDir
        guard list.status == 0, !list.timedOut else {
            return WorktreeRepository(commonDir: commonDir, mainPath: fallbackMain, issue: "git worktree list failed")
        }
        let entries = WorktreeEntry.parse(porcelain: list.output)
        let mainPath = entries.first?.path ?? fallbackMain
        let defaultBranch = await defaultBranch(commonDir: commonDir)

        var worktrees: [AgentWorktree] = []
        await withTaskGroup(of: (Int, AgentWorktree).self) { group in
            var next = 0
            func add() {
                guard next < entries.count else { return }
                let index = next, entry = entries[index]
                next += 1
                group.addTask { [self] in
                    (index, await self.inspect(entry, isMain: index == 0, commonDir: commonDir, defaultBranch: defaultBranch))
                }
            }
            for _ in 0..<min(4, entries.count) { add() }
            var collected: [(Int, AgentWorktree)] = []
            for await item in group { collected.append(item); add() }
            worktrees = collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // A session in <main>/.claude/worktrees/x belongs to that worktree, not to the main checkout.
        for (index, linked) in sessions.assign(to: worktrees.map(\.path)) {
            worktrees[index].sessionIdentities = linked.map(\.identity)
            worktrees[index].activeSessions = linked.filter { $0.active }.count
        }
        return WorktreeRepository(commonDir: commonDir, mainPath: mainPath, defaultBranch: defaultBranch, worktrees: worktrees)
    }

    private func defaultBranch(commonDir: String) async -> String? {
        let remote = await git.run(["--git-dir=\(commonDir)", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        let name = remote.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if remote.status == 0, !name.isEmpty { return name }
        for candidate in ["main", "master", "develop"] {
            let check = await git.run(["--git-dir=\(commonDir)", "rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"])
            if check.status == 0 { return candidate }
        }
        return nil
    }

    private func inspect(_ entry: WorktreeEntry, isMain: Bool, commonDir: String, defaultBranch: String?) async -> AgentWorktree {
        var worktree = AgentWorktree(entry: entry, owner: .infer(path: entry.path, branch: entry.branch, isMain: isMain), isMain: isMain)
        guard !entry.isBare, !entry.isPrunable, fileManager.fileExists(atPath: entry.path) else { return worktree }

        let status = await git.run(["-C", entry.path, "status", "--porcelain=v1", "--branch", "--untracked-files=normal"])
        if status.status == 0 { worktree.status = WorktreeStatus.parse(status.output) }
        else { worktree.issue = status.timedOut ? "git status timed out" : "git status failed" }

        let log = await git.run(["-C", entry.path, "log", "-1", "--format=%ct"])
        if let seconds = TimeInterval(log.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            worktree.lastCommitAt = Date(timeIntervalSince1970: seconds)
        }
        if let head = entry.head, let defaultBranch, !isMain {
            let merged = await git.run(["-C", entry.path, "merge-base", "--is-ancestor", head, defaultBranch])
            if merged.status == 0 { worktree.mergedIntoDefault = true }
            else if merged.status == 1 { worktree.mergedIntoDefault = false }
        }
        worktree.lastTouchedAt = indexModified(path: entry.path, commonDir: commonDir, isMain: isMain)
        return worktree
    }

    private func indexModified(path: String, commonDir: String, isMain: Bool) -> Date? {
        var gitDir = commonDir
        if !isMain {
            // A linked worktree's .git is a file: "gitdir: <common>/worktrees/<id>".
            guard let text = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
                  let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
            gitDir = String(line.dropFirst("gitdir: ".count))
        }
        let attributes = try? fileManager.attributesOfItem(atPath: gitDir + "/index")
        return attributes?[.modificationDate] as? Date
    }
}

/// Matches observed sessions to worktree folders (also when a session ran in a subfolder).
struct SessionIndex {
    struct Item { var identity: String; var path: String; var active: Bool }
    private let items: [Item]

    init(_ sessions: [CodexSession], now: Date) {
        items = sessions.compactMap { session in
            guard let path = session.projectPath, !path.isEmpty else { return nil }
            let phase = session.displayPhase(at: now)
            return Item(identity: session.identity, path: Self.normalize(path), active: phase == .running || phase == .attention)
        }
    }

    /// Each session goes to the most specific worktree containing its folder.
    func assign(to worktrees: [String]) -> [Int: [Item]] {
        let roots = worktrees.map(Self.normalize)
        var result: [Int: [Item]] = [:]
        for item in items {
            let match = roots.indices
                .filter { item.path == roots[$0] || item.path.hasPrefix(roots[$0] + "/") }
                .max { roots[$0].count < roots[$1].count }
            if let match { result[match, default: []].append(item) }
        }
        return result
    }

    static func normalize(_ path: String) -> String {
        var value = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if value.hasPrefix("/private/") { value = String(value.dropFirst("/private".count)) }
        return value
    }
}
