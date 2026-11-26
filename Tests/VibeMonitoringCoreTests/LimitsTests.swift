import Foundation
import XCTest
@testable import VibeMonitoringCore

final class LimitsTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private let statusLineInput = """
    {"session_id":"s","cwd":"/demo","model":{"id":"example"},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1800000000},"seven_day":{"used_percentage":12,"resets_at":1800500000}}}
    """

    func testParsesClaudeStatusLineLimits() throws {
        let report = try XCTUnwrap(AgentLimits.claude(statusLine: Data(statusLineInput.utf8), observedAt: nil))
        XCTAssertEqual(report.windows.count, 2)
        XCTAssertEqual(report.windows[0].usedPercent, 42.5)
        XCTAssertEqual(report.windows[0].title, "5h window")
        XCTAssertEqual(report.windows[0].resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(report.windows[1].title, "Weekly window")
        XCTAssertNil(AgentLimits.claude(statusLine: Data(#"{"session_id":"s"}"#.utf8), observedAt: nil))
    }

    func testCodexUsesMostRecentReport() {
        var old = CodexSession(id: "old")
        old.primaryWindow = UsageWindow(usedPercent: 90, minutes: 300)
        old.limitsObservedAt = Date(timeIntervalSince1970: 100)
        var new = CodexSession(id: "new")
        new.primaryWindow = UsageWindow(usedPercent: 10, minutes: 10_080)
        new.limitsObservedAt = Date(timeIntervalSince1970: 200)
        new.plan = "plus"
        var claude = CodexSession(id: "c", agent: .claude)
        claude.primaryWindow = UsageWindow(usedPercent: 99)
        claude.limitsObservedAt = Date(timeIntervalSince1970: 300)
        let report = AgentLimits.codex(from: [old, new, claude])
        XCTAssertEqual(report?.windows.first?.usedPercent, 10)
        XCTAssertEqual(report?.plan, "plus")
        XCTAssertNil(AgentLimits.codex(from: [claude]))
    }

    private func bridge() -> ClaudeStatusLineBridge {
        ClaudeStatusLineBridge(claudeHome: directory.appendingPathComponent("claude"),
                               supportDirectory: directory.appendingPathComponent("support dir"))
    }

    private func settings(_ bridge: ClaudeStatusLineBridge) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bridge.settingsURL)) as? [String: Any])
    }

    private func runScript(_ bridge: ClaudeStatusLineBridge, input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", bridge.command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output, as: UTF8.self)
    }

    func testBridgeChainsExistingStatusLineAndRestoresIt() throws {
        let bridge = bridge()
        try FileManager.default.createDirectory(at: bridge.claudeHome, withIntermediateDirectories: true)
        let original: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "true"]]]]],
            "statusLine": ["type": "command", "command": "cat >/dev/null; echo 'my line'", "padding": 1],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: bridge.settingsURL)
        XCTAssertEqual(bridge.existingCommand(), "cat >/dev/null; echo 'my line'")

        try bridge.install()
        XCTAssertTrue(bridge.isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.backupURL.path))
        let installed = try settings(bridge)
        XCTAssertNotNil(installed["hooks"])
        XCTAssertEqual((installed["statusLine"] as? [String: Any])?["padding"] as? Int, 1)

        // The user's status line output is unchanged and the limits are saved.
        XCTAssertEqual(try runScript(bridge, input: statusLineInput), "my line\n")
        XCTAssertEqual(bridge.latestReport()?.windows.first?.usedPercent, 42.5)
        let mode = try FileManager.default.attributesOfItem(atPath: bridge.reportURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        // Input without limits does not overwrite the last good report.
        _ = try runScript(bridge, input: #"{"session_id":"api-key"}"#)
        XCTAssertEqual(bridge.latestReport()?.windows.first?.usedPercent, 42.5)

        try bridge.uninstall()
        XCTAssertFalse(bridge.isInstalled)
        let restored = try settings(bridge)
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "cat >/dev/null; echo 'my line'")
        XCTAssertNotNil(restored["hooks"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.scriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.reportURL.path))
    }

    func testBridgeWithoutPreviousStatusLineRemovesEntryOnUninstall() throws {
        let bridge = bridge()
        try bridge.install()
        XCTAssertEqual(try runScript(bridge, input: statusLineInput), "")
        XCTAssertNotNil(bridge.latestReport())
        try bridge.uninstall()
        XCTAssertNil(try settings(bridge)["statusLine"])
    }

    func testBridgeKeepsSymlinkedSettingsAndRejectsInvalidJSON() throws {
        let bridge = bridge()
        try FileManager.default.createDirectory(at: bridge.claudeHome, withIntermediateDirectories: true)
        let real = directory.appendingPathComponent("dotfiles-settings.json")
        try #"{"theme":"dark"}"#.write(to: real, atomically: true, encoding: .utf8)
        let link = bridge.claudeHome.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try bridge.install()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("statusLine"))

        try "{ not json".write(to: real, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try bridge.uninstall())
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "{ not json")
    }

    func testParallelClaudeSessionsDoNotCollide() throws {
        let bridge = bridge()
        try bridge.install()
        // Two concurrent writers, like two Claude Code sessions refreshing their status lines.
        let script = """
        for i in $(seq 1 60); do printf '%s' "$1" | \(bridge.command) || echo FAIL; done
        """
        let processes = try (0..<2).map { _ -> (Process, Pipe) in
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script, "sh", statusLineInput]
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            return (process, pipe)
        }
        for (process, pipe) in processes {
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(text, "", "no mv errors or failures")
            XCTAssertEqual(process.terminationStatus, 0)
        }
        XCTAssertEqual(bridge.latestReport()?.windows.first?.usedPercent, 42.5)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bridge.supportDirectory.path)
            .filter { $0.hasPrefix(".claude-statusline.") }
        XCTAssertEqual(leftovers, [])
    }

    func testOutdatedBridgeScriptIsRewritten() throws {
        let bridge = bridge()
        try bridge.install()
        try "#!/bin/sh\nold\n".write(to: bridge.scriptURL, atomically: true, encoding: .utf8)
        bridge.updateScriptIfInstalled()
        XCTAssertEqual(try String(contentsOf: bridge.scriptURL, encoding: .utf8), bridge.script)
    }
}
