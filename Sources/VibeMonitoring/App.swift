import AppKit
import SwiftUI

@main
struct VibeMonitoringApp: App {
    @StateObject private var store: MonitorStore

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
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
        _store = StateObject(wrappedValue: MonitorStore(demo: CommandLine.arguments.contains("--demo")))
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: store, popover: true)
        } label: {
            Image(systemName: "waveform.path.ecg")
            if store.snapshot.activeCount() > 0 { Text("\(store.snapshot.activeCount())") }
        }
        .menuBarExtraStyle(.window)

        Window("VibeMonitoring", id: "dashboard") {
            DashboardView(store: store)
        }.defaultSize(width: 520, height: 760)

        Window("VibeMonitoring Settings", id: "preferences") {
            PreferencesView(store: store)
        }.windowResizability(.contentSize)
    }
}
