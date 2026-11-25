import Foundation

/// How one agent's local JSONL transcripts are found and interpreted.
public protocol JournalFormat: Sendable {
    associatedtype State: Sendable
    var agent: AgentKind { get }
    /// Directory enumerated below `home`.
    func root(home: URL) -> URL
    var missingIssue: String { get }
    /// Path components below `root`, ending with the file name.
    func includes(_ components: [String]) -> Bool
    /// Whether a directory below `root` can contain session files; pruning keeps 2-second polling cheap.
    func descends(into components: [String]) -> Bool
    func makeSession(for file: URL, components: [String]) -> CodexSession
    func initialState() -> State
    /// The first line is applied before a bounded tail is read (Codex keeps session metadata there).
    var readsHeader: Bool { get }
    func apply(_ line: Data, to session: inout CodexSession, state: inout State)
    /// Reverse scan used when the file is larger than the tail: nil skips a line; `true` stops at the turn start.
    func turnEvent(in line: Data) -> Bool?
    /// Called on every scan, also for unchanged files, so time-derived state stays current.
    func refresh(_ session: inout CodexSession, state: State, modified: Date, now: Date)
}

public extension JournalFormat {
    func descends(into components: [String]) -> Bool { true }
    var readsHeader: Bool { false }
    func turnEvent(in line: Data) -> Bool? { nil }
    func refresh(_ session: inout CodexSession, state: State, modified: Date, now: Date) {}
}

public actor JournalScanner<Format: JournalFormat> {
    private struct Cursor {
        var session: CodexSession
        var state: Format.State
        var offset: UInt64
        var modified: Date
        var inode: UInt64
        var framer: LineFramer
    }

    public nonisolated let format: Format
    private var cursors: [URL: Cursor] = [:]
    private var currentHome: URL?
    private let tailBytes: Int
    private let maximumFiles: Int
    private let fileManager = FileManager.default

    public init(format: Format, tailBytes: Int = 2 * 1024 * 1024, maximumFiles: Int = 40) {
        self.format = format
        self.tailBytes = max(1024, tailBytes)
        self.maximumFiles = max(1, maximumFiles)
    }

    public func scan(home: URL, now: Date = Date()) -> ScanSnapshot {
        if home != currentHome {
            cursors.removeAll()
            currentHome = home
        }
        let directory = format.root(home: home).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ScanSnapshot(issue: format.missingIssue, unavailable: [format.agent])
        }

        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in enumerationFailed = true; return true }
        ) else { return ScanSnapshot(issue: "The \(format.agent.title) journal directory could not be read.") }

        let base = directory.pathComponents.count
        var candidates: [(URL, Date, [String])] = []
        for case let url as URL in enumerator {
            let components = Array(url.standardizedFileURL.pathComponents.dropFirst(base))
            if url.pathExtension != "jsonl" {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                   !format.descends(into: components) { enumerator.skipDescendants() }
                continue
            }
            guard format.includes(components),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast, components))
        }
        candidates.sort { $0.1 > $1.1 }
        let selected = Array(candidates.prefix(maximumFiles))
        let selectedURLs = Set(selected.map(\.0))
        cursors = cursors.filter { selectedURLs.contains($0.key) }
        var errors = enumerationFailed ? 1 : 0

        for (url, _, components) in selected {
            do { try update(url, components: components) } catch { errors += 1 }
        }
        let sessions = selected.compactMap { entry -> CodexSession? in
            guard let cursor = cursors[entry.0] else { return nil }
            var session = cursor.session
            format.refresh(&session, state: cursor.state, modified: cursor.modified, now: now)
            return session
        }
        let issue = errors == 0 ? nil : "Some local \(format.agent.title) journals could not be read. Their last known data may be stale."
        return ScanSnapshot(sessions: sessions, issue: issue)
    }

    private func update(_ url: URL, components: [String]) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let previous = cursors[url]
        if let previous, previous.offset == size, previous.modified == modified, previous.inode == inode { return }

        let canAppend = previous.map {
            $0.inode == inode && size > $0.offset && size - $0.offset <= UInt64(tailBytes)
        } ?? false
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var cursor: Cursor
        if canAppend, let previous {
            cursor = previous
            try handle.seek(toOffset: previous.offset)
        } else {
            var session = format.makeSession(for: url, components: components)
            var state = format.initialState()
            let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            if format.readsHeader {
                try handle.seek(toOffset: 0)
                let header = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if let newline = header.firstIndex(of: 10) {
                    format.apply(Data(header[..<newline]), to: &session, state: &state)
                }
            }
            if start > 0 {
                // Starting in a JSON line must not turn a fragment into an event.
                try handle.seek(toOffset: start)
                let prefix = try handle.read(upToCount: tailBytes) ?? Data()
                let end = try handle.offset()
                let skipped = prefix.firstIndex(of: 10).map { prefix.distance(from: prefix.startIndex, to: $0) + 1 } ?? prefix.count
                // A long active turn can begin well before the token/activity tail. The reverse scan stops
                // where the tail starts, so no line is applied twice (Claude usage is additive).
                for event in try latestTurnEvents(in: handle, before: start + UInt64(skipped)) {
                    format.apply(event, to: &session, state: &state)
                }
                cursor = Cursor(session: session, state: state, offset: end, modified: modified, inode: inode,
                                framer: LineFramer())
                cursor.session.isPartialHistory = true
                cursor.framer.consume(Data(prefix.dropFirst(skipped))) { format.apply($0, to: &cursor.session, state: &cursor.state) }
                cursors[url] = cursor
                return
            }
            try handle.seek(toOffset: 0)
            cursor = Cursor(session: session, state: state, offset: 0, modified: modified, inode: inode,
                            framer: LineFramer())
            cursor.session.isPartialHistory = false
        }
        let data = try handle.read(upToCount: tailBytes) ?? Data()
        cursor.framer.consume(data) { format.apply($0, to: &cursor.session, state: &cursor.state) }
        cursor.offset = try handle.offset()
        cursor.modified = modified
        cursors[url] = cursor
    }

    /// Turn events that precede the tail, oldest first, back to the latest turn start.
    private func latestTurnEvents(in handle: FileHandle, before offset: UInt64) throws -> [Data] {
        var events: [Data] = []
        try ReverseJournalReader.read(in: handle, before: offset) { line in
            guard let isStart = format.turnEvent(in: line) else { return true }
            events.append(line)
            return !isStart
        }
        return events.reversed()
    }
}

public struct CodexJournalFormat: JournalFormat {
    private let parser = JournalParser()
    public init() {}
    public var agent: AgentKind { .codex }
    public func root(home: URL) -> URL { home.appendingPathComponent("sessions") }
    public var missingIssue: String { "No sessions directory. Choose your Codex home in Settings." }
    public func includes(_ components: [String]) -> Bool { true }
    public func makeSession(for file: URL, components: [String]) -> CodexSession {
        CodexSession(id: file.deletingPathExtension().lastPathComponent, agent: .codex)
    }
    public func initialState() {}
    public var readsHeader: Bool { true }
    public func apply(_ line: Data, to session: inout CodexSession, state: inout Void) { parser.apply(line, to: &session) }
    public func turnEvent(in line: Data) -> Bool? {
        parser.turnEventType(in: line).map { $0 == "task_started" }
    }

    public static func defaultHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
}

public typealias CodexScanner = JournalScanner<CodexJournalFormat>

public extension JournalScanner where Format == CodexJournalFormat {
    init(tailBytes: Int = 2 * 1024 * 1024, maximumFiles: Int = 40) {
        self.init(format: CodexJournalFormat(), tailBytes: tailBytes, maximumFiles: maximumFiles)
    }

    static func defaultHome() -> URL { CodexJournalFormat.defaultHome() }
}
