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
                Text("Codex monitoring is local and requires no account. If you connect Quickping, the app contacts only your chosen server for authorization and read-only monitoring. Codex journals and conversation content are never uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            QuickpingPreferencesView(store: store.quickping)
        }
        .formStyle(.grouped).padding(12).frame(width: 570, height: 610)
        .onAppear { path = store.codexHome }
        .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { path = url.path; store.applyHome(path) }
        }
    }
}
