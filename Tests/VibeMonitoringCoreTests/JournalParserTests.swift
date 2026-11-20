import Foundation
import XCTest
@testable import VibeMonitoringCore

final class JournalParserTests: XCTestCase {
    let parser = JournalParser()

    func apply(_ payload: [String: Any], kind: String = "event_msg", second: Int = 0,
               to session: inout CodexSession) {
        let record: [String: Any] = ["timestamp": String(format: "2026-01-01T12:00:%02dZ", second),
                                     "type": kind, "payload": payload]
        parser.apply(try! JSONSerialization.data(withJSONObject: record), to: &session)
    }

    func testCumulativeUsageSnapshotsAreNotAddedAndReasoningIsNotDoubleCounted() {
        var session = CodexSession(id: "test")
        let counters = ["input_tokens": 100, "cached_input_tokens": 80,
                        "output_tokens": 20, "reasoning_output_tokens": 10, "total_tokens": 120]
        let payload: [String: Any] = ["type": "token_count", "info": ["total_token_usage": counters]]
        apply(payload, to: &session)
        apply(payload, second: 1, to: &session)
        XCTAssertEqual(session.usage?.input, 100)
        XCTAssertEqual(session.usage?.output, 20)
        XCTAssertEqual(session.usage?.total, 120)
        apply(["thread_token_usage": counters], kind: "token_usage_record", second: 2, to: &session)
        XCTAssertEqual(session.usage?.total, 120)
    }

    func testEarlierTurnCompletionDoesNotFinishTheCurrentTurn() {
        var session = CodexSession(id: "test")
        apply(["type": "task_started", "turn_id": "first"], to: &session)
        apply(["type": "task_started", "turn_id": "second"], second: 2, to: &session)
        apply(["type": "task_complete", "turn_id": "first"], second: 3, to: &session)
        XCTAssertEqual(session.phase, .running)
        apply(["type": "task_complete", "turn_id": "second"], second: 4, to: &session)
        XCTAssertEqual(session.phase, .completed)
        apply(["type": "task_started", "turn_id": "first"], second: 1, to: &session)
        XCTAssertEqual(session.phase, .completed)
    }

    func testInterruptedTurnAndStaleActiveTurnAreDistinct() {
        var session = CodexSession(id: "test")
        apply(["type": "task_started", "turn_id": "first"], to: &session)
        let start = session.lastActivity!
        XCTAssertEqual(session.displayPhase(at: start.addingTimeInterval(20)), .running)
        XCTAssertEqual(session.displayPhase(at: start.addingTimeInterval(181)), .stale)
        apply(["type": "turn_aborted", "turn_id": "first"], second: 2, to: &session)
        XCTAssertEqual(session.displayPhase(at: start.addingTimeInterval(999)), .interrupted)
    }

    func testCompletionTimeAndDurationDoNotFollowLaterActivity() {
        var session = CodexSession(id: "test")
        apply(["type": "task_started", "turn_id": "first"], to: &session)
        apply(["type": "task_complete", "turn_id": "first", "duration_ms": 1_500], second: 2, to: &session)
        let completedAt = session.stateChangedAt
        apply(["type": "token_count"], second: 5, to: &session)
        XCTAssertEqual(session.statusTimestamp, completedAt)
        XCTAssertNotEqual(session.statusTimestamp, session.lastActivity)
        XCTAssertEqual(session.turnDuration, 1.5)

        apply(["type": "task_started", "turn_id": "second"], second: 6, to: &session)
        XCTAssertNil(session.turnDuration)
        XCTAssertEqual(session.statusTimestamp, session.lastActivity)
        apply(["type": "task_complete", "turn_id": "first", "duration_ms": 3_000], second: 7, to: &session)
        XCTAssertNil(session.turnDuration)
        XCTAssertEqual(session.phase, .running)
        apply(["type": "turn_aborted", "turn_id": "second", "duration_ms": -1], second: 8, to: &session)
        XCTAssertEqual(session.phase, .interrupted)
        XCTAssertNil(session.turnDuration)
    }

    func testLimitsAndMetadataAreParsedWithoutConversationFields() {
        var session = CodexSession(id: "test")
        apply(["id": "sample", "cwd": "/demo/project", "originator": "Codex CLI",
               "base_instructions": "ignored"], kind: "session_meta", to: &session)
        apply(["model": "example-model", "unrecognized": "ignored"], kind: "turn_context", to: &session)
        apply(["type": "token_count", "rate_limits": ["plan_type": "example",
               "primary": ["used_percent": 37.5, "window_minutes": 300, "resets_at": 1_800_000_000]]], to: &session)
        XCTAssertEqual(session.id, "sample")
        XCTAssertEqual(session.projectName, "project")
        XCTAssertEqual(session.model, "example-model")
        XCTAssertEqual(session.primaryWindow?.usedPercent, 37.5)
        XCTAssertEqual(session.primaryWindow?.title, "5h window")
        XCTAssertNotNil(session.limitsObservedAt)
    }

    func testCorruptAndNegativeUsageDoesNotReplaceValidData() {
        var session = CodexSession(id: "test")
        apply(["type": "token_count", "info": ["total_token_usage": ["total_tokens": 20]]], to: &session)
        parser.apply(Data("{broken".utf8), to: &session)
        apply(["type": "token_count", "info": ["total_token_usage": ["total_tokens": -1]]], second: 1, to: &session)
        XCTAssertEqual(session.usage?.total, 20)
    }
}
