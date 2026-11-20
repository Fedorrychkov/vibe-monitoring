import Foundation
import XCTest
@testable import VibeMonitoringCore

final class ScannerTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sessions/2026/01/01"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func record(_ type: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-01-01T12:00:00Z",
                                                               "type": type, "payload": payload])
        data.append(10)
        return data
    }

    var journal: URL { directory.appendingPathComponent("sessions/2026/01/01/sample.jsonl") }

    func testPartialAppendsAreNotReadUntilTheLineIsComplete() async throws {
        var data = try record("session_meta", ["id": "sample", "cwd": "/demo/project"])
        data.append(try record("event_msg", ["type": "task_started", "turn_id": "first"]))
        try data.write(to: journal)
        let scanner = CodexScanner()
        let first = await scanner.scan(home: directory)
        XCTAssertEqual(first.sessions.first?.phase, .running)

        let completed = try record("event_msg", ["type": "task_complete", "turn_id": "first"])
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: completed.dropLast())
        let partial = await scanner.scan(home: directory)
        XCTAssertEqual(partial.sessions.first?.phase, .running)
        try handle.write(contentsOf: Data([10]))
        try handle.close()
        let finished = await scanner.scan(home: directory)
        XCTAssertEqual(finished.sessions.first?.phase, .completed)
    }

    func testBoundedTailStillReadsHeaderAndLastUsage() async throws {
        var data = try record("session_meta", ["id": "sample", "cwd": "/demo/project"])
        data.append(try record("response_item", ["ignored": String(repeating: "x", count: 12_000)]))
        data.append(try record("event_msg", ["type": "task_complete", "turn_id": "first"]))
        data.append(try record("event_msg", ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 42]]]))
        try data.write(to: journal)
        let snapshot = await CodexScanner(tailBytes: 1024).scan(home: directory)
        XCTAssertEqual(snapshot.sessions.first?.projectName, "project")
        XCTAssertEqual(snapshot.sessions.first?.phase, .completed)
        XCTAssertEqual(snapshot.sessions.first?.usage?.total, 42)
        XCTAssertEqual(snapshot.sessions.first?.isPartialHistory, true)
    }

    func testTruncatedOrAtomicallyReplacedFileIsReadAgain() async throws {
        try record("event_msg", ["type": "task_started", "turn_id": "long-first-turn"]).write(to: journal)
        let scanner = CodexScanner()
        _ = await scanner.scan(home: directory)
        try record("event_msg", ["type": "task_complete", "turn_id": "x"]).write(to: journal, options: .atomic)
        let snapshot = await scanner.scan(home: directory)
        XCTAssertEqual(snapshot.sessions.first?.phase, .completed)
    }

    func testSymlinkedJournalsAreNotRead() async throws {
        let outside = directory.appendingPathComponent("outside.jsonl")
        try record("session_meta", ["id": "outside"]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: outside)
        let snapshot = await CodexScanner().scan(home: directory)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testFramerRecoversAfterOversizedRecord() {
        var framer = LineFramer(maximumLineBytes: 8)
        var lines: [String] = []
        framer.consume(Data("123456789\nnext".utf8)) { lines.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertTrue(lines.isEmpty)
        framer.consume(Data("\nlast\n".utf8)) { lines.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(lines, ["next", "last"])
    }

    func testMissingHomeIsReportedWithoutReadingOtherDirectories() async {
        let snapshot = await CodexScanner().scan(home: directory.appendingPathComponent("missing"))
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertNotNil(snapshot.issue)
    }
}
