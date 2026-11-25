import Foundation

// JSONDecoder and ISO8601DateFormatter hold no shared mutable state during decoding; each scanner
// actor serializes its own use.
extension JournalParser: @unchecked Sendable {}

// MARK: - Claude Code

/// Claude Code session transcripts: `~/.claude/projects/<encoded cwd>/<session id>.jsonl`.
/// Subagent transcripts live in nested directories and are not separate sessions.
public struct ClaudeJournalFormat: JournalFormat, @unchecked Sendable {
    public struct State: Sendable {
        var messageID: String?
        var messageUsage = TokenUsage()
        var totals = TokenUsage()
        var turnStartedAt: Date?
    }

    private let decoder = JSONDecoder()
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    public init() { fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }

    public var agent: AgentKind { .claude }
    public func root(home: URL) -> URL { home.appendingPathComponent("projects") }
    public var missingIssue: String { "No Claude Code projects directory." }
    public func includes(_ components: [String]) -> Bool { components.count == 2 }
    public func descends(into components: [String]) -> Bool { components.count < 2 }
    public func makeSession(for file: URL, components: [String]) -> CodexSession {
        CodexSession(id: file.deletingPathExtension().lastPathComponent, agent: .claude)
    }
    public func initialState() -> State { State() }

    public static func defaultHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !home.isEmpty {
            return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    public func turnEvent(in line: Data) -> Bool? {
        guard let record = try? decoder.decode(ClaudeRecord.self, from: line), record.isSidechain != true else { return nil }
        switch classify(record) {
        case .prompt: return true
        case .interrupted, .finished, .needsAttention: return false
        case .activity, .ignored: return nil
        }
    }

    public func apply(_ line: Data, to session: inout CodexSession, state: inout State) {
        guard let record = try? decoder.decode(ClaudeRecord.self, from: line), record.isSidechain != true else { return }
        let date = record.timestamp.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) }
        if let cwd = record.cwd, !cwd.isEmpty { session.projectPath = cwd }
        if let entrypoint = record.entrypoint, !entrypoint.isEmpty { session.origin = "Claude Code · \(entrypoint)" }
        if let date, date > (session.lastActivity ?? .distantPast), record.type == "user" || record.type == "assistant" {
            session.lastActivity = date
        }
        if record.type == "assistant", let message = record.message {
            if let model = message.model, model != "<synthetic>" { session.model = model }
            if let usage = message.usage?.value {
                // Each content block of one API message is a separate line repeating the same usage.
                if let id = message.id, id == state.messageID {
                    state.totals = state.totals.subtracting(state.messageUsage).adding(usage)
                } else {
                    state.totals = state.totals.adding(usage)
                    state.messageID = message.id
                }
                state.messageUsage = usage
                session.usage = state.totals
                session.usageObservedAt = date
            }
        }
        guard (date ?? .distantPast) >= (session.stateChangedAt ?? .distantPast) else { return }
        switch classify(record) {
        case .prompt:
            session.phase = .running
            session.activeTurnID = record.promptId ?? record.uuid
            session.stateChangedAt = date
            session.turnDuration = nil
            state.turnStartedAt = date
        case .activity:
            // A tool loop or a slash-command skill without a recorded prompt still means work is in progress.
            if session.phase != .running {
                session.phase = .running
                session.stateChangedAt = date
                session.turnDuration = nil
            }
        case .finished:
            session.phase = .completed
            session.stateChangedAt = date
            if let start = state.turnStartedAt, let date, date >= start { session.turnDuration = date.timeIntervalSince(start) }
        case .interrupted:
            session.phase = .interrupted
            session.stateChangedAt = date
        case .needsAttention:
            session.phase = .attention
            session.stateChangedAt = date
        case .ignored:
            break
        }
    }

    private enum Kind { case prompt, activity, finished, interrupted, needsAttention, ignored }

    private func classify(_ record: ClaudeRecord) -> Kind {
        switch record.type {
        case "user":
            guard record.isMeta != true, record.isCompactSummary != true, let content = record.message?.content else { return .ignored }
            if content.hasToolResult { return .activity }
            guard let text = content.firstText?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return content.hasImage ? .prompt : .ignored
            }
            if text.hasPrefix("[Request interrupted") { return .interrupted }
            // Local slash commands (/model, /clear …) and their output do not start a model turn.
            if text.hasPrefix("<command-name>") || text.hasPrefix("<local-command") || text.hasPrefix("<command-message>") { return .ignored }
            return .prompt
        case "assistant":
            switch record.message?.stopReason {
            case "end_turn", "stop_sequence": return .finished
            case "max_tokens", "refusal": return .needsAttention
            // These tools wait for the person until their result is recorded.
            case "tool_use" where record.message?.content?.asksUser == true: return .needsAttention
            default: return .activity
            }
        default:
            return .ignored
        }
    }
}

private struct ClaudeRecord: Decodable {
    let type: String
    let timestamp: String?
    let cwd: String?
    let entrypoint: String?
    let uuid: String?
    let promptId: String?
    let isSidechain: Bool?
    let isMeta: Bool?
    let isCompactSummary: Bool?
    let message: ClaudeMessage?
}

private struct ClaudeMessage: Decodable {
    let id: String?
    let model: String?
    let stopReason: String?
    let usage: ClaudeUsage?
    let content: ClaudeContent?

    enum CodingKeys: String, CodingKey {
        case id, model, usage, content
        case stopReason = "stop_reason"
    }
}

private struct ClaudeContent: Decodable {
    private struct Block: Decodable { let type: String?; let text: String?; let name: String? }
    static let userInputTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    let firstText: String?
    let hasToolResult: Bool
    let hasImage: Bool
    let asksUser: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            firstText = text; hasToolResult = false; hasImage = false; asksUser = false
            return
        }
        let blocks = (try? container.decode([Block].self)) ?? []
        firstText = blocks.first { $0.type == "text" }?.text
        hasToolResult = blocks.contains { $0.type == "tool_result" }
        hasImage = blocks.contains { $0.type == "image" }
        asksUser = blocks.contains { $0.type == "tool_use" && Self.userInputTools.contains($0.name ?? "") }
    }
}

private struct ClaudeUsage: Decodable {
    let input: Int64?
    let cacheRead: Int64?
    let cacheCreation: Int64?
    let output: Int64?

    enum CodingKeys: String, CodingKey {
        case input = "input_tokens"
        case cacheRead = "cache_read_input_tokens"
        case cacheCreation = "cache_creation_input_tokens"
        case output = "output_tokens"
    }

    /// Matches the Codex convention: cached and cache-write input are parts of input.
    var value: TokenUsage? {
        let values = [input, cacheRead, cacheCreation, output].compactMap { $0 }
        guard !values.isEmpty, values.allSatisfy({ $0 >= 0 }) else { return nil }
        let read = cacheRead ?? 0, write = cacheCreation ?? 0
        let total = (input ?? 0) + read + write
        return TokenUsage(input: total, cachedInput: read, cacheWriteInput: write,
                          output: output ?? 0, total: total + (output ?? 0))
    }
}

extension TokenUsage {
    func adding(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(input: input + other.input, cachedInput: cachedInput + other.cachedInput,
                   cacheWriteInput: cacheWriteInput + other.cacheWriteInput, output: output + other.output,
                   reasoningOutput: reasoningOutput + other.reasoningOutput, total: total + other.total)
    }

    func subtracting(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(input: input - other.input, cachedInput: cachedInput - other.cachedInput,
                   cacheWriteInput: cacheWriteInput - other.cacheWriteInput, output: output - other.output,
                   reasoningOutput: reasoningOutput - other.reasoningOutput, total: total - other.total)
    }
}

// MARK: - Cursor

/// Cursor agent transcripts: `~/.cursor/projects/<encoded workspace>/agent-transcripts/<id>/<id>.jsonl`.
/// Lines carry only a role and content (no timestamps, model or token counts), so activity comes from
/// the file modification time and the shape of the last record.
public struct CursorJournalFormat: JournalFormat, @unchecked Sendable {
    public struct State: Sendable {
        var last: Last = .none
        enum Last: Sendable { case none, user, toolCall, reply, ended(SessionPhase) }
    }

    /// A reply followed by this much silence counts as a finished turn.
    public let quietPeriod: TimeInterval
    /// Older transcripts have no end marker; an unanswered request this old is not shown as active.
    public let abandonedAfter: TimeInterval
    private let decoder = JSONDecoder()
    private let resolver: @Sendable (String) -> String?

    public init(quietPeriod: TimeInterval = 20, abandonedAfter: TimeInterval = 600,
                resolveWorkspace: @escaping @Sendable (String) -> String? = CursorJournalFormat.resolveWorkspace) {
        self.quietPeriod = quietPeriod
        self.abandonedAfter = abandonedAfter
        resolver = resolveWorkspace
    }

    public var agent: AgentKind { .cursor }
    public func root(home: URL) -> URL { home.appendingPathComponent("projects") }
    public var missingIssue: String { "No Cursor projects directory." }
    public func includes(_ components: [String]) -> Bool {
        components.count >= 3 && components[1] == "agent-transcripts" && !components.contains("subagents")
    }
    public func descends(into components: [String]) -> Bool {
        switch components.count {
        case 1: return true
        case 2: return components[1] == "agent-transcripts"
        case 3: return true
        default: return false
        }
    }
    public func makeSession(for file: URL, components: [String]) -> CodexSession {
        var session = CodexSession(id: file.deletingPathExtension().lastPathComponent, agent: .cursor)
        session.origin = "Cursor agent"
        let folder = components.first ?? ""
        session.projectPath = resolver(folder)
        if session.projectPath == nil, folder.range(of: "^[0-9]+$", options: .regularExpression) == nil {
            session.fallbackName = folder.split(separator: "-").last.map(String.init)
        }
        return session
    }
    public func initialState() -> State { State() }

    public static func defaultHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
    }

    public func apply(_ line: Data, to session: inout CodexSession, state: inout State) {
        guard let record = try? decoder.decode(CursorRecord.self, from: line) else { return }
        if record.type == "turn_ended" {
            let status = record.status?.lowercased() ?? ""
            if status.contains("abort") || status.contains("cancel") || status.contains("interrupt") {
                state.last = .ended(.interrupted)
            } else if status.contains("error") || status.contains("fail") {
                state.last = .ended(.attention)
            } else {
                state.last = .ended(.completed)
            }
            return
        }
        switch record.role {
        case "user": state.last = .user
        case "assistant":
            state.last = record.message?.content?.last?.type == "tool_use" ? .toolCall : .reply
        default: break
        }
    }

    public func refresh(_ session: inout CodexSession, state: State, modified: Date, now: Date) {
        session.lastActivity = modified
        switch state.last {
        case .none:
            session.phase = .unknown
        case .user, .toolCall:
            session.phase = now.timeIntervalSince(modified) < abandonedAfter ? .running : .unknown
            session.stateChangedAt = modified
        case .ended(let phase):
            session.phase = phase
            session.stateChangedAt = modified
        case .reply:
            if now.timeIntervalSince(modified) < quietPeriod {
                session.phase = .running
            } else {
                session.phase = .completed
            }
            session.stateChangedAt = modified
        }
    }

    /// Cursor encodes the workspace path by replacing "/" with "-", which is ambiguous for names that
    /// contain "-". Resolve it against existing directories; nil if no unique existing path matches.
    public static func resolveWorkspace(_ encoded: String) -> String? {
        let tokens = encoded.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !tokens.isEmpty, tokens.count <= 40, !tokens.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let fileManager = FileManager.default
        var budget = 400
        func search(_ index: Int, _ path: String) -> String? {
            if index == tokens.count { return path }
            var component = ""
            for end in index..<tokens.count {
                budget -= 1
                guard budget > 0 else { return nil }
                component += (component.isEmpty ? "" : "-") + tokens[end]
                let candidate = path + "/" + component
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue,
                   let found = search(end + 1, candidate) { return found }
            }
            return nil
        }
        return search(0, "")
    }
}

private struct CursorRecord: Decodable {
    struct Message: Decodable { let content: [Block]? }
    struct Block: Decodable { let type: String? }
    let role: String?
    let type: String?
    let status: String?
    let message: Message?
}

public typealias ClaudeScanner = JournalScanner<ClaudeJournalFormat>
public typealias CursorScanner = JournalScanner<CursorJournalFormat>
