import Foundation

public actor CodexScanner {
    private struct Cursor {
        var session: CodexSession
        var offset: UInt64
        var modified: Date
        var inode: UInt64
        var framer: LineFramer
    }

    private var cursors: [URL: Cursor] = [:]
    private var currentHome: URL?
    private let parser = JournalParser()
    private let tailBytes: Int
    private let maximumFiles: Int
    private let fileManager = FileManager.default

    public init(tailBytes: Int = 2 * 1024 * 1024, maximumFiles: Int = 40) {
        self.tailBytes = max(1024, tailBytes)
        self.maximumFiles = max(1, maximumFiles)
    }

    public static func defaultHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public func scan(home: URL) -> ScanSnapshot {
        if home != currentHome {
            cursors.removeAll()
            currentHome = home
        }
        let directory = home.appendingPathComponent("sessions")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ScanSnapshot(issue: "No sessions directory. Choose your Codex home in Settings.")
        }

        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in enumerationFailed = true; return true }
        ) else { return ScanSnapshot(issue: "The Codex sessions directory could not be read.") }

        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        candidates.sort { $0.1 > $1.1 }
        let selected = Array(candidates.prefix(maximumFiles))
        let selectedURLs = Set(selected.map(\.0))
        cursors = cursors.filter { selectedURLs.contains($0.key) }
        var errors = enumerationFailed ? 1 : 0

        for (url, _) in selected {
            do { try update(url) } catch { errors += 1 }
        }
        let sessions = selected.compactMap { cursors[$0.0]?.session }
        let issue = errors == 0 ? nil : "Some local journals could not be read. Their last known data may be stale."
        return ScanSnapshot(sessions: sessions, issue: issue)
    }

    private func update(_ url: URL) throws {
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
            var session = CodexSession(id: url.deletingPathExtension().lastPathComponent)
            try handle.seek(toOffset: 0)
            let header = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if let newline = header.firstIndex(of: 10) {
                parser.apply(Data(header[..<newline]), to: &session)
            }
            let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            try handle.seek(toOffset: start)
            cursor = Cursor(session: session, offset: start, modified: modified, inode: inode,
                            framer: LineFramer())
            cursor.session.isPartialHistory = start > 0
            if start > 0 {
                // Starting in a JSON line must not turn a fragment into an event.
                let prefix = try handle.read(upToCount: tailBytes) ?? Data()
                if let newline = prefix.firstIndex(of: 10) {
                    let complete = Data(prefix[prefix.index(after: newline)...])
                    cursor.framer.consume(complete) { parser.apply($0, to: &cursor.session) }
                }
                cursor.offset = try handle.offset()
                cursors[url] = cursor
                return
            }
        }
        let data = try handle.read(upToCount: tailBytes) ?? Data()
        cursor.framer.consume(data) { parser.apply($0, to: &cursor.session) }
        cursor.offset = try handle.offset()
        cursor.modified = modified
        cursors[url] = cursor
    }
}
