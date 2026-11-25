import AppKit

@MainActor
enum VPNActionConfirmation {
    static func perform(_ title: String, direct: Bool = false, warning: String? = nil, activeTurns: Int, action: () -> Void) {
        let applications = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier?.lowercased() else { return false }
            return ["chrome", "safari", "firefox", "brave", "opera", "edge", "terminal", "iterm", "warp", "cursor", "vscode", "xcode", "codex", "claude", "jetbrains"].contains { id.contains($0) }
        }.compactMap(\.localizedName)
        guard direct || warning != nil || activeTurns > 0 || !applications.isEmpty else { action(); return }
        let alert = NSAlert()
        alert.messageText = title
        var text = direct ? "This removes our VPN profile and disables our network filter. Your subscription stays saved. Wait for confirmation before starting Happ or another VPN. Direct Internet can expose your real IP; existing connections may reconnect outside our VPN." : "This changes network access. Open connections may pause or reconnect."
        if let warning { text += "\n" + warning }
        if activeTurns > 0 { text += "\nObserved active agent turns: \(activeTurns)." }
        if !applications.isEmpty { text += "\nOpen apps: " + Array(Set(applications)).sorted().joined(separator: ", ") + "." }
        text += "\nThis is a local app list, not a complete inventory of background network activity."
        alert.informativeText = text
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: title)
        alert.alertStyle = .warning
        if alert.runModal() == .alertSecondButtonReturn { action() }
    }
}
