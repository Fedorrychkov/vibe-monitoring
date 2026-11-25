import Foundation
import VibeMonitoringCore

@main
struct ScanCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") {
            print("Usage: vibe-monitoring-scan [--home CODEX_HOME] [--claude-home DIR] [--cursor-home DIR] [--demo]")
            print("Prints aggregate local status counts for Codex, Claude Code and Cursor. No prompts, paths, IDs or credentials are printed.")
            return
        }
        func directory(_ flag: String, _ fallback: URL) -> URL {
            guard let index = arguments.firstIndex(of: flag) else { return fallback }
            guard arguments.indices.contains(index + 1) else {
                fputs("\(flag) requires a directory\n", stderr)
                exit(2)
            }
            return URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath)
        }
        let codexHome = directory("--home", CodexScanner.defaultHome())
        let snapshot: ScanSnapshot
        if arguments.contains("--demo") {
            snapshot = DemoData.snapshot()
        } else {
            let parts = [
                await CodexScanner().scan(home: codexHome),
                await ClaudeScanner(format: ClaudeJournalFormat()).scan(home: directory("--claude-home", ClaudeJournalFormat.defaultHome())),
                await CursorScanner(format: CursorJournalFormat()).scan(home: directory("--cursor-home", CursorJournalFormat.defaultHome())),
            ]
            // An explicit --home keeps reporting a missing Codex directory as an issue.
            snapshot = ScanSnapshot.merged(parts, reportMissing: arguments.contains("--home") ? [.codex] : [])
        }
        let byAgent = Dictionary(grouping: snapshot.sessions, by: \.agent.rawValue).mapValues { sessions -> [String: Any] in
            [
                "sessions": sessions.count,
                "phaseCounts": Dictionary(grouping: sessions, by: { $0.displayPhase().rawValue }).mapValues(\.count),
                "tokenSnapshots": sessions.filter { $0.usage != nil }.count,
            ]
        }
        let counts = Dictionary(grouping: snapshot.sessions, by: { $0.displayPhase().rawValue }).mapValues(\.count)
        let result: [String: Any] = [
            "sessions": snapshot.sessions.count,
            "phaseCounts": counts,
            "agents": byAgent,
            "unavailableAgents": snapshot.unavailable.map(\.rawValue).sorted(),
            "tokenSnapshots": snapshot.sessions.filter { $0.usage != nil }.count,
            "quotaSnapshots": snapshot.sessions.filter { $0.limitsObservedAt != nil }.count,
            "issue": snapshot.issue as Any? ?? NSNull(),
            "demo": arguments.contains("--demo"),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        if snapshot.issue != nil { exit(1) }
    }
}
