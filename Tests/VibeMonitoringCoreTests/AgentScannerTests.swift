import Foundation
import XCTest
@testable import VibeMonitoringCore

final class AgentScannerTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }

    private func write(_ lines: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.map(line).reduce(Data(), +).write(to: url)
    }

    private func append(_ lines: [[String: Any]], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        for value in lines { try handle.write(contentsOf: line(value)) }
        try handle.close()
    }

    private func user(_ text: Any, at time: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "user", "timestamp": "2026-01-01T12:00:\(time)Z", "cwd": "/demo/billing", "entrypoint": "cli",
         "uuid": UUID().uuidString, "message": ["role": "user", "content": text]].merging(extra) { $1 }
    }

    private func assistant(_ id: String, stop: String?, at time: String, input: Int = 10, output: Int = 5,
                           blocks: [[String: Any]] = [["type": "text", "text": "done"]]) -> [String: Any] {
        var message: [String: Any] = ["id": id, "model": "example-model", "role": "assistant", "content": blocks,
                                      "usage": ["input_tokens": input, "cache_read_input_tokens": 100,
                                                "cache_creation_input_tokens": 20, "output_tokens": output]]
        message["stop_reason"] = stop ?? NSNull()
        return ["type": "assistant", "timestamp": "2026-01-01T12:00:\(time)Z", "cwd": "/demo/billing", "message": message]
    }

    // MARK: Claude Code

    var claudeJournal: URL { directory.appendingPathComponent("projects/-demo-billing/session-1.jsonl") }

    func testClaudeTurnLifecycleUsageAndMetadata() async throws {
        try write([
            ["type": "mode", "mode": "default", "sessionId": "session-1"],
            user("Fix the bug", at: "00"),
            assistant("msg-1", stop: "tool_use", at: "01", blocks: [["type": "tool_use", "name": "Bash"]]),
            user([["type": "tool_result", "content": "ok"]], at: "02"),
        ], to: claudeJournal)
        let scanner = ClaudeScanner(format: ClaudeJournalFormat())
        let first = await scanner.scan(home: directory)
        let running = try XCTUnwrap(first.sessions.first)
        XCTAssertEqual(running.agent, .claude)
        XCTAssertEqual(running.id, "session-1")
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.projectName, "billing")
        XCTAssertEqual(running.model, "example-model")
        XCTAssertEqual(running.origin, "Claude Code · cli")
        XCTAssertEqual(running.usage?.input, 130)
        XCTAssertEqual(running.usage?.cachedInput, 100)

        // Two content blocks of the same API message repeat its usage; they count once.
        try append([
            assistant("msg-2", stop: nil, at: "03", output: 1, blocks: [["type": "thinking"]]),
            assistant("msg-2", stop: "end_turn", at: "05", output: 7),
            ["type": "system", "subtype": "stop_hook_summary", "timestamp": "2026-01-01T12:00:06Z"],
        ], to: claudeJournal)
        let scanned1 = await scanner.scan(home: directory).sessions.first
        let done = try XCTUnwrap(scanned1)
        XCTAssertEqual(done.phase, .completed)
        XCTAssertEqual(done.turnDuration, 5)
        XCTAssertEqual(done.usage?.input, 260)
        XCTAssertEqual(done.usage?.output, 12)
        XCTAssertEqual(done.usage?.total, 272)
        XCTAssertEqual(done.isPartialHistory, false)
    }

    func testClaudeInterruptsQuestionsAndLocalCommands() async throws {
        try write([
            user("Start", at: "00"),
            user([["type": "text", "text": "[Request interrupted by user]"]], at: "01"),
        ], to: claudeJournal)
        let scanner = ClaudeScanner(format: ClaudeJournalFormat())
        let scanned2 = await scanner.scan(home: directory).sessions.first
        XCTAssertEqual(scanned2?.phase, .interrupted)

        try append([user("<command-name>/model</command-name>", at: "02"),
                    user("Caveat", at: "03", extra: ["isMeta": true])], to: claudeJournal)
        let scanned3 = await scanner.scan(home: directory).sessions.first
        XCTAssertEqual(scanned3?.phase, .interrupted)

        try append([user("Plan it", at: "04"),
                    assistant("msg-3", stop: "tool_use", at: "05", blocks: [["type": "tool_use", "name": "AskUserQuestion"]])],
                   to: claudeJournal)
        let scanned4 = await scanner.scan(home: directory).sessions.first
        XCTAssertEqual(scanned4?.phase, .attention)
        try append([user([["type": "tool_result", "content": "answer"]], at: "06")], to: claudeJournal)
        let scanned5 = await scanner.scan(home: directory).sessions.first
        XCTAssertEqual(scanned5?.phase, .running)
    }

    func testClaudeSidechainAndSubagentFilesAreNotSessions() async throws {
        try write([
            user("Main", at: "00"),
            assistant("main", stop: "end_turn", at: "01"),
            assistant("side", stop: "tool_use", at: "02", blocks: [["type": "tool_use", "name": "Bash"]]).merging(["isSidechain": true]) { $1 },
        ], to: claudeJournal)
        try write([user("Sub", at: "00")],
                  to: directory.appendingPathComponent("projects/-demo-billing/session-1/subagents/agent-1.jsonl"))
        let snapshot = await ClaudeScanner(format: ClaudeJournalFormat()).scan(home: directory)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.phase, .completed)
    }

    func testClaudeLongTurnBeforeTailIsRecoveredWithoutDoubleCountingUsage() async throws {
        try write([
            user("Long task", at: "00"),
            assistant("a", stop: "tool_use", at: "01", blocks: [["type": "tool_use", "name": "Bash"]]),
            user([["type": "tool_result", "content": String(repeating: "x", count: 20_000)]], at: "02"),
            assistant("b", stop: "tool_use", at: "03", input: 1, output: 1, blocks: [["type": "tool_use", "name": "Bash"]]),
        ], to: claudeJournal)
        let scanned6 = await ClaudeScanner(format: ClaudeJournalFormat(), tailBytes: 1024).scan(home: directory).sessions.first
        let session = try XCTUnwrap(scanned6)
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(session.isPartialHistory, true)
        XCTAssertNotNil(session.activeTurnID)
        // Only message "b" is inside the tail; the recovered prompt carries no usage.
        XCTAssertEqual(session.usage?.total, 122)
    }

    // MARK: Cursor

    private func cursorFormat(_ path: String? = "/demo/landing") -> CursorJournalFormat {
        CursorJournalFormat(quietPeriod: 20, abandonedAfter: 600, resolveWorkspace: { _ in path })
    }

    private var cursorJournal: URL {
        directory.appendingPathComponent("projects/demo-landing/agent-transcripts/abc/abc.jsonl")
    }

    private func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testCursorStatusIsInferredFromLastRecordAndQuietPeriod() async throws {
        let now = Date()
        try write([["role": "user", "message": ["content": [["type": "text", "text": "Hi"]]]],
                   ["role": "assistant", "message": ["content": [["type": "tool_use", "name": "Shell"]]]]], to: cursorJournal)
        try touch(cursorJournal, now.addingTimeInterval(-30))
        let scanner = CursorScanner(format: cursorFormat())
        let scanned7 = await scanner.scan(home: directory, now: now).sessions.first
        let working = try XCTUnwrap(scanned7)
        XCTAssertEqual(working.agent, .cursor)
        XCTAssertEqual(working.phase, .running)
        XCTAssertEqual(working.projectName, "landing")
        XCTAssertNil(working.usage)

        try append([["role": "assistant", "message": ["content": [["type": "text", "text": "Done"]]]]], to: cursorJournal)
        try touch(cursorJournal, now.addingTimeInterval(-5))
        let scanned8 = await scanner.scan(home: directory, now: now).sessions.first
        XCTAssertEqual(scanned8?.phase, .running)
        // Unchanged file, later scan: the quiet period has passed.
        let scanned9 = await scanner.scan(home: directory, now: now.addingTimeInterval(30)).sessions.first
        XCTAssertEqual(scanned9?.phase, .completed)

        try append([["role": "user", "message": ["content": [["type": "text", "text": "More"]]]]], to: cursorJournal)
        try touch(cursorJournal, now.addingTimeInterval(-700))
        let scanned10 = await scanner.scan(home: directory, now: now).sessions.first
        XCTAssertEqual(scanned10?.phase, .unknown)
    }

    func testCursorTurnEndedMarkerAndPathFilters() async throws {
        try write([["role": "user", "message": ["content": [["type": "text", "text": "Hi"]]]],
                   ["type": "turn_ended", "status": "success"]], to: cursorJournal)
        try write([["role": "user", "message": ["content": []]]],
                  to: directory.appendingPathComponent("projects/demo-landing/agent-transcripts/abc/subagents/s.jsonl"))
        try write([["role": "user", "message": ["content": []]]],
                  to: directory.appendingPathComponent("projects/demo-landing/canvases/c.jsonl"))
        let scanner = CursorScanner(format: cursorFormat(nil))
        let snapshot = await scanner.scan(home: directory)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.phase, .completed)
        XCTAssertEqual(snapshot.sessions.first?.projectName, "landing")

        try append([["role": "user", "message": ["content": [["type": "text", "text": "Again"]]]],
                    ["type": "turn_ended", "status": "aborted"]], to: cursorJournal)
        let scanned11 = await scanner.scan(home: directory).sessions.first
        XCTAssertEqual(scanned11?.phase, .interrupted)
    }

    func testCursorWorkspaceResolutionHandlesDashedNames() throws {
        let root = directory.appendingPathComponent("a-b/c/my-app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoded = root.path.dropFirst().replacingOccurrences(of: "/", with: "-")
        XCTAssertEqual(CursorJournalFormat.resolveWorkspace(encoded), root.path)
        XCTAssertNil(CursorJournalFormat.resolveWorkspace(encoded + "-missing"))
        XCTAssertNil(CursorJournalFormat.resolveWorkspace("a--..-b"))
    }

    // MARK: Merging

    func testMergeHidesMissingAgentsUnlessRequested() async {
        let missing = directory.appendingPathComponent("missing")
        let parts = [await CodexScanner().scan(home: missing),
                     await ClaudeScanner(format: ClaudeJournalFormat()).scan(home: missing),
                     await CursorScanner(format: cursorFormat()).scan(home: missing)]
        let quiet = ScanSnapshot.merged(parts)
        XCTAssertNil(quiet.issue)
        XCTAssertEqual(quiet.unavailable, [.codex, .claude, .cursor])
        XCTAssertNotNil(ScanSnapshot.merged(parts, reportMissing: [.codex]).issue)
        let failure = ScanSnapshot(issue: "Some local journals could not be read.")
        XCTAssertEqual(ScanSnapshot.merged(parts + [failure]).issue, failure.issue)
    }
}
