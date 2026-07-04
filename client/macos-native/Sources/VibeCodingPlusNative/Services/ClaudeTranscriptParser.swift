import Foundation

/// State extracted from `~/.claude/projects/**/*.jsonl` (read-only observation).
struct ClaudeTranscriptSnapshot: Equatable {
    var sessionId: String = ""
    var cwd: String = ""
    var lastUserPrompt: String = ""
    var lastAssistantMessage: String = ""
    var currentTool: String = ""
    var updatedAt: Date?
}

enum ClaudeTranscriptParser {

    private static let maxAge: TimeInterval = 24 * 60 * 60
    private static let maxFiles = 40
    private static let chunkSize = 64 * 1024

    static func projectsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func discoverLatest(cwdFilter: String? = nil) -> ClaudeTranscriptSnapshot? {
        let files = recentTranscriptFiles()
        guard !files.isEmpty else { return nil }

        let normalizedCwd = cwdFilter?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var best: (snapshot: ClaudeTranscriptSnapshot, date: Date)?
        for file in files {
            guard let snapshot = snapshot(from: file) else { continue }
            if let normalizedCwd, !normalizedCwd.isEmpty {
                let snapshotCwd = snapshot.cwd
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !snapshotCwd.isEmpty, snapshotCwd != normalizedCwd {
                    continue
                }
            }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.date {
                best = (snapshot, date)
            }
        }
        return best?.snapshot
    }

    static func snapshot(from url: URL) -> ClaudeTranscriptSnapshot? {
        guard let lines = streamLines(from: url), !lines.isEmpty else { return nil }
        var snapshot = ClaudeTranscriptSnapshot()
        for line in lines {
            apply(line: line, to: &snapshot)
        }
        return snapshot.sessionId.isEmpty && snapshot.lastAssistantMessage.isEmpty ? nil : snapshot
    }

    static func apply(line: String, to snapshot: inout ClaudeTranscriptSnapshot) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let sid = object["sessionId"] as? String, !sid.isEmpty {
            snapshot.sessionId = sid
        }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty {
            snapshot.cwd = cwd
        }
        if let timestamp = object["timestamp"] as? String {
            snapshot.updatedAt = ISO8601DateFormatter().date(from: timestamp)
        }

        if object["type"] as? String == "summary",
           let summary = object["summary"] as? String, !summary.isEmpty {
            snapshot.lastAssistantMessage = summary
            return
        }

        guard let message = object["message"] as? [String: Any],
              let role = message["role"] as? String else {
            return
        }

        let parsed = parseMessageContent(message["content"])
        if let tool = parsed.tool {
            snapshot.currentTool = tool
        }
        guard !parsed.text.isEmpty else { return }
        if role == "user" {
            snapshot.lastUserPrompt = parsed.text
        } else if role == "assistant" {
            snapshot.lastAssistantMessage = parsed.text
        }
    }

    // MARK: - Private

    private static func recentTranscriptFiles() -> [URL] {
        let root = projectsRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-maxAge)
        var files: [URL] = []
        for case let file as URL in enumerator {
            if file.pathExtension != "jsonl" { continue }
            if file.path.contains("/subagents/") { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < cutoff { continue }
            files.append(file)
        }
        files.sort { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }
        return Array(files.prefix(maxFiles))
    }

    private static func streamLines(from url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var lines: [String] = []
        var carry = Data()
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            carry.append(chunk)
            while let range = carry.firstRange(of: Data([0x0A])) {
                let lineData = carry.subdata(in: 0..<range.lowerBound)
                carry.removeSubrange(0...range.lowerBound)
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
            }
        }
        if !carry.isEmpty, let line = String(data: carry, encoding: .utf8) {
            lines.append(line)
        }
        return lines
    }

    private struct ParsedMessageContent {
        var text: String = ""
        var tool: String?
    }

    private static func parseMessageContent(_ content: Any?) -> ParsedMessageContent {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedMessageContent(text: trimmed)
        }
        guard let blocks = content as? [[String: Any]] else { return ParsedMessageContent() }
        var parts: [String] = []
        var tool: String?
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    parts.append(text)
                }
            case "tool_use":
                tool = block["name"] as? String ?? tool
            default:
                break
            }
        }
        return ParsedMessageContent(
            text: parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            tool: tool
        )
    }
}
