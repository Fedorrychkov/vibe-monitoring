import AppKit
import SwiftUI
import VibeMonitoringCore

@main
struct VibeMonitoringApp: App {
    @StateObject private var store: MonitorStore
    @ObservedObject private var vpn: VPNStore

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--vpn-diagnostics") {
            let checkNetwork = CommandLine.arguments.contains("--network-check")
            DispatchQueue.global().asyncAfter(deadline: .now() + (checkNetwork ? 20 : 10)) {
                fputs("Read-only diagnostics timed out.\n", stderr); exit(1)
            }
            Task {
                do {
                    let data = try await VPNReadOnlyDiagnostics.collect(checkNetwork: checkNetwork)
                    print(String(decoding: data, as: UTF8.self)); exit(0)
                } catch {
                    fputs("Read-only diagnostics unavailable (code \((error as NSError).code)).\n", stderr); exit(1)
                }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--check-vpn-storage") {
            Task {
                do {
                    try await VPNCredentialClient.probeStorage()
                    print("VPN credential storage check passed. No tunnel was started or VPN preferences changed.")
                    exit(0)
                } catch {
                    fputs("\(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            dispatchMain()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-demo"),
           CommandLine.arguments.indices.contains(index + 1) {
            do {
                try DemoPreview.write(to: CommandLine.arguments[index + 1])
                exit(0)
            } catch {
                fputs("Demo preview could not be rendered.\n", stderr)
                exit(1)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-worktrees-demo"),
           CommandLine.arguments.indices.contains(index + 1) {
            do {
                try DemoPreview.writeWorktrees(to: CommandLine.arguments[index + 1])
                exit(0)
            } catch {
                fputs("Worktree demo preview could not be rendered.\n", stderr)
                exit(1)
            }
        }
        let monitor = MonitorStore(demo: CommandLine.arguments.contains("--demo"))
        _store = StateObject(wrappedValue: monitor)
        _vpn = ObservedObject(wrappedValue: monitor.vpn)
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: store, popover: true)
        } label: {
            Image(nsImage: VPNMenuIcon.make(vpn.state)).renderingMode(.original)
                .accessibilityLabel(vpn.statusTitle).help(vpn.statusTitle)
            Text([vpn.traffic?.title, store.snapshot.activeCount() > 0 ? "\(store.snapshot.activeCount())" : nil]
                .compactMap { $0 }.joined(separator: " · ")).monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        Window("VibeMonitoring", id: "dashboard") {
            DashboardView(store: store)
        }.defaultSize(width: 520, height: 760)

        Window("Agent worktrees", id: "worktrees") {
            WorktreesView(store: store.worktrees, monitor: store)
        }.defaultSize(width: 700, height: 760)

        Window("VibeMonitoring Settings", id: "preferences") {
            PreferencesView(store: store, worktrees: store.worktrees)
        }.windowResizability(.contentSize)
    }
}
