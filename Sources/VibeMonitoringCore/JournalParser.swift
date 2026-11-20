import Foundation

public struct JournalParser {
    private let decoder = JSONDecoder()
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    public init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func apply(_ line: Data, to session: inout CodexSession) {
        guard let record = try? decoder.decode(Record.self, from: line) else { return }
        let payload = record.payload
        let date = record.timestamp.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) }

        switch record.type {
        case "session_meta":
            session.id = payload.id ?? payload.sessionID ?? session.id
            session.projectPath = payload.cwd ?? session.projectPath
            session.origin = payload.originator ?? session.origin

        case "turn_context":
            session.model = payload.model ?? session.model
            session.projectPath = payload.cwd ?? session.projectPath

        case "token_usage_record":
            if let counters = payload.threadTokenUsage?.value {
                applyUsage(counters, at: date, to: &session)
            }

        case "event_msg":
            if let date, date > (session.lastActivity ?? .distantPast) {
                session.lastActivity = date
            }
            switch payload.type {
            case "task_started":
                if canChangeState(at: date, in: session) {
                    session.activeTurnID = payload.turnID
                    session.phase = .running
                    session.stateChangedAt = date
                    session.turnDuration = nil
                }
            case "task_complete", "turn_aborted":
                let matchesTurn = session.activeTurnID == nil || payload.turnID == nil
                    || session.activeTurnID == payload.turnID
                if matchesTurn && canChangeState(at: date, in: session) {
                    session.phase = payload.type == "task_complete" ? .completed : .interrupted
                    session.stateChangedAt = date
                    session.turnDuration = payload.durationMilliseconds.flatMap {
                        $0.isFinite && $0 >= 0 ? $0 / 1_000 : nil
                    }
                }
            case "exec_approval_request", "apply_patch_approval_request", "request_user_input", "error":
                if canChangeState(at: date, in: session) {
                    session.phase = .attention
                    session.stateChangedAt = date
                }
            case "token_count":
                if let counters = payload.info?.totalTokenUsage?.value {
                    applyUsage(counters, at: date, to: &session)
                }
                if let window = payload.info?.modelContextWindow, window > 0 {
                    session.contextWindow = window
                }
                if let limits = payload.rateLimits,
                   (date ?? .distantPast) >= (session.limitsObservedAt ?? .distantPast) {
                    session.primaryWindow = limits.primary?.value
                    session.secondaryWindow = limits.secondary?.value
                    session.plan = limits.planType
                    session.limitsObservedAt = date
                }
            default:
                break
            }
        default:
            break
        }
    }

    private func canChangeState(at date: Date?, in session: CodexSession) -> Bool {
        (date ?? .distantPast) >= (session.stateChangedAt ?? .distantPast)
    }

    private func applyUsage(_ counters: TokenUsage, at date: Date?, to session: inout CodexSession) {
        guard (date ?? .distantPast) >= (session.usageObservedAt ?? .distantPast) else { return }
        // Codex reports cumulative snapshots. Adding them would count the same tokens repeatedly.
        session.usage = counters
        session.usageObservedAt = date
    }
}

private struct Record: Decodable {
    let timestamp: String?
    let type: String
    let payload: Payload
}

private struct Payload: Decodable {
    var id: String?
    var sessionID: String?
    var cwd: String?
    var originator: String?
    var model: String?
    var type: String?
    var turnID: String?
    var info: TokenInfo?
    var rateLimits: Limits?
    var threadTokenUsage: Counters?
    var durationMilliseconds: Double?

    enum CodingKeys: String, CodingKey {
        case id, cwd, originator, model, type, info
        case sessionID = "session_id"
        case turnID = "turn_id"
        case rateLimits = "rate_limits"
        case threadTokenUsage = "thread_token_usage"
        case durationMilliseconds = "duration_ms"
    }
}

private struct TokenInfo: Decodable {
    let totalTokenUsage: Counters?
    let modelContextWindow: Int?

    enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
        case modelContextWindow = "model_context_window"
    }
}

private struct Counters: Decodable {
    let input: Int64?
    let cachedInput: Int64?
    let cacheWriteInput: Int64?
    let output: Int64?
    let reasoningOutput: Int64?
    let total: Int64?

    enum CodingKeys: String, CodingKey {
        case input = "input_tokens"
        case cachedInput = "cached_input_tokens"
        case cacheWriteInput = "cache_write_input_tokens"
        case output = "output_tokens"
        case reasoningOutput = "reasoning_output_tokens"
        case total = "total_tokens"
    }

    var value: TokenUsage? {
        let values = [input, cachedInput, cacheWriteInput, output, reasoningOutput, total].compactMap { $0 }
        guard !values.isEmpty, values.allSatisfy({ $0 >= 0 }) else { return nil }
        return TokenUsage(input: input ?? 0, cachedInput: cachedInput ?? 0,
                          cacheWriteInput: cacheWriteInput ?? 0, output: output ?? 0,
                          reasoningOutput: reasoningOutput ?? 0, total: total ?? 0)
    }
}

private struct Limits: Decodable {
    let primary: Window?
    let secondary: Window?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary, secondary
        case planType = "plan_type"
    }
}

private struct Window: Decodable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }

    var value: UsageWindow? {
        guard usedPercent.isFinite, usedPercent >= 0 else { return nil }
        return UsageWindow(usedPercent: usedPercent, minutes: windowMinutes,
                           resetsAt: resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
    }
}
