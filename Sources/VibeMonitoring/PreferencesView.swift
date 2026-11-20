import SwiftUI
import UniformTypeIdentifiers
import VibeMonitoringCore

struct PreferencesView: View {
    @ObservedObject var store: MonitorStore
    @State private var path = ""
    @State private var choosingDirectory = false

    var body: some View {
        Form {
            Section("Codex") {
                TextField("Codex home", text: $path).onSubmit { store.applyHome(path) }
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Choose folder…") { choosingDirectory = true }
                    Button("Apply") { store.applyHome(path) }
                    Button("Use default") { path = CodexScanner.defaultHome().path; store.applyHome(path) }
                }
                Text("Choose the directory containing sessions/, normally ~/.codex. Only recent journal tails are read; unchanged files are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Notify when an observed active turn finishes", isOn: Binding(
                    get: { store.notifyOnFinish }, set: { store.setNotifications($0) }
                ))
                if let issue = store.notificationIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            }
            Section("Privacy") {
                Text("No accounts or API keys are required. VibeMonitoring makes no network requests, does not change Codex settings, and does not store or upload conversation content.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(12).frame(width: 530, height: 380)
        .onAppear { path = store.codexHome }
        .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { path = url.path; store.applyHome(path) }
        }
    }
}
