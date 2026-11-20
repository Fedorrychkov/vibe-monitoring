import AppKit
import SwiftUI
import UserNotifications
import VibeMonitoringCore

@MainActor
final class MonitorStore: ObservableObject {
    @Published var snapshot = ScanSnapshot()
    @Published var isRefreshing = false
    @Published var showFinished = true
    @Published var codexHome: String
    @Published var notifyOnFinish: Bool
    @Published var notificationIssue: String?
    let isDemo: Bool
    let quickping: QuickpingStore
    let vpn: VPNStore
    private let scanner = CodexScanner()
    private var polling: Task<Void, Never>?

    init(demo: Bool = false, startPolling: Bool = true) {
        isDemo = demo
        quickping = QuickpingStore(demo: demo)
        vpn = VPNStore(demo: demo)
        codexHome = UserDefaults.standard.string(forKey: "codexHome") ?? CodexScanner.defaultHome().path
        notifyOnFinish = UserDefaults.standard.bool(forKey: "notifyOnFinish")
        if demo { snapshot = DemoData.snapshot() }
        if startPolling {
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    deinit { polling?.cancel() }

    var visibleSessions: [CodexSession] {
        snapshot.sessions.filter { showFinished || $0.displayPhase() != .completed }
            .sorted { lhs, rhs in
                let left = rank(lhs.displayPhase()), right = rank(rhs.displayPhase())
                if left != right { return left < right }
                return (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
            }
    }

    private func rank(_ phase: SessionPhase) -> Int {
        switch phase {
        case .running: return 0
        case .attention: return 1
        case .stale: return 2
        case .unknown: return 3
        case .interrupted: return 4
        case .completed: return 5
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if isDemo { snapshot = DemoData.snapshot(); return }
        let home = URL(fileURLWithPath: NSString(string: codexHome).expandingTildeInPath)
        let previous = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let next = await scanner.scan(home: home)
        snapshot = next
        guard notifyOnFinish else { return }
        for session in next.sessions where session.phase == .completed {
            guard previous[session.id]?.phase == .running,
                  let finished = session.stateChangedAt, Date().timeIntervalSince(finished) < 60 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Codex turn finished"
            content.body = session.projectName
            content.sound = .default
            let request = UNNotificationRequest(identifier: "\(session.id)-\(session.activeTurnID ?? "turn")",
                                                content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func applyHome(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        codexHome = NSString(string: trimmed).expandingTildeInPath
        UserDefaults.standard.set(codexHome, forKey: "codexHome")
        Task { await refresh() }
    }

    func setNotifications(_ enabled: Bool) {
        notificationIssue = nil
        if !enabled {
            notifyOnFinish = false
            UserDefaults.standard.set(false, forKey: "notifyOnFinish")
            return
        }
        guard Bundle.main.bundleIdentifier != nil else {
            notificationIssue = "Notifications are available in the bundled .app."
            return
        }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notifyOnFinish = granted
                UserDefaults.standard.set(granted, forKey: "notifyOnFinish")
                if !granted { notificationIssue = "Notifications are disabled in macOS Settings." }
            } catch { notificationIssue = "Notification permission could not be requested." }
        }
    }
}
