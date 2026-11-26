import Foundation

/// The latest usage-limit report seen for one agent. Values are what the agent itself last reported
/// locally; nothing here calls a provider API.
public struct AgentLimitReport: Identifiable, Sendable {
    public var agent: AgentKind
    public var windows: [UsageWindow]
    public var observedAt: Date?
    public var plan: String?

    public init(agent: AgentKind, windows: [UsageWindow], observedAt: Date?, plan: String? = nil) {
        self.agent = agent
        self.windows = windows
        self.observedAt = observedAt
        self.plan = plan
    }

    public var id: String { agent.rawValue }
}

public enum AgentLimits {
    /// Codex writes `rate_limits` into its journals; the most recently observed session wins.
    public static func codex(from sessions: [CodexSession]) -> AgentLimitReport? {
        let latest = sessions.filter { $0.agent == .codex && $0.limitsObservedAt != nil }
            .max { ($0.limitsObservedAt ?? .distantPast) < ($1.limitsObservedAt ?? .distantPast) }
        guard let latest else { return nil }
        let windows = [latest.primaryWindow, latest.secondaryWindow].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return AgentLimitReport(agent: .codex, windows: windows, observedAt: latest.limitsObservedAt, plan: latest.plan)
    }

    /// Parses the JSON that Claude Code passes to a status line command; only `rate_limits` is read.
    public static func claude(statusLine data: Data, observedAt: Date?) -> AgentLimitReport? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any] else { return nil }
        let known: [(String, Int?, String?)] = [("five_hour", 300, nil), ("seven_day", 10_080, nil), ("spend_limit", nil, "Spend limit")]
        let windows = known.compactMap { key, minutes, label -> UsageWindow? in
            guard let value = limits[key] as? [String: Any], let used = number(value["used_percentage"]) else { return nil }
            let reset = number(value["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(usedPercent: used, minutes: minutes, resetsAt: reset, label: label)
        }
        return windows.isEmpty ? nil : AgentLimitReport(agent: .claude, windows: windows, observedAt: observedAt)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }
}

/// Installs a small status line command into Claude Code that saves its input (which carries `rate_limits`)
/// for VibeMonitoring. An existing status line command keeps running and its output is still shown.
public struct ClaudeStatusLineBridge: Sendable {
    public enum BridgeError: LocalizedError {
        case unreadableSettings
        public var errorDescription: String? {
            "Claude Code settings.json could not be parsed. It was not changed."
        }
    }

    public let claudeHome: URL
    public let supportDirectory: URL

    public init(claudeHome: URL = ClaudeJournalFormat.defaultHome(), supportDirectory: URL = ClaudeStatusLineBridge.defaultSupportDirectory()) {
        self.claudeHome = claudeHome
        self.supportDirectory = supportDirectory
    }

    public static func defaultSupportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VibeMonitoring")
    }

    /// Resolved so a symlinked settings.json (dotfiles) is updated in place rather than replaced.
    public var settingsURL: URL { claudeHome.appendingPathComponent("settings.json").resolvingSymlinksInPath() }
    public var scriptURL: URL { supportDirectory.appendingPathComponent("claude-statusline.sh") }
    public var previousCommandURL: URL { supportDirectory.appendingPathComponent("claude-statusline-previous.sh") }
    public var reportURL: URL { supportDirectory.appendingPathComponent("claude-statusline.json") }
    public var backupURL: URL { claudeHome.appendingPathComponent("settings.json.vibemonitoring-backup") }

    public var command: String { "sh \(Self.shellQuoted(scriptURL.path))" }

    public var isInstalled: Bool {
        (try? statusLine(in: loadSettings()))?["command"] as? String == command
    }

    public func latestReport() -> AgentLimitReport? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: reportURL.path))?[.modificationDate] as? Date
        return AgentLimits.claude(statusLine: data, observedAt: modified)
    }

    /// The status line command currently configured by the user, if any (and not the bridge itself).
    public func existingCommand() -> String? {
        guard let line = try? statusLine(in: loadSettings()), let current = line["command"] as? String,
              current != command, !current.isEmpty else { return nil }
        return current
    }

    public func install() throws {
        var settings = try loadSettings()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        var line = statusLine(in: settings) ?? [:]
        if let current = line["command"] as? String, current != command, !current.isEmpty {
            try current.appending("\n").write(to: previousCommandURL, atomically: true, encoding: .utf8)
        } else if line["command"] as? String != command {
            try? fileManager.removeItem(at: previousCommandURL)
        }
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        if fileManager.fileExists(atPath: settingsURL.path) {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: settingsURL, to: backupURL)
        } else {
            try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        }
        line["type"] = "command"
        line["command"] = command
        settings["statusLine"] = line
        try save(settings)
    }

    /// Rewrites an installed bridge script that was written by an older version of the app.
    public func updateScriptIfInstalled() {
        guard isInstalled, (try? String(contentsOf: scriptURL, encoding: .utf8)) != script else { return }
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    /// Restores the previous status line command (or removes the entry) and deletes the bridge files.
    public func uninstall() throws {
        var settings = try loadSettings()
        if var line = statusLine(in: settings), line["command"] as? String == command {
            if let previous = try? String(contentsOf: previousCommandURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty {
                line["command"] = previous
                settings["statusLine"] = line
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            try save(settings)
        }
        for url in [scriptURL, previousCommandURL, reportURL] { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Private

    /// Saves stdin only when it carries rate limits (API-key sessions have none), then hands it to the previous
    /// status line command so its output is unchanged.
    var script: String {
        let directory = Self.shellQuoted(supportDirectory.path)
        return """
        #!/bin/sh
        # VibeMonitoring: saves Claude Code's status line input (it includes rate_limits) for the menu bar app.
        # Remove from VibeMonitoring Settings › Limits; the previous status line command is restored.
        dir=\(directory)
        input=$(cat)
        case "$input" in
          *'"rate_limits"'*)
            # A unique temp file per run: parallel Claude Code sessions never share one, and rename is atomic.
            # A failure here must not skip the previous status line below.
            if tmp=$(mktemp "$dir/.claude-statusline.XXXXXX"); then
              if printf '%s' "$input" > "$tmp" && mv -f "$tmp" "$dir/claude-statusline.json"; then :; else rm -f "$tmp"; fi
            fi
            ;;
        esac
        if [ -f "$dir/claude-statusline-previous.sh" ]; then
          printf '%s' "$input" | sh "$dir/claude-statusline-previous.sh"
        fi

        """
    }

    private func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.unreadableSettings }
        return object
    }

    private func statusLine(in settings: [String: Any]) -> [String: Any]? {
        settings["statusLine"] as? [String: Any]
    }

    private func save(_ settings: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: settingsURL, options: .atomic)
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
