import Foundation
import VibeMonitoringCore

@main
struct ScanCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") {
            print("Usage: vibe-monitoring-scan [--home CODEX_HOME] [--demo]")
            print("Prints aggregate local status counts. No prompts, paths, IDs or credentials are printed.")
            return
        }
        var home = CodexScanner.defaultHome()
        if let index = arguments.firstIndex(of: "--home") {
            guard arguments.indices.contains(index + 1) else {
                fputs("--home requires a directory\n", stderr)
                exit(2)
            }
            home = URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath)
        }
        let scanner = CodexScanner()
        let snapshot = arguments.contains("--demo") ? DemoData.snapshot() : await scanner.scan(home: home)
        let counts = Dictionary(grouping: snapshot.sessions, by: { $0.displayPhase().rawValue }).mapValues(\.count)
        let result: [String: Any] = [
            "sessions": snapshot.sessions.count,
            "phaseCounts": counts,
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
