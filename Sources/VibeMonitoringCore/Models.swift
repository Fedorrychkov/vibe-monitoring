import Foundation

public enum SessionPhase: String, Codable, Sendable {
    case running, completed, interrupted, attention, unknown, stale

    public var title: String {
        switch self {
        case .running: return "Active turn"
        case .completed: return "Turn finished"
        case .interrupted: return "Interrupted"
        case .attention: return "Needs attention"
        case .unknown: return "No turn signal"
        case .stale: return "No recent signal"
        }
    }
}

public struct TokenUsage: Equatable, Codable, Sendable {
    public var input: Int64
    public var cachedInput: Int64
    public var cacheWriteInput: Int64
    public var output: Int64
    public var reasoningOutput: Int64
    public var total: Int64

    public init(input: Int64 = 0, cachedInput: Int64 = 0, cacheWriteInput: Int64 = 0,
                output: Int64 = 0, reasoningOutput: Int64 = 0, total: Int64 = 0) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.output = output
        self.reasoningOutput = reasoningOutput
        self.total = total
    }
}

public struct UsageWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let minutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, minutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.minutes = minutes
        self.resetsAt = resetsAt
    }

    public var title: String {
        guard let minutes else { return "Usage window" }
        if minutes == 10_080 { return "Weekly window" }
        if minutes % 60 == 0 { return "\(minutes / 60)h window" }
        return "\(minutes)m window"
    }
}

public enum AgentKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case codex, claude, cursor

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        }
    }
}

/// A locally observed agent session. The name predates Claude Code and Cursor support.
public struct CodexSession: Identifiable, Sendable {
    public var id: String
    public var agent: AgentKind
    /// Shown when no project path is known (e.g. a Cursor folder name that does not resolve on disk).
    public var fallbackName: String?
    public var projectPath: String?
    public var model: String?
    public var origin: String?
    public var phase: SessionPhase = .unknown
    public var activeTurnID: String?
    public var lastActivity: Date?
    public var stateChangedAt: Date?
    public var turnDuration: TimeInterval?
    public var usage: TokenUsage?
    public var usageObservedAt: Date?
    public var contextWindow: Int?
    public var primaryWindow: UsageWindow?
    public var secondaryWindow: UsageWindow?
    public var limitsObservedAt: Date?
    public var plan: String?
    public var isPartialHistory = true

    public init(id: String, agent: AgentKind = .codex) {
        self.id = id
        self.agent = agent
    }

    public var projectName: String {
        guard let projectPath, !projectPath.isEmpty else { return fallbackName ?? "\(agent.title) session" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    public var shortID: String { String(id.prefix(8)) }
    public var identity: String { "\(agent.rawValue):\(id)" }

    public var statusTimestamp: Date? {
        phase == .completed || phase == .interrupted ? stateChangedAt : lastActivity
    }

    public func displayPhase(at now: Date = Date(), staleAfter: TimeInterval = 180) -> SessionPhase {
        guard phase == .running || phase == .attention else { return phase }
        guard let lastActivity, now.timeIntervalSince(lastActivity) <= staleAfter else { return .stale }
        return phase
    }
}

public struct ScanSnapshot: Sendable {
    public var sessions: [CodexSession]
    public var updatedAt: Date
    public var issue: String?
    /// Agents whose journal directory does not exist (not installed or never used).
    public var unavailable: Set<AgentKind>

    public init(sessions: [CodexSession] = [], updatedAt: Date = Date(), issue: String? = nil,
                unavailable: Set<AgentKind> = []) {
        self.sessions = sessions
        self.updatedAt = updatedAt
        self.issue = issue
        self.unavailable = unavailable
    }

    /// Combines per-agent scans. A missing directory for an agent the user does not use is not an issue.
    public static func merged(_ parts: [ScanSnapshot], reportMissing: Set<AgentKind> = []) -> ScanSnapshot {
        var result = ScanSnapshot(updatedAt: parts.map(\.updatedAt).max() ?? Date())
        var issues: [String] = []
        for part in parts {
            result.sessions += part.sessions
            result.unavailable.formUnion(part.unavailable)
            guard let issue = part.issue else { continue }
            if part.unavailable.isDisjoint(with: reportMissing) && !part.unavailable.isEmpty { continue }
            if !issues.contains(issue) { issues.append(issue) }
        }
        result.issue = issues.isEmpty ? nil : issues.joined(separator: " ")
        return result
    }

    public func activeCount(at now: Date = Date()) -> Int {
        sessions.filter { $0.displayPhase(at: now) == .running }.count
    }
}
