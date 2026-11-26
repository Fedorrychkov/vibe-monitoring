import Foundation

/// Who most likely created a worktree, inferred from its location or branch name.
public enum WorktreeOwner: String, Codable, Sendable, CaseIterable, Identifiable {
    case main, codex, claude, cursor, t3, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .main: return "Main checkout"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .t3: return "T3 Code"
        case .other: return "Other"
        }
    }

    /// Path first (agents use fixed directories), branch prefix as a fallback for worktrees placed elsewhere.
    public static func infer(path: String, branch: String?, isMain: Bool) -> WorktreeOwner {
        if isMain { return .main }
        let lower = path.lowercased()
        if lower.contains("/.codex/worktrees/") { return .codex }
        if lower.contains("/.claude/worktrees/") { return .claude }
        // Claude Code session scratchpads: /private/tmp/claude-<uid>/<project>/<session>/scratchpad/...
        if lower.range(of: #"/tmp/claude-\d+/"#, options: .regularExpression) != nil { return .claude }
        if lower.contains("/.cursor/worktrees/") { return .cursor }
        if lower.contains("/.t3/worktrees/") { return .t3 }
        let name = branch?.lowercased() ?? ""
        if name.hasPrefix("codex/") { return .codex }
        if name.hasPrefix("claude/") || name.hasPrefix("worktree-") { return .claude }
        if name.hasPrefix("cursor/") { return .cursor }
        if name.hasPrefix("t3/") || name.hasPrefix("t3code/") { return .t3 }
        return .other
    }
}

/// One record of `git worktree list --porcelain`.
public struct WorktreeEntry: Equatable, Sendable {
    public var path: String
    public var head: String?
    /// Short branch name (without refs/heads/); nil when detached or bare.
    public var branch: String?
    public var isDetached = false
    public var isBare = false
    public var lockedReason: String?
    public var isLocked = false
    public var prunableReason: String?
    public var isPrunable = false

    public init(path: String) { self.path = path }

    /// Parses porcelain output. The first record is the main worktree.
    public static func parse(porcelain text: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        func flush() { if let current { entries.append(current) }; current = nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { flush(); continue }
            let (key, value) = split(line)
            switch key {
            case "worktree": flush(); current = WorktreeEntry(path: value ?? "")
            case "HEAD": current?.head = value
            case "branch":
                guard let value else { break }
                current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
            case "detached": current?.isDetached = true
            case "bare": current?.isBare = true
            case "locked": current?.isLocked = true; current?.lockedReason = value
            case "prunable": current?.isPrunable = true; current?.prunableReason = value
            default: break
            }
        }
        flush()
        return entries.filter { !$0.path.isEmpty }
    }

    private static func split(_ line: String) -> (String, String?) {
        guard let space = line.firstIndex(of: " ") else { return (line, nil) }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}

/// Parsed `git status --porcelain=v1 --branch` output.
public struct WorktreeStatus: Equatable, Sendable {
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    /// The configured upstream branch no longer exists (often: merged and deleted on the remote).
    public var upstreamGone = false
    public var changedFiles = 0
    public var untrackedFiles = 0

    public init() {}

    public var isDirty: Bool { changedFiles + untrackedFiles > 0 }

    public static func parse(_ text: String) -> WorktreeStatus {
        var status = WorktreeStatus()
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("## ") {
                status.parseBranchLine(String(line.dropFirst(3)))
            } else if line.hasPrefix("??") {
                status.untrackedFiles += 1
            } else if line.count >= 2, !line.hasPrefix("!!") {
                status.changedFiles += 1
            }
        }
        return status
    }

    private mutating func parseBranchLine(_ line: String) {
        // Forms: "main...origin/main [ahead 1, behind 2]", "main", "HEAD (no branch)", "No commits yet on x".
        var rest = line
        var tracking: String?
        if let bracket = rest.range(of: " [", options: .backwards), rest.hasSuffix("]") {
            tracking = String(rest[bracket.upperBound..<rest.index(before: rest.endIndex)])
            rest = String(rest[..<bracket.lowerBound])
        }
        if let dots = rest.range(of: "...") { upstream = String(rest[dots.upperBound...]) }
        guard let tracking else { return }
        for part in tracking.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part == "gone" { upstreamGone = true }
            else if part.hasPrefix("ahead "), let n = Int(part.dropFirst(6)) { ahead = n }
            else if part.hasPrefix("behind "), let n = Int(part.dropFirst(7)) { behind = n }
        }
    }
}

public struct AgentWorktree: Identifiable, Sendable {
    public var entry: WorktreeEntry
    public var owner: WorktreeOwner
    public var isMain: Bool
    /// Only set for worktrees present on disk; prunable records have no status.
    public var status: WorktreeStatus?
    /// Whether HEAD is contained in the repository's default branch. nil when unknown.
    public var mergedIntoDefault: Bool?
    public var lastCommitAt: Date?
    /// Last time git touched this worktree's index (checkout, add, commit, status refresh by tools).
    public var lastTouchedAt: Date?
    /// Identities of observed agent sessions whose project folder is this worktree.
    public var sessionIdentities: [String] = []
    public var activeSessions = 0
    public var issue: String?

    public init(entry: WorktreeEntry, owner: WorktreeOwner, isMain: Bool) {
        self.entry = entry
        self.owner = owner
        self.isMain = isMain
    }

    public var id: String { entry.path }
    public var path: String { entry.path }
    public var name: String { URL(fileURLWithPath: entry.path).lastPathComponent }
    public var branchTitle: String {
        if let branch = entry.branch { return branch }
        if entry.isBare { return "bare" }
        if let head = entry.head { return "detached @ \(head.prefix(8))" }
        return "detached"
    }

    public var lastActivity: Date? {
        [lastCommitAt, lastTouchedAt].compactMap { $0 }.max()
    }

    /// No uncommitted work, no active session and HEAD already contained in the default branch.
    /// A deleted upstream alone is not enough: git then reports no ahead count, so unpublished commits are unknown.
    public var looksFinished: Bool {
        guard !isMain, !entry.isPrunable, let status, !status.isDirty, activeSessions == 0,
              mergedIntoDefault == true else { return false }
        return status.upstreamGone || status.upstream == nil || status.ahead == 0
    }
}

/// A missing worktree whose HEAD is the only reference to its commits.
public struct UnreferencedHead: Equatable, Sendable {
    public var path: String
    public var head: String
    public var branch: String?

    public init(path: String, head: String, branch: String? = nil) {
        self.path = path
        self.head = head
        self.branch = branch
    }

    /// e.g. `recovery/orbit-review-42-0123abcd`
    public var suggestedBranch: String {
        let folder = URL(fileURLWithPath: path).lastPathComponent
        let safe = folder.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let trimmed = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return "recovery/\(trimmed.isEmpty ? "worktree" : String(trimmed.prefix(60)))-\(head.prefix(8))"
    }
}

public struct PrunePlan: Sendable {
    public var records: [String]
    public var unreferenced: [UnreferencedHead]

    public init(records: [String], unreferenced: [UnreferencedHead]) {
        self.records = records
        self.unreferenced = unreferenced
    }
}

public struct WorktreeRepository: Identifiable, Sendable {
    /// Absolute path of the shared git directory; stable across worktrees.
    public var commonDir: String
    public var mainPath: String
    public var defaultBranch: String?
    public var worktrees: [AgentWorktree]
    public var issue: String?

    public init(commonDir: String, mainPath: String, defaultBranch: String? = nil,
                worktrees: [AgentWorktree] = [], issue: String? = nil) {
        self.commonDir = commonDir
        self.mainPath = mainPath
        self.defaultBranch = defaultBranch
        self.worktrees = worktrees
        self.issue = issue
    }

    public var id: String { commonDir }
    public var name: String { URL(fileURLWithPath: mainPath).lastPathComponent }
    public var linked: [AgentWorktree] { worktrees.filter { !$0.isMain } }
    public var prunable: [AgentWorktree] { worktrees.filter(\.entry.isPrunable) }
}

public struct WorktreeSnapshot: Sendable {
    public var repositories: [WorktreeRepository]
    public var updatedAt: Date
    public var issue: String?

    public init(repositories: [WorktreeRepository] = [], updatedAt: Date = Date(), issue: String? = nil) {
        self.repositories = repositories
        self.updatedAt = updatedAt
        self.issue = issue
    }

    public var linked: [AgentWorktree] { repositories.flatMap(\.linked) }
    public var prunableCount: Int { repositories.reduce(0) { $0 + $1.prunable.count } }
    public var dirtyCount: Int { linked.filter { $0.status?.isDirty == true }.count }
    public var finishedCount: Int { linked.filter(\.looksFinished).count }
}
